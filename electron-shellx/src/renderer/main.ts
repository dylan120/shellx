import { FitAddon } from "@xterm/addon-fit";
import { Terminal } from "@xterm/xterm";
import type {
  AppSettings,
  AppSnapshot,
  AppUpdateProgress,
  BatchExecutionResult,
  CreateTerminalRequest,
  RemoteNetworkForwarding,
  ScriptFolder,
  ScriptLanguage,
  ScriptLibrary,
  SessionFolder,
  SessionWorkspace,
  SSHAuthMethod,
  SSHSessionProfile,
  UserScript
} from "../shared/terminal";
import "./styles.css";

interface TerminalTab {
  id: string;
  title: string;
  subtitle: string;
  request: CreateTerminalRequest;
  terminal: Terminal;
  fitAddon: FitAddon;
  pane: HTMLDivElement;
  disposeData: () => void;
  disposeExit: () => void;
  disposeZmodem: () => void;
  connecting: boolean;
  exited: boolean;
  pinned: boolean;
  unread: boolean;
  attention: "normal" | "prompt" | "error";
  recentOutput: string;
  passwordAutofillAttempted: boolean;
  passwordPromptPending: boolean;
  zmodemActive: boolean;
  zmodemHandled: boolean;
  transferMessage: string;
  lastPtyCols: number;
  lastPtyRows: number;
  lastFitPaneWidth: number;
  lastFitPaneHeight: number;
}

type ViewMode = "terminal" | "detail";

const tabs = new Map<string, TerminalTab>();
let activeTabID: string | null = null;
let snapshot: AppSnapshot;
let selectedFolderID: string | null = null;
let selectedSessionID: string | null = null;
let selectedScriptID: string | null = null;
let selectedScriptFolderID: string | null = null;
let viewMode: ViewMode = "terminal";
let searchText = "";
let rootExpanded = true;
let statusMessage = "Ready";
let statusSpinning = false;
let statusClearTimer: number | undefined;
const expandedFolderIDs = new Set<string>();
const expandedScriptFolderIDs = new Set<string>();
const sidebarCollapsedStorageKey = "shellx.sidebarCollapsed";
const sidebarWidthStorageKey = "shellx.sidebarWidth";
const sidebarMinWidth = 240;
const sidebarMaxWidth = 520;
const sidebarCollapsedWidth = 0;
const terminalMinimumRightReservePixels = 36;
const terminalScrollbarTextGapPixels = 12;
const terminalPtyRightGuardColumns = 1;
const terminalLineHeight = 1;
const terminalTheme = {
  background: "#0c0f11",
  foreground: "#e7ecef",
  cursor: "#f2c66d",
  cursorAccent: "#0c0f11",
  selectionBackground: "#31524e",
  selectionForeground: "#f4fbfa",
  selectionInactiveBackground: "#263a38",
  black: "#000000",
  red: "#cc4b4c",
  green: "#4f9f6f",
  yellow: "#c49a46",
  blue: "#4d82c8",
  magenta: "#b06ac8",
  cyan: "#4aa6a6",
  white: "#ffffff",
  brightBlack: "#5f6a6a",
  brightRed: "#e06c6d",
  brightGreen: "#6fbd8a",
  brightYellow: "#e0b85c",
  brightBlue: "#6fa3e6",
  brightMagenta: "#c989e2",
  brightCyan: "#69c7c7",
  brightWhite: "#ffffff"
};
const sessionDoubleClickIntervalMs = 1200;
const sessionSingleClickDelayMs = 320;
let sidebarCollapsed = localStorage.getItem(sidebarCollapsedStorageKey) === "true";
let sidebarWidth = clampSidebarWidth(Number(localStorage.getItem(sidebarWidthStorageKey)) || 300);
let windowFullScreen = false;
let lastSessionClick: { id: string; at: number } | null = null;
let pendingSessionClickRenderTimer: number | undefined;
let suppressNextSessionClickID: string | null = null;
let terminalFitFrame: number | undefined;
let selectionClipboardTimer: number | undefined;
let selectionClipboardSerial = 0;

interface AppCommandEvent {
  command: string;
  payload?: Record<string, unknown>;
}

const appRoot = document.querySelector<HTMLDivElement>("#app")!;
if (!appRoot) throw new Error("Missing app root");

const now = () => new Date().toISOString();
const uid = () => crypto.randomUUID();

function setWindowFullScreen(value: boolean): void {
  windowFullScreen = value;
  document.documentElement.dataset.windowFullscreen = value ? "true" : "false";
  scheduleActiveTerminalFitAfterLayout();
}
const text = (value: unknown) => String(value ?? "");
const cleanTags = (value: string) => Array.from(new Set(value.split(/[，,\n]/).map((item) => item.trim()).filter(Boolean))).slice(0, 12);
const passwordPromptPattern = /(?:^|[\r\n\s])(?:password|passphrase)(?:\s+for\s+[^:]+)?:\s*$/i;
const zmodemStartMarker = "**\x18B0";
const zmodemPattern = /\*\*\x18B0/;
const zmodemUploadFramePattern = /\*\*\x18B01/;
const zmodemDownloadFramePattern = /\*\*\x18B00/;
const zmodemDownloadAutoStartPattern = /rz\r?\n?\*\*\x18B00/;
const zmodemUploadHintPattern = /(?:rz\s+(?:waiting|ready|receive)|waiting\s+to\s+receive|receive\s+zmodem)/i;
const rzWaitingLinePattern = /(?:^|[\r\n])[^\r\n]*(?:rz\s+)?waiting\s+to\s+receive\.[^\r\n]*/i;

function keychainAccount(session: SSHSessionProfile): string {
  return `${session.username.trim() || "default"}@${session.host.trim()}:${session.port || 22}`;
}

const defaultForwarding = (): RemoteNetworkForwarding => ({
  isEnabled: false,
  mode: "dynamicSOCKS",
  bindAddress: "127.0.0.1",
  port: 1080,
  localProxyHost: "127.0.0.1",
  localProxyPort: 7890,
  remoteProxyScheme: "socks5h",
  setProxyEnvironment: false
});

function newSession(folderID?: string): SSHSessionProfile {
  const timestamp = now();
  return {
    id: uid(),
    folderID,
    name: "新建会话",
    host: "",
    port: 22,
    username: "",
    authMethod: "agent",
    privateKeyPath: "",
    passwordStoredInKeychain: false,
    useKeychainForPrivateKey: false,
    remoteNetworkForwarding: defaultForwarding(),
    startupCommand: "",
    tags: [],
    createdAt: timestamp,
    updatedAt: timestamp
  };
}

function newScript(folderID?: string): UserScript {
  const timestamp = now();
  return { id: uid(), folderID, name: "新建脚本", content: "#!/bin/sh\n", language: "shell", createdAt: timestamp, updatedAt: timestamp };
}

function normalizeScriptLibrary(library: Partial<ScriptLibrary> | null | undefined): ScriptLibrary {
  return { folders: library?.folders ?? [], scripts: library?.scripts ?? [] };
}

function sessionTitle(session: SSHSessionProfile): string {
  return session.name.trim() || session.host.trim() || "未命名会话";
}

async function persistWorkspace(): Promise<void> {
  await window.shellx.app.saveWorkspace(snapshot.workspace);
  render();
}

async function persistScripts(): Promise<void> {
  snapshot.scriptLibrary = normalizeScriptLibrary(snapshot.scriptLibrary);
  await window.shellx.app.saveScripts(snapshot.scriptLibrary);
  render();
}

async function persistSettings(): Promise<void> {
  await window.shellx.app.saveSettings(snapshot.settings);
  render();
}

function setStatus(message: string, spinning = false, autoClear = false): void {
  if (statusClearTimer) window.clearTimeout(statusClearTimer);
  statusMessage = message;
  statusSpinning = spinning;
  updateStatusbar();
  if (autoClear && !spinning) {
    statusClearTimer = window.setTimeout(() => restoreActiveStatus(), 4200);
  }
}

function restoreActiveStatus(): void {
  statusClearTimer = undefined;
  const active = activeTabID ? tabs.get(activeTabID) : undefined;
  statusMessage = defaultStatusForTab(active);
  statusSpinning = Boolean((active?.connecting || active?.zmodemActive) && !active.exited);
  updateStatusbar();
}

function defaultStatusForTab(tab?: TerminalTab): string {
  if (!tab) return "Ready";
  if (tab.exited) return "Process exited";
  if (tab.zmodemActive && tab.transferMessage) return tab.transferMessage;
  if (tab.connecting) return "连接中";
  return tab.request.kind === "ssh" ? "已连接" : "本机终端";
}

function clampSidebarWidth(width: number): number {
  return Math.min(sidebarMaxWidth, Math.max(sidebarMinWidth, Math.round(width)));
}

function currentSidebarWidth(): number {
  return sidebarCollapsed ? sidebarCollapsedWidth : sidebarWidth;
}

function applySidebarWidth(): void {
  document.querySelector<HTMLElement>(".shell")?.style.setProperty("--sidebar-width", `${currentSidebarWidth()}px`);
}

function setSidebarCollapsed(collapsed: boolean): void {
  if (sidebarCollapsed === collapsed) return;
  sidebarCollapsed = collapsed;
  localStorage.setItem(sidebarCollapsedStorageKey, String(sidebarCollapsed));
  render();
  scheduleActiveTerminalFitAfterLayout();
}

function bindPressAction(element: HTMLElement | null, action: () => void): void {
  if (!element) return;
  element.addEventListener("pointerdown", (event) => {
    if (event.button !== 0) return;
    event.preventDefault();
    event.stopPropagation();
    action();
  });
  element.addEventListener("click", (event) => {
    event.preventDefault();
    event.stopPropagation();
  });
  element.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" && event.key !== " ") return;
    event.preventDefault();
    event.stopPropagation();
    action();
  });
}

function fitAndSyncTerminal(tab: TerminalTab): void {
  if (!tab.pane.isConnected || !tab.pane.classList.contains("active") || tab.pane.clientWidth <= 0 || tab.pane.clientHeight <= 0) return;
  const paneWidth = Math.round(tab.pane.clientWidth);
  const paneHeight = Math.round(tab.pane.clientHeight);
  if (tab.lastFitPaneWidth === paneWidth && tab.lastFitPaneHeight === paneHeight) return;
  tab.lastFitPaneWidth = paneWidth;
  tab.lastFitPaneHeight = paneHeight;
  resizeTerminalToFit(tab.terminal, tab.fitAddon);
  syncTerminalPtySize(tab);
}

function fitActiveTerminal(): void {
  const active = activeTabID ? tabs.get(activeTabID) : undefined;
  if (!active) return;
  fitAndSyncTerminal(active);
}

function scheduleActiveTerminalFit(): void {
  if (terminalFitFrame) window.cancelAnimationFrame(terminalFitFrame);
  terminalFitFrame = window.requestAnimationFrame(() => {
    terminalFitFrame = undefined;
    fitActiveTerminal();
  });
}

function scheduleActiveTerminalFitAfterLayout(): void {
  scheduleActiveTerminalFit();
  window.requestAnimationFrame(() => scheduleActiveTerminalFit());
}

function expandSidebar(): void {
  setSidebarCollapsed(false);
}

function terminalSizeHint(): Pick<CreateTerminalRequest, "initialCols" | "initialRows"> {
  const stack = document.querySelector<HTMLDivElement>("#terminal-stack");
  const width = Math.max(0, (stack?.clientWidth ?? window.innerWidth) - 18);
  const height = Math.max(0, (stack?.clientHeight ?? window.innerHeight) - 18);
  return {
    initialCols: Math.max(20, Math.min(400, Math.floor(width / 7.25))),
    initialRows: Math.max(8, Math.min(120, Math.floor(height / 15.5)))
  };
}

function terminalCellSize(terminal: Terminal): { width: number; height: number } | undefined {
  const dimensions = (terminal as unknown as { _core?: { _renderService?: { dimensions?: { css?: { cell?: { width?: number; height?: number } } } } } })._core?._renderService?.dimensions?.css?.cell;
  if (!dimensions?.width || !dimensions.height) return undefined;
  return { width: dimensions.width, height: dimensions.height };
}

function terminalScrollbarWidth(terminal: Terminal): number {
  const scrollbar = terminal.element?.querySelector<HTMLElement>(".xterm-scrollable-element > .scrollbar.vertical");
  if (scrollbar) return Math.max(0, scrollbar.offsetWidth || Number.parseFloat(scrollbar.style.width) || 0);
  const viewport = terminal.element?.querySelector<HTMLElement>(".xterm-viewport");
  if (!viewport) return 0;
  return Math.max(0, viewport.offsetWidth - viewport.clientWidth);
}

function terminalSizeFromFit(terminal: Terminal, fitAddon: FitAddon): Pick<CreateTerminalRequest, "initialCols" | "initialRows"> {
  const measured = fitAddon.proposeDimensions();
  if (!measured) return terminalSizeHint();
  const parent = terminal.element?.parentElement;
  const cell = terminalCellSize(terminal);
  const rightReserve = Math.max(terminalMinimumRightReservePixels, terminalScrollbarWidth(terminal) + terminalScrollbarTextGapPixels);
  const measuredCols = parent && cell ? Math.floor(Math.max(0, parent.clientWidth - rightReserve) / cell.width) : Math.floor(measured.cols);
  return {
    initialCols: Math.max(20, Math.min(400, measuredCols)),
    initialRows: Math.max(8, Math.min(120, Math.floor(measured.rows)))
  };
}

function resizeTerminalToFit(terminal: Terminal, fitAddon: FitAddon): void {
  const size = terminalSizeFromFit(terminal, fitAddon);
  terminal.resize(size.initialCols ?? terminal.cols, size.initialRows ?? terminal.rows);
}

function ptyColsForTerminal(terminal: Terminal): number {
  return Math.max(20, terminal.cols - terminalPtyRightGuardColumns);
}

function terminalPtySize(terminal: Terminal): Pick<CreateTerminalRequest, "initialCols" | "initialRows"> {
  return { initialCols: ptyColsForTerminal(terminal), initialRows: terminal.rows };
}

function syncTerminalPtySize(tab: TerminalTab): void {
  const cols = ptyColsForTerminal(tab.terminal);
  const rows = tab.terminal.rows;
  if (tab.lastPtyCols === cols && tab.lastPtyRows === rows) return;
  tab.lastPtyCols = cols;
  tab.lastPtyRows = rows;
  window.shellx.terminal.resize(tab.id, cols, rows);
}

function scheduleSelectionClipboardCopy(terminal: Terminal): void {
  if (selectionClipboardTimer) window.clearTimeout(selectionClipboardTimer);
  const serial = ++selectionClipboardSerial;
  selectionClipboardTimer = window.setTimeout(() => {
    selectionClipboardTimer = undefined;
    if (serial !== selectionClipboardSerial) return;
    const selection = terminal.getSelection();
    if (selection) void navigator.clipboard.writeText(selection);
  }, 90);
}

function updateStatusbar(): void {
  const node = document.querySelector<HTMLSpanElement>("#status-text");
  if (node) node.textContent = statusMessage;
  document.querySelector<HTMLDivElement>("#statusbar")?.classList.toggle("spinning", statusSpinning);
  const active = activeTabID ? tabs.get(activeTabID) : undefined;
  const host = terminalHost(active);
  const hostNode = document.querySelector<HTMLSpanElement>("#status-host");
  if (hostNode) hostNode.textContent = host || "本机终端";
  const copyButton = document.querySelector<HTMLButtonElement>("#status-copy-host");
  if (copyButton) copyButton.hidden = !host;
  const tagWrap = document.querySelector<HTMLDivElement>("#status-tags");
  if (tagWrap) {
    tagWrap.replaceChildren();
    const session = sessionForTab(active);
    for (const tag of session?.tags ?? []) tagWrap.append(h("span", "status-tag", tag));
  }
}

function rootSessions(): SSHSessionProfile[] {
  return filteredSessions(snapshot.workspace.sessions.filter((session) => !session.folderID));
}

function childFolders(parentID?: string): SessionFolder[] {
  return snapshot.workspace.folders.filter((folder) => (folder.parentID ?? "") === (parentID ?? ""));
}

function childSessions(folderID: string): SSHSessionProfile[] {
  return filteredSessions(snapshot.workspace.sessions.filter((session) => session.folderID === folderID));
}

function filteredSessions(sessions: SSHSessionProfile[]): SSHSessionProfile[] {
  const query = searchText.trim().toLowerCase();
  if (!query) return sessions;
  return sessions.filter((session) => [session.name, session.host, session.username, ...session.tags].some((value) => value.toLowerCase().includes(query)));
}

function selectedSession(): SSHSessionProfile | undefined {
  return snapshot.workspace.sessions.find((session) => session.id === selectedSessionID);
}

function selectedScript(): UserScript | undefined {
  return snapshot.scriptLibrary.scripts.find((script) => script.id === selectedScriptID);
}

function rootScripts(): UserScript[] {
  return snapshot.scriptLibrary.scripts.filter((script) => !script.folderID);
}

function childScriptFolders(parentID?: string): ScriptFolder[] {
  return snapshot.scriptLibrary.folders.filter((folder) => (folder.parentID ?? "") === (parentID ?? ""));
}

function childScripts(folderID: string): UserScript[] {
  return snapshot.scriptLibrary.scripts.filter((script) => script.folderID === folderID);
}

function scriptFolderName(folderID?: string): string {
  return snapshot.scriptLibrary.folders.find((folder) => folder.id === folderID)?.name ?? "未分组";
}

function scriptFolderOptions(): [string, string][] {
  const options: [string, string][] = [["", "未分组"]];
  const append = (folder: ScriptFolder, level: number): void => {
    options.push([folder.id, `${"  ".repeat(level)}${folder.name}`]);
    for (const child of childScriptFolders(folder.id)) append(child, level + 1);
  };
  for (const folder of childScriptFolders()) append(folder, 0);
  return options;
}

function scriptLabel(script: UserScript): string {
  const folder = scriptFolderName(script.folderID);
  return script.folderID ? `${folder} / ${script.name || "未命名脚本"}` : script.name || "未命名脚本";
}

function sessionForTab(tab?: TerminalTab): SSHSessionProfile | undefined {
  const request = tab?.request;
  if (!request || request.kind !== "ssh" || !request.sessionID) return undefined;
  return snapshot.workspace.sessions.find((session) => session.id === request.sessionID);
}

function terminalHost(tab?: TerminalTab): string {
  if (!tab || tab.request.kind !== "ssh") return "";
  return `${tab.request.username ? `${tab.request.username}@` : ""}${tab.request.host}:${tab.request.port || 22}`;
}

function displayableTerminalData(data: string): string {
  if (!zmodemPattern.test(data)) return data;
  const startIndex = data.search(zmodemPattern);
  const beforeStart = data.slice(0, startIndex).replace(/(?:^|[\r\n])rz\r?\n?$/g, "");
  return beforeStart.replace(rzWaitingLinePattern, "");
}

function zmodemDirection(data: string, recentOutput: string): "upload" | "download" {
  const context = `${recentOutput.slice(-512)}${data}`;
  const startIndex = context.lastIndexOf(zmodemStartMarker);
  const triggerContext = startIndex >= 0 ? context.slice(Math.max(0, startIndex - 160), startIndex + 16) : context;
  if (zmodemDownloadAutoStartPattern.test(triggerContext) || zmodemDownloadFramePattern.test(triggerContext)) return "download";
  if (zmodemUploadFramePattern.test(triggerContext)) return "upload";
  return zmodemUploadHintPattern.test(triggerContext) ? "upload" : "download";
}

async function copyActiveHost(): Promise<void> {
  const active = activeTabID ? tabs.get(activeTabID) : undefined;
  const host = active?.request.kind === "ssh" ? active.request.host.trim() : "";
  if (!host) return;
  await navigator.clipboard.writeText(host);
  setStatus(`已复制 IP：${host}`, false, true);
}

function payloadID(payload?: Record<string, unknown>, key = "id"): string | undefined {
  const value = payload?.[key];
  return typeof value === "string" ? value : undefined;
}

function isRootPayload(payload?: Record<string, unknown>): boolean {
  return payload?.root === true;
}

function menu(type: "root" | "folder" | "session" | "tab" | "terminal" | "script" | "scriptRoot" | "scriptFolder", payload?: Record<string, unknown>): void {
  void window.shellx.menu.popup({ type, payload });
}

function h<K extends keyof HTMLElementTagNameMap>(tag: K, className = "", content = ""): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (content) node.textContent = content;
  return node;
}

function button(label: string, className: string, onClick: () => void): HTMLButtonElement {
  const node = h("button", className, label);
  node.type = "button";
  node.addEventListener("click", onClick);
  return node;
}

function promptText(title: string, label: string, initialValue = ""): Promise<string | null> {
  return new Promise((resolve) => {
    const overlay = h("div", "sheet-overlay prompt-overlay");
    const sheet = h("section", "prompt-sheet");
    const header = h("div", "sheet-header");
    header.append(h("div", "", title));
    const body = h("div", "sheet-body");
    const input = h("input", "") as HTMLInputElement;
    input.value = initialValue;
    const fieldWrap = h("label", "field");
    fieldWrap.append(h("span", "field-label", label), input);
    body.append(fieldWrap);
    const footer = h("div", "sheet-footer");

    function finish(value: string | null): void {
      overlay.remove();
      resolve(value?.trim() || null);
    }

    footer.append(button("取消", "secondary", () => finish(null)), button("确定", "primary", () => finish(input.value)));
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter") { event.preventDefault(); finish(input.value); }
      if (event.key === "Escape") { event.preventDefault(); finish(null); }
    });
    sheet.append(header, body, footer);
    overlay.append(sheet);
    document.body.append(overlay);
    requestAnimationFrame(() => { input.focus(); input.select(); });
  });
}

function field(label: string, value: string | number, onInput: (value: string) => void, options: { type?: string; placeholder?: string; textarea?: boolean } = {}): HTMLElement {
  const wrap = h("label", "field");
  wrap.append(h("span", "field-label", label));
  const input = options.textarea ? h("textarea", "") : h("input", "");
  if (input instanceof HTMLInputElement) input.type = options.type ?? "text";
  input.setAttribute("placeholder", options.placeholder ?? "");
  (input as HTMLInputElement | HTMLTextAreaElement).value = String(value ?? "");
  input.addEventListener("input", () => onInput((input as HTMLInputElement | HTMLTextAreaElement).value));
  wrap.append(input);
  return wrap;
}

function selectField<T extends string>(label: string, value: T, choices: Array<[T, string]>, onInput: (value: T) => void): HTMLElement {
  const wrap = h("label", "field");
  wrap.append(h("span", "field-label", label));
  const select = h("select", "");
  for (const [id, title] of choices) {
    const option = h("option", "", title);
    option.value = id;
    option.selected = id === value;
    select.append(option);
  }
  select.addEventListener("change", () => onInput(select.value as T));
  wrap.append(select);
  return wrap;
}

function checkbox(label: string, value: boolean, onInput: (value: boolean) => void): HTMLElement {
  const wrap = h("label", "check-row");
  const input = h("input", "") as HTMLInputElement;
  input.type = "checkbox";
  input.checked = value;
  input.addEventListener("change", () => onInput(input.checked));
  wrap.append(input, h("span", "", label));
  return wrap;
}

function render(): void {
  document.documentElement.dataset.theme = snapshot.settings.theme;
  appRoot.innerHTML = `
    <main class="shell ${sidebarCollapsed ? "sidebar-collapsed" : ""} ${windowFullScreen ? "window-fullscreen" : ""}">
      <aside class="sidebar">
        <section class="brand">
          <div class="brand-copy"><h1>ShellX</h1><p>SSH 会话、终端、脚本和传输工作台</p></div>
          <button id="sidebar-toggle" class="sidebar-toggle" type="button" title="${sidebarCollapsed ? "展开侧边栏" : "折叠侧边栏"}" aria-label="${sidebarCollapsed ? "展开侧边栏" : "折叠侧边栏"}" aria-expanded="${!sidebarCollapsed}">${sidebarCollapsed ? "›" : "‹"}</button>
        </section>
        ${sidebarCollapsed ? "" : `<nav class="tree" id="tree"></nav>`}
        <div id="sidebar-resizer" class="sidebar-resizer" role="separator" aria-orientation="vertical" aria-label="调整侧边栏宽度"></div>
      </aside>
      <section class="mainpane">
        <section class="content" id="content"></section>
      </section>
    </main>
  `;
  applySidebarWidth();
  bindPressAction(document.querySelector<HTMLButtonElement>("#sidebar-toggle"), () => setSidebarCollapsed(!sidebarCollapsed));
  bindSidebarResize();
  if (!sidebarCollapsed) renderTree();
  renderContent();
  scheduleActiveTerminalFitAfterLayout();
}

function bindSidebarResize(): void {
  const handle = document.querySelector<HTMLDivElement>("#sidebar-resizer");
  if (!handle) return;
  handle.addEventListener("pointerdown", (event) => {
    if (sidebarCollapsed) return;
    event.preventDefault();
    handle.setPointerCapture(event.pointerId);
    document.body.classList.add("resizing-sidebar");

    const onMove = (moveEvent: PointerEvent) => {
      sidebarWidth = clampSidebarWidth(moveEvent.clientX);
      applySidebarWidth();
      scheduleActiveTerminalFit();
    };

    const finish = (endEvent: PointerEvent) => {
      handle.releasePointerCapture(endEvent.pointerId);
      handle.removeEventListener("pointermove", onMove);
      handle.removeEventListener("pointerup", finish);
      handle.removeEventListener("pointercancel", finish);
      document.body.classList.remove("resizing-sidebar");
      localStorage.setItem(sidebarWidthStorageKey, String(sidebarWidth));
      scheduleActiveTerminalFitAfterLayout();
    };

    handle.addEventListener("pointermove", onMove);
    handle.addEventListener("pointerup", finish);
    handle.addEventListener("pointercancel", finish);
  });
}

async function createFolder(parentID?: string): Promise<void> {
  const name = await promptText("新建文件夹", "文件夹名称", "新建文件夹");
  if (!name) return;
  snapshot.workspace.folders.push({ id: uid(), parentID, name, createdAt: now(), updatedAt: now() });
  selectedFolderID = parentID ?? null;
  selectedSessionID = null;
  rootExpanded = true;
  if (parentID) expandedFolderIDs.add(parentID);
  await persistWorkspace();
}

async function renameFolder(folderID?: string): Promise<void> {
  const folder = snapshot.workspace.folders.find((item) => item.id === (folderID ?? selectedFolderID));
  if (!folder) return;
  const name = await promptText("重命名文件夹", "文件夹名称", folder.name);
  if (!name) return;
  folder.name = name;
  folder.updatedAt = now();
  await persistWorkspace();
}

async function deleteFolder(folderID?: string): Promise<void> {
  const id = folderID ?? selectedFolderID;
  const folder = snapshot.workspace.folders.find((item) => item.id === id);
  if (!folder) return;
  if (!confirm(`删除文件夹「${folder.name}」？其中的会话会移动到未分组。`)) return;
  const childIDs = new Set<string>([folder.id]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const child of snapshot.workspace.folders) {
      if (child.parentID && childIDs.has(child.parentID) && !childIDs.has(child.id)) { childIDs.add(child.id); changed = true; }
    }
  }
  snapshot.workspace.folders = snapshot.workspace.folders.filter((item) => !childIDs.has(item.id));
  for (const session of snapshot.workspace.sessions) if (session.folderID && childIDs.has(session.folderID)) session.folderID = undefined;
  selectedFolderID = null;
  selectedSessionID = null;
  await persistWorkspace();
}

function createSession(folderID?: string | null): void {
  const session = newSession(folderID === null ? undefined : folderID ?? selectedFolderID ?? undefined);
  presentSessionEditor(session, true);
}

function editSession(sessionID?: string): void {
  const session = snapshot.workspace.sessions.find((item) => item.id === (sessionID ?? selectedSessionID));
  if (session) presentSessionEditor(session, false);
}

async function duplicateSession(sessionID?: string): Promise<void> {
  const source = snapshot.workspace.sessions.find((item) => item.id === (sessionID ?? selectedSessionID));
  if (!source) return;
  const copy: SSHSessionProfile = { ...JSON.parse(JSON.stringify(source)) as SSHSessionProfile, id: uid(), name: `${sessionTitle(source)} 副本`, createdAt: now(), updatedAt: now(), lastConnectedAt: undefined };
  snapshot.workspace.sessions.push(copy);
  selectedSessionID = copy.id;
  selectedFolderID = copy.folderID ?? null;
  await persistWorkspace();
}

async function deleteSession(sessionID?: string): Promise<void> {
  const id = sessionID ?? selectedSessionID;
  const session = snapshot.workspace.sessions.find((item) => item.id === id);
  if (!session) return;
  if (!confirm(`删除会话「${sessionTitle(session)}」？`)) return;
  snapshot.workspace.sessions = snapshot.workspace.sessions.filter((item) => item.id !== session.id);
  selectedSessionID = null;
  await persistWorkspace();
}

async function connectSelected(sessionID?: string): Promise<void> {
  const session = snapshot.workspace.sessions.find((item) => item.id === (sessionID ?? selectedSessionID));
  if (session) await connectSession(session);
}

function renderTree(): void {
  const tree = document.querySelector<HTMLDivElement>("#tree")!;
  const root = treeRow("全部会话", !selectedFolderID && !selectedSessionID, "root", () => { selectedFolderID = null; selectedSessionID = null; viewMode = "detail"; rootExpanded = !rootExpanded; render(); }, 0, rootExpanded, snapshot.workspace.sessions.length);
  root.addEventListener("contextmenu", (event) => { event.preventDefault(); selectedFolderID = null; selectedSessionID = null; menu("root", { root: true }); });
  enableTreeDrop(root, undefined);
  tree.append(root);
  if (rootExpanded) {
    for (const folder of childFolders()) renderFolder(tree, folder, 1);
    for (const session of rootSessions()) tree.append(sessionRow(session, 1));
  }
}

function enableTreeDrop(row: HTMLElement, targetFolderID?: string): void {
  row.addEventListener("dragover", (event) => {
    if (event.dataTransfer?.types.includes("application/x-shellx-session") || event.dataTransfer?.types.includes("application/x-shellx-folder")) {
      event.preventDefault();
      row.classList.add("drop-target");
      event.dataTransfer.dropEffect = "move";
    }
  });
  row.addEventListener("dragleave", () => row.classList.remove("drop-target"));
  row.addEventListener("drop", (event) => {
    event.preventDefault();
    row.classList.remove("drop-target");
    const sessionID = event.dataTransfer?.getData("application/x-shellx-session");
    const folderID = event.dataTransfer?.getData("application/x-shellx-folder");
    if (sessionID) void moveSession(sessionID, targetFolderID);
    else if (folderID) void moveFolder(folderID, targetFolderID);
  });
}

async function moveSession(sessionID: string, targetFolderID?: string): Promise<void> {
  const session = snapshot.workspace.sessions.find((item) => item.id === sessionID);
  if (!session || session.folderID === targetFolderID) return;
  session.folderID = targetFolderID;
  session.updatedAt = now();
  if (targetFolderID) expandedFolderIDs.add(targetFolderID);
  await persistWorkspace();
}

function isDescendantFolder(folderID: string, possibleParentID?: string): boolean {
  let cursor = possibleParentID;
  while (cursor) {
    if (cursor === folderID) return true;
    cursor = snapshot.workspace.folders.find((folder) => folder.id === cursor)?.parentID;
  }
  return false;
}

async function moveFolder(folderID: string, targetParentID?: string): Promise<void> {
  const folder = snapshot.workspace.folders.find((item) => item.id === folderID);
  if (!folder || folder.id === targetParentID || folder.parentID === targetParentID || isDescendantFolder(folder.id, targetParentID)) return;
  folder.parentID = targetParentID;
  folder.updatedAt = now();
  rootExpanded = true;
  if (targetParentID) expandedFolderIDs.add(targetParentID);
  await persistWorkspace();
}

function treeRow(title: string, active: boolean, kind: string, onClick: () => void, level = 0, expanded = false, count?: number): HTMLDivElement {
  const row = h("div", `tree-row ${active ? "active" : ""}`);
  row.style.paddingLeft = `${12 + level * 16}px`;
  const disclosure = kind === "session" ? "" : expanded ? "▾" : "▸";
  row.append(h("span", "tree-disclosure", disclosure), h("span", `tree-icon tree-icon-${kind}`), h("span", "tree-title", title));
  if (typeof count === "number") row.append(h("span", "tree-count", String(count)));
  row.addEventListener("click", onClick);
  return row;
}

function cancelPendingSessionClickRender(): void {
  if (!pendingSessionClickRenderTimer) return;
  window.clearTimeout(pendingSessionClickRenderTimer);
  pendingSessionClickRenderTimer = undefined;
}

function openSessionFromTreeDoubleClick(session: SSHSessionProfile): void {
  cancelPendingSessionClickRender();
  lastSessionClick = null;
  suppressNextSessionClickID = session.id;
  selectedSessionID = session.id;
  selectedFolderID = session.folderID ?? null;
  viewMode = "terminal";
  void connectSession(session);
}

function sessionRow(session: SSHSessionProfile, level = 0): HTMLDivElement {
  const row = treeRow(sessionTitle(session), selectedSessionID === session.id, "session", () => {
    if (suppressNextSessionClickID === session.id) {
      suppressNextSessionClickID = null;
      return;
    }
    const clickedAt = Date.now();
    const shouldConnect = lastSessionClick?.id === session.id && clickedAt - lastSessionClick.at <= sessionDoubleClickIntervalMs;
    lastSessionClick = { id: session.id, at: clickedAt };
    selectedSessionID = session.id;
    selectedFolderID = session.folderID ?? null;
    viewMode = "detail";
    cancelPendingSessionClickRender();
    if (shouldConnect) {
      openSessionFromTreeDoubleClick(session);
      return;
    }
    pendingSessionClickRenderTimer = window.setTimeout(() => {
      pendingSessionClickRenderTimer = undefined;
      render();
    }, sessionSingleClickDelayMs);
  }, level);
  row.addEventListener("pointerdown", (event) => {
    if (event.button !== 0 || event.detail < 2) return;
    event.preventDefault();
    event.stopPropagation();
    openSessionFromTreeDoubleClick(session);
  }, { capture: true });
  row.draggable = true;
  row.addEventListener("dragstart", (event) => {
    event.dataTransfer?.setData("application/x-shellx-session", session.id);
    event.dataTransfer?.setData("text/plain", sessionTitle(session));
    event.dataTransfer!.effectAllowed = "move";
  });
  if (session.tags.length > 0) {
    const tagWrap = h("span", "tree-tags");
    for (const tag of session.tags.slice(0, 3)) tagWrap.append(h("span", "tree-tag", tag));
    row.append(tagWrap);
  }
  row.addEventListener("contextmenu", (event) => {
    event.preventDefault();
    cancelPendingSessionClickRender();
    lastSessionClick = null;
    suppressNextSessionClickID = null;
    selectedSessionID = session.id;
    selectedFolderID = session.folderID ?? null;
    row.classList.add("active");
    menu("session", { id: session.id });
  });
  return row;
}

function renderFolder(parent: HTMLElement, folder: SessionFolder, level: number): void {
  const expanded = expandedFolderIDs.has(folder.id);
  const row = treeRow(folder.name, selectedFolderID === folder.id && !selectedSessionID, "folder", () => {
    selectedFolderID = folder.id;
    selectedSessionID = null;
    viewMode = "detail";
    if (expanded) expandedFolderIDs.delete(folder.id);
    else expandedFolderIDs.add(folder.id);
    render();
  }, level, expanded, childSessions(folder.id).length);
  row.addEventListener("contextmenu", (event) => {
    event.preventDefault();
    selectedFolderID = folder.id;
    selectedSessionID = null;
    row.classList.add("active");
    menu("folder", { id: folder.id });
  });
  row.draggable = true;
  row.addEventListener("dragstart", (event) => {
    event.dataTransfer?.setData("application/x-shellx-folder", folder.id);
    event.dataTransfer?.setData("text/plain", folder.name);
    event.dataTransfer!.effectAllowed = "move";
  });
  enableTreeDrop(row, folder.id);
  parent.append(row);
  if (expanded) {
    for (const child of childFolders(folder.id)) renderFolder(parent, child, level + 1);
    for (const session of childSessions(folder.id)) parent.append(sessionRow(session, level + 1));
  }
}

function renderContent(): void {
  const content = document.querySelector<HTMLDivElement>("#content")!;
  if (viewMode === "terminal" || tabs.size > 0) renderTerminalWorkbench(content);
  else renderSessionReadOnly(content);
}

function renderTerminalWorkbench(content: HTMLElement): void {
  content.innerHTML = `<section class="workspace"><div class="resourcebar" id="resourcebar"></div><div class="tabbar" id="tabbar"></div><div class="terminal-stack" id="terminal-stack"><div class="empty" id="empty">打开本机终端或选择 SSH 会话连接。</div></div><div class="statusbar" id="statusbar"><span class="status-spinner"></span><span id="status-text">Ready</span><span class="status-separator"></span><span id="status-host" class="status-host">本机终端</span><button id="status-copy-host" class="status-icon-button" type="button" title="复制 IP">⧉</button><div id="status-tags" class="status-tags"></div></div></section>`;
  const resourcebar = document.querySelector<HTMLDivElement>("#resourcebar")!;
  if (tabs.size >= snapshot.settings.freezeThreshold) {
    resourcebar.textContent = `${tabs.size} 个终端标签正在运行。可通过右键标签固定、关闭或切换。`;
  } else {
    resourcebar.remove();
  }
  const stack = document.querySelector<HTMLDivElement>("#terminal-stack")!;
  for (const tab of tabs.values()) stack.append(tab.pane);
  resizeObserver.observe(stack);
  renderTabs();
  document.querySelector<HTMLButtonElement>("#status-copy-host")?.addEventListener("click", () => void copyActiveHost());
  updateStatusbar();
}

function renderSessionReadOnly(content: HTMLElement): void {
  const session = selectedSession();
  if (!session) {
    content.innerHTML = `<section class="detail-page">${sidebarCollapsed ? `<button id="detail-sidebar-reopen" class="detail-sidebar-reopen" type="button" title="展开侧边栏" aria-label="展开侧边栏">›</button>` : ""}<div class="empty-state"><div class="empty-icon">⌁</div><h2>选择一个会话</h2><p>从左侧文件夹树中选择 SSH 会话，查看连接信息、认证方式和启动配置。</p></div></section>`;
    bindPressAction(document.querySelector<HTMLButtonElement>("#detail-sidebar-reopen"), expandSidebar);
    return;
  }
  content.innerHTML = `<section class="detail-page" id="detail-page">${sidebarCollapsed ? `<button id="detail-sidebar-reopen" class="detail-sidebar-reopen" type="button" title="展开侧边栏" aria-label="展开侧边栏">›</button>` : ""}</section>`;
  bindPressAction(document.querySelector<HTMLButtonElement>("#detail-sidebar-reopen"), expandSidebar);
  const detail = document.querySelector<HTMLDivElement>("#detail-page")!;
  const hero = h("section", "session-hero");
  hero.append(h("div", "hero-icon", authGlyph(session.authMethod)));
  const copy = h("div", "hero-copy");
  copy.append(h("h2", "", sessionTitle(session)), h("p", "", `${session.username ? `${session.username}@` : ""}${session.host}:${session.port}`));
  const pills = h("div", "pill-row");
  pills.append(statusPill(authTitle(session.authMethod), authGlyph(session.authMethod), "accent"), statusPill(session.lastConnectedAt ? "已连接" : "未连接过", session.lastConnectedAt ? "✓" : "◷", session.lastConnectedAt ? "green" : "neutral"));
  copy.append(pills);
  const heroActions = h("div", "hero-actions");
  heroActions.append(button("编辑", "secondary", () => presentSessionEditor(session, false)), button("连接", "primary", () => void connectSession(session)));
  hero.append(copy, heroActions);
  detail.append(hero);
  detail.append(infoSection("基础信息", [["主机", session.host], ["端口", String(session.port)], ["用户名", session.username || "未填写"], ["所属文件夹", folderName(session.folderID)], ["最近连接", session.lastConnectedAt ? new Date(session.lastConnectedAt).toLocaleString() : "暂无"]]));
  const securityRows: Array<[string, string]> = [["认证方式", authTitle(session.authMethod)]];
  if (session.privateKeyPath) securityRows.push(["私钥路径", session.privateKeyPath], ["Keychain", session.useKeychainForPrivateKey ? "已启用" : "未启用"]);
  if (session.authMethod === "password") securityRows.push(["密码存储", session.passwordStoredInKeychain ? "系统 Keychain" : "未保存"]);
  detail.append(infoSection("认证与安全", securityRows));
  detail.append(infoSection("远端网络出口", session.remoteNetworkForwarding.isEnabled ? [["出口模式", session.remoteNetworkForwarding.mode === "dynamicSOCKS" ? "本机网络出口" : "本机已有代理"], ["代理地址", `${session.remoteNetworkForwarding.mode === "dynamicSOCKS" ? "socks5h" : session.remoteNetworkForwarding.remoteProxyScheme}://${session.remoteNetworkForwarding.bindAddress}:${session.remoteNetworkForwarding.port}`], ["环境变量", session.remoteNetworkForwarding.setProxyEnvironment ? "连接后自动设置" : "手动使用代理地址"]] : [["状态", "未启用远端网络出口"]]));
  const tagSection = infoSection("标签与启动行为", []);
  const tags = h("div", "tag-wrap");
  if (session.tags.length === 0) tags.append(h("span", "muted", "尚未添加标签"));
  else for (const tag of session.tags) tags.append(h("span", "tag-chip", tag));
  tagSection.append(tags);
  if (session.startupCommand) tagSection.append(h("pre", "code-block", session.startupCommand));
  detail.append(tagSection);
}

function authGlyph(method: SSHAuthMethod): string { return method === "agent" ? "⌘" : method === "privateKey" ? "▤" : "🔒"; }
function authTitle(method: SSHAuthMethod): string { return method === "agent" ? "SSH Agent" : method === "privateKey" ? "私钥文件" : "账号密码"; }
function folderName(folderID?: string): string { return snapshot.workspace.folders.find((folder) => folder.id === folderID)?.name ?? "未分组"; }
function statusPill(title: string, icon: string, tone: string): HTMLElement { const node = h("span", `status-pill ${tone}`); node.append(h("span", "", icon), h("span", "", title)); return node; }
function infoSection(title: string, rows: Array<[string, string]>): HTMLElement {
  const section = h("section", "info-section");
  section.append(h("h3", "", title));
  for (const [label, value] of rows) { const row = h("div", "info-row"); row.append(h("span", "info-label", label), h("span", "info-value", value)); section.append(row); }
  return section;
}

function presentSessionEditor(source: SSHSessionProfile, isNew: boolean): void {
  const draft: SSHSessionProfile = JSON.parse(JSON.stringify(source)) as SSHSessionProfile;
  let pendingPassword = "";
  const overlay = h("div", "sheet-overlay");
  const sheet = h("section", "session-sheet");
  const header = h("div", "sheet-header");
  header.append(h("div", "", isNew ? "新建 SSH 会话" : "编辑 SSH 会话"), h("p", "", "配置 SSH 目标、认证方式和连接后的启动行为。"));
  sheet.append(header);
  const body = h("div", "sheet-body");
  const base = infoSection("基础信息", []);
  base.append(field("会话名称", draft.name, (value) => { draft.name = value; }), field("主机地址", draft.host, (value) => { draft.host = value; }), field("用户名", draft.username, (value) => { draft.username = value; }), field("端口", draft.port, (value) => { draft.port = Number(value) || 22; }, { type: "number" }));
  const auth = infoSection("认证", []);
  const authFields = h("div", "auth-fields");
  auth.append(selectField<SSHAuthMethod>("认证方式", draft.authMethod, [["agent", "SSH Agent"], ["privateKey", "私钥文件"], ["password", "账号密码"]], (value) => { draft.authMethod = value; renderAuthFields(); }), authFields);

  function renderAuthFields(): void {
    authFields.replaceChildren();
    if (draft.authMethod === "agent") {
      authFields.append(helpText("使用本机 SSH Agent 认证，不需要在 ShellX 保存密码或私钥路径。"));
      return;
    }
    if (draft.authMethod === "privateKey") {
      const wrap = h("label", "field");
      const row = h("div", "file-picker-row");
      const input = h("input", "") as HTMLInputElement;
      input.readOnly = true;
      input.value = draft.privateKeyPath;
      input.placeholder = "选择私钥文件";
      row.append(input, button("选择...", "secondary", async () => {
        const result = await window.shellx.dialog.privateKey();
        if (!result.canceled && result.filePaths[0]) {
          draft.privateKeyPath = result.filePaths[0];
          input.value = draft.privateKeyPath;
        }
      }));
      wrap.append(h("span", "field-label", "私钥文件"), row);
      authFields.append(wrap, checkbox("将私钥口令交给系统 Keychain 管理", draft.useKeychainForPrivateKey, (value) => { draft.useKeychainForPrivateKey = value; }));
      return;
    }
    authFields.append(field("登录密码", pendingPassword, (value) => { pendingPassword = value; draft.passwordStoredInKeychain = value.length > 0 || draft.passwordStoredInKeychain; }, { type: "password", placeholder: isNew ? "账号密码认证时填写" : "留空则保留已保存密码" }), checkbox("将密码保存到系统 Keychain", draft.passwordStoredInKeychain, (value) => { draft.passwordStoredInKeychain = value; }));
  }
  renderAuthFields();
  const forwarding = infoSection("远端网络出口", []);
  forwarding.append(checkbox("启用远端动态转发", draft.remoteNetworkForwarding.isEnabled, (value) => { draft.remoteNetworkForwarding.isEnabled = value; }), selectField("出口模式", draft.remoteNetworkForwarding.mode, [["dynamicSOCKS", "本机网络出口"], ["localProxy", "本机已有代理"]], (value) => { draft.remoteNetworkForwarding.mode = value; }), field("监听地址", draft.remoteNetworkForwarding.bindAddress, (value) => { draft.remoteNetworkForwarding.bindAddress = value; }), field("监听端口", draft.remoteNetworkForwarding.port, (value) => { draft.remoteNetworkForwarding.port = Number(value) || 1080; }, { type: "number" }), field("本机代理", draft.remoteNetworkForwarding.localProxyHost, (value) => { draft.remoteNetworkForwarding.localProxyHost = value; }), field("代理端口", draft.remoteNetworkForwarding.localProxyPort, (value) => { draft.remoteNetworkForwarding.localProxyPort = Number(value) || 7890; }, { type: "number" }), checkbox("连接后设置代理环境变量", draft.remoteNetworkForwarding.setProxyEnvironment, (value) => { draft.remoteNetworkForwarding.setProxyEnvironment = value; }));
  const organization = infoSection("组织", []);
  organization.append(selectField("所属文件夹", draft.folderID ?? "", [["", "未分组"], ...snapshot.workspace.folders.map((folder) => [folder.id, folder.name] as [string, string])], (value) => { draft.folderID = value || undefined; }), tagEditor(draft));
  const startup = infoSection("启动行为", []);
  startup.append(field("连接后执行命令", draft.startupCommand, (value) => { draft.startupCommand = value; }, { textarea: true }));
  body.append(base, auth, forwarding, organization, startup);
  const footer = h("div", "sheet-footer");
  footer.append(button("取消", "secondary", () => overlay.remove()), button("保存", "primary", async () => {
    if (!draft.name.trim() || !draft.host.trim() || draft.port < 1 || draft.port > 65535) { setStatus("请填写有效的名称、主机和端口", false, true); return; }
    draft.updatedAt = now();
    if (draft.authMethod === "password" && draft.passwordStoredInKeychain && pendingPassword) {
      const result = await window.shellx.keychain.setPassword(draft.id, keychainAccount(draft), pendingPassword);
      if (result.code !== 0) { setStatus(`Keychain 保存失败：${result.output || result.code}`, false, true); return; }
    }
    if (isNew) snapshot.workspace.sessions.push(draft);
    else snapshot.workspace.sessions = snapshot.workspace.sessions.map((session) => session.id === draft.id ? draft : session);
    selectedSessionID = draft.id;
    viewMode = "terminal";
    overlay.remove();
    await persistWorkspace();
  }));
  sheet.append(body, footer);
  overlay.append(sheet);
  document.body.append(overlay);
}

function tagEditor(draft: SSHSessionProfile): HTMLElement {
  const wrap = h("div", "tag-editor");
  const inputRow = h("div", "tag-input-row");
  const input = h("input", "") as HTMLInputElement;
  input.placeholder = "输入标签后回车或点击添加";
  const add = button("添加", "secondary", () => appendTag());
  const chips = h("div", "tag-wrap");
  const help = h("p", "settings-help", "标签会显示在会话详情和终端底部栏，用于快速识别环境、角色或用途。");

  function redraw(): void {
    chips.replaceChildren();
    if (draft.tags.length === 0) chips.append(h("span", "muted", "尚未添加标签"));
    for (const tag of draft.tags) {
      const chip = h("button", "tag-chip removable", `${tag} ×`);
      chip.type = "button";
      chip.addEventListener("click", () => {
        draft.tags = draft.tags.filter((item) => item !== tag);
        redraw();
      });
      chips.append(chip);
    }
  }

  function appendTag(): void {
    const values = cleanTags(input.value);
    if (values.length === 0) return;
    draft.tags = Array.from(new Set([...draft.tags, ...values])).slice(0, 12);
    input.value = "";
    redraw();
  }

  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter") { event.preventDefault(); appendTag(); }
  });
  inputRow.append(input, add);
  wrap.append(inputRow, chips, help);
  redraw();
  return wrap;
}

async function connectSession(session: SSHSessionProfile): Promise<void> {
  if (!session.host.trim()) { setStatus("主机不能为空", false, true); return; }
  session.lastConnectedAt = now();
  await window.shellx.app.saveWorkspace(snapshot.workspace);
  await openTerminal({ kind: "ssh", host: session.host.trim(), port: session.port, username: session.username.trim(), identityFile: session.privateKeyPath.trim() || undefined, authMethod: session.authMethod, useKeychainForPrivateKey: session.useKeychainForPrivateKey, remoteNetworkForwarding: session.remoteNetworkForwarding, startupCommand: session.startupCommand, sessionID: session.id }, sessionTitle(session), `${session.username}@${session.host}:${session.port}`);
}

function renderTabs(): void {
  const tabbar = document.querySelector<HTMLDivElement>("#tabbar");
  if (!tabbar) return;
  hideTabPreview();
  tabbar.replaceChildren();
  if (!tabbar.dataset.scrollBound) {
    tabbar.dataset.scrollBound = "true";
    tabbar.addEventListener("wheel", (event) => {
      const delta = Math.abs(event.deltaX) > Math.abs(event.deltaY) ? event.deltaX : event.deltaY;
      if (!delta) return;
      event.preventDefault();
      tabbar.scrollLeft += delta;
    }, { passive: false });
  }
  if (sidebarCollapsed) {
    const reopen = h("button", "tabbar-sidebar-reopen", "›") as HTMLButtonElement;
    reopen.type = "button";
    reopen.title = "展开侧边栏";
    reopen.setAttribute("aria-label", "展开侧边栏");
    bindPressAction(reopen, expandSidebar);
    tabbar.append(reopen);
  }
  for (const tab of tabs.values()) {
    const status = tabStatus(tab);
    const row = h("button", `terminal-tab ${tab.id === activeTabID ? "active" : ""} ${tab.unread ? "unread" : ""} ${status.className}`);
    row.type = "button";
    row.dataset.tabId = tab.id;
    row.draggable = true;
    row.title = `${tab.subtitle}\n${status.help}`;
    row.append(h("span", "tab-status-icon", status.icon), h("span", "tab-title", tab.title), h("span", "tab-status-badge", status.label));
    if (tab.pinned) row.append(h("span", "tab-pin", "⌖"));
    if (!tab.exited && tab.unread) row.append(h("span", `tab-unread ${tab.attention}`, ""));
    const close = h("span", "tab-close", "×");
    close.setAttribute("role", "button");
    close.setAttribute("tabindex", "0");
    close.setAttribute("aria-label", `关闭终端 ${tab.title}`);
    close.addEventListener("pointerdown", (event) => {
      event.stopPropagation();
      event.preventDefault();
      if (event.button !== 0) return;
      closeTab(tab.id);
    });
    close.addEventListener("click", (event) => {
      event.stopPropagation();
      event.preventDefault();
    });
    close.addEventListener("keydown", (event) => {
      if (event.key !== "Enter" && event.key !== " ") return;
      event.stopPropagation();
      event.preventDefault();
      closeTab(tab.id);
    });
    row.append(close);
    row.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      if ((event.target as HTMLElement).closest(".tab-close")) return;
      activateTab(tab.id, false);
    });
    row.addEventListener("click", () => activateTab(tab.id));
    row.addEventListener("dragstart", (event) => {
      event.dataTransfer?.setData("application/x-shellx-tab", tab.id);
      event.dataTransfer!.effectAllowed = "move";
    });
    row.addEventListener("dragover", (event) => {
      if (event.dataTransfer?.types.includes("application/x-shellx-tab")) { event.preventDefault(); row.classList.add("drop-target"); }
    });
    row.addEventListener("dragleave", () => row.classList.remove("drop-target"));
    row.addEventListener("drop", (event) => {
      event.preventDefault();
      row.classList.remove("drop-target");
      const sourceID = event.dataTransfer?.getData("application/x-shellx-tab");
      if (sourceID) reorderTab(sourceID, tab.id);
    });
    row.addEventListener("contextmenu", (event) => { event.preventDefault(); menu("tab", { id: tab.id }); });
    row.addEventListener("mouseenter", () => showTabPreview(tab, row));
    row.addEventListener("mouseleave", hideTabPreview);
    tabbar.append(row);
  }
}

function reorderTab(sourceID: string, targetID: string): void {
  if (sourceID === targetID) return;
  const entries = [...tabs.entries()];
  const sourceIndex = entries.findIndex(([id]) => id === sourceID);
  const targetIndex = entries.findIndex(([id]) => id === targetID);
  if (sourceIndex < 0 || targetIndex < 0) return;
  const [source] = entries.splice(sourceIndex, 1);
  entries.splice(targetIndex, 0, source!);
  tabs.clear();
  for (const [id, tab] of entries) tabs.set(id, tab);
  renderTabs();
}

function tabStatus(tab: TerminalTab): { label: string; icon: string; className: string; help: string } {
  if (tab.connecting && !tab.exited) return { label: "连接中", icon: "◌", className: "state-prompt", help: "终端进程已启动，正在等待首次输出。" };
  if (tab.exited) return { label: "未连接", icon: "↯", className: "state-disconnected", help: "终端进程已退出，当前标签未连接。" };
  if (tab.unread && tab.attention === "error") return { label: "注意", icon: "!", className: "state-error", help: "后台终端出现错误或高优先级输出。" };
  if (tab.unread && tab.attention === "prompt") return { label: "提示", icon: "?", className: "state-prompt", help: "后台终端可能正在等待交互。" };
  return { label: "已连接", icon: "●", className: "state-connected", help: "终端已连接并正在运行。" };
}

function previewText(tab: TerminalTab): string {
  const buffer = tab.terminal.buffer.active;
  const end = buffer.baseY + buffer.cursorY;
  const start = Math.max(0, end - 23);
  const lines: string[] = [];
  for (let index = start; index <= end; index += 1) {
    lines.push(buffer.getLine(index)?.translateToString(true) ?? "");
  }
  return lines.join("\n").trim() || "终端预览尚未就绪";
}

function showTabPreview(tab: TerminalTab, anchor: HTMLElement): void {
  if (tab.id === activeTabID) return;
  hideTabPreview();
  const rect = anchor.getBoundingClientRect();
  const preview = h("div", "tab-preview");
  const status = tabStatus(tab);
  preview.innerHTML = `<div class="tab-preview-header"><span class="preview-terminal-icon"></span><strong></strong><em class="${status.className}"></em></div><pre class="terminal-preview-screen"></pre>`;
  preview.querySelector("strong")!.textContent = tab.title;
  preview.querySelector("em")!.textContent = status.label;
  preview.querySelector("pre")!.textContent = previewText(tab);
  preview.style.left = `${Math.min(rect.left, window.innerWidth - 560)}px`;
  preview.style.top = `${rect.bottom + 8}px`;
  document.body.append(preview);
}

function hideTabPreview(): void {
  document.querySelector(".tab-preview")?.remove();
}

function hideTabPreviewWhenPointerLeavesTabs(event: PointerEvent): void {
  if (!document.querySelector(".tab-preview")) return;
  const target = event.target;
  if (target instanceof HTMLElement && target.closest(".terminal-tab")) return;
  hideTabPreview();
}

function activateTab(id: string, shouldRenderTabs = true): void {
  activeTabID = id;
  for (const tab of tabs.values()) {
    tab.pane.classList.toggle("active", tab.id === id);
    if (tab.id === id) { tab.unread = false; tab.attention = "normal"; }
  }
  const active = tabs.get(id);
  setStatus(defaultStatusForTab(active), Boolean((active?.connecting || active?.zmodemActive) && !active.exited), false);
  if (shouldRenderTabs) {
    renderTabs();
  } else {
    for (const row of document.querySelectorAll<HTMLButtonElement>(".terminal-tab")) {
      row.classList.toggle("active", row.dataset.tabId === id);
    }
  }
  requestAnimationFrame(() => { scheduleActiveTerminalFit(); active?.terminal.focus(); });
}

function closeTab(id: string): void {
  const tab = tabs.get(id);
  if (!tab) return;
  if (!tab.exited && !confirm(`关闭终端 ${tab.title}？`)) return;
  tab.disposeData();
  tab.disposeExit();
  tab.disposeZmodem();
  tab.terminal.dispose();
  tab.pane.remove();
  window.shellx.terminal.dispose(id);
  tabs.delete(id);
  if (activeTabID === id) activeTabID = tabs.keys().next().value ?? null;
  if (activeTabID) activateTab(activeTabID);
  renderTabs();
}

function closeOtherTabs(id = activeTabID): void {
  if (!id) return;
  const closable = [...tabs.keys()].filter((tabID) => tabID !== id);
  if (closable.length === 0) return;
  if (!confirm(`关闭其他 ${closable.length} 个终端标签？`)) return;
  for (const tabID of closable) closeTabWithoutPrompt(tabID);
  activateTab(id);
}

function closeTabsRightOf(id = activeTabID): void {
  if (!id) return;
  const keys = [...tabs.keys()];
  const index = keys.indexOf(id);
  const closable = index >= 0 ? keys.slice(index + 1) : [];
  if (closable.length === 0) return;
  if (!confirm(`关闭右侧 ${closable.length} 个终端标签？`)) return;
  for (const tabID of closable) closeTabWithoutPrompt(tabID);
  activateTab(id);
}

function closeTabWithoutPrompt(id: string): void {
  const tab = tabs.get(id);
  if (!tab) return;
  tab.disposeData();
  tab.disposeExit();
  tab.disposeZmodem();
  tab.terminal.dispose();
  tab.pane.remove();
  window.shellx.terminal.dispose(id);
  tabs.delete(id);
  if (activeTabID === id) activeTabID = tabs.keys().next().value ?? null;
}

function togglePinned(id = activeTabID): void {
  const tab = id ? tabs.get(id) : undefined;
  if (!tab) return;
  tab.pinned = !tab.pinned;
  renderTabs();
}

async function duplicateTab(id = activeTabID): Promise<void> {
  const tab = id ? tabs.get(id) : undefined;
  if (!tab) return;
  await openTerminal(tab.request, tab.title, tab.subtitle, tab.id);
}

async function reconnectTab(id = activeTabID): Promise<void> {
  const tab = id ? tabs.get(id) : undefined;
  if (!tab) return;
  const request = tab.request;
  const title = tab.title;
  const subtitle = tab.subtitle;
  closeTabWithoutPrompt(tab.id);
  await openTerminal(request, title, subtitle);
}

async function openTerminal(request: CreateTerminalRequest, titleOverride?: string, subtitle = "", insertAfterTabID?: string): Promise<void> {
  viewMode = "terminal";
  if (!document.querySelector("#terminal-stack")) render();
  const pane = h("div", "terminal-pane");
  const surface = h("div", "terminal-surface");
  pane.append(surface);
  for (const tab of tabs.values()) tab.pane.classList.remove("active");
  pane.classList.add("active");
  document.querySelector<HTMLDivElement>("#terminal-stack")?.append(pane);
  document.querySelector<HTMLDivElement>("#empty")?.remove();
  const terminal = new Terminal({ cursorBlink: true, cursorStyle: "bar", scrollback: snapshot.settings.terminalScrollback, fontFamily: "Menlo, Monaco, 'SF Mono', monospace", fontSize: 13, lineHeight: terminalLineHeight, letterSpacing: 0, customGlyphs: true, macOptionIsMeta: true, reflowCursorLine: true, theme: terminalTheme });
  const fitAddon = new FitAddon();
  terminal.loadAddon(fitAddon);
  terminal.open(surface);
  resizeTerminalToFit(terminal, fitAddon);
  const initialPtySize = terminalPtySize(terminal);
  const { id, title } = await window.shellx.terminal.create({ ...request, ...initialPtySize });
  pane.addEventListener("contextmenu", (event) => { event.preventDefault(); activateTab(id); menu("terminal", { id }); });
  terminal.onData((data) => window.shellx.terminal.write(id, data));
  terminal.onResize(() => {
    const tab = tabs.get(id);
    if (tab) syncTerminalPtySize(tab);
  });
  terminal.attachCustomKeyEventHandler((event) => {
    if (event.metaKey && event.key.toLowerCase() === "w" && event.type === "keydown") { closeTab(id); return false; }
    if (event.metaKey && !event.altKey && !event.ctrlKey && !event.shiftKey && event.type === "keydown") {
      if (event.key === "ArrowLeft") { window.shellx.terminal.write(id, "\x01"); return false; }
      if (event.key === "ArrowRight") { window.shellx.terminal.write(id, "\x05"); return false; }
    }
    return true;
  });
  terminal.onSelectionChange(() => {
    if (!snapshot.settings.copySelectionToClipboard) return;
    scheduleSelectionClipboardCopy(terminal);
  });
  const disposeData = window.shellx.terminal.onData(id, (data) => {
    const tab = tabs.get(id);
    const displayData = displayableTerminalData(data);
    const hasZmodemMarker = zmodemPattern.test(data);
    const fallbackZmodemDirection = tab && hasZmodemMarker ? zmodemDirection(data, tab.recentOutput) : undefined;
    if (displayData) terminal.write(displayData);
    if (tab) {
      tab.recentOutput = `${tab.recentOutput}${displayData}`.slice(-4096);
      if (tab.connecting) {
        tab.connecting = false;
        if (activeTabID === id) setStatus(defaultStatusForTab(tab), false, false);
        renderTabs();
      }
      void handlePasswordPrompt(tab);
      if (!hasZmodemMarker && !tab.zmodemActive) tab.zmodemHandled = false;
      if (fallbackZmodemDirection) void maybeStartZmodem(tab, fallbackZmodemDirection);
    }
    if (tab && activeTabID !== id) {
      tab.unread = true;
      if (/password:|passphrase|\?\s*$|\[sudo\]|continue connecting|yes\/no/i.test(data)) tab.attention = "prompt";
      if (/error|failed|denied|refused|timeout|no route|permission denied/i.test(data)) tab.attention = "error";
      renderTabs();
    }
  });
  const disposeExit = window.shellx.terminal.onExit(id, ({ exitCode }) => {
    const tab = tabs.get(id);
    if (tab) { tab.exited = true; tab.connecting = false; }
    terminal.writeln(`\r\n[ShellX] process exited: ${exitCode ?? "signal"}`);
    renderTabs();
    setStatus("Process exited", false, false);
  });
  const disposeZmodem = window.shellx.terminal.onZmodemStatus(id, (payload) => {
    const tab = tabs.get(id);
    if (!tab) return;
    if (payload.state === "detected") {
      tab.transferMessage = payload.message;
      if (activeTabID === id) setStatus(payload.message, true, false);
      void maybeStartZmodem(tab, payload.direction);
      return;
    }
    tab.zmodemActive = payload.state === "started";
    tab.transferMessage = payload.message;
    if (payload.state === "finished") tab.zmodemHandled = false;
    if (payload.state === "failed") tab.terminal.write(`\r\n[ShellX] ${payload.message}\r\n`);
    if (activeTabID === id) setStatus(payload.message, payload.state === "started", payload.state !== "started");
  });
  insertTab(id, { id, title: titleOverride ?? title, subtitle, request, terminal, fitAddon, pane, disposeData, disposeExit, disposeZmodem, connecting: true, exited: false, pinned: false, unread: false, attention: "normal", recentOutput: "", passwordAutofillAttempted: false, passwordPromptPending: false, zmodemActive: false, zmodemHandled: false, transferMessage: "", lastPtyCols: initialPtySize.initialCols ?? ptyColsForTerminal(terminal), lastPtyRows: initialPtySize.initialRows ?? terminal.rows, lastFitPaneWidth: Math.round(pane.clientWidth), lastFitPaneHeight: Math.round(pane.clientHeight) }, insertAfterTabID);
  activateTab(id);
}

function insertTab(id: string, tab: TerminalTab, insertAfterTabID?: string): void {
  if (!insertAfterTabID || !tabs.has(insertAfterTabID)) {
    tabs.set(id, tab);
    return;
  }

  const entries = [...tabs.entries()];
  tabs.clear();
  for (const [existingID, existingTab] of entries) {
    tabs.set(existingID, existingTab);
    if (existingID === insertAfterTabID) tabs.set(id, tab);
  }
}

async function maybeStartZmodem(tab: TerminalTab, direction: "upload" | "download"): Promise<void> {
  if (tab.zmodemActive || tab.zmodemHandled) return;
  tab.zmodemHandled = true;
  const isUpload = direction === "upload";
  if (isUpload) {
    const result = await window.shellx.dialog.openPath({ multiple: true });
    if (result.canceled || result.filePaths.length === 0) { cancelPendingZmodem(tab); setStatus("已取消 lrzsz 上传", false, true); return; }
    const start = await window.shellx.terminal.startZmodemUpload(tab.id, result.filePaths);
    setStatus(start.message, start.ok, !start.ok);
    return;
  }
  const result = await window.shellx.dialog.openPath({
    directories: true,
    title: "选择 lrzsz 下载保存目录",
    buttonLabel: "选择此目录"
  });
  if (result.canceled || !result.filePaths[0]) { cancelPendingZmodem(tab); setStatus("已取消 lrzsz 下载", false, true); return; }
  const start = await window.shellx.terminal.startZmodemDownload(tab.id, result.filePaths[0]);
  setStatus(start.message, start.ok, !start.ok);
}

function cancelPendingZmodem(tab: TerminalTab): void {
  tab.zmodemHandled = true;
  tab.zmodemActive = false;
  tab.transferMessage = "";
  tab.terminal.write("\r\x1b[2K[ShellX] 已取消 lrzsz\r\n");
  window.shellx.terminal.write(tab.id, "\x18\x18\x18\x18\x18\x08\x08\x08\x08\x08\x03");
}

async function handlePasswordPrompt(tab: TerminalTab): Promise<void> {
  const request = tab.request;
  if (request.kind !== "ssh" || request.authMethod !== "password" || !request.sessionID) return;
  if (tab.passwordAutofillAttempted || tab.passwordPromptPending) return;
  if (!passwordPromptPattern.test(tab.recentOutput)) return;
  const session = snapshot.workspace.sessions.find((item) => item.id === request.sessionID);
  if (!session?.passwordStoredInKeychain) return;
  tab.passwordPromptPending = true;
  try {
    const password = await window.shellx.keychain.getPassword(session.id, keychainAccount(session));
    tab.passwordAutofillAttempted = true;
    if (password) {
      window.shellx.terminal.write(tab.id, `${password}\r`);
      if (activeTabID === tab.id) setStatus("已从 Keychain 自动填充密码", false, true);
    } else if (activeTabID === tab.id) {
      setStatus("Keychain 未找到该会话密码，请手动输入", false, true);
    }
  } finally {
    tab.passwordPromptPending = false;
  }
}

function presentDialog(title: string, className: string, renderBody: (body: HTMLElement) => void | (() => void)): void {
  const existing = document.querySelector<HTMLElement>(".sheet-overlay.app-dialog-overlay") as (HTMLElement & { shellxCleanup?: () => void }) | null;
  existing?.shellxCleanup?.();
  existing?.remove();
  const overlay = h("div", "sheet-overlay app-dialog-overlay");
  const sheet = h("section", `session-sheet app-dialog ${className}`);
  const header = h("div", "sheet-header dialog-header");
  let cleanup: (() => void) | undefined;
  const close = (): void => {
    cleanup?.();
    overlay.remove();
  };
  header.append(h("div", "", title), button("关闭", "secondary", close));
  const body = h("div", "sheet-body dialog-body");
  sheet.append(header, body);
  overlay.append(sheet);
  document.body.append(overlay);
  cleanup = renderBody(body) ?? undefined;
  (overlay as HTMLElement & { shellxCleanup?: () => void }).shellxCleanup = cleanup;
}

function presentScriptsDialog(): void { presentDialog("脚本管理", "script-dialog", renderScripts); }
function presentBatchDialog(): void { presentDialog("批量执行脚本", "batch-dialog", renderBatch); }
function presentSettingsDialog(): void { presentDialog("全局配置", "settings-dialog", renderSettings); }

function renderScripts(content: HTMLElement): void {
  content.innerHTML = `<section class="script-view"><aside class="script-list" id="script-list"></aside><section class="script-editor" id="script-editor"></section></section>`;
  const list = content.querySelector<HTMLDivElement>("#script-list")!;
  if (!selectedScriptID && !selectedScriptFolderID && snapshot.scriptLibrary.scripts[0]) {
    selectedScriptID = snapshot.scriptLibrary.scripts[0].id;
    selectedScriptFolderID = snapshot.scriptLibrary.scripts[0].folderID ?? null;
  }
  const toolbar = h("div", "script-toolbar");
  toolbar.append(button("+ 脚本", "primary", async () => { await createScript(false); renderScripts(content); }), button("+ 文件夹", "secondary", async () => { await createScriptFolder(selectedScriptFolderID ?? undefined, false); renderScripts(content); }));
  list.append(toolbar);
  const root = treeRow("全部脚本", !selectedScriptFolderID && !selectedScriptID, "root", () => { selectedScriptFolderID = null; selectedScriptID = null; renderScripts(content); }, 0, true, snapshot.scriptLibrary.scripts.length);
  root.addEventListener("contextmenu", (event) => { event.preventDefault(); selectedScriptFolderID = null; selectedScriptID = null; menu("scriptRoot", { root: true }); });
  enableScriptTreeDrop(root, undefined);
  list.append(root);
  for (const folder of childScriptFolders()) renderScriptFolder(list, folder, 1, content);
  for (const script of rootScripts()) list.append(scriptRow(script, 1, content));
  const editor = content.querySelector<HTMLDivElement>("#script-editor")!;
  const selectedFolder = selectedScriptFolderID ? snapshot.scriptLibrary.folders.find((folder) => folder.id === selectedScriptFolderID) : undefined;
  const script = selectedScript();
  if (selectedFolder && !selectedScriptID) {
    editor.append(h("div", "panel-title", "脚本文件夹"));
    editor.append(field("名称", selectedFolder.name, (value) => { selectedFolder.name = value; selectedFolder.updatedAt = now(); }));
    editor.append(selectField("上级文件夹", selectedFolder.parentID ?? "", scriptFolderOptions().filter(([id]) => id !== selectedFolder.id && !isDescendantScriptFolder(selectedFolder.id, id || undefined)), (value) => { selectedFolder.parentID = value || undefined; selectedFolder.updatedAt = now(); }));
    const actions = h("div", "actions");
    actions.append(button("保存", "primary", async () => { await window.shellx.app.saveScripts(snapshot.scriptLibrary); renderScripts(content); }), button("新建脚本", "secondary", async () => { await createScript(false, selectedFolder.id); renderScripts(content); }), button("删除", "danger", async () => { await deleteScriptFolder(selectedFolder.id); renderScripts(content); }));
    editor.append(actions);
    return;
  }
  if (!script) { editor.append(h("div", "empty-panel", "脚本库为空。")); return; }
  editor.append(h("div", "panel-title", "脚本管理"));
  editor.append(field("名称", script.name, (value) => { script.name = value; script.updatedAt = now(); }));
  editor.append(selectField("所属文件夹", script.folderID ?? "", scriptFolderOptions(), (value) => { script.folderID = value || undefined; script.updatedAt = now(); }));
  editor.append(selectField("语言", script.language, [["shell", "Shell"], ["python", "Python"]], (value) => { script.language = value; script.updatedAt = now(); renderScripts(content); }));
  editor.append(scriptContentEditor(script, () => {}));
  const actions = h("div", "actions");
  actions.append(button("保存", "primary", async () => { await window.shellx.app.saveScripts(snapshot.scriptLibrary); renderScripts(content); }), button("复制内容", "secondary", () => void copyScript(script.id)), button("删除", "danger", async () => { await deleteScript(script.id); renderScripts(content); }));
  editor.append(actions);
}

async function createScript(shouldRender = true, folderID = selectedScriptFolderID ?? undefined): Promise<void> {
  const script = newScript(folderID);
  snapshot.scriptLibrary.scripts.push(script);
  selectedScriptID = script.id;
  selectedScriptFolderID = folderID ?? null;
  if (script.folderID) expandedScriptFolderIDs.add(script.folderID);
  await window.shellx.app.saveScripts(snapshot.scriptLibrary);
  if (shouldRender) render();
}

async function createScriptFolder(parentID?: string, shouldRender = true): Promise<void> {
  const name = await promptText("新建脚本文件夹", "文件夹名称", "新建文件夹");
  if (!name) return;
  const timestamp = now();
  const folder = { id: uid(), parentID, name, createdAt: timestamp, updatedAt: timestamp };
  snapshot.scriptLibrary.folders.push(folder);
  selectedScriptFolderID = folder.id;
  selectedScriptID = null;
  expandedScriptFolderIDs.add(folder.id);
  if (parentID) expandedScriptFolderIDs.add(parentID);
  await persistScripts();
  if (shouldRender) render();
}

async function renameScriptFolder(folderID?: string): Promise<void> {
  const folder = snapshot.scriptLibrary.folders.find((item) => item.id === (folderID ?? selectedScriptFolderID));
  if (!folder) return;
  const name = await promptText("重命名脚本文件夹", "文件夹名称", folder.name);
  if (!name) return;
  folder.name = name;
  folder.updatedAt = now();
  await persistScripts();
}

async function deleteScriptFolder(folderID?: string): Promise<void> {
  const id = folderID ?? selectedScriptFolderID;
  const folder = snapshot.scriptLibrary.folders.find((item) => item.id === id);
  if (!folder) return;
  if (!confirm(`删除脚本文件夹「${folder.name}」？其中的脚本会移动到未分组。`)) return;
  const childIDs = new Set<string>([folder.id]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const child of snapshot.scriptLibrary.folders) {
      if (child.parentID && childIDs.has(child.parentID) && !childIDs.has(child.id)) { childIDs.add(child.id); changed = true; }
    }
  }
  snapshot.scriptLibrary.folders = snapshot.scriptLibrary.folders.filter((item) => !childIDs.has(item.id));
  for (const script of snapshot.scriptLibrary.scripts) if (script.folderID && childIDs.has(script.folderID)) script.folderID = undefined;
  selectedScriptFolderID = null;
  selectedScriptID = null;
  await persistScripts();
}

function renderScriptFolder(parent: HTMLElement, folder: ScriptFolder, level: number, content: HTMLElement): void {
  const expanded = expandedScriptFolderIDs.has(folder.id);
  const row = treeRow(folder.name, selectedScriptFolderID === folder.id && !selectedScriptID, "folder", () => {
    selectedScriptFolderID = folder.id;
    selectedScriptID = null;
    if (expanded) expandedScriptFolderIDs.delete(folder.id);
    else expandedScriptFolderIDs.add(folder.id);
    renderScripts(content);
  }, level, expanded, childScripts(folder.id).length);
  row.addEventListener("contextmenu", (event) => { event.preventDefault(); selectedScriptFolderID = folder.id; selectedScriptID = null; row.classList.add("active"); menu("scriptFolder", { id: folder.id }); });
  row.draggable = true;
  row.addEventListener("dragstart", (event) => {
    event.dataTransfer?.setData("application/x-shellx-script-folder", folder.id);
    event.dataTransfer?.setData("text/plain", folder.name);
  });
  enableScriptTreeDrop(row, folder.id);
  parent.append(row);
  if (expanded) {
    for (const child of childScriptFolders(folder.id)) renderScriptFolder(parent, child, level + 1, content);
    for (const script of childScripts(folder.id)) parent.append(scriptRow(script, level + 1, content));
  }
}

function scriptRow(script: UserScript, level: number, content: HTMLElement): HTMLDivElement {
  const row = treeRow(script.name || "未命名脚本", selectedScriptID === script.id, "session", () => { selectedScriptID = script.id; selectedScriptFolderID = script.folderID ?? null; renderScripts(content); }, level);
  row.addEventListener("contextmenu", (event) => { event.preventDefault(); selectedScriptID = script.id; selectedScriptFolderID = script.folderID ?? null; row.classList.add("active"); menu("script", { id: script.id }); });
  row.draggable = true;
  row.addEventListener("dragstart", (event) => {
    event.dataTransfer?.setData("application/x-shellx-script", script.id);
    event.dataTransfer?.setData("text/plain", script.name || "未命名脚本");
  });
  return row;
}

function enableScriptTreeDrop(row: HTMLElement, targetFolderID?: string): void {
  row.addEventListener("dragover", (event) => {
    if (event.dataTransfer?.types.includes("application/x-shellx-script") || event.dataTransfer?.types.includes("application/x-shellx-script-folder")) {
      event.preventDefault();
      row.classList.add("drop-target");
    }
  });
  row.addEventListener("dragleave", () => row.classList.remove("drop-target"));
  row.addEventListener("drop", (event) => {
    event.preventDefault();
    row.classList.remove("drop-target");
    const scriptID = event.dataTransfer?.getData("application/x-shellx-script");
    const folderID = event.dataTransfer?.getData("application/x-shellx-script-folder");
    if (scriptID) void moveScript(scriptID, targetFolderID);
    else if (folderID) void moveScriptFolder(folderID, targetFolderID);
  });
}

async function moveScript(scriptID: string, targetFolderID?: string): Promise<void> {
  const script = snapshot.scriptLibrary.scripts.find((item) => item.id === scriptID);
  if (!script || script.folderID === targetFolderID) return;
  script.folderID = targetFolderID;
  script.updatedAt = now();
  selectedScriptID = script.id;
  selectedScriptFolderID = targetFolderID ?? null;
  if (targetFolderID) expandedScriptFolderIDs.add(targetFolderID);
  await persistScripts();
}

function isDescendantScriptFolder(folderID: string, possibleParentID?: string): boolean {
  let cursor = possibleParentID;
  while (cursor) {
    if (cursor === folderID) return true;
    cursor = snapshot.scriptLibrary.folders.find((folder) => folder.id === cursor)?.parentID;
  }
  return false;
}

async function moveScriptFolder(folderID: string, targetParentID?: string): Promise<void> {
  const folder = snapshot.scriptLibrary.folders.find((item) => item.id === folderID);
  if (!folder || folder.id === targetParentID || folder.parentID === targetParentID || isDescendantScriptFolder(folder.id, targetParentID)) return;
  folder.parentID = targetParentID;
  folder.updatedAt = now();
  selectedScriptFolderID = folder.id;
  selectedScriptID = null;
  if (targetParentID) expandedScriptFolderIDs.add(targetParentID);
  await persistScripts();
}

async function copyScript(scriptID?: string): Promise<void> {
  const script = snapshot.scriptLibrary.scripts.find((item) => item.id === (scriptID ?? selectedScriptID));
  if (script) await navigator.clipboard.writeText(script.content);
}

async function deleteScript(scriptID?: string): Promise<void> {
  const script = snapshot.scriptLibrary.scripts.find((item) => item.id === (scriptID ?? selectedScriptID));
  if (!script) return;
  if (!confirm(`删除脚本「${script.name || "未命名脚本"}」？`)) return;
  snapshot.scriptLibrary.scripts = snapshot.scriptLibrary.scripts.filter((item) => item.id !== script.id);
  selectedScriptID = null;
  selectedScriptFolderID = script.folderID ?? null;
  await persistScripts();
}

function renderBatch(content: HTMLElement): void {
  content.innerHTML = `<section class="batch-view"><section class="form-panel" id="batch-form"></section><section class="output-panel" id="batch-output">等待执行</section></section>`;
  const form = document.querySelector<HTMLDivElement>("#batch-form")!;
  let scriptID = snapshot.scriptLibrary.scripts[0]?.id ?? "";
  let args = "";
  let timeoutSeconds = 3600;
  const selected = new Set<string>();
  form.append(selectField("脚本", scriptID, snapshot.scriptLibrary.scripts.map((script) => [script.id, scriptLabel(script)]), (value) => { scriptID = value; }));
  form.append(field("参数", args, (value) => { args = value; }));
  form.append(field("超时秒数", timeoutSeconds, (value) => { timeoutSeconds = Number(value) || 3600; }, { type: "number" }));
  const targets = h("div", "target-list");
  for (const session of snapshot.workspace.sessions) targets.append(checkbox(sessionTitle(session), false, (value) => value ? selected.add(session.id) : selected.delete(session.id)));
  form.append(h("h3", "", "目标会话"), targets, button("批量执行", "primary", async () => {
    const script = snapshot.scriptLibrary.scripts.find((item) => item.id === scriptID);
    const sessions = snapshot.workspace.sessions.filter((session) => selected.has(session.id));
    if (!script || sessions.length === 0) { setStatus("请选择脚本和目标会话", false, true); return; }
    const output = document.querySelector<HTMLDivElement>("#batch-output")!;
    output.textContent = "执行中...";
    const results = await window.shellx.batch.run({ script, sessions, args, timeoutSeconds });
    output.textContent = results.map(formatBatchResult).join("\n\n");
  }));
}

function formatBatchResult(result: BatchExecutionResult): string {
  return `[${result.status}] ${result.sessionName}\n${result.output || "(no output)"}`;
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function updateProgressText(progress: AppUpdateProgress): string {
  if (progress.phase === "downloading" && typeof progress.receivedBytes === "number") {
    const total = typeof progress.totalBytes === "number" ? ` / ${formatBytes(progress.totalBytes)}` : "";
    return `${progress.message}：${formatBytes(progress.receivedBytes)}${total}`;
  }
  return progress.message;
}

function updateProgressPercent(progress: AppUpdateProgress): number {
  if (typeof progress.percent === "number") return Math.max(0, Math.min(100, Math.round(progress.percent * 100)));
  if (progress.phase === "downloaded") return 100;
  return 0;
}

function renderUpdateControls(): { element: HTMLElement; dispose: () => void } {
  const panel = h("div", "update-panel");
  const progress = h("progress", "update-progress") as HTMLProgressElement;
  const status = h("p", "settings-help update-status", "未检查更新");
  const actions = h("div", "settings-action-row");
  const checkButton = button("检查更新", "secondary", () => void checkForUpdate());
  const restartButton = button("重启更新", "primary", () => void restartToInstallUpdate());
  progress.max = 100;
  progress.value = 0;
  restartButton.disabled = true;
  actions.append(checkButton, restartButton);
  panel.append(actions, progress, status);

  const dispose = window.shellx.app.onUpdateProgress((payload) => {
    progress.value = updateProgressPercent(payload);
    progress.classList.toggle("downloading", payload.phase === "downloading");
    status.textContent = updateProgressText(payload);
    checkButton.disabled = payload.phase === "checking" || payload.phase === "downloading" || payload.phase === "verifying";
    restartButton.disabled = payload.phase !== "downloaded";
  });

  async function checkForUpdate(): Promise<void> {
    checkButton.disabled = true;
    restartButton.disabled = true;
    progress.value = 0;
    progress.classList.remove("downloading");
    status.textContent = "正在检查更新...";
    const result = await window.shellx.app.checkAndDownloadUpdate();
    status.textContent = result.message;
    checkButton.disabled = false;
    restartButton.disabled = result.status !== "downloaded";
    progress.classList.remove("downloading");
  }

  async function restartToInstallUpdate(): Promise<void> {
    restartButton.disabled = true;
    checkButton.disabled = true;
    status.textContent = "正在准备重启更新...";
    const result = await window.shellx.app.installPendingUpdate();
    status.textContent = result.message;
    if (result.status === "failed") {
      checkButton.disabled = false;
      restartButton.disabled = false;
    }
  }

  return { element: panel, dispose };
}

function renderSettings(content: HTMLElement): () => void {
  const settings = snapshot.settings;
  content.innerHTML = `<section class="settings-view"><section class="settings-stack" id="settings-form"></section></section>`;
  const form = document.querySelector<HTMLDivElement>("#settings-form")!;
  const updateControls = renderUpdateControls();
  form.append(h("div", "settings-title", "全局配置"));
  form.append(settingsSection("界面主题", [selectField("主题模式", settings.theme, [["system", "跟随系统"], ["light", "浅色"], ["dark", "深色"]], (value) => { settings.theme = value; void persistSettings(); }), helpText("可在跟随系统、浅色和深色之间切换；修改后会立即作用于当前应用窗口。") ]));
  form.append(settingsSection("窗口行为", [checkbox("重新打开上次标签页", settings.reopenPreviousTabs, (value) => { settings.reopenPreviousTabs = value; void persistSettings(); }), helpText("关闭后会在主窗口重新打开时保留标签页；关闭该选项后，下次打开只进入默认状态。") ]));
  form.append(settingsSection("鼠标 / 触控板行为", [checkbox("选中文本复制", settings.copySelectionToClipboard, (value) => { settings.copySelectionToClipboard = value; void persistSettings(); }), helpText("控制终端选区变化后是否自动复制。关闭后仍可继续使用系统复制命令手动复制。") ]));
  form.append(settingsSection("终端性能", [field("终端历史行数上限", settings.terminalScrollback, (value) => { settings.terminalScrollback = Number(value) || 10000; void persistSettings(); }, { type: "number" }), checkbox("自动冻结后台标签", settings.autoFreezeTabs, (value) => { settings.autoFreezeTabs = value; void persistSettings(); }), field("打开多少个终端后开始自动冻结", settings.freezeThreshold, (value) => { settings.freezeThreshold = Number(value) || 12; void persistSettings(); }, { type: "number" }), field("保留最近多少个后台标签为热标签", settings.hotTabCount, (value) => { settings.hotTabCount = Number(value) || 6; void persistSettings(); }, { type: "number" }), helpText("固定标签、连接中、传输中、等待确认或出现提示/错误的标签不会被自动冻结。") ]));
  form.append(settingsSection("应用更新", [checkbox("自动更新", settings.autoUpdateEnabled, (value) => { settings.autoUpdateEnabled = value; void persistSettings(); }), updateControls.element]));
  return updateControls.dispose;
}

function settingsSection(title: string, children: HTMLElement[]): HTMLElement {
  const section = h("section", "form-panel settings-section");
  section.append(h("h3", "", title));
  for (const child of children) section.append(child);
  return section;
}

function helpText(value: string): HTMLElement {
  return h("p", "settings-help", value);
}

function escapeHTML(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function highlightPlainShell(value: string): string {
  return escapeHTML(value)
    .replace(/\b(if|then|else|elif|fi|for|in|do|done|case|esac|while|until|function|select|time)\b/g, '<span class="syntax-keyword">$1</span>')
    .replace(/(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|\$[0-9@#?*!-])/g, '<span class="syntax-variable">$1</span>');
}

function highlightShellLine(line: string): string {
  const commentIndex = line.search(/(^|\s)#/);
  const code = commentIndex >= 0 ? line.slice(0, commentIndex + (line[commentIndex] === "#" ? 0 : 1)) : line;
  const comment = commentIndex >= 0 ? line.slice(code.length) : "";
  const parts: string[] = [];
  let cursor = 0;
  const stringPattern = /(['"])(?:\\.|(?!\1).)*\1/g;
  for (const match of code.matchAll(stringPattern)) {
    const index = match.index ?? 0;
    parts.push(highlightPlainShell(code.slice(cursor, index)));
    parts.push(`<span class="syntax-string">${escapeHTML(match[0])}</span>`);
    cursor = index + match[0].length;
  }
  parts.push(highlightPlainShell(code.slice(cursor)));
  return parts.join("") + (comment ? `<span class="syntax-comment">${escapeHTML(comment)}</span>` : "");
}

function highlightPythonLine(line: string): string {
  const commentIndex = line.search(/(^|\s)#/);
  const code = commentIndex >= 0 ? line.slice(0, commentIndex + (line[commentIndex] === "#" ? 0 : 1)) : line;
  const comment = commentIndex >= 0 ? line.slice(code.length) : "";
  const parts: string[] = [];
  let cursor = 0;
  const stringPattern = /[rubfRUBF]*(['"])(?:\\.|(?!\1).)*\1/g;
  for (const match of code.matchAll(stringPattern)) {
    const index = match.index ?? 0;
    parts.push(escapeHTML(code.slice(cursor, index))
      .replace(/\b(False|None|True|and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|pass|raise|return|try|while|with|yield)\b/g, '<span class="syntax-keyword">$1</span>')
      .replace(/(@[A-Za-z_][A-Za-z0-9_.]*)/g, '<span class="syntax-variable">$1</span>'));
    parts.push(`<span class="syntax-string">${escapeHTML(match[0])}</span>`);
    cursor = index + match[0].length;
  }
  parts.push(escapeHTML(code.slice(cursor))
    .replace(/\b(False|None|True|and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|pass|raise|return|try|while|with|yield)\b/g, '<span class="syntax-keyword">$1</span>')
    .replace(/(@[A-Za-z_][A-Za-z0-9_.]*)/g, '<span class="syntax-variable">$1</span>'));
  return parts.join("") + (comment ? `<span class="syntax-comment">${escapeHTML(comment)}</span>` : "");
}

function highlightedScriptHTML(value: string, language: ScriptLanguage): string {
  const lines = value.split("\n");
  const highlighter = language === "python" ? highlightPythonLine : highlightShellLine;
  return lines.map((line) => highlighter(line) || " ").join("\n");
}

function scriptContentEditor(script: UserScript, onInput: () => void): HTMLElement {
  const wrap = h("label", "field script-content-field");
  const editor = h("div", "syntax-editor");
  const backdrop = h("pre", "syntax-backdrop");
  const code = h("code", "");
  const textarea = h("textarea", "syntax-input") as HTMLTextAreaElement;

  function redraw(): void {
    code.innerHTML = highlightedScriptHTML(script.content, script.language);
  }

  textarea.spellcheck = false;
  textarea.value = script.content;
  textarea.addEventListener("input", () => {
    script.content = textarea.value;
    script.updatedAt = now();
    redraw();
    onInput();
  });
  textarea.addEventListener("scroll", () => {
    backdrop.scrollTop = textarea.scrollTop;
    backdrop.scrollLeft = textarea.scrollLeft;
  });
  backdrop.append(code);
  editor.append(backdrop, textarea);
  wrap.append(h("span", "field-label", "内容"), editor);
  redraw();
  return wrap;
}

async function handleAppCommand(event: AppCommandEvent): Promise<void> {
  const id = payloadID(event.payload);
  switch (event.command) {
    case "view:terminal": viewMode = "terminal"; render(); break;
    case "view:scripts": presentScriptsDialog(); break;
    case "view:batch": presentBatchDialog(); break;
    case "view:settings": presentSettingsDialog(); break;
    case "folder:new": await createFolder(isRootPayload(event.payload) ? undefined : id ?? selectedFolderID ?? undefined); break;
    case "folder:rename": await renameFolder(id); break;
    case "folder:delete": await deleteFolder(id); break;
    case "session:new": createSession(isRootPayload(event.payload) ? null : id); break;
    case "session:connect": await connectSelected(id); break;
    case "session:edit": editSession(id); break;
    case "session:duplicate": await duplicateSession(id); break;
    case "session:delete": await deleteSession(id); break;
    case "terminal:newLocal": await openTerminal({ kind: "local" }, "本机终端", "local"); break;
    case "tab:activate": if (id) activateTab(id); break;
    case "tab:close": closeTab(id ?? activeTabID ?? ""); break;
    case "tab:closeOthers": closeOtherTabs(id ?? activeTabID); break;
    case "tab:closeRight": closeTabsRightOf(id ?? activeTabID); break;
    case "tab:togglePinned": togglePinned(id ?? activeTabID); break;
    case "tab:duplicate": await duplicateTab(id ?? activeTabID); break;
    case "tab:reconnect": await reconnectTab(id ?? activeTabID); break;
    case "terminal:copy": {
      const tab = tabs.get(id ?? activeTabID ?? "");
      const selection = tab?.terminal.getSelection();
      if (selection) await navigator.clipboard.writeText(selection);
      break;
    }
    case "terminal:paste": {
      const tab = tabs.get(id ?? activeTabID ?? "");
      const value = await navigator.clipboard.readText();
      if (tab && value) window.shellx.terminal.write(tab.id, value);
      break;
    }
    case "script:new": await createScript(false, isRootPayload(event.payload) ? undefined : id ?? selectedScriptFolderID ?? undefined); presentScriptsDialog(); break;
    case "script:copy": await copyScript(id); break;
    case "script:delete": await deleteScript(id); break;
    case "scriptFolder:new": await createScriptFolder(isRootPayload(event.payload) ? undefined : id ?? selectedScriptFolderID ?? undefined, false); presentScriptsDialog(); break;
    case "scriptFolder:rename": await renameScriptFolder(id); presentScriptsDialog(); break;
    case "scriptFolder:delete": await deleteScriptFolder(id); presentScriptsDialog(); break;
    case "data:export": {
      const result = await window.shellx.app.exportData();
      if (!result.canceled) setStatus(`已导出 ${result.filePaths[0]}`, false, true);
      break;
    }
    case "data:import": {
      const imported = await window.shellx.app.importData();
      if (imported) { snapshot = imported; snapshot.scriptLibrary = normalizeScriptLibrary(snapshot.scriptLibrary); render(); }
      break;
    }
  }
}

const resizeObserver = new ResizeObserver(() => {
  scheduleActiveTerminalFit();
});

window.addEventListener("resize", scheduleActiveTerminalFitAfterLayout);
window.addEventListener("pointermove", hideTabPreviewWhenPointerLeavesTabs, true);
window.addEventListener("blur", hideTabPreview);

void (async () => {
  snapshot = await window.shellx.app.load();
  snapshot.scriptLibrary = normalizeScriptLibrary(snapshot.scriptLibrary);
  setWindowFullScreen(await window.shellx.app.isFullScreen());
  window.shellx.app.onFullScreenChange(setWindowFullScreen);
  window.shellx.app.onCommand((event) => { void handleAppCommand(event); });
  selectedSessionID = snapshot.workspace.sessions[0]?.id ?? null;
  render();
  const stack = document.querySelector<HTMLDivElement>("#terminal-stack");
  if (stack) resizeObserver.observe(stack);
  void openTerminal({ kind: "local" }, "本机终端", "local");
})();
