import { contextBridge, ipcRenderer } from "electron";

/**
 * Exposes a safe API to the renderer process via context bridge.
 * The renderer process cannot access Node.js or Electron APIs directly.
 */
contextBridge.exposeInMainWorld("guavaEngine", {
  /** The OS platform (e.g. "darwin", "win32", "linux") */
  platform: process.platform,

  // ── Launcher ────────────────────────────────────────────────────

  /** Get the current app mode (launcher or editor) */
  getAppMode: (): Promise<"launcher" | "editor"> =>
    ipcRenderer.invoke("launcher:getAppMode"),

  /** Get list of recently opened projects */
  getRecentProjects: (): Promise<{ path: string; name: string; lastOpened: string }[]> =>
    ipcRenderer.invoke("launcher:getRecentProjects"),

  /** Remove a project from the recent list */
  removeRecentProject: (projectPath: string): Promise<void> =>
    ipcRenderer.invoke("launcher:removeRecentProject", projectPath),

  /** Open a native folder selection dialog */
  browseFolder: (): Promise<string | null> =>
    ipcRenderer.invoke("launcher:browseFolder"),

  /** Get available project templates */
  getTemplates: (): Promise<{ id: string; name: string; description: string; icon: string }[]> =>
    ipcRenderer.invoke("launcher:getTemplates"),

  /** Open a project by path (starts engine + connects) */
  openProject: (projectPath: string): Promise<{ ok: boolean; error?: string }> =>
    ipcRenderer.invoke("launcher:openProject", projectPath),

  /** Create a new project and open it */
  createProject: (projectPath: string, projectName: string, templateId?: string): Promise<{ ok: boolean; error?: string }> =>
    ipcRenderer.invoke("launcher:createProject", projectPath, projectName, templateId),

  /** Call an engine RPC method */
  call: (method: string, params: unknown): Promise<unknown> =>
    ipcRenderer.invoke("engine:call", method, params),

  /** Get engine connection status */
  getStatus: (): Promise<{ engineRunning: boolean; rpcConnected: boolean }> =>
    ipcRenderer.invoke("engine:status"),

  /** Subscribe to engine push events */
  onEvent: (
    callback: (event: string, data: unknown) => void,
  ): (() => void) => {
    const handler = (
      _event: Electron.IpcRendererEvent,
      eventName: string,
      data: unknown,
    ) => {
      callback(eventName, data);
    };
    ipcRenderer.on("engine:event", handler);
    return () => ipcRenderer.removeListener("engine:event", handler);
  },

  /** Engine connected notification */
  onConnected: (callback: () => void): (() => void) => {
    const handler = () => callback();
    ipcRenderer.on("engine:connected", handler);
    return () => ipcRenderer.removeListener("engine:connected", handler);
  },

  /** Engine error notification */
  onError: (callback: (error: string) => void): (() => void) => {
    const handler = (_event: Electron.IpcRendererEvent, error: string) =>
      callback(error);
    ipcRenderer.on("engine:error", handler);
    return () => ipcRenderer.removeListener("engine:error", handler);
  },

  /** Engine disconnected notification (crash or unexpected exit) */
  onDisconnected: (
    callback: (info: { code: number | null; restarting: boolean }) => void,
  ): (() => void) => {
    const handler = (
      _event: Electron.IpcRendererEvent,
      info: { code: number | null; restarting: boolean },
    ) => callback(info);
    ipcRenderer.on("engine:disconnected", handler);
    return () => ipcRenderer.removeListener("engine:disconnected", handler);
  },

  // ── Viewport (cross-platform) ───────────────────────────────────

  /** Attach a viewport surface to the Electron window at the given rect */
  viewportAttachSurface: (
    surfaceId: number,
    x: number,
    y: number,
    w: number,
    h: number,
    shmName?: string,
  ): Promise<boolean> =>
    ipcRenderer.invoke("viewport:attachSurface", surfaceId, x, y, w, h, shmName),

  /** Replace the surface (e.g. after engine-side resize) */
  viewportUpdateSurface: (surfaceId: number, shmName?: string, width?: number, height?: number): Promise<void> =>
    ipcRenderer.invoke("viewport:updateSurface", surfaceId, shmName, width, height),

  /** Remove the viewport surface */
  viewportDetach: (): Promise<void> => ipcRenderer.invoke("viewport:detach"),

  /** Report viewport div bounds to main process for native overlay positioning */
  viewportUpdateBounds: (x: number, y: number, w: number, h: number): void => {
    ipcRenderer.send("viewport:updateBounds", x, y, w, h);
  },

  /** Report exclusion rects (overlay-relative CSS points) to punch holes in the native overlay */
  viewportUpdateExclusions: (rects: number[][]): void => {
    ipcRenderer.send("viewport:updateExclusions", rects);
  },

  /** Subscribe to native overlay activation (macOS zero-copy path) */
  onViewportOverlayActive: (
    callback: (active: boolean) => void,
  ): (() => void) => {
    const handler = (_event: Electron.IpcRendererEvent, active: boolean) => callback(active);
    ipcRenderer.on("viewport:overlay-active", handler);
    return () => ipcRenderer.removeListener("viewport:overlay-active", handler);
  },

  /** Subscribe to pixel data pushed from main process (Linux shm path) */
  onViewportPixels: (
    callback: (pixels: Buffer, width: number, height: number) => void,
  ): (() => void) => {
    const handler = (
      _event: Electron.IpcRendererEvent,
      pixels: Buffer,
      width: number,
      height: number,
    ) => callback(pixels, width, height);
    ipcRenderer.on("viewport:pixels", handler);
    return () => ipcRenderer.removeListener("viewport:pixels", handler);
  },

  /** Subscribe to SharedArrayBuffer for zero-copy viewport pixels (macOS) */
  onViewportSharedBuffer: (
    callback: (sab: SharedArrayBuffer) => void,
  ): (() => void) => {
    const handler = (
      _event: Electron.IpcRendererEvent,
      sab: SharedArrayBuffer,
    ) => {
      if (sab instanceof SharedArrayBuffer) {
        callback(sab);
      }
    };
    ipcRenderer.on("viewport:shared-buffer", handler);
    return () => ipcRenderer.removeListener("viewport:shared-buffer", handler);
  },

  /** Test connection to a remote engine server */
  testRemoteConnection: (url: string): Promise<{ ok: boolean; version?: string; error?: string }> =>
    ipcRenderer.invoke("settings:testRemoteConnection", url),

  /** Connect to a remote engine server (or "local" to switch back) */
  connectToServer: (url: string): Promise<{ ok: boolean; error?: string }> =>
    ipcRenderer.invoke("settings:connectToServer", url),

  // ── Multi-window popout ─────────────────────────────────────────

  /** Pop out one or more panels into a separate window */
  popoutPanel: (panels: string[], initialState?: unknown, originInfo?: unknown, bounds?: { width?: number; height?: number; x?: number; y?: number }): Promise<number> =>
    ipcRenderer.invoke("window:popout-panel", panels, initialState, originInfo, bounds),

  /** Close the current popout window (call from popout window only) */
  closePopout: (): Promise<void> =>
    ipcRenderer.invoke("window:close-popout"),

  /** Check if the current window is a popout window */
  isPopoutWindow: (): boolean => {
    const params = new URLSearchParams(window.location.search);
    return params.has("popout");
  },

  /** Get the panel IDs for the current popout window */
  getPopoutPanels: (): string[] => {
    const params = new URLSearchParams(window.location.search);
    const popout = params.get("popout");
    return popout ? popout.split(",").map(decodeURIComponent) : [];
  },

  /** Subscribe to popout window closed notifications (main window only) */
  onPopoutClosed: (callback: (panels: string[], originInfo?: unknown, bounds?: { x: number; y: number; width: number; height: number }) => void): (() => void) => {
    const handler = (_event: Electron.IpcRendererEvent, panels: string[], originInfo?: unknown, bounds?: { x: number; y: number; width: number; height: number }) =>
      callback(panels, originInfo, bounds);
    ipcRenderer.on("popout:closed", handler);
    return () => ipcRenderer.removeListener("popout:closed", handler);
  },

  /** Subscribe to initial state pushed from main process (popout windows only) */
  onInitState: (callback: (state: unknown) => void): (() => void) => {
    const handler = (_event: Electron.IpcRendererEvent, state: unknown) =>
      callback(state);
    ipcRenderer.on("popout:init-state", handler);
    return () => ipcRenderer.removeListener("popout:init-state", handler);
  },

  // ── Build / Package ─────────────────────────────────────────────

  /** Build a standalone game package */
  buildPackage: (opts?: { outputDir?: string; optimize?: string; choosePath?: boolean }): Promise<{ ok: boolean; path?: string; error?: string }> =>
    ipcRenderer.invoke("build:package", opts),

  /** Cancel an in-progress build */
  cancelBuild: (): Promise<{ ok: boolean; error?: string }> =>
    ipcRenderer.invoke("build:cancel"),

  /** Run a previously built game package */
  runBuiltGame: (appPath: string): Promise<{ ok: boolean; error?: string }> =>
    ipcRenderer.invoke("build:run", appPath),

  /** Subscribe to build progress updates */
  onBuildProgress: (callback: (progress: { stage: string; percent: number; detail?: string; log?: string }) => void): (() => void) => {
    const handler = (_event: Electron.IpcRendererEvent, progress: { stage: string; percent: number; detail?: string; log?: string }) =>
      callback(progress);
    ipcRenderer.on("build:progress", handler);
    return () => ipcRenderer.removeListener("build:progress", handler);
  },

  // ── File System (project-scoped) ────────────────────────────────

  /** Create a directory (relative to project root) */
  fsMkdir: (relativePath: string): Promise<{ ok: boolean; error?: string }> =>
    ipcRenderer.invoke("fs:mkdir", relativePath),

  /** Rename/move a file or directory (relative to project root) */
  fsRename: (oldPath: string, newPath: string): Promise<{ ok: boolean; error?: string }> =>
    ipcRenderer.invoke("fs:rename", oldPath, newPath),

  /** Delete a file or directory (relative to project root) */
  fsDelete: (relativePath: string): Promise<{ ok: boolean; error?: string }> =>
    ipcRenderer.invoke("fs:delete", relativePath),

  /** Create a file with content (relative to project root) */
  fsCreateFile: (relativePath: string, content: string): Promise<{ ok: boolean; error?: string }> =>
    ipcRenderer.invoke("fs:createFile", relativePath, content),

  /** Open native file dialog and copy selected files into target directory */
  fsImportFiles: (targetRelDir: string): Promise<{ ok: boolean; files: string[]; canceled?: boolean; error?: string }> =>
    ipcRenderer.invoke("fs:importFiles", targetRelDir),

  /** Import files/directories from given absolute OS paths (drag-drop) */
  fsImportPaths: (targetRelDir: string, sourcePaths: string[]): Promise<{ ok: boolean; files: string[]; error?: string }> =>
    ipcRenderer.invoke("fs:importPaths", targetRelDir, sourcePaths),

  /** Listen for import progress events */
  onImportProgress: (callback: (progress: { current: number; total: number; name?: string; done?: boolean }) => void): (() => void) => {
    const handler = (_event: unknown, progress: { current: number; total: number; name?: string; done?: boolean }) => callback(progress);
    ipcRenderer.on("fs:importProgress", handler);
    return () => ipcRenderer.removeListener("fs:importProgress", handler);
  },
});

/** Type declaration for the exposed API (used in renderer) */
export interface GuavaEngineAPI {
  platform: string;
  // Launcher
  getAppMode(): Promise<"launcher" | "editor">;
  getRecentProjects(): Promise<{ path: string; name: string; lastOpened: string }[]>;
  removeRecentProject(projectPath: string): Promise<void>;
  browseFolder(): Promise<string | null>;
  getTemplates(): Promise<{ id: string; name: string; description: string; icon: string }[]>;
  openProject(projectPath: string): Promise<{ ok: boolean; error?: string }>;
  createProject(projectPath: string, projectName: string, templateId?: string): Promise<{ ok: boolean; error?: string }>;
  // Engine RPC
  call<M extends import("../shared/rpc-types").RpcMethodName>(
    method: M,
    params: import("../shared/rpc-types").RpcParams<M>,
  ): Promise<import("../shared/rpc-types").RpcResult<M>>;
  getStatus(): Promise<{ engineRunning: boolean; rpcConnected: boolean }>;
  onEvent(callback: (event: string, data: unknown) => void): () => void;
  onConnected(callback: () => void): () => void;
  onError(callback: (error: string) => void): () => void;
  onDisconnected(callback: (info: { code: number | null; restarting: boolean }) => void): () => void;
  viewportAttachSurface(surfaceId: number, x: number, y: number, w: number, h: number, shmName?: string): Promise<boolean>;
  viewportUpdateSurface(surfaceId: number, shmName?: string, width?: number, height?: number): Promise<void>;
  viewportDetach(): Promise<void>;
  viewportUpdateBounds(x: number, y: number, w: number, h: number): void;
  viewportUpdateExclusions(rects: number[][]): void;
  onViewportOverlayActive(callback: (active: boolean) => void): () => void;
  onViewportPixels(callback: (pixels: Buffer, width: number, height: number) => void): () => void;
  onViewportSharedBuffer(callback: (sab: SharedArrayBuffer) => void): () => void;
  testRemoteConnection(url: string): Promise<{ ok: boolean; version?: string; error?: string }>;
  connectToServer(url: string): Promise<{ ok: boolean; error?: string }>;
  popoutPanel(panels: string[], initialState?: unknown, originInfo?: unknown, bounds?: { width?: number; height?: number; x?: number; y?: number }): Promise<number>;
  closePopout(): Promise<void>;
  isPopoutWindow(): boolean;
  getPopoutPanels(): string[];
  onPopoutClosed(callback: (panels: string[], originInfo?: unknown, bounds?: { x: number; y: number; width: number; height: number }) => void): () => void;
  onInitState(callback: (state: unknown) => void): () => void;
  // Build
  buildPackage(opts?: { outputDir?: string; optimize?: string; choosePath?: boolean }): Promise<{ ok: boolean; path?: string; error?: string }>;
  cancelBuild(): Promise<{ ok: boolean; error?: string }>;
  runBuiltGame(appPath: string): Promise<{ ok: boolean; error?: string }>;
  onBuildProgress(callback: (progress: { stage: string; percent: number; detail?: string; log?: string }) => void): () => void;
  // File system
  fsMkdir(relativePath: string): Promise<{ ok: boolean; error?: string }>;
  fsRename(oldPath: string, newPath: string): Promise<{ ok: boolean; error?: string }>;
  fsDelete(relativePath: string): Promise<{ ok: boolean; error?: string }>;
  fsCreateFile(relativePath: string, content: string): Promise<{ ok: boolean; error?: string }>;
  fsImportFiles(targetRelDir: string): Promise<{ ok: boolean; files: string[]; canceled?: boolean; error?: string }>;
  fsImportPaths(targetRelDir: string, sourcePaths: string[]): Promise<{ ok: boolean; files: string[]; error?: string }>;
  onImportProgress(callback: (progress: { current: number; total: number; name?: string; done?: boolean }) => void): () => void;
}
