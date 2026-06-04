import type {
  AppSettings,
  AppSnapshot,
  AppUpdateProgress,
  AppUpdateResult,
  BatchExecutionRequest,
  BatchExecutionResult,
  DialogFileResult,
  ScriptLibrary,
  SessionWorkspace
} from "../shared/terminal";
import type { ShellXBridge } from "../main/preload";

interface AppCommandEvent {
  command: string;
  payload?: Record<string, unknown>;
}

interface ContextMenuRequest {
  type: "root" | "folder" | "session" | "tab" | "terminal" | "script" | "scriptRoot" | "scriptFolder";
  payload?: Record<string, unknown>;
}

declare global {
  interface Window {
    shellx: {
      terminal: ShellXBridge;
      app: {
        load(): Promise<AppSnapshot>;
        saveWorkspace(workspace: SessionWorkspace): Promise<void>;
        saveScripts(library: ScriptLibrary): Promise<void>;
        saveSettings(settings: AppSettings): Promise<void>;
        exportData(): Promise<DialogFileResult>;
        importData(): Promise<AppSnapshot | null>;
        checkAndDownloadUpdate(): Promise<AppUpdateResult>;
        installPendingUpdate(): Promise<AppUpdateResult>;
        onUpdateProgress(callback: (progress: AppUpdateProgress) => void): () => void;
        onCommand(callback: (event: AppCommandEvent) => void): () => void;
      };
      menu: {
        popup(request: ContextMenuRequest): Promise<void>;
      };
      dialog: {
        privateKey(): Promise<DialogFileResult>;
        openPath(options: { directories?: boolean; multiple?: boolean; title?: string; buttonLabel?: string; defaultPath?: string }): Promise<DialogFileResult>;
      };
      keychain: {
        setPassword(sessionID: string, account: string, password: string): Promise<{ code: number; output: string }>;
        getPassword(sessionID: string, account: string): Promise<string | null>;
      };
      batch: {
        run(request: BatchExecutionRequest): Promise<BatchExecutionResult[]>;
      };
    };
  }
}

export {};
