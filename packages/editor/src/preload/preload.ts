import { contextBridge, ipcRenderer } from "electron";

/**
 * Exposes a safe API to the renderer process via context bridge.
 * The renderer process cannot access Node.js or Electron APIs directly.
 */
contextBridge.exposeInMainWorld("guavaEngine", {
  /** The OS platform (e.g. "darwin", "win32", "linux") */
  platform: process.platform,

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

  /** Subscribe to pixel data pushed from main process (Linux shm path) */
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
});

/** Type declaration for the exposed API (used in renderer) */
export interface GuavaEngineAPI {
  platform: string;
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
  onViewportPixels(callback: (pixels: Buffer, width: number, height: number) => void): () => void;
  onViewportSharedBuffer(callback: (sab: SharedArrayBuffer) => void): () => void;
  testRemoteConnection(url: string): Promise<{ ok: boolean; version?: string; error?: string }>;
  connectToServer(url: string): Promise<{ ok: boolean; error?: string }>;
}
