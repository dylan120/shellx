export type TerminalKind = "local" | "ssh";

export type SSHAuthMethod = "agent" | "privateKey" | "password";
export type ThemeMode = "system" | "light" | "dark";
export type ScriptLanguage = "shell" | "python";

export interface RemoteNetworkForwarding {
  isEnabled: boolean;
  mode: "dynamicSOCKS" | "localProxy";
  bindAddress: string;
  port: number;
  localProxyHost: string;
  localProxyPort: number;
  remoteProxyScheme: "socks5h" | "http";
  setProxyEnvironment: boolean;
}

export interface SessionFolder {
  id: string;
  parentID?: string;
  name: string;
  createdAt: string;
  updatedAt: string;
}

export interface SSHSessionProfile {
  id: string;
  folderID?: string;
  name: string;
  host: string;
  port: number;
  username: string;
  authMethod: SSHAuthMethod;
  privateKeyPath: string;
  passwordStoredInKeychain: boolean;
  useKeychainForPrivateKey: boolean;
  remoteNetworkForwarding: RemoteNetworkForwarding;
  startupCommand: string;
  tags: string[];
  createdAt: string;
  updatedAt: string;
  lastConnectedAt?: string;
}

export interface SessionWorkspace {
  folders: SessionFolder[];
  sessions: SSHSessionProfile[];
}

export interface UserScript {
  id: string;
  name: string;
  content: string;
  language: ScriptLanguage;
  createdAt: string;
  updatedAt: string;
}

export interface ScriptLibrary {
  scripts: UserScript[];
}

export interface AppSettings {
  theme: ThemeMode;
  reopenPreviousTabs: boolean;
  copySelectionToClipboard: boolean;
  terminalScrollback: number;
  autoFreezeTabs: boolean;
  freezeThreshold: number;
  hotTabCount: number;
  autoUpdateEnabled: boolean;
}

export interface AppSnapshot {
  workspace: SessionWorkspace;
  scriptLibrary: ScriptLibrary;
  settings: AppSettings;
}

export interface AppUpdateResult {
  status: "upToDate" | "downloaded" | "installing" | "failed";
  message: string;
  currentVersion: string;
  latestVersion?: string;
}

export interface AppUpdateProgress {
  phase: "checking" | "downloading" | "verifying" | "downloaded" | "installing" | "failed";
  message: string;
  receivedBytes?: number;
  totalBytes?: number;
  percent?: number;
}

export interface LocalTerminalRequest {
  kind: "local";
  cwd?: string;
  shell?: string;
  initialCols?: number;
  initialRows?: number;
}

export interface SSHTerminalRequest {
  kind: "ssh";
  host: string;
  port?: number;
  username?: string;
  identityFile?: string;
  authMethod?: SSHAuthMethod;
  useKeychainForPrivateKey?: boolean;
  remoteNetworkForwarding?: RemoteNetworkForwarding;
  startupCommand?: string;
  sessionID?: string;
  initialCols?: number;
  initialRows?: number;
}

export type CreateTerminalRequest = LocalTerminalRequest | SSHTerminalRequest;

export interface CreateTerminalResponse {
  id: string;
  title: string;
}

export interface TerminalExitPayload {
  id: string;
  exitCode: number | null;
  signal?: number;
}

export interface ZmodemStatusPayload {
  id: string;
  state: "started" | "finished" | "failed";
  direction: "upload" | "download";
  message: string;
}

export interface DialogFileResult {
  canceled: boolean;
  filePaths: string[];
}

export interface BatchExecutionRequest {
  script: UserScript;
  sessions: SSHSessionProfile[];
  args: string;
  timeoutSeconds: number;
}

export interface BatchExecutionResult {
  sessionID: string;
  sessionName: string;
  status: "succeeded" | "failed";
  output: string;
}
