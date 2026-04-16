/** Type definition for the guava-bridge.js global `window.guavaEngine` API. */
export interface GuavaEngineAPI {
  // Core RPC
  call(method: string, params?: unknown): Promise<unknown>;

  // Engine lifecycle
  getStatus(): Promise<unknown>;
  onStatusChanged(callback: (status: unknown) => void): () => void;
  onConnected(callback: () => void): () => void;
  onError(callback: (error: unknown) => void): () => void;
  onEvent(callback: (event: string, data?: unknown) => void): () => void;
  connectToServer(url: string): Promise<{ ok: boolean; error?: string }>;
  testRemoteConnection(url: string): Promise<{ ok: boolean; error?: string }>;

  // Project management
  openProject(path: string): Promise<{ ok: boolean; error?: string }>;
  getRecentProjects(): Promise<unknown>;
  removeRecentProject(path: string): Promise<void>;
  createProject(path: string, name: string, template?: string): Promise<{ ok: boolean; error?: string }>;
  getTemplates(): Promise<unknown>;
  getProjectPath(): string;
  getAppMode(): string;
  platform: string;

  // File operations
  selectFolder(): Promise<string | null>;
  browseFolder(opts?: unknown): Promise<string | null>;
  readDir(path: string, opts?: unknown): Promise<unknown>;
  readTextFile(path: string): Promise<string>;
  writeTextFile(path: string, content: string): Promise<void>;
  fsCreateFile(path: string, content?: string): Promise<{ ok: boolean; error?: string }>;
  fsDelete(path: string): Promise<{ ok: boolean; error?: string }>;
  fsMkdir(path: string): Promise<{ ok: boolean; error?: string }>;
  fsRename(oldPath: string, newPath: string): Promise<{ ok: boolean; error?: string }>;
  fsImportFiles(dest: string): Promise<{ ok: boolean; error?: string }>;
  fsImportPaths(paths: string[], dest: string): Promise<{ ok: boolean; error?: string }>;
  onImportProgress(callback: (progress: unknown) => void): () => void;

  // Engine / launcher
  launchEngine(opts?: unknown): Promise<{ ok: boolean; error?: string }>;
  runBuiltGame(opts?: unknown): Promise<{ ok: boolean; error?: string }>;
  buildPackage(opts?: unknown): Promise<{ ok: boolean; error?: string }>;
  cancelBuild(): Promise<void>;
  onBuildProgress(callback: (progress: unknown) => void): () => void;

  // Viewport
  viewportAttachSurface(surfaceId: number, x: number, y: number, w: number, h: number, shmName?: string): Promise<unknown>;
  viewportDetach(): Promise<void>;
  viewportUpdateSurface(surfaceId: number, shmName?: string, width?: number, height?: number): Promise<void>;
  viewportUpdateBounds(x: number, y: number, w: number, h: number): Promise<void>;
  viewportUpdateExclusions(rects: number[][]): Promise<void>;
  onViewportPixels(callback: (pixels: unknown, width: unknown, height: unknown) => void): () => void;
  onViewportSharedBuffer(callback: (sab: unknown) => void): () => void;
  onViewportOverlayActive(callback: (active: unknown) => void): () => void;

  // Popout windows
  popoutPanel(panels: string[], state?: unknown, originInfo?: unknown, bounds?: unknown): Promise<number>;
  closePopout(): Promise<void>;
  isPopoutWindow(): boolean;
  getPopoutPanels(): string[];
  onPopoutClosed(callback: (panels: string[], originInfo?: unknown, bounds?: unknown) => void): () => void;
  onInitState(callback: (state: unknown) => void): () => void;
}

declare global {
  interface Window {
    guavaEngine: GuavaEngineAPI;
  }
}
