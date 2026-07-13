import { app, BrowserWindow, dialog, ipcMain, Menu, nativeImage, nativeTheme } from "electron";
import type { IpcMainInvokeEvent, MenuItemConstructorOptions, WebContents } from "electron";
import { execFile, spawn } from "node:child_process";
import type { ChildProcessWithoutNullStreams } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { createWriteStream, existsSync, promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { StringDecoder } from "node:string_decoder";
import { fileURLToPath } from "node:url";
import pty from "node-pty";
import type {
  AppSettings,
  AppSnapshot,
  AppUpdateProgress,
  AppUpdateResult,
  BatchExecutionRequest,
  BatchExecutionResult,
  CreateTerminalRequest,
  CreateTerminalResponse,
  DialogFileResult,
  RemoteNetworkForwarding,
  ScriptFolder,
  ScriptLibrary,
  SessionWorkspace,
  SSHSessionProfile,
  TerminalExitPayload,
  ZmodemStatusPayload
} from "../shared/terminal.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

interface ManagedTerminal {
  id: string;
  title: string;
  ptyProcess: pty.IPty;
  decoder: StringDecoder;
  ptyCols: number;
  ptyRows: number;
  codexHome?: string;
  pendingZmodemInput?: Buffer[];
  pendingZmodemInputBytes?: number;
  pendingZmodemScanTail?: Buffer;
  pendingZmodemNotified?: boolean;
  transfer?: {
    direction: "upload" | "download";
    child: ChildProcessWithoutNullStreams;
    downloadRemoteFinSeen?: boolean;
    downloadFinReplySent?: boolean;
    downloadRemoteReturnedToShell?: boolean;
    downloadHelperOOSent?: boolean;
    uploadRemoteReturnedToShell?: boolean;
    uploadHelperOOSent?: boolean;
  };
}

const terminals = new Map<string, ManagedTerminal>();
let mainWindow: BrowserWindow | null = null;
let didCreateMainWindow = false;
let pendingDownloadedUpdate: { assetPath: string; latestVersion: string } | null = null;
const fixedWebContentsZoomLevel = 0;
const fixedWebContentsZoomFactor = 1;
const zmodemIntroBytes = Buffer.from("**\x18", "binary");
const zmodemHeaderEncodingBytes = new Set([0x41, 0x42, 0x43]);
const zmodemFrameTypePrefixByte = 0x30;
const zmodemFrameTypeDownload = 0x30;
const zmodemFrameTypeUpload = 0x31;
const zmodemFrameTypeFin = 0x38;
const zmodemCancelBytes = Buffer.from("\x18\x18\x18\x18\x18\x08\x08\x08\x08\x08\x03", "binary");
const pendingZmodemInputLimit = 1024 * 1024;
const shellToolPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(":");
const shellToolDirs = shellToolPath.split(":");
const codexHistoryFileName = "history.jsonl";
const codexVolatileHomeEntries = new Set([".tmp", "log", "tmp"]);
const codexSQLiteFilePattern = /^(state|logs|goals|memories)_\d+\.sqlite(?:-(?:shm|wal))?$/;

type AppCommandPayload = Record<string, unknown> | undefined;

interface GitHubReleaseAsset {
  name: string;
  browser_download_url: string;
  size: number;
}

interface GitHubRelease {
  id: number;
  tag_name: string;
  name?: string;
  draft: boolean;
  prerelease: boolean;
  assets: GitHubReleaseAsset[];
}

interface UpdateAsset {
  name: string;
  downloadURL: string;
  sha256URL: string;
  size: number;
}

interface ContextMenuRequest {
  type: "root" | "folder" | "session" | "tab" | "terminal" | "script" | "scriptRoot" | "scriptFolder";
  payload?: Record<string, unknown>;
}

const defaultSettings: AppSettings = {
  theme: "system",
  reopenPreviousTabs: true,
  copySelectionToClipboard: false,
  terminalScrollback: 10000,
  autoFreezeTabs: true,
  freezeThreshold: 12,
  hotTabCount: 6,
  autoUpdateEnabled: false
};

function storageRoot(): string {
  return path.join(app.getPath("userData"));
}

function storageFile(name: string): string {
  return path.join(storageRoot(), name);
}

function workspaceRoot(): string {
  return path.join(storageRoot(), "workspace");
}

function sessionsRoot(): string {
  return path.join(workspaceRoot(), "sessions");
}

function scriptsRoot(): string {
  return path.join(workspaceRoot(), "scripts");
}

function updatesRoot(): string {
  return path.join(storageRoot(), "Updates");
}

function codexTerminalHomesRoot(): string {
  return path.join(storageRoot(), "CodexTerminalHomes");
}

function legacyShellXRoot(): string {
  return path.join(app.getPath("appData"), "ShellX");
}

function legacyMigrationMarkerFile(): string {
  return path.join(workspaceRoot(), "swift-shellx-migration.json");
}

async function ensureStorage(): Promise<void> {
  await fs.mkdir(storageRoot(), { recursive: true });
}

async function readJSON<T>(fileName: string, fallback: T): Promise<T> {
  await ensureStorage();
  try {
    return JSON.parse(await fs.readFile(storageFile(fileName), "utf8")) as T;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return fallback;
    throw error;
  }
}

async function writeJSON<T>(fileName: string, value: T): Promise<void> {
  await ensureStorage();
  await fs.writeFile(storageFile(fileName), `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

async function readJSONFile<T>(filePath: string): Promise<T> {
  return JSON.parse(await fs.readFile(filePath, "utf8")) as T;
}

async function writeJSONFile<T>(filePath: string, value: T): Promise<void> {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function safeFileSegment(value: string, fallback: string): string {
  const cleaned = value
    .trim()
    .replace(/[\\/:*?"<>|]/g, "-")
    .replace(/\s+/g, " ")
    .replace(/^\.+$/, "")
    .slice(0, 72);
  return cleaned || fallback;
}

function entityName(name: string, id: string, fallback: string, extension = "json"): string {
  return `${safeFileSegment(name, fallback)}__${id}.${extension}`;
}

function folderDirectoryName(folder: { id: string; name: string }): string {
  return `${safeFileSegment(folder.name, "folder")}__${folder.id}`;
}

function normalizeScriptLibrary(library: Partial<ScriptLibrary> | null | undefined): ScriptLibrary {
  return { folders: library?.folders ?? [], scripts: library?.scripts ?? [] };
}

async function pathExists(filePath: string): Promise<boolean> {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

function expandHomePath(filePath: string): string {
  if (filePath === "~") return os.homedir();
  if (filePath.startsWith("~/")) return path.join(os.homedir(), filePath.slice(2));
  return filePath;
}

function resolvedCodexSourceHome(): string | undefined {
  const configured = process.env.CODEX_HOME?.trim();
  if (configured) return path.resolve(expandHomePath(configured));
  const home = os.homedir();
  return home ? path.join(home, ".codex") : undefined;
}

function shouldLinkCodexHomeEntry(entryName: string): boolean {
  if (entryName === codexHistoryFileName) return false;
  if (codexVolatileHomeEntries.has(entryName)) return false;
  if (codexSQLiteFilePattern.test(entryName)) return false;
  return true;
}

function isPathWithin(parentPath: string, candidatePath: string): boolean {
  const relative = path.relative(parentPath, candidatePath);
  return Boolean(relative) && !relative.startsWith("..") && !path.isAbsolute(relative);
}

async function prepareCodexHomeForTerminal(id: string): Promise<string | undefined> {
  const sourceHome = resolvedCodexSourceHome();
  if (!sourceHome || !(await pathExists(sourceHome))) return undefined;
  const targetHome = path.join(codexTerminalHomesRoot(), id);
  await fs.rm(targetHome, { recursive: true, force: true });
  await fs.mkdir(targetHome, { recursive: true });

  // Keep Codex config/session resources shared, but leave history.jsonl per terminal tab.
  let entries: import("node:fs").Dirent[] = [];
  try {
    entries = await fs.readdir(sourceHome, { withFileTypes: true });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return targetHome;
    throw error;
  }

  for (const entry of entries) {
    if (!shouldLinkCodexHomeEntry(entry.name)) continue;
    const sourcePath = path.join(sourceHome, entry.name);
    const targetPath = path.join(targetHome, entry.name);
    try {
      await fs.symlink(sourcePath, targetPath, entry.isDirectory() ? "dir" : "file");
    } catch (error) {
      console.warn(`Unable to link Codex home entry ${entry.name}:`, error);
    }
  }

  return targetHome;
}

function cleanupCodexHome(codexHome: string | undefined): void {
  if (!codexHome || !isPathWithin(codexTerminalHomesRoot(), codexHome)) return;
  void fs.rm(codexHome, { recursive: true, force: true }).catch((error) => {
    console.warn(`Unable to clean Codex terminal home ${codexHome}:`, error);
  });
}

async function replaceDirectory(tempPath: string, targetPath: string): Promise<void> {
  await fs.rm(tempPath, { recursive: true, force: true });
  await fs.mkdir(tempPath, { recursive: true });
}

async function readWorkspaceDirectory(directory: string, parentID: string | undefined, folders: SessionWorkspace["folders"], sessions: SessionWorkspace["sessions"]): Promise<void> {
  let entries: import("node:fs").Dirent[] = [];
  try {
    entries = await fs.readdir(directory, { withFileTypes: true });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
    throw error;
  }

  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      const folderPath = path.join(entryPath, "folder.json");
      if (!(await pathExists(folderPath))) continue;
      const folder = await readJSONFile<SessionWorkspace["folders"][number]>(folderPath);
      folders.push({ ...folder, parentID });
      await readWorkspaceDirectory(entryPath, folder.id, folders, sessions);
    } else if (entry.isFile() && entry.name.endsWith(".json") && entry.name !== "folder.json") {
      const session = await readJSONFile<SSHSessionProfile>(entryPath);
      sessions.push({ ...session, folderID: parentID });
    }
  }
}

async function readWorkspaceTopology(): Promise<SessionWorkspace | null> {
  if (!(await pathExists(sessionsRoot()))) return null;
  const workspace: SessionWorkspace = { folders: [], sessions: [] };
  await readWorkspaceDirectory(sessionsRoot(), undefined, workspace.folders, workspace.sessions);
  return workspace;
}

async function writeWorkspaceTopology(workspace: SessionWorkspace): Promise<void> {
  await ensureStorage();
  const target = sessionsRoot();
  const temp = `${target}.tmp`;
  await replaceDirectory(temp, target);

  const folderPaths = new Map<string, string>();
  const children = new Map<string, SessionWorkspace["folders"]>();
  for (const folder of workspace.folders) {
    const key = folder.parentID ?? "";
    children.set(key, [...(children.get(key) ?? []), folder]);
  }

  async function writeFolder(folder: SessionWorkspace["folders"][number], parentPath: string): Promise<void> {
    const folderPath = path.join(parentPath, folderDirectoryName(folder));
    folderPaths.set(folder.id, folderPath);
    await writeJSONFile(path.join(folderPath, "folder.json"), folder);
    for (const child of (children.get(folder.id) ?? []).sort((a, b) => a.name.localeCompare(b.name))) await writeFolder(child, folderPath);
  }

  for (const folder of (children.get("") ?? []).sort((a, b) => a.name.localeCompare(b.name))) await writeFolder(folder, temp);
  for (const session of workspace.sessions) {
    const parentPath = session.folderID ? folderPaths.get(session.folderID) ?? temp : temp;
    await writeJSONFile(path.join(parentPath, entityName(session.name || session.host, session.id, "session")), session);
  }

  await fs.rm(target, { recursive: true, force: true });
  await fs.rename(temp, target);
}

async function readScriptTopology(): Promise<ScriptLibrary | null> {
  if (!(await pathExists(scriptsRoot()))) return null;
  const library: ScriptLibrary = { folders: [], scripts: [] };
  await readScriptDirectory(scriptsRoot(), undefined, library.folders, library.scripts);
  return library;
}

async function readScriptDirectory(directory: string, parentID: string | undefined, folders: ScriptFolder[], scripts: ScriptLibrary["scripts"]): Promise<void> {
  let entries: import("node:fs").Dirent[] = [];
  try {
    entries = await fs.readdir(directory, { withFileTypes: true });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
    throw error;
  }

  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      const folderPath = path.join(entryPath, "folder.json");
      if (!(await pathExists(folderPath))) continue;
      const folder = await readJSONFile<ScriptFolder>(folderPath);
      folders.push({ ...folder, parentID });
      await readScriptDirectory(entryPath, folder.id, folders, scripts);
    } else if (entry.isFile() && entry.name.endsWith(".json") && entry.name !== "folder.json") {
      const script = await readJSONFile<ScriptLibrary["scripts"][number]>(entryPath);
      scripts.push({ ...script, folderID: parentID });
    }
  }
}

async function readLegacyShellXWorkspace(): Promise<SessionWorkspace | null> {
  const legacyRoot = legacyShellXRoot();
  const legacySessionsRoot = path.join(legacyRoot, "Sessions");
  if (await pathExists(legacySessionsRoot)) {
    const workspace: SessionWorkspace = { folders: [], sessions: [] };
    await readWorkspaceDirectory(legacySessionsRoot, undefined, workspace.folders, workspace.sessions);
    return workspace;
  }

  const legacyFile = path.join(legacyRoot, "sessions.json");
  if (!(await pathExists(legacyFile))) return null;
  return readJSONFile<SessionWorkspace>(legacyFile);
}

async function readLegacyShellXScripts(): Promise<ScriptLibrary | null> {
  const legacyRoot = legacyShellXRoot();
  const legacyScriptsRoot = path.join(legacyRoot, "Scripts");
  if (await pathExists(legacyScriptsRoot)) {
    let entries: import("node:fs").Dirent[] = [];
    try {
      entries = await fs.readdir(legacyScriptsRoot, { withFileTypes: true });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
      throw error;
    }
    const scripts: ScriptLibrary["scripts"] = [];
    for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
      if (!entry.isFile() || !entry.name.endsWith(".json")) continue;
      scripts.push(await readJSONFile<ScriptLibrary["scripts"][number]>(path.join(legacyScriptsRoot, entry.name)));
    }
    return { folders: [], scripts };
  }

  const legacyFile = path.join(legacyRoot, "scripts.json");
  if (!(await pathExists(legacyFile))) return null;
  return normalizeScriptLibrary(await readJSONFile<Partial<ScriptLibrary>>(legacyFile));
}

function mergeWorkspace(base: SessionWorkspace, incoming: SessionWorkspace): { workspace: SessionWorkspace; importedFolders: number; importedSessions: number } {
  const folderIDs = new Set(base.folders.map((folder) => folder.id));
  const sessionIDs = new Set(base.sessions.map((session) => session.id));
  const importedFolders = incoming.folders.filter((folder) => !folderIDs.has(folder.id));
  const importedSessions = incoming.sessions.filter((session) => !sessionIDs.has(session.id));
  return {
    workspace: {
      folders: [...base.folders, ...importedFolders],
      sessions: [...base.sessions, ...importedSessions]
    },
    importedFolders: importedFolders.length,
    importedSessions: importedSessions.length
  };
}

function mergeScripts(base: ScriptLibrary, incoming: ScriptLibrary): { library: ScriptLibrary; importedScripts: number } {
  const folderIDs = new Set(base.folders.map((folder) => folder.id));
  const scriptIDs = new Set(base.scripts.map((script) => script.id));
  const importedFolders = incoming.folders.filter((folder) => !folderIDs.has(folder.id));
  const importedScripts = incoming.scripts.filter((script) => !scriptIDs.has(script.id));
  return { library: { folders: [...base.folders, ...importedFolders], scripts: [...base.scripts, ...importedScripts] }, importedScripts: importedScripts.length };
}

async function copyLegacyKnownHostsIfNeeded(): Promise<boolean> {
  const source = path.join(legacyShellXRoot(), "known_hosts");
  if (!(await pathExists(source))) return false;
  const target = path.join(workspaceRoot(), "known_hosts");
  if (await pathExists(target)) return false;
  await fs.mkdir(workspaceRoot(), { recursive: true });
  await fs.copyFile(source, target);
  return true;
}

async function writeScriptTopology(library: ScriptLibrary): Promise<void> {
  await ensureStorage();
  const target = scriptsRoot();
  const temp = `${target}.tmp`;
  await replaceDirectory(temp, target);

  const normalized = normalizeScriptLibrary(library);
  const folderPaths = new Map<string, string>();
  const children = new Map<string, ScriptFolder[]>();
  for (const folder of normalized.folders) {
    const key = folder.parentID ?? "";
    children.set(key, [...(children.get(key) ?? []), folder]);
  }

  async function writeFolder(folder: ScriptFolder, parentPath: string): Promise<void> {
    const folderPath = path.join(parentPath, folderDirectoryName(folder));
    await fs.mkdir(folderPath, { recursive: true });
    folderPaths.set(folder.id, folderPath);
    await writeJSONFile(path.join(folderPath, "folder.json"), folder);
    for (const child of (children.get(folder.id) ?? []).sort((a, b) => a.name.localeCompare(b.name))) await writeFolder(child, folderPath);
  }

  for (const folder of (children.get("") ?? []).sort((a, b) => a.name.localeCompare(b.name))) await writeFolder(folder, temp);
  for (const script of normalized.scripts) {
    const parentPath = script.folderID ? folderPaths.get(script.folderID) ?? temp : temp;
    await writeJSONFile(path.join(parentPath, entityName(script.name, script.id, "script")), script);
  }
  await fs.rm(target, { recursive: true, force: true });
  await fs.rename(temp, target);
}

async function migrateLegacyStorageIfNeeded(): Promise<void> {
  const workspace = await readWorkspaceTopology();
  if (!workspace) {
    const legacyWorkspace = await readJSON<SessionWorkspace>("sessions.json", { folders: [], sessions: [] });
    if (legacyWorkspace.folders.length > 0 || legacyWorkspace.sessions.length > 0) await writeWorkspaceTopology(legacyWorkspace);
  }

  const scripts = await readScriptTopology();
  if (!scripts) {
    const legacyScripts = normalizeScriptLibrary(await readJSON<Partial<ScriptLibrary>>("scripts.json", { scripts: [] }));
    if (legacyScripts.scripts.length > 0) await writeScriptTopology(legacyScripts);
  }
}

async function migrateLegacyShellXDataIfNeeded(): Promise<void> {
  if (await pathExists(legacyMigrationMarkerFile())) return;

  const existingWorkspace = await readWorkspaceTopology() ?? { folders: [], sessions: [] };
  const existingScripts = await readScriptTopology() ?? { folders: [], scripts: [] };
  const legacyWorkspace = await readLegacyShellXWorkspace();
  const legacyScripts = await readLegacyShellXScripts();

  let importedFolders = 0;
  let importedSessions = 0;
  let importedScripts = 0;
  let copiedKnownHosts = false;

  if (legacyWorkspace) {
    const merged = mergeWorkspace(existingWorkspace, legacyWorkspace);
    importedFolders = merged.importedFolders;
    importedSessions = merged.importedSessions;
    if (importedFolders > 0 || importedSessions > 0) await writeWorkspaceTopology(merged.workspace);
  }

  if (legacyScripts) {
    const merged = mergeScripts(existingScripts, legacyScripts);
    importedScripts = merged.importedScripts;
    if (importedScripts > 0) await writeScriptTopology(merged.library);
  }

  copiedKnownHosts = await copyLegacyKnownHostsIfNeeded();
  await writeJSONFile(legacyMigrationMarkerFile(), {
    migratedAt: new Date().toISOString(),
    source: legacyShellXRoot(),
    importedFolders,
    importedSessions,
    importedScripts,
    copiedKnownHosts
  });
}

function applyTheme(theme: AppSettings["theme"]): void {
  nativeTheme.themeSource = theme;
}

function appIconPath(): string {
  return app.isPackaged
    ? path.join(process.resourcesPath, "icon.icns")
    : path.join(__dirname, "../../assets/icon.icns");
}

function applyDockIcon(): void {
  if (process.platform !== "darwin" || !app.dock) return;
  const iconPath = appIconPath();
  if (!existsSync(iconPath)) return;
  const icon = nativeImage.createFromPath(iconPath);
  if (!icon.isEmpty()) app.dock.setIcon(icon);
}

function sendCommand(command: string, payload?: AppCommandPayload): void {
  const target = BrowserWindow.getFocusedWindow() ?? mainWindow;
  target?.webContents.send("app:command", { command, payload });
}

function isZoomShortcutInput(input: { key?: string; meta?: boolean; control?: boolean; alt?: boolean; type?: string }): boolean {
  if (input.type && input.type !== "keyDown") return false;
  const key = input.key?.toLowerCase();
  const isCommandOrControl = process.platform === "darwin" ? input.meta : input.control;
  return Boolean(isCommandOrControl && !input.alt && key && ["+", "=", "-", "_", "0"].includes(key));
}

function isReloadShortcutInput(input: { key?: string; meta?: boolean; control?: boolean; alt?: boolean; shift?: boolean; type?: string }): boolean {
  if (input.type && input.type !== "keyDown") return false;
  const key = input.key?.toLowerCase();
  const isCommandOrControl = process.platform === "darwin" ? input.meta : input.control;
  return Boolean(isCommandOrControl && !input.alt && !input.shift && key === "r");
}

function lockWebContentsZoom(contents: WebContents): void {
  const resetZoom = (): void => {
    if (contents.isDestroyed()) return;
    if (contents.getZoomLevel() !== fixedWebContentsZoomLevel) contents.setZoomLevel(fixedWebContentsZoomLevel);
    if (contents.getZoomFactor() !== fixedWebContentsZoomFactor) contents.setZoomFactor(fixedWebContentsZoomFactor);
  };

  contents.on("zoom-changed", (event) => {
    event.preventDefault();
    resetZoom();
  });
  contents.on("before-input-event", (event, input) => {
    if (isReloadShortcutInput(input)) {
      event.preventDefault();
      return;
    }
    if (!isZoomShortcutInput(input)) return;
    event.preventDefault();
    resetZoom();
  });
  contents.on("did-finish-load", resetZoom);
  resetZoom();
}

function menuItem(label: string, command: string, payload?: AppCommandPayload, accelerator?: string): MenuItemConstructorOptions {
  return { label, accelerator, click: () => sendCommand(command, payload) };
}

function setNativeMenu(): void {
  const isMac = process.platform === "darwin";
  const template: MenuItemConstructorOptions[] = [
    ...(isMac ? [{ label: app.name, submenu: [{ role: "about" as const }, { type: "separator" as const }, { role: "services" as const }, { type: "separator" as const }, { role: "hide" as const }, { role: "hideOthers" as const }, { role: "unhide" as const }, { type: "separator" as const }, { role: "quit" as const }] }] : []),
    {
      label: "文件",
      submenu: [
        menuItem("新建会话", "session:new", undefined, "CommandOrControl+N"),
        menuItem("新建文件夹", "folder:new", undefined, "Shift+CommandOrControl+N"),
        { type: "separator" },
        menuItem("导入数据...", "data:import"),
        menuItem("导出数据...", "data:export"),
        { type: "separator" },
        isMac ? { role: "close" } : { role: "quit" }
      ]
    },
    {
      label: "会话",
      submenu: [
        menuItem("连接", "session:connect", undefined, "CommandOrControl+Return"),
        menuItem("编辑会话...", "session:edit", undefined, "CommandOrControl+E"),
        menuItem("复制会话", "session:duplicate", undefined, "Shift+CommandOrControl+D"),
        menuItem("删除会话", "session:delete"),
        { type: "separator" },
        menuItem("打开本机终端", "terminal:newLocal", undefined, "CommandOrControl+T")
      ]
    },
    {
      label: "终端",
      submenu: [
        menuItem("关闭当前标签", "tab:close", undefined, "CommandOrControl+W"),
        menuItem("关闭其他标签", "tab:closeOthers"),
        menuItem("关闭右侧标签", "tab:closeRight"),
        { type: "separator" },
        menuItem("固定/取消固定", "tab:togglePinned"),
        menuItem("复制到新标签", "tab:duplicate"),
        { type: "separator" },
        { role: "copy" },
        { role: "paste" },
        { role: "selectAll" }
      ]
    },
    {
      label: "脚本",
      submenu: [
        menuItem("脚本管理", "view:scripts", undefined, "CommandOrControl+2"),
        menuItem("批量执行脚本", "view:batch", undefined, "CommandOrControl+3"),
        { type: "separator" },
        menuItem("新建脚本", "script:new"),
        menuItem("新建脚本文件夹", "scriptFolder:new"),
        menuItem("复制脚本内容", "script:copy"),
        menuItem("删除脚本", "script:delete")
      ]
    },
    {
      label: "显示",
      submenu: [
        menuItem("终端工作台", "view:terminal", undefined, "CommandOrControl+1"),
        menuItem("全局配置", "view:settings", undefined, "CommandOrControl+,"),
        { type: "separator" },
        { role: "toggleDevTools" },
        { type: "separator" },
        { role: "togglefullscreen" }
      ]
    }
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

function contextTemplate(request: ContextMenuRequest): MenuItemConstructorOptions[] {
  const payload = request.payload;
  if (request.type === "root") return [menuItem("新建会话", "session:new", payload), menuItem("新建文件夹", "folder:new", payload), { type: "separator" }, menuItem("打开本机终端", "terminal:newLocal")];
  if (request.type === "folder") return [menuItem("在此新建会话", "session:new", payload), menuItem("新建子文件夹", "folder:new", payload), { type: "separator" }, menuItem("重命名文件夹", "folder:rename", payload), menuItem("删除文件夹", "folder:delete", payload)];
  if (request.type === "session") return [menuItem("连接", "session:connect", payload), menuItem("编辑...", "session:edit", payload), menuItem("复制会话", "session:duplicate", payload), { type: "separator" }, menuItem("删除会话", "session:delete", payload)];
  if (request.type === "tab") return [menuItem("切换到此标签", "tab:activate", payload), menuItem("重连", "tab:reconnect", payload), menuItem("固定/取消固定", "tab:togglePinned", payload), menuItem("复制到新标签", "tab:duplicate", payload), { type: "separator" }, menuItem("关闭右侧标签", "tab:closeRight", payload), menuItem("关闭其他标签", "tab:closeOthers", payload), menuItem("关闭当前标签", "tab:close", payload)];
  if (request.type === "terminal") return [menuItem("复制", "terminal:copy", payload), menuItem("粘贴", "terminal:paste", payload), { role: "selectAll" }, { type: "separator" }, menuItem("关闭当前标签", "tab:close", payload)];
  if (request.type === "scriptRoot") return [menuItem("新建脚本", "script:new", payload), menuItem("新建脚本文件夹", "scriptFolder:new", payload)];
  if (request.type === "scriptFolder") return [menuItem("在此新建脚本", "script:new", payload), menuItem("新建子文件夹", "scriptFolder:new", payload), { type: "separator" }, menuItem("重命名文件夹", "scriptFolder:rename", payload), menuItem("删除文件夹", "scriptFolder:delete", payload)];
  return [menuItem("新建脚本", "script:new"), menuItem("复制脚本内容", "script:copy", payload), menuItem("删除脚本", "script:delete", payload)];
}

function currentVersion(): string {
  return app.getVersion() || "0.0.0";
}

function normalizeVersion(version: string): string {
  return version.trim().replace(/^v/i, "");
}

function compareVersions(lhs: string, rhs: string): number {
  const left = normalizeVersion(lhs).split(".").map((item) => Number.parseInt(item, 10) || 0);
  const right = normalizeVersion(rhs).split(".").map((item) => Number.parseInt(item, 10) || 0);
  const count = Math.max(left.length, right.length);
  for (let index = 0; index < count; index += 1) {
    const diff = (left[index] ?? 0) - (right[index] ?? 0);
    if (diff !== 0) return diff;
  }
  return 0;
}

function allowedReleaseURL(url: string): boolean {
  try {
    const parsed = new URL(url);
    return parsed.protocol === "https:" && parsed.host.toLowerCase() === "github.com" && parsed.pathname.startsWith("/dylan120/shellx/releases/download/");
  } catch {
    return false;
  }
}

function selectedUpdateAsset(assets: GitHubReleaseAsset[]): UpdateAsset | null {
  const installAssets = assets
    .filter((asset) => /\.(dmg|zip)$/i.test(asset.name) && allowedReleaseURL(asset.browser_download_url))
    .sort((a, b) => Number(b.name.toLowerCase().endsWith(".dmg")) - Number(a.name.toLowerCase().endsWith(".dmg")));
  for (const asset of installAssets) {
    const checksum = assets.find((item) => [
      `${asset.name}.sha256`,
      `${asset.name}.sha256.txt`,
      `${asset.name}.sha256sum`
    ].includes(item.name) && allowedReleaseURL(item.browser_download_url));
    if (checksum) return { name: asset.name, downloadURL: asset.browser_download_url, sha256URL: checksum.browser_download_url, size: asset.size };
  }
  return null;
}

async function fetchText(url: string): Promise<string> {
  const response = await fetch(url, { headers: { "User-Agent": `ShellX/${currentVersion()}` } });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.text();
}

async function downloadFile(url: string, targetPath: string, totalHint: number, onProgress: (progress: AppUpdateProgress) => void): Promise<void> {
  const response = await fetch(url, { headers: { "User-Agent": `ShellX/${currentVersion()}` } });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  await fs.mkdir(path.dirname(targetPath), { recursive: true });
  const totalBytes = Number(response.headers.get("content-length")) || totalHint || undefined;
  const body = response.body;
  if (!body) {
    await fs.writeFile(targetPath, Buffer.from(await response.arrayBuffer()));
    onProgress({ phase: "downloading", message: "正在下载更新包", receivedBytes: totalBytes, totalBytes, percent: 1 });
    return;
  }

  await new Promise<void>((resolve, reject) => {
    const writer = createWriteStream(targetPath);
    const reader = body.getReader();
    let receivedBytes = 0;

    const pump = (): void => {
      reader.read().then(({ done, value }) => {
        if (done) {
          writer.end();
          return;
        }
        const chunk = Buffer.from(value);
        receivedBytes += chunk.byteLength;
        onProgress({
          phase: "downloading",
          message: "正在下载更新包",
          receivedBytes,
          totalBytes,
          percent: totalBytes ? Math.min(receivedBytes / totalBytes, 1) : undefined
        });
        if (!writer.write(chunk)) writer.once("drain", pump);
        else pump();
      }).catch(reject);
    };

    writer.on("finish", resolve);
    writer.on("error", reject);
    pump();
  });
}

function parseSHA256(value: string): string {
  const match = value.match(/[a-fA-F0-9]{64}/);
  if (!match) throw new Error("SHA256 文件格式无效");
  return match[0]!.toLowerCase();
}

async function sha256File(filePath: string): Promise<string> {
  const hash = createHash("sha256");
  hash.update(await fs.readFile(filePath));
  return hash.digest("hex");
}

async function latestRelease(): Promise<{ release: GitHubRelease; asset: UpdateAsset }> {
  const response = await fetch("https://api.github.com/repos/dylan120/shellx/releases/latest", {
    headers: { Accept: "application/vnd.github+json", "User-Agent": `ShellX/${currentVersion()}` }
  });
  if (!response.ok) throw new Error(`GitHub Release 响应失败：HTTP ${response.status}`);
  const release = await response.json() as GitHubRelease;
  if (release.draft || release.prerelease) throw new Error("未找到稳定版本 Release");
  const asset = selectedUpdateAsset(release.assets);
  if (!asset) throw new Error("最新 Release 未包含可校验 SHA256 的 .dmg 或 .zip 安装包");
  return { release, asset };
}

function installerScript(): string {
  return `#!/usr/bin/env bash
set -Eeuo pipefail
APP_PATH="$1"
ASSET_PATH="$2"
APP_PID="$3"
APP_NAME="ShellX"
WORK_DIR="$(mktemp -d "\${TMPDIR:-/tmp}/shellx-electron-update.XXXXXX")"
MOUNT_DIR="$WORK_DIR/mount"
EXTRACT_DIR="$WORK_DIR/extract"
STAGED_APP="$WORK_DIR/ShellX.app"
BACKUP_APP="\${APP_PATH}.backup.$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$HOME/Library/Application Support/shellx-electron/Updater"
LOG_PATH="$LOG_DIR/install-update.log"
mkdir -p "$LOG_DIR" "$MOUNT_DIR" "$EXTRACT_DIR"
exec >>"$LOG_PATH" 2>&1
echo "==== ShellX Electron updater started at $(date) ===="
cleanup() {
  if mount | grep -q "$MOUNT_DIR"; then hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true; fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
while kill -0 "$APP_PID" >/dev/null 2>&1; do sleep 0.2; done
find_app() { find "$1" -maxdepth 3 -name "$APP_NAME.app" -type d -print -quit; }
validate_app() {
  local candidate="$1"
  local info_plist="$candidate/Contents/Info.plist"
  local executable_name
  local bundle_id
  [[ -f "$info_plist" ]] || return 1
  executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist" 2>/dev/null || true)"
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null || true)"
  [[ "$bundle_id" == "com.example.ShellX" ]] || return 1
  [[ -n "$executable_name" && -x "$candidate/Contents/MacOS/$executable_name" ]] || return 1
}
case "$ASSET_PATH" in
  *.dmg|*.DMG) hdiutil attach "$ASSET_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIR" >/dev/null; SOURCE_APP="$(find_app "$MOUNT_DIR")" ;;
  *.zip|*.ZIP) ditto -x -k "$ASSET_PATH" "$EXTRACT_DIR"; SOURCE_APP="$(find_app "$EXTRACT_DIR")" ;;
  *) echo "Unsupported asset: $ASSET_PATH"; exit 2 ;;
esac
[[ -n "\${SOURCE_APP:-}" ]] || exit 3
validate_app "$SOURCE_APP" || exit 4
ditto --noextattr --noacl "$SOURCE_APP" "$STAGED_APP"
validate_app "$STAGED_APP" || exit 5
if [[ -d "$APP_PATH" ]]; then mv "$APP_PATH" "$BACKUP_APP"; fi
if ! ditto --noextattr --noacl "$STAGED_APP" "$APP_PATH"; then
  rm -rf "$APP_PATH"
  [[ -d "$BACKUP_APP" ]] && mv "$BACKUP_APP" "$APP_PATH"
  exit 6
fi
validate_app "$APP_PATH" || { rm -rf "$APP_PATH"; [[ -d "$BACKUP_APP" ]] && mv "$BACKUP_APP" "$APP_PATH"; exit 7; }
/usr/bin/codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 || true
/usr/bin/xattr -cr "$APP_PATH" >/dev/null 2>&1 || true
touch "$APP_PATH" || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_PATH" >/dev/null 2>&1 || true
killall Dock >/dev/null 2>&1 || true
open "$APP_PATH" || true
rm -rf "$BACKUP_APP"
echo "==== ShellX Electron updater finished at $(date) ===="
`;
}

async function installDownloadedUpdate(assetPath: string): Promise<void> {
  if (!app.isPackaged || !app.getPath("exe").includes(".app/Contents/MacOS/")) throw new Error("当前不是 .app 打包运行，无法执行自动更新安装");
  const appPath = app.getPath("exe").split(".app/Contents/MacOS/")[0] + ".app";
  const scriptPath = path.join(updatesRoot(), "install-update.sh");
  await fs.mkdir(path.dirname(scriptPath), { recursive: true });
  await fs.writeFile(scriptPath, installerScript(), { encoding: "utf8", mode: 0o700 });
  const child = spawn("/bin/bash", [scriptPath, appPath, assetPath, String(process.pid)], { detached: true, stdio: "ignore" });
  child.unref();
  app.quit();
}

function sendUpdateProgress(sender: WebContents, progress: AppUpdateProgress): void {
  sender.send("app:updateProgress", progress);
}

async function checkAndDownloadUpdate(event: IpcMainInvokeEvent): Promise<AppUpdateResult> {
  const progress = (payload: AppUpdateProgress) => sendUpdateProgress(event.sender, payload);
  try {
    const current = currentVersion();
    progress({ phase: "checking", message: "正在检查 GitHub Release" });
    const { release, asset } = await latestRelease();
    const latest = normalizeVersion(release.tag_name);
    if (compareVersions(latest, current) <= 0) return { status: "upToDate", message: `当前已是最新版本：${current}`, currentVersion: current, latestVersion: latest };

    const updateDir = path.join(updatesRoot(), release.tag_name.replace(/[^A-Za-z0-9_.-]/g, "-"));
    const assetPath = path.join(updateDir, asset.name.replace(/[\\/:*?"<>|]/g, "-"));
    pendingDownloadedUpdate = null;
    const expectedSHA256 = parseSHA256(await fetchText(asset.sha256URL));
    await downloadFile(asset.downloadURL, assetPath, asset.size, progress);
    progress({ phase: "verifying", message: "正在校验 SHA256" });
    const actualSHA256 = await sha256File(assetPath);
    if (actualSHA256 !== expectedSHA256) throw new Error(`SHA256 校验失败：期望 ${expectedSHA256}，实际 ${actualSHA256}`);
    pendingDownloadedUpdate = { assetPath, latestVersion: latest };
    progress({ phase: "downloaded", message: `${release.tag_name} 已下载并校验完成，点击“重启更新”后安装`, receivedBytes: asset.size, totalBytes: asset.size, percent: 1 });
    return { status: "downloaded", message: `${release.tag_name} 已下载完成，可重启更新`, currentVersion: current, latestVersion: latest };
  } catch (error) {
    const message = `检查更新失败：${(error as Error).message}`;
    progress({ phase: "failed", message });
    return { status: "failed", message, currentVersion: currentVersion() };
  }
}

async function installPendingDownloadedUpdate(event: IpcMainInvokeEvent): Promise<AppUpdateResult> {
  try {
    if (!pendingDownloadedUpdate) throw new Error("没有已下载的更新包，请先检查更新");
    sendUpdateProgress(event.sender, { phase: "installing", message: "正在准备重启更新" });
    const { assetPath, latestVersion } = pendingDownloadedUpdate;
    await installDownloadedUpdate(assetPath);
    return { status: "installing", message: `正在安装 ${latestVersion}，ShellX 将重新打开`, currentVersion: currentVersion(), latestVersion };
  } catch (error) {
    const message = `启动更新失败：${(error as Error).message}`;
    sendUpdateProgress(event.sender, { phase: "failed", message });
    return { status: "failed", message, currentVersion: currentVersion() };
  }
}

async function loadSnapshot(): Promise<AppSnapshot> {
  await migrateLegacyStorageIfNeeded();
  await migrateLegacyShellXDataIfNeeded();
  const workspace = await readWorkspaceTopology() ?? { folders: [], sessions: [] };
  const scriptLibrary = await readScriptTopology() ?? { folders: [], scripts: [] };
  const settings = { ...defaultSettings, ...(await readJSON<Partial<AppSettings>>("settings.json", {})) };
  applyTheme(settings.theme);
  return { workspace, scriptLibrary, settings };
}

function createMainWindow(): void {
  if (didCreateMainWindow) return;
  didCreateMainWindow = true;
  applyDockIcon();

  mainWindow = new BrowserWindow({
    width: 1360,
    height: 820,
    minWidth: 1080,
    minHeight: 680,
    show: false,
    title: "ShellX",
    backgroundColor: "#101214",
    titleBarStyle: "hiddenInset",
    trafficLightPosition: { x: 16, y: 18 },
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      zoomFactor: fixedWebContentsZoomFactor
    }
  });
  lockWebContentsZoom(mainWindow.webContents);

  const notifyFullScreenState = (): void => {
    if (!mainWindow || mainWindow.webContents.isDestroyed()) return;
    mainWindow.webContents.send("window:fullScreenChanged", mainWindow.isFullScreen());
  };
  mainWindow.on("enter-full-screen", notifyFullScreenState);
  mainWindow.on("leave-full-screen", notifyFullScreenState);

  if (app.isPackaged) {
    void mainWindow.loadFile(path.join(__dirname, "../renderer/index.html"));
  } else {
    void mainWindow.loadURL("http://127.0.0.1:5173");
  }

  mainWindow.once("ready-to-show", () => {
    mainWindow?.show();
    mainWindow?.focus();
    app.focus({ steal: true });
  });

  mainWindow.on("closed", () => {
    mainWindow = null;
    didCreateMainWindow = false;
  });

  setNativeMenu();
}

function openMainWindowWhenReady(): void {
  void app.whenReady().then(() => {
    if (mainWindow) {
      mainWindow.show();
      mainWindow.focus();
      return;
    }
    createMainWindow();
  });
}

function shellPath(request: CreateTerminalRequest): string {
  if (request.kind === "local" && request.shell) return request.shell;
  return process.env.SHELL || "/bin/zsh";
}

function localShellArgs(shell: string): string[] {
  const name = path.basename(shell);
  if (["bash", "zsh", "sh", "ksh", "mksh"].includes(name)) return ["-l"];
  if (name === "fish") return ["--login"];
  return [];
}

function terminalEnvironment(request: CreateTerminalRequest, localShell?: string, codexHome?: string): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env };
  if (request.kind === "local") {
    delete env.NO_COLOR;
    env.CLICOLOR = env.CLICOLOR || "1";
    if (codexHome) {
      const sourceHome = resolvedCodexSourceHome();
      env.CODEX_HOME = codexHome;
      if (sourceHome && !env.CODEX_SQLITE_HOME) env.CODEX_SQLITE_HOME = sourceHome;
    }
  }
  return {
    ...env,
    TERM: "xterm-256color",
    COLORTERM: "truecolor",
    LANG: env.LANG || "en_US.UTF-8",
    LC_CTYPE: env.LC_CTYPE || "en_US.UTF-8",
    ...(localShell ? { SHELL: localShell } : {})
  };
}

function proxyEnvironment(forwarding?: RemoteNetworkForwarding): string[] {
  if (!forwarding?.isEnabled || !forwarding.setProxyEnvironment) return [];
  const proxyHost = ["", "0.0.0.0", "::", "*"].includes(forwarding.bindAddress.trim()) ? "127.0.0.1" : forwarding.bindAddress.trim();
  const scheme = forwarding.mode === "dynamicSOCKS" ? "socks5h" : forwarding.remoteProxyScheme;
  const proxyURL = `${scheme}://${proxyHost}:${forwarding.port}`;
  return [`export ALL_PROXY=${proxyURL}`, `export HTTPS_PROXY=${proxyURL}`, `export HTTP_PROXY=${proxyURL}`];
}

const remoteUTF8Locale = "C.UTF-8";

function forwardedSSHEnvironmentArgs(): string[] {
  const setEnv = [
    `LANG=${remoteUTF8Locale}`,
    `LC_CTYPE=${remoteUTF8Locale}`,
    "BUILDKIT_PROGRESS=plain",
    "COMPOSE_PROGRESS=plain"
  ].join(",");

  return ["-o", "SendEnv=LANG LC_* BUILDKIT_PROGRESS COMPOSE_PROGRESS", "-o", `SetEnv=${setEnv}`];
}

function remoteLocaleEnvironment(): string[] {
  return [`export LANG=${remoteUTF8Locale}`, `export LC_CTYPE=${remoteUTF8Locale}`];
}

function sshArgs(request: Extract<CreateTerminalRequest, { kind: "ssh" }>): string[] {
  const destination = request.username ? `${request.username}@${request.host}` : request.host;
  const args = ["-tt", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3", "-o", "StrictHostKeyChecking=accept-new", "-o", "EscapeChar=none"];
  args.push(...forwardedSSHEnvironmentArgs());
  if (request.port) args.push("-p", String(request.port));
  if (request.identityFile) args.push("-i", request.identityFile);
  if (request.useKeychainForPrivateKey) args.push("-o", "UseKeychain=yes", "-o", "AddKeysToAgent=yes");
  if (request.remoteNetworkForwarding?.isEnabled) {
    const forwarding = request.remoteNetworkForwarding;
    args.push("-o", "ExitOnForwardFailure=yes", "-R");
    args.push(forwarding.mode === "dynamicSOCKS"
      ? `${forwarding.bindAddress}:${forwarding.port}`
      : `${forwarding.bindAddress}:${forwarding.port}:${forwarding.localProxyHost}:${forwarding.localProxyPort}`);
  }
  args.push(destination);
  const startupCommand = request.startupCommand?.trim();
  const bootstrapParts = [...remoteLocaleEnvironment(), ...proxyEnvironment(request.remoteNetworkForwarding), startupCommand].filter(Boolean);
  const bootstrap = bootstrapParts.join("; ");
  if (bootstrap) args.push(startupCommand ? bootstrap : `${bootstrap}; exec "\${SHELL:-/bin/sh}" -l`);
  return args;
}

async function createPty(request: CreateTerminalRequest): Promise<ManagedTerminal> {
  const id = randomUUID();
  const localShell = request.kind === "local" ? shellPath(request) : undefined;
  const codexHome = request.kind === "local" ? await prepareCodexHomeForTerminal(id) : undefined;
  const env = terminalEnvironment(request, localShell, codexHome);
  const cols = Math.max(20, Math.min(400, Math.round(request.initialCols ?? 100)));
  const rows = Math.max(8, Math.min(120, Math.round(request.initialRows ?? 30)));
  const options: pty.IPtyForkOptions = {
    name: "xterm-256color",
    cols,
    rows,
    cwd: request.kind === "local" ? request.cwd || os.homedir() : os.homedir(),
    encoding: null,
    env
  };

  const ptyProcess = request.kind === "ssh"
    ? pty.spawn("/usr/bin/ssh", sshArgs(request), options)
    : pty.spawn(localShell ?? shellPath(request), localShellArgs(localShell ?? shellPath(request)), options);

  const title = request.kind === "ssh"
    ? `${request.username ? `${request.username}@` : ""}${request.host}`
    : path.basename(shellPath(request));

  const terminal: ManagedTerminal = { id, title, ptyProcess, decoder: new StringDecoder("utf8"), ptyCols: cols, ptyRows: rows, codexHome };
  terminals.set(id, terminal);

  ptyProcess.onData((data: string | Buffer) => {
    const chunk = Buffer.isBuffer(data) ? data : Buffer.from(data, "utf8");
    const activeTransfer = terminal.transfer;
    if (activeTransfer) {
      writeZmodemTransferRemoteData(terminal, activeTransfer.child, activeTransfer.direction, chunk);
      return;
    }
    const displayChunk = rememberPendingZmodemInput(terminal, chunk);
    if (displayChunk?.length) sendTerminalData(terminal, displayChunk);
  });
  ptyProcess.onExit(({ exitCode, signal }) => {
    terminal.transfer?.child.kill("SIGTERM");
    cleanupCodexHome(terminal.codexHome);
    if (!terminal.pendingZmodemInput && terminal.pendingZmodemScanTail?.length) {
      sendTerminalData(terminal, terminal.pendingZmodemScanTail);
      terminal.pendingZmodemScanTail = undefined;
    }
    const trailingData = terminal.decoder.end();
    if (trailingData) mainWindow?.webContents.send(`terminal:data:${id}`, trailingData);
    const payload: TerminalExitPayload = { id, exitCode, signal };
    mainWindow?.webContents.send(`terminal:exit:${id}`, payload);
    terminals.delete(id);
  });

  return terminal;
}

function zmodemStatus(payload: ZmodemStatusPayload): void {
  mainWindow?.webContents.send(`terminal:zmodem:${payload.id}`, payload);
}

function sendTerminalData(terminal: ManagedTerminal, chunk: Buffer): void {
  if (chunk.length === 0) return;
  const decoded = terminal.decoder.write(chunk);
  if (decoded) mainWindow?.webContents.send(`terminal:data:${terminal.id}`, decoded);
}

function findZmodemIntroIndex(buffer: Buffer): number {
  let searchFrom = 0;
  while (searchFrom < buffer.length) {
    const introIndex = buffer.indexOf(zmodemIntroBytes, searchFrom);
    if (introIndex === -1) return -1;
    const encodingByte = buffer[introIndex + zmodemIntroBytes.length];
    if (encodingByte !== undefined && zmodemHeaderEncodingBytes.has(encodingByte)) return introIndex;
    searchFrom = introIndex + 1;
  }
  return -1;
}

function zmodemFrameTypeAt(buffer: Buffer, introIndex: number): number | undefined {
  const frameTypePrefix = buffer[introIndex + zmodemIntroBytes.length + 1];
  const frameType = buffer[introIndex + zmodemIntroBytes.length + 2];
  return frameTypePrefix === zmodemFrameTypePrefixByte ? frameType : undefined;
}

function findZmodemFrameIndex(buffer: Buffer, frameType: number): number {
  let searchFrom = 0;
  while (searchFrom < buffer.length) {
    const introIndex = findZmodemIntroIndex(buffer.subarray(searchFrom));
    if (introIndex === -1) return -1;
    const absoluteIntroIndex = searchFrom + introIndex;
    if (zmodemFrameTypeAt(buffer, absoluteIntroIndex) === frameType) return absoluteIntroIndex;
    searchFrom = absoluteIntroIndex + 1;
  }
  return -1;
}

function zmodemFrameEndIndex(buffer: Buffer, introIndex: number): number {
  for (let index = introIndex + zmodemIntroBytes.length + 3; index < buffer.length; index += 1) {
    if (buffer[index] === 0x0d) return Math.min(buffer.length, index + 2);
  }
  return buffer.length;
}

function zmodemPartialIntroTailLength(buffer: Buffer): number {
  const maxLength = Math.min(zmodemIntroBytes.length - 1, buffer.length);
  for (let length = maxLength; length > 0; length -= 1) {
    const offset = buffer.length - length;
    let matches = true;
    for (let index = 0; index < length; index += 1) {
      if (buffer[offset + index] !== zmodemIntroBytes[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return length;
  }
  return 0;
}

function zmodemDirectionFromBuffer(buffer: Buffer): "upload" | "download" | undefined {
  const startIndex = findZmodemIntroIndex(buffer);
  if (startIndex === -1) return undefined;
  const frameType = zmodemFrameTypeAt(buffer, startIndex);
  if (frameType === zmodemFrameTypeUpload) return "upload";
  if (frameType === zmodemFrameTypeDownload) return "download";
  return undefined;
}

function notifyPendingZmodem(terminal: ManagedTerminal): void {
  if (terminal.pendingZmodemNotified) return;
  const chunks = terminal.pendingZmodemInput;
  if (!chunks || chunks.length === 0) return;
  const direction = zmodemDirectionFromBuffer(Buffer.concat(chunks));
  if (!direction) return;
  terminal.pendingZmodemNotified = true;
  zmodemStatus({
    id: terminal.id,
    direction,
    state: "detected",
    message: direction === "upload" ? "检测到远端 rz，准备上传" : "检测到远端 sz，准备下载"
  });
}

function rememberPendingZmodemInput(terminal: ManagedTerminal, chunk: Buffer): Buffer | undefined {
  if (chunk.length === 0) return chunk;

  if (!terminal.pendingZmodemInput) {
    const scanChunk = terminal.pendingZmodemScanTail?.length ? Buffer.concat([terminal.pendingZmodemScanTail, chunk]) : chunk;
    const startIndex = findZmodemIntroIndex(scanChunk);
    if (startIndex === -1) {
      const tailLength = zmodemPartialIntroTailLength(scanChunk);
      terminal.pendingZmodemScanTail = tailLength > 0 ? scanChunk.subarray(scanChunk.length - tailLength) : undefined;
      const displayChunk = tailLength > 0 ? scanChunk.subarray(0, scanChunk.length - tailLength) : scanChunk;
      return displayChunk.length > 0 ? displayChunk : undefined;
    }

    terminal.pendingZmodemScanTail = undefined;
    terminal.pendingZmodemInput = [scanChunk.subarray(startIndex)];
    terminal.pendingZmodemInputBytes = terminal.pendingZmodemInput[0]?.length ?? 0;
    notifyPendingZmodem(terminal);
    return startIndex > 0 ? scanChunk.subarray(0, startIndex) : undefined;
  }

  terminal.pendingZmodemInput ??= [];
  terminal.pendingZmodemInput.push(chunk);
  terminal.pendingZmodemInputBytes = (terminal.pendingZmodemInputBytes ?? 0) + chunk.length;
  notifyPendingZmodem(terminal);

  while ((terminal.pendingZmodemInputBytes ?? 0) > pendingZmodemInputLimit && terminal.pendingZmodemInput.length > 1) {
    const dropped = terminal.pendingZmodemInput.shift();
    terminal.pendingZmodemInputBytes = (terminal.pendingZmodemInputBytes ?? 0) - (dropped?.length ?? 0);
  }

  return undefined;
}

function consumePendingZmodemInput(terminal: ManagedTerminal): Buffer | undefined {
  const chunks = terminal.pendingZmodemInput;
  terminal.pendingZmodemInput = undefined;
  terminal.pendingZmodemInputBytes = undefined;
  terminal.pendingZmodemScanTail = undefined;
  terminal.pendingZmodemNotified = undefined;
  if (!chunks || chunks.length === 0) return undefined;
  return Buffer.concat(chunks);
}

function resolveShellTool(command: string): string | undefined {
  const paths = [...shellToolDirs, ...(process.env.PATH ?? "").split(":")].filter(Boolean);
  for (const dir of paths) {
    const candidate = path.join(dir, command);
    if (existsSync(candidate)) return candidate;
  }
  return undefined;
}

function cancelZmodemTransfer(terminal: ManagedTerminal, id: string, message: string): void {
  const activeTransfer = terminal.transfer;
  consumePendingZmodemInput(terminal);
  if (activeTransfer) {
    terminal.transfer = undefined;
    activeTransfer.child.kill("SIGTERM");
  }
  terminal.ptyProcess.write(zmodemCancelBytes);
  zmodemStatus({ id, direction: activeTransfer?.direction ?? "download", state: "failed", message });
}

function failZmodemTransfer(terminal: ManagedTerminal, child: ChildProcessWithoutNullStreams, direction: "upload" | "download", message: string): void {
  if (terminal.transfer?.child !== child) return;
  terminal.transfer = undefined;
  child.kill("SIGTERM");
  terminal.ptyProcess.write(zmodemCancelBytes);
  zmodemStatus({ id: terminal.id, direction, state: "failed", message });
}

function writeZmodemHelperInput(terminal: ManagedTerminal, child: ChildProcessWithoutNullStreams, direction: "upload" | "download", chunk: Buffer): void {
  if (terminal.transfer?.child !== child) return;
  if (child.stdin.destroyed || child.stdin.writableEnded || !child.stdin.writable) {
    failZmodemTransfer(terminal, child, direction, "lrzsz 本地 helper 管道已关闭");
    return;
  }
  try {
    child.stdin.write(chunk);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    failZmodemTransfer(terminal, child, direction, `lrzsz 本地 helper 写入失败：${message}`);
  }
}

function sendDownloadHelperOO(terminal: ManagedTerminal, child: ChildProcessWithoutNullStreams): void {
  const activeTransfer = terminal.transfer;
  if (!activeTransfer || activeTransfer.child !== child || activeTransfer.direction !== "download" || activeTransfer.downloadHelperOOSent) return;
  activeTransfer.downloadHelperOOSent = true;
  writeZmodemHelperInput(terminal, child, "download", Buffer.from("OO", "ascii"));
}

function writeZmodemDownloadRemoteData(terminal: ManagedTerminal, child: ChildProcessWithoutNullStreams, chunk: Buffer): void {
  const activeTransfer = terminal.transfer;
  if (!activeTransfer || activeTransfer.child !== child || activeTransfer.direction !== "download") return;

  if (activeTransfer.downloadRemoteFinSeen) {
    activeTransfer.downloadRemoteReturnedToShell = true;
    sendTerminalData(terminal, chunk);
    sendDownloadHelperOO(terminal, child);
    return;
  }

  const finIndex = findZmodemFrameIndex(chunk, zmodemFrameTypeFin);
  if (finIndex === -1) {
    writeZmodemHelperInput(terminal, child, "download", chunk);
    return;
  }

  const protocolEndIndex = zmodemFrameEndIndex(chunk, finIndex);
  const protocolChunk = chunk.subarray(0, protocolEndIndex);
  activeTransfer.downloadRemoteFinSeen = true;
  writeZmodemHelperInput(terminal, child, "download", protocolChunk);

  const displayChunk = chunk.subarray(protocolEndIndex);
  if (displayChunk.length) {
    activeTransfer.downloadRemoteReturnedToShell = true;
    sendTerminalData(terminal, displayChunk);
    sendDownloadHelperOO(terminal, child);
  }
}

function writeZmodemTransferRemoteData(terminal: ManagedTerminal, child: ChildProcessWithoutNullStreams, direction: "upload" | "download", chunk: Buffer): void {
  if (direction === "download") {
    writeZmodemDownloadRemoteData(terminal, child, chunk);
    return;
  }
  writeZmodemUploadRemoteData(terminal, child, chunk);
}

function stripAnsiSequences(value: string): string {
  return value
    .replace(/\x1b\][^\x07]*(?:\x07|\x1b\\)/g, "")
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "");
}

function looksLikeRemoteShellOutput(chunk: Buffer): boolean {
  if (findZmodemIntroIndex(chunk) !== -1) return false;
  if (chunk.includes(0x00)) return false;
  const text = stripAnsiSequences(chunk.toString("utf8"));
  if (/\b(?:command not found|event not found|No such file|There are stopped jobs|Permission denied)\b/i.test(text)) return true;
  if (/(?:^|[\r\n])[^\r\n]{0,160}[#$] $/.test(text)) return true;

  let printableBytes = 0;
  let escapeBytes = 0;
  for (const byte of chunk) {
    if (byte === 0x09 || byte === 0x0a || byte === 0x0d || byte === 0x1b || byte === 0x07 || (byte >= 0x20 && byte <= 0x7e)) printableBytes += 1;
    if (byte === 0x18) escapeBytes += 1;
  }
  if (chunk.length > 0 && escapeBytes / chunk.length > 0.02) return false;
  return chunk.length > 0 && printableBytes / chunk.length > 0.85 && /[\r\n]/.test(text) && /(?:bash|zsh|sh|\$|#|error|failed)/i.test(text);
}

function stopUploadAfterRemoteShellReturn(terminal: ManagedTerminal, child: ChildProcessWithoutNullStreams, chunk: Buffer): void {
  const activeTransfer = terminal.transfer;
  if (!activeTransfer || activeTransfer.child !== child || activeTransfer.direction !== "upload") return;
  activeTransfer.uploadRemoteReturnedToShell = true;
  sendTerminalData(terminal, chunk);
  if (activeTransfer.uploadHelperOOSent) return;

  terminal.transfer = undefined;
  child.kill("SIGTERM");
  zmodemStatus({ id: terminal.id, direction: "upload", state: "finished", message: "lrzsz 上传完成" });
}

function writeZmodemUploadRemoteData(terminal: ManagedTerminal, child: ChildProcessWithoutNullStreams, chunk: Buffer): void {
  const activeTransfer = terminal.transfer;
  if (!activeTransfer || activeTransfer.child !== child || activeTransfer.direction !== "upload") return;
  if (activeTransfer.uploadRemoteReturnedToShell) {
    sendTerminalData(terminal, chunk);
    return;
  }
  if (looksLikeRemoteShellOutput(chunk)) {
    stopUploadAfterRemoteShellReturn(terminal, child, chunk);
    return;
  }
  writeZmodemHelperInput(terminal, child, "upload", chunk);
}

function writeZmodemRemoteInput(terminal: ManagedTerminal, child: ChildProcessWithoutNullStreams, direction: "upload" | "download", chunk: Buffer): void {
  const activeTransfer = terminal.transfer;
  if (activeTransfer?.child !== child) return;

  if (direction === "upload") {
    if (activeTransfer.uploadRemoteReturnedToShell) return;
    if (chunk.equals(Buffer.from("OO", "ascii"))) activeTransfer.uploadHelperOOSent = true;
  }

  if (direction === "download") {
    const finIndex = findZmodemFrameIndex(chunk, zmodemFrameTypeFin);
    if (finIndex !== -1) {
      activeTransfer.downloadRemoteFinSeen = true;
      if (!activeTransfer.downloadRemoteReturnedToShell && !activeTransfer.downloadFinReplySent) {
        const finEndIndex = zmodemFrameEndIndex(chunk, finIndex);
        activeTransfer.downloadFinReplySent = true;
        try {
          terminal.ptyProcess.write(chunk.subarray(finIndex, finEndIndex));
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          failZmodemTransfer(terminal, child, direction, `lrzsz 写入远端失败：${message}`);
        }
      }
      return;
    }

    if (activeTransfer.downloadRemoteFinSeen) {
      return;
    }
  }

  try {
    terminal.ptyProcess.write(chunk);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    failZmodemTransfer(terminal, child, direction, `lrzsz 写入远端失败：${message}`);
  }
}

function startZmodemTransfer(id: string, direction: "upload" | "download", args: string[], cwd?: string): { ok: boolean; message: string } {
  const terminal = terminals.get(id);
  if (!terminal) return { ok: false, message: "终端不存在" };
  if (terminal.transfer) return { ok: false, message: "已有 lrzsz 传输正在进行" };
  const pendingInput = consumePendingZmodemInput(terminal);
  const command = args[0];
  const resolvedCommand = command ? resolveShellTool(command) : undefined;
  if (!command || !resolvedCommand) {
    const message = `本机未找到 ${command || "lrzsz"}，请先安装 lrzsz`;
    terminal.ptyProcess.write(zmodemCancelBytes);
    zmodemStatus({ id, direction, state: "failed", message });
    return { ok: false, message };
  }

  const child = spawn(resolvedCommand, args.slice(1), { cwd, env: { ...process.env, PATH: `${shellToolPath}:${process.env.PATH ?? ""}` } });
  terminal.transfer = { direction, child };
  const label = direction === "upload" ? "上传" : "下载";
  let stderrText = "";

  zmodemStatus({ id, direction, state: "started", message: `lrzsz ${label}已开始` });
  if (pendingInput?.length) writeZmodemHelperInput(terminal, child, direction, pendingInput);
  child.stdout.on("data", (chunk: Buffer) => writeZmodemRemoteInput(terminal, child, direction, chunk));
  child.stderr.on("data", (chunk: Buffer) => {
    stderrText = `${stderrText}${chunk.toString("utf8")}`.slice(-1000);
    zmodemStatus({ id, direction, state: "started", message: chunk.toString("utf8").trim() || `lrzsz ${label}中` });
  });
  child.stdin.on("error", (error: NodeJS.ErrnoException) => {
    failZmodemTransfer(terminal, child, direction, `lrzsz ${label}中断：${error.message}`);
  });
  child.on("close", (code) => {
    if (terminal.transfer?.child !== child) return;
    if (terminal.transfer?.child === child) terminal.transfer = undefined;
    if (code !== 0) terminal.ptyProcess.write(zmodemCancelBytes);
    const detail = stderrText.trim().split(/\r?\n/).filter(Boolean).at(-1);
    zmodemStatus({ id, direction, state: code === 0 ? "finished" : "failed", message: code === 0 ? `lrzsz ${label}完成` : `lrzsz ${label}失败：${detail || code || "signal"}` });
  });
  child.on("error", (error) => {
    if (terminal.transfer?.child === child) terminal.transfer = undefined;
    terminal.ptyProcess.write(zmodemCancelBytes);
    zmodemStatus({ id, direction, state: "failed", message: `lrzsz 启动失败：${error.message}` });
  });
  return { ok: true, message: `lrzsz ${label}已开始` };
}

function execFileText(command: string, args: string[], input?: string): Promise<{ code: number; output: string }> {
  return new Promise((resolve) => {
    const child = execFile(command, args, { timeout: 60000 }, (error, stdout, stderr) => {
      resolve({ code: error ? ((error as NodeJS.ErrnoException & { code?: number }).code || 1) : 0, output: `${stdout}${stderr}` });
    });
    if (input) child.stdin?.end(input);
  });
}

ipcMain.handle("app:load", loadSnapshot);
ipcMain.handle("window:isFullScreen", (event) => {
  const window = BrowserWindow.fromWebContents(event.sender) ?? mainWindow;
  return Boolean(window?.isFullScreen());
});
ipcMain.handle("app:saveWorkspace", async (_event, workspace: SessionWorkspace) => writeWorkspaceTopology(workspace));
ipcMain.handle("app:saveScripts", async (_event, library: ScriptLibrary) => writeScriptTopology(normalizeScriptLibrary(library)));
ipcMain.handle("app:saveSettings", async (_event, settings: AppSettings) => {
  applyTheme(settings.theme);
  await writeJSON("settings.json", settings);
});
ipcMain.handle("app:updateCheckAndDownload", checkAndDownloadUpdate);
ipcMain.handle("app:updateInstallPending", installPendingDownloadedUpdate);
ipcMain.handle("app:export", async (): Promise<DialogFileResult> => {
  const result = mainWindow
    ? await dialog.showSaveDialog(mainWindow, { defaultPath: "shellx-export.json", filters: [{ name: "ShellX Export", extensions: ["json"] }] })
    : await dialog.showSaveDialog({ defaultPath: "shellx-export.json", filters: [{ name: "ShellX Export", extensions: ["json"] }] });
  if (result.canceled || !result.filePath) return { canceled: true, filePaths: [] };
  await fs.writeFile(result.filePath, JSON.stringify(await loadSnapshot(), null, 2), "utf8");
  return { canceled: false, filePaths: [result.filePath] };
});
ipcMain.handle("app:import", async (): Promise<AppSnapshot | null> => {
  const result = mainWindow
    ? await dialog.showOpenDialog(mainWindow, { properties: ["openFile"], filters: [{ name: "ShellX Export", extensions: ["json"] }] })
    : await dialog.showOpenDialog({ properties: ["openFile"], filters: [{ name: "ShellX Export", extensions: ["json"] }] });
  if (result.canceled || result.filePaths.length === 0) return null;
  const snapshot = JSON.parse(await fs.readFile(result.filePaths[0]!, "utf8")) as AppSnapshot;
  await writeWorkspaceTopology(snapshot.workspace ?? { folders: [], sessions: [] });
  await writeScriptTopology(normalizeScriptLibrary(snapshot.scriptLibrary));
  await writeJSON("settings.json", { ...defaultSettings, ...(snapshot.settings ?? {}) });
  return loadSnapshot();
});
ipcMain.handle("dialog:privateKey", async (): Promise<DialogFileResult> => {
  const result = mainWindow
    ? await dialog.showOpenDialog(mainWindow, { properties: ["openFile", "showHiddenFiles"] })
    : await dialog.showOpenDialog({ properties: ["openFile", "showHiddenFiles"] });
  return { canceled: result.canceled, filePaths: result.filePaths };
});
ipcMain.handle("dialog:openPath", async (_event, options: { directories?: boolean; multiple?: boolean; title?: string; buttonLabel?: string; defaultPath?: string }): Promise<DialogFileResult> => {
  const properties: Electron.OpenDialogOptions["properties"] = [options.directories ? "openDirectory" : "openFile"];
  if (options.multiple) properties.push("multiSelections");
  if (options.directories) properties.push("createDirectory");
  const dialogOptions: Electron.OpenDialogOptions = {
    properties,
    title: options.title,
    buttonLabel: options.buttonLabel,
    defaultPath: options.defaultPath ?? (options.directories ? app.getPath("downloads") : undefined)
  };
  const result = mainWindow ? await dialog.showOpenDialog(mainWindow, dialogOptions) : await dialog.showOpenDialog(dialogOptions);
  return { canceled: result.canceled, filePaths: result.filePaths };
});
ipcMain.handle("keychain:setPassword", async (_event, sessionID: string, account: string, password: string) => {
  await execFileText("/usr/bin/security", ["delete-generic-password", "-s", "com.shellx.session-password", "-a", `${sessionID}:${account}`]);
  return execFileText("/usr/bin/security", ["add-generic-password", "-s", "com.shellx.session-password", "-a", `${sessionID}:${account}`, "-w", password]);
});
ipcMain.handle("keychain:getPassword", async (_event, sessionID: string, account: string) => {
  const currentResult = await execFileText("/usr/bin/security", ["find-generic-password", "-s", "com.shellx.session-password", "-a", `${sessionID}:${account}`, "-w"]);
  if (currentResult.code === 0) return currentResult.output.trimEnd();

  const legacyResult = await execFileText("/usr/bin/security", ["find-generic-password", "-s", "com.shellx.session-password", "-a", sessionID, "-w"]);
  return legacyResult.code === 0 ? legacyResult.output.trimEnd() : null;
});
ipcMain.handle("batch:run", async (_event, request: BatchExecutionRequest): Promise<BatchExecutionResult[]> => {
  const args = request.args.trim().split(/\s+/).filter(Boolean);
  const timeout = Math.max(1, request.timeoutSeconds || 3600) * 1000;
  return Promise.all(request.sessions.map(async (session) => {
    const remote = `${session.username}@${session.host}`;
    const sshArgsForBatch = ["-o", "BatchMode=yes", "-p", String(session.port || 22), remote, "sh", "-s", "--", ...args];
    if (session.authMethod === "privateKey" && session.privateKeyPath) sshArgsForBatch.unshift("-i", session.privateKeyPath);
    const result = await new Promise<{ code: number; output: string }>((resolve) => {
      const child = execFile("/usr/bin/ssh", sshArgsForBatch, { timeout }, (error, stdout, stderr) => {
        resolve({ code: error ? 1 : 0, output: `${stdout}${stderr}` });
      });
      child.stdin?.end(request.script.content);
    });
    return { sessionID: session.id, sessionName: session.name, status: result.code === 0 ? "succeeded" : "failed", output: result.output };
  }));
});

ipcMain.handle("menu:popup", (event, request: ContextMenuRequest) => {
  const window = BrowserWindow.fromWebContents(event.sender) ?? mainWindow;
  if (!window) return;
  Menu.buildFromTemplate(contextTemplate(request)).popup({ window });
});

ipcMain.handle("terminal:create", async (_event, request: CreateTerminalRequest): Promise<CreateTerminalResponse> => {
  const terminal = await createPty(request);
  return { id: terminal.id, title: terminal.title };
});
ipcMain.handle("terminal:zmodemUpload", (_event, payload: { id: string; filePaths: string[] }) => {
  const filePaths = payload.filePaths.filter(Boolean);
  if (filePaths.length === 0) return { ok: false, message: "未选择上传文件" };
  return startZmodemTransfer(payload.id, "upload", ["sz", "-b", "-e", ...filePaths]);
});
ipcMain.handle("terminal:zmodemDownload", (_event, payload: { id: string; directory: string }) => {
  if (!payload.directory) return { ok: false, message: "未选择下载目录" };
  return startZmodemTransfer(payload.id, "download", ["rz", "-b", "-e", "-E"], payload.directory);
});
ipcMain.on("terminal:write", (_event, payload: { id: string; data: string }) => {
  const terminal = terminals.get(payload.id);
  if (!terminal) return;
  if (terminal.transfer) {
    if (payload.data.includes("\x03")) cancelZmodemTransfer(terminal, payload.id, "已取消 lrzsz");
    return;
  }
  if (payload.data.includes("\x18\x18")) consumePendingZmodemInput(terminal);
  terminal.ptyProcess.write(payload.data);
});
ipcMain.on("terminal:resize", (_event, payload: { id: string; cols: number; rows: number }) => {
  const terminal = terminals.get(payload.id);
  if (!terminal) return;
  const cols = Math.max(20, Math.min(400, Math.round(payload.cols)));
  const rows = Math.max(8, Math.min(120, Math.round(payload.rows)));
  if (terminal.ptyCols === cols && terminal.ptyRows === rows) return;
  terminal.ptyCols = cols;
  terminal.ptyRows = rows;
  terminal.ptyProcess.resize(cols, rows);
});
ipcMain.on("terminal:dispose", (_event, payload: { id: string }) => {
  const terminal = terminals.get(payload.id);
  if (!terminal) return;
  terminal.ptyProcess.kill();
  cleanupCodexHome(terminal.codexHome);
  terminals.delete(payload.id);
});

app.on("window-all-closed", () => {
  for (const terminal of terminals.values()) {
    terminal.ptyProcess.kill();
    cleanupCodexHome(terminal.codexHome);
  }
  terminals.clear();
  if (process.platform !== "darwin") app.quit();
});

app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    openMainWindowWhenReady();
  }
});

openMainWindowWhenReady();
