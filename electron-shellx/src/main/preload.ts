import { contextBridge, ipcRenderer } from "electron";
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
  ScriptLibrary,
  SessionWorkspace,
  TerminalExitPayload,
  ZmodemStatusPayload
} from "../shared/terminal.js";

type Disposable = () => void;

interface AppCommandEvent {
  command: string;
  payload?: Record<string, unknown>;
}

interface ContextMenuRequest {
  type: "root" | "folder" | "session" | "tab" | "terminal" | "script" | "scriptRoot" | "scriptFolder";
  payload?: Record<string, unknown>;
}

const terminalAPI = {
  create(request: CreateTerminalRequest): Promise<CreateTerminalResponse> {
    return ipcRenderer.invoke("terminal:create", request) as Promise<CreateTerminalResponse>;
  },
  write(id: string, data: string): void {
    ipcRenderer.send("terminal:write", { id, data });
  },
  resize(id: string, cols: number, rows: number): void {
    ipcRenderer.send("terminal:resize", { id, cols, rows });
  },
  dispose(id: string): void {
    ipcRenderer.send("terminal:dispose", { id });
  },
  startZmodemUpload(id: string, filePaths: string[]): Promise<{ ok: boolean; message: string }> {
    return ipcRenderer.invoke("terminal:zmodemUpload", { id, filePaths }) as Promise<{ ok: boolean; message: string }>;
  },
  startZmodemDownload(id: string, directory: string): Promise<{ ok: boolean; message: string }> {
    return ipcRenderer.invoke("terminal:zmodemDownload", { id, directory }) as Promise<{ ok: boolean; message: string }>;
  },
  onData(id: string, callback: (data: string) => void): Disposable {
    const channel = `terminal:data:${id}`;
    const listener = (_event: Electron.IpcRendererEvent, data: string) => callback(data);
    ipcRenderer.on(channel, listener);
    return () => ipcRenderer.off(channel, listener);
  },
  onExit(id: string, callback: (payload: TerminalExitPayload) => void): Disposable {
    const channel = `terminal:exit:${id}`;
    const listener = (_event: Electron.IpcRendererEvent, payload: TerminalExitPayload) => callback(payload);
    ipcRenderer.on(channel, listener);
    return () => ipcRenderer.off(channel, listener);
  },
  onZmodemStatus(id: string, callback: (payload: ZmodemStatusPayload) => void): Disposable {
    const channel = `terminal:zmodem:${id}`;
    const listener = (_event: Electron.IpcRendererEvent, payload: ZmodemStatusPayload) => callback(payload);
    ipcRenderer.on(channel, listener);
    return () => ipcRenderer.off(channel, listener);
  }
};

contextBridge.exposeInMainWorld("shellx", {
  terminal: terminalAPI,
  app: {
    load(): Promise<AppSnapshot> {
      return ipcRenderer.invoke("app:load") as Promise<AppSnapshot>;
    },
    saveWorkspace(workspace: SessionWorkspace): Promise<void> {
      return ipcRenderer.invoke("app:saveWorkspace", workspace) as Promise<void>;
    },
    saveScripts(library: ScriptLibrary): Promise<void> {
      return ipcRenderer.invoke("app:saveScripts", library) as Promise<void>;
    },
    saveSettings(settings: AppSettings): Promise<void> {
      return ipcRenderer.invoke("app:saveSettings", settings) as Promise<void>;
    },
    exportData(): Promise<DialogFileResult> {
      return ipcRenderer.invoke("app:export") as Promise<DialogFileResult>;
    },
    importData(): Promise<AppSnapshot | null> {
      return ipcRenderer.invoke("app:import") as Promise<AppSnapshot | null>;
    },
    checkAndDownloadUpdate(): Promise<AppUpdateResult> {
      return ipcRenderer.invoke("app:updateCheckAndDownload") as Promise<AppUpdateResult>;
    },
    installPendingUpdate(): Promise<AppUpdateResult> {
      return ipcRenderer.invoke("app:updateInstallPending") as Promise<AppUpdateResult>;
    },
    onUpdateProgress(callback: (progress: AppUpdateProgress) => void): Disposable {
      const listener = (_event: Electron.IpcRendererEvent, payload: AppUpdateProgress) => callback(payload);
      ipcRenderer.on("app:updateProgress", listener);
      return () => ipcRenderer.off("app:updateProgress", listener);
    },
    onCommand(callback: (event: AppCommandEvent) => void): Disposable {
      const listener = (_event: Electron.IpcRendererEvent, payload: AppCommandEvent) => callback(payload);
      ipcRenderer.on("app:command", listener);
      return () => ipcRenderer.off("app:command", listener);
    },
    isFullScreen(): Promise<boolean> {
      return ipcRenderer.invoke("window:isFullScreen") as Promise<boolean>;
    },
    onFullScreenChange(callback: (isFullScreen: boolean) => void): Disposable {
      const listener = (_event: Electron.IpcRendererEvent, value: boolean) => callback(value);
      ipcRenderer.on("window:fullScreenChanged", listener);
      return () => ipcRenderer.off("window:fullScreenChanged", listener);
    }
  },
  menu: {
    popup(request: ContextMenuRequest): Promise<void> {
      return ipcRenderer.invoke("menu:popup", request) as Promise<void>;
    }
  },
  dialog: {
    privateKey(): Promise<DialogFileResult> {
      return ipcRenderer.invoke("dialog:privateKey") as Promise<DialogFileResult>;
    },
    openPath(options: { directories?: boolean; multiple?: boolean; title?: string; buttonLabel?: string; defaultPath?: string }): Promise<DialogFileResult> {
      return ipcRenderer.invoke("dialog:openPath", options) as Promise<DialogFileResult>;
    }
  },
  keychain: {
    setPassword(sessionID: string, account: string, password: string): Promise<{ code: number; output: string }> {
      return ipcRenderer.invoke("keychain:setPassword", sessionID, account, password) as Promise<{ code: number; output: string }>;
    },
    getPassword(sessionID: string, account: string): Promise<string | null> {
      return ipcRenderer.invoke("keychain:getPassword", sessionID, account) as Promise<string | null>;
    }
  },
  batch: {
    run(request: BatchExecutionRequest): Promise<BatchExecutionResult[]> {
      return ipcRenderer.invoke("batch:run", request) as Promise<BatchExecutionResult[]>;
    }
  }
});

export type ShellXBridge = typeof terminalAPI;
