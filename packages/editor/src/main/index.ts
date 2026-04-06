import { app, BrowserWindow, dialog, ipcMain, session } from "electron";
import path from "path";
import fs from "fs/promises";
import { EngineProcess } from "./engine-process";
import { EngineClient } from "./engine-client";
import {
  loadRecentProjects,
  addRecentProject,
  removeRecentProject,
  readProjectName,
  readStartScene,
  isGuavaProject,
  createNewProject,
} from "./recent-projects";
import { PROJECT_TEMPLATES, applyTemplate } from "./project-templates";
import { buildProject, type BuildProgress } from "./build-project";

// Guard against EPIPE on stdout/stderr — happens when the parent process
// (e.g. Vite dev server terminal) closes its end of the pipe while we're
// still writing log output.  Without this, Electron shows a crash dialog.
for (const stream of [process.stdout, process.stderr]) {
  stream.on("error", (err: NodeJS.ErrnoException) => {
    if (err.code === "EPIPE") return;
    throw err;
  });
}

// Enable SharedArrayBuffer in the renderer process without COOP/COEP headers.
// Required for file:// protocol where onHeadersReceived doesn't apply.
app.commandLine.appendSwitch("enable-features", "SharedArrayBuffer");

const DEFAULT_PORT = 9100;

let mainWindow: BrowserWindow | null = null;
const popoutWindows: Map<number, { win: BrowserWindow; panels: string[]; originInfo?: unknown }> = new Map();
let engineProcess: EngineProcess | null = null;
let engineClient: EngineClient | null = null;
let isQuitting = false;
let restartCount = 0;
const MAX_RESTARTS = 3;
let launcherMode = false;

// ── Native viewport addon (platform-specific) ───────────────────

interface ViewportAddon {
  attach(handle: Buffer, surfaceId: number, x: number, y: number, w: number, h: number): void;
  updateSurface(surfaceId: number, shmName?: string, width?: number, height?: number): void;
  detach(): void;
  refresh(): { pixels: Buffer; width: number; height: number } | void;
  setSharedBuffer?(sab: ArrayBufferLike | Uint8Array): void;
  refreshShared?(): boolean;
}

let ioSurfaceView: ViewportAddon | null = null;
let viewportSAB: SharedArrayBuffer | null = null;
const isMac = process.platform === "darwin";
try {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const addonPath = app.isPackaged
    ? path.join(process.resourcesPath, "iosurface_view.node")
    : path.join(__dirname, "../../native/build/Release/iosurface_view.node");
  ioSurfaceView = require(addonPath) as ViewportAddon;
} catch (err) {
  console.warn("[Main] Viewport native addon not available:", err);
}

/** Send a message to all open renderer windows (main + popouts) */
function broadcastToRenderers(channel: string, ...args: unknown[]): void {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send(channel, ...args);
  }
  for (const [, { win }] of popoutWindows) {
    if (!win.isDestroyed()) {
      win.webContents.send(channel, ...args);
    }
  }
}

function getEngineBinaryPath(): string {
  if (app.isPackaged) {
    // In packaged app, guava-engine is placed next to the asar in Resources/
    return path.join(process.resourcesPath, "guava-engine");
  }
  // In development, use the sibling engine package's build output
  return path.resolve(__dirname, "../../..", "engine/zig-out/bin/guava-engine");
}

function getProjectPath(): string | undefined {
  // Check command-line arguments for --project-path
  const args = process.argv;
  const idx = args.indexOf("--project-path");
  if (idx !== -1 && idx + 1 < args.length) {
    return args[idx + 1];
  }
  return undefined;
}

async function createMainWindow(): Promise<BrowserWindow> {
  const isLauncher = launcherMode;
  const win = new BrowserWindow({
    width: isLauncher ? 900 : 1200,
    height: isLauncher ? 560 : 800,
    minWidth: isLauncher ? 640 : 800,
    minHeight: isLauncher ? 400 : 600,
    titleBarStyle: "hiddenInset",
    trafficLightPosition: { x: 12, y: 12 },
    backgroundColor: "#1e1e2e",
    webPreferences: {
      preload: path.join(__dirname, "../preload/preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });

  // In editor mode, maximize the window by default
  if (!isLauncher) {
    win.maximize();
  }

  // In development, load from Vite dev server; in production, load built files
  if (process.env.VITE_DEV_SERVER_URL) {
    await win.loadURL(process.env.VITE_DEV_SERVER_URL);
  } else {
    await win.loadFile(path.join(__dirname, "../renderer/index.html"));
  }

  // Open DevTools in development for debugging
  if (process.env.NODE_ENV === "development" || process.env.VITE_DEV_SERVER_URL) {
    win.webContents.openDevTools({ mode: "detach" });
  }

  // Block DevTools keyboard shortcuts in packaged builds
  if (app.isPackaged) {
    win.webContents.on("before-input-event", (event, input) => {
      // F12 or Cmd/Ctrl+Option+I
      if (
        input.key === "F12" ||
        (input.alt && (input.meta || input.control) && input.key.toLowerCase() === "i")
      ) {
        event.preventDefault();
      }
    });
  }

  // Forward renderer console output to main process stdout for debugging
  win.webContents.on("console-message", (_event, level, message, line, sourceId) => {
    const prefix = ["[Renderer:V]", "[Renderer:I]", "[Renderer:W]", "[Renderer:E]"][level] ?? "[Renderer]";
    console.log(`${prefix} ${message} (${sourceId}:${line})`);
  });

  return win;
}

/** Currently active project path (set by CLI arg or launcher selection). */
let currentProjectPath: string | undefined;

async function startEngine(): Promise<void> {
  const projectPath = currentProjectPath ?? getProjectPath();

  engineProcess = new EngineProcess({
    engineBinary: getEngineBinaryPath(),
    projectPath,
    port: DEFAULT_PORT,
  });

  // Wait for engine to be ready
  const readyPromise = new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("Engine startup timeout")), 15000);

    engineProcess!.once("ready", () => {
      clearTimeout(timeout);
      resolve();
    });

    engineProcess!.once("error", (err: Error) => {
      clearTimeout(timeout);
      reject(err);
    });
  });

  engineProcess.start();
  await readyPromise;

  // Connect WebSocket RPC client
  engineClient = new EngineClient(`ws://127.0.0.1:${DEFAULT_PORT}`, {
    timeout: 10000,
    reconnectInterval: 2000,
    onReconnected: () => {
      // If the engine reconnects (e.g. after a restart), notify all renderer windows.
      broadcastToRenderers("engine:connected");
    },
  });
  await engineClient.connect();

  // Register subscription handlers BEFORE any RPC calls so buffered
  // engine notifications (e.g. console logs) are not silently dropped.
  setupSubscriptionForwarding();

  // Verify connection
  await engineClient.call("editor.getCapabilities", {});
}

// ── Engine process crash monitoring & auto-restart ───────────────

function monitorEngineProcess(): void {
  if (!engineProcess) return;

  engineProcess.on("exit", async (code: number | null) => {
    if (isQuitting) return;

    const canRestart = restartCount < MAX_RESTARTS;
    console.error(
      `[Main] Engine process exited unexpectedly (code: ${code}). ` +
      (canRestart ? `Restarting (${restartCount + 1}/${MAX_RESTARTS})...` : "Max restarts reached."),
    );

    // Notify all renderer windows immediately
    broadcastToRenderers("engine:disconnected", { code, restarting: canRestart });

    if (!canRestart) {
      broadcastToRenderers(
        "engine:error",
        `Engine crashed ${MAX_RESTARTS} times. Please restart the application.`,
      );
      return;
    }

    restartCount++;

    // Clean up old client (stops reconnect loop)
    engineClient?.disconnect();
    engineClient = null;

    // Brief delay before restart
    await new Promise((r) => setTimeout(r, 1500));
    if (isQuitting) return;

    try {
      await startEngine();
      monitorEngineProcess(); // Re-attach to new process instance
      broadcastToRenderers("engine:connected");
      restartCount = 0; // Reset on successful restart
      console.log("[Main] Engine restarted successfully");
    } catch (err) {
      console.error("[Main] Engine restart failed:", err);
      broadcastToRenderers("engine:error", `Engine restart failed: ${err}`);
    }
  });
}

// ── IPC Bridge: Renderer ↔ Engine ────────────────────────────────

ipcMain.handle("engine:call", async (_event, method: string, params: unknown) => {
  // If momentarily disconnected (e.g. after HMR), wait briefly for reconnection.
  if (!engineClient?.connected) {
    await new Promise((r) => setTimeout(r, 500));
    if (!engineClient?.connected) {
      throw new Error("Engine not connected");
    }
  }
  return engineClient.call(method as keyof typeof engineClient.call, params as never);
});

ipcMain.handle("engine:status", () => {
  return {
    engineRunning: engineProcess?.running ?? false,
    rpcConnected: engineClient?.connected ?? false,
  };
});

// ── Subscription forwarding: Engine push → Renderer ──────────────

function setupSubscriptionForwarding(): void {
  if (!engineClient) return;

  const events = [
    "on:scene.changed",
    "on:selection.changed",
    "on:viewport.metrics",
    "on:console.log",
    "on:console.logs",
    "on:playback.stateChanged",
    "on:asset.changed",
    "on:editor.historyChanged",
    "on:mesh.stateChanged",
  ] as const;

  for (const event of events) {
    engineClient.on(event, (data) => {
      broadcastToRenderers("engine:event", event, data);
    });
  }
}

// ── Viewport integration (cross-platform) ────────────────────────

let surfaceRefreshTimer: ReturnType<typeof setInterval> | null = null;

// Renderer calls this to start pixel streaming from the engine's shared surface.
ipcMain.handle(
  "viewport:attachSurface",
  async (_event, surfaceId: number, _x: number, _y: number, w: number, h: number, shmName?: string) => {
    if (!ioSurfaceView || !mainWindow) return false;

    if (isMac) {
      // macOS: store the IOSurface reference for pixel readback
      ioSurfaceView.attach(Buffer.alloc(8), surfaceId, 0, 0, w, h);
    } else if (shmName) {
      // Linux: set up shm mapping for pixel readback
      ioSurfaceView.updateSurface(0, shmName, w, h);
    }

    if (surfaceRefreshTimer) clearInterval(surfaceRefreshTimer);

    // Prefer SharedArrayBuffer path: zero-IPC pixel delivery.
    // The renderer polls the SAB directly via Atomics; we only need to
    // memcpy IOSurface → SAB on each tick here in the main process.
    const useSAB = isMac && typeof ioSurfaceView.setSharedBuffer === "function";
    let sabActive = false;
    if (useSAB) {
      try {
        // Allocate SAB for up to 4K viewport, double-buffered (ping-pong)
        // to prevent tearing when the native addon writes while the renderer reads.
        const maxPixelBytes = 3840 * 2160 * 4;
        const sabSize = 16 + maxPixelBytes * 2;
        viewportSAB = new SharedArrayBuffer(sabSize);
        // Pass a Uint8Array view — N-API can extract the backing ArrayBuffer from
        // a TypedArray regardless of whether it's a regular or shared buffer.
        ioSurfaceView.setSharedBuffer!(new Uint8Array(viewportSAB) as never);

        // Send SAB to renderer (one-time, zero-copy share)
        mainWindow.webContents.postMessage("viewport:shared-buffer", viewportSAB);

        // Poll-based refresh: the staging IOSurface is always safe to read
        // (GPU never writes to it directly).  The addon's refreshShared() uses
        // IOSurfaceGetSeed to skip redundant copies, so fast polling is cheap.
        const doRefresh = () => {
          if (!ioSurfaceView || !mainWindow) return;
          if (mainWindow.webContents.isDestroyed()) {
            if (surfaceRefreshTimer) clearInterval(surfaceRefreshTimer);
            surfaceRefreshTimer = null;
            return;
          }
          ioSurfaceView.refreshShared!();
        };
        // Poll at ~120Hz — seed check makes redundant calls nearly free.
        surfaceRefreshTimer = setInterval(doRefresh, 8);
        sabActive = true;
      } catch (e) {
        console.warn("[Viewport] SAB path failed, falling back to IPC:", (e as Error).message);
        viewportSAB = null;
      }
    }
    if (!sabActive) {
      // Fallback: IPC-based pixel delivery (Linux / no SAB support)
      surfaceRefreshTimer = setInterval(() => {
        if (!ioSurfaceView || !mainWindow) return;
        if (mainWindow.webContents.isDestroyed()) {
          clearInterval(surfaceRefreshTimer!);
          surfaceRefreshTimer = null;
          return;
        }
        const result = ioSurfaceView.refresh();
        if (result && result.pixels) {
          mainWindow.webContents.send("viewport:pixels", result.pixels, result.width, result.height);
        }
      }, 16);
    }

    return true;
  },
);

ipcMain.handle("viewport:updateSurface", async (_event, surfaceId: number, shmName?: string, width?: number, height?: number) => {
  if (isMac) {
    ioSurfaceView?.updateSurface(surfaceId);
  } else if (shmName && width && height) {
    ioSurfaceView?.updateSurface(0, shmName, width, height);
  }
});

ipcMain.handle("viewport:detach", async () => {
  if (surfaceRefreshTimer) {
    clearInterval(surfaceRefreshTimer);
    surfaceRefreshTimer = null;
  }
  ioSurfaceView?.detach();
});

// ── Remote server support ────────────────────────────────────────

import WebSocket from "ws";

// ── Popout window management ─────────────────────────────────────

async function createPopoutWindow(panels: string[], initialState?: unknown, originInfo?: unknown, bounds?: { width?: number; height?: number; x?: number; y?: number }): Promise<number> {
  const panelQuery = panels.map((p) => encodeURIComponent(p)).join(",");

  const win = new BrowserWindow({
    width: bounds?.width ?? 600,
    height: bounds?.height ?? 500,
    ...(bounds?.x != null && bounds?.y != null ? { x: bounds.x, y: bounds.y } : {}),
    minWidth: 300,
    minHeight: 200,
    backgroundColor: "#1e1e2e",
    webPreferences: {
      preload: path.join(__dirname, "../preload/preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      // Disable DevTools in packaged builds to prevent runtime inspection
      devTools: !app.isPackaged,
    },
  });

  const winId = win.id;
  popoutWindows.set(winId, { win, panels, originInfo });

  if (process.env.VITE_DEV_SERVER_URL) {
    await win.loadURL(`${process.env.VITE_DEV_SERVER_URL}?popout=${panelQuery}`);
  } else {
    await win.loadFile(path.join(__dirname, "../renderer/index.html"), {
      query: { popout: panelQuery },
    });
  }

  // Forward renderer console output for debugging
  win.webContents.on("console-message", (_event, level, message, line, sourceId) => {
    const prefix = ["[Popout:V]", "[Popout:I]", "[Popout:W]", "[Popout:E]"][level] ?? "[Popout]";
    console.log(`${prefix} ${message} (${sourceId}:${line})`);
  });

  // Send current engine status to new window once loaded
  win.webContents.on("did-finish-load", () => {
    if (engineClient?.connected) {
      win.webContents.send("engine:connected");
    }
    // Forward initial store state so popout has context (e.g. console logs)
    if (initialState) {
      win.webContents.send("popout:init-state", initialState);
    }
  });

  // Capture bounds before the window is destroyed
  let closeBounds: Electron.Rectangle | null = null;
  win.on("close", () => {
    closeBounds = win.getBounds();
  });

  win.on("closed", () => {
    const info = popoutWindows.get(winId);
    popoutWindows.delete(winId);
    // Notify main window that the popout was closed so it can re-add the panel
    if (mainWindow && !mainWindow.isDestroyed()) {
      mainWindow.webContents.send("popout:closed", panels, info?.originInfo, closeBounds);
    }
  });

  return winId;
}

ipcMain.handle("window:popout-panel", async (_event, panels: string[], initialState?: unknown, originInfo?: unknown, bounds?: { width?: number; height?: number; x?: number; y?: number }) => {
  const winId = await createPopoutWindow(panels, initialState, originInfo, bounds);
  return winId;
});

ipcMain.handle("window:close-popout", async (event) => {
  const senderWin = BrowserWindow.fromWebContents(event.sender);
  if (senderWin && popoutWindows.has(senderWin.id)) {
    senderWin.close();
  }
});

/** Test whether a remote engine server is reachable and responds to RPC. */
ipcMain.handle("settings:testRemoteConnection", async (_event, url: string) => {
  return new Promise<{ ok: boolean; version?: string; error?: string }>((resolve) => {
    const timeout = setTimeout(() => {
      ws.close();
      resolve({ ok: false, error: "Connection timeout (5s)" });
    }, 5000);

    let ws: WebSocket;
    try {
      ws = new WebSocket(url);
    } catch (err) {
      clearTimeout(timeout);
      resolve({ ok: false, error: String(err) });
      return;
    }

    ws.on("open", () => {
      // Send an RPC ping to verify it's actually a Guava Engine server
      const pingRequest = JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "editor.getCapabilities",
        params: {},
      });
      ws.send(pingRequest);
    });

    ws.on("message", (data: WebSocket.Data) => {
      clearTimeout(timeout);
      try {
        const msg = JSON.parse(data.toString());
        if (msg.result?.version) {
          resolve({ ok: true, version: msg.result.version });
        } else if (msg.error) {
          resolve({ ok: false, error: `RPC error: ${msg.error.message}` });
        } else {
          resolve({ ok: true });
        }
      } catch {
        resolve({ ok: false, error: "Invalid response from server" });
      }
      ws.close();
    });

    ws.on("error", (err: Error) => {
      clearTimeout(timeout);
      resolve({ ok: false, error: err.message });
    });
  });
});

/** Switch the engine connection to a remote server URL, or "local" to reconnect locally. */
ipcMain.handle("settings:connectToServer", async (_event, url: string) => {
  try {
    // Disconnect current client
    engineClient?.disconnect();
    engineClient = null;

    // Stop viewport pixel streaming
    if (surfaceRefreshTimer) {
      clearInterval(surfaceRefreshTimer);
      surfaceRefreshTimer = null;
    }

    if (url === "local") {
      // Reconnect to local engine process
      if (!engineProcess?.running) {
        return { ok: false, error: "Local engine is not running" };
      }
      engineClient = new EngineClient(`ws://127.0.0.1:${DEFAULT_PORT}`, {
        timeout: 10000,
        reconnectInterval: 2000,
        onReconnected: () => {
          broadcastToRenderers("engine:connected");
        },
      });
      await engineClient.connect();
      setupSubscriptionForwarding();
      await engineClient.call("editor.getCapabilities", {});
      broadcastToRenderers("engine:connected");
      return { ok: true };
    }

    // Connect to remote server
    engineClient = new EngineClient(url, {
      timeout: 10000,
      reconnectInterval: 3000,
      onReconnected: () => {
        broadcastToRenderers("engine:connected");
      },
    });
    await engineClient.connect();
    setupSubscriptionForwarding();
    await engineClient.call("editor.getCapabilities", {});
    broadcastToRenderers("engine:connected");
    return { ok: true };
  } catch (err) {
    return { ok: false, error: String(err) };
  }
});

// ── Launcher IPC ─────────────────────────────────────────────────

ipcMain.handle("launcher:getAppMode", () => {
  return launcherMode ? "launcher" : "editor";
});

ipcMain.handle("launcher:getRecentProjects", () => {
  return loadRecentProjects();
});

ipcMain.handle("launcher:removeRecentProject", (_event, projectPath: string) => {
  removeRecentProject(projectPath);
});

ipcMain.handle("launcher:browseFolder", async () => {
  if (!mainWindow) return null;
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ["openDirectory", "createDirectory"],
  });
  if (result.canceled || result.filePaths.length === 0) return null;
  return result.filePaths[0];
});

ipcMain.handle("launcher:openProject", async (_event, projectPath: string) => {
  try {
    const normalized = path.resolve(projectPath);
    if (!isGuavaProject(normalized)) {
      return { ok: false, error: `Not a Guava project: no .guava file found in ${normalized}` };
    }

    const projectName = readProjectName(normalized);
    addRecentProject(normalized, projectName);
    launcherMode = false;
    currentProjectPath = normalized;

    // Transition from launcher to editor: maximize the window
    if (mainWindow) {
      mainWindow.setMinimumSize(800, 600);
      mainWindow.maximize();
    }

    await startEngine();
    monitorEngineProcess();
    broadcastToRenderers("engine:connected");
    return { ok: true };
  } catch (err) {
    return { ok: false, error: String(err) };
  }
});

ipcMain.handle("launcher:getTemplates", () => {
  return PROJECT_TEMPLATES;
});

ipcMain.handle("launcher:createProject", async (_event, projectPath: string, projectName: string, templateId?: string) => {
  try {
    const normalized = path.resolve(projectPath);
    createNewProject(normalized, projectName);
    applyTemplate(normalized, templateId ?? "empty");
    addRecentProject(normalized, projectName);
    launcherMode = false;
    currentProjectPath = normalized;

    // Transition from launcher to editor: maximize the window
    if (mainWindow) {
      mainWindow.setMinimumSize(800, 600);
      mainWindow.maximize();
    }

    await startEngine();
    monitorEngineProcess();
    broadcastToRenderers("engine:connected");
    return { ok: true };
  } catch (err) {
    return { ok: false, error: String(err) };
  }
});

// ── Build / Package ──────────────────────────────────────────────

ipcMain.handle("build:package", async (_event, opts?: { outputDir?: string; optimize?: string; choosePath?: boolean }) => {
  if (!currentProjectPath) return { ok: false, error: "No project open" };

  const projectName = await readProjectName(currentProjectPath) ?? path.basename(currentProjectPath);

  // Default output directory: {project}/Build/
  let outputDir = opts?.outputDir ?? path.join(currentProjectPath, "Build");

  // Only show dialog if user explicitly requests it
  if (opts?.choosePath && mainWindow) {
    const result = await dialog.showOpenDialog(mainWindow, {
      title: "Choose build output folder",
      defaultPath: outputDir,
      buttonLabel: "Build Here",
      properties: ["openDirectory", "createDirectory"],
    });
    if (result.canceled || result.filePaths.length === 0) {
      return { ok: false, error: "Cancelled" };
    }
    outputDir = result.filePaths[0];
  }
  if (!outputDir) return { ok: false, error: "No output directory" };

  try {
    broadcastToRenderers("build:progress", { stage: "compile", percent: 0, detail: "Starting build..." });

    const outPath = await buildProject(
      {
        projectPath: currentProjectPath,
        outputDir,
        gameName: projectName,
        optimize: (opts?.optimize as "Debug" | "ReleaseSafe" | "ReleaseFast") ?? "ReleaseSafe",
      },
      (p: BuildProgress) => {
        broadcastToRenderers("build:progress", p);
      },
    );

    return { ok: true, path: outPath };
  } catch (err) {
    return { ok: false, error: String(err) };
  }
});

ipcMain.handle("build:run", async (_event, appPath: string) => {
  try {
    const { spawn: spawnProc } = await import("child_process");
    if (process.platform === "darwin" && appPath.endsWith(".app")) {
      spawnProc("open", [appPath], { detached: true, stdio: "ignore" });
    } else {
      const exe = process.platform === "win32"
        ? path.join(appPath, "guava-player.exe")
        : path.join(appPath, "bin", "guava-player");
      spawnProc(exe, [], { cwd: appPath, detached: true, stdio: "ignore" });
    }
    return { ok: true };
  } catch (err) {
    return { ok: false, error: String(err) };
  }
});

// ── File System Operations (scoped to project) ──────────────────

/** Resolve a relative path within the current project directory. Rejects paths that escape the project root. */
function resolveProjectPath(relativePath: string): string {
  if (!currentProjectPath) throw new Error("No project open");
  const resolved = path.resolve(currentProjectPath, relativePath);
  if (!resolved.startsWith(currentProjectPath + path.sep) && resolved !== currentProjectPath) {
    throw new Error("Path escapes project directory");
  }
  return resolved;
}

ipcMain.handle("fs:mkdir", async (_event, relativePath: string) => {
  try {
    const abs = resolveProjectPath(relativePath);
    await fs.mkdir(abs, { recursive: true });
    return { ok: true };
  } catch (err) {
    return { ok: false, error: String(err) };
  }
});

ipcMain.handle("fs:rename", async (_event, oldRelPath: string, newRelPath: string) => {
  try {
    const oldAbs = resolveProjectPath(oldRelPath);
    const newAbs = resolveProjectPath(newRelPath);
    await fs.rename(oldAbs, newAbs);
    return { ok: true };
  } catch (err) {
    return { ok: false, error: String(err) };
  }
});

ipcMain.handle("fs:delete", async (_event, relativePath: string) => {
  try {
    const abs = resolveProjectPath(relativePath);
    await fs.rm(abs, { recursive: true });
    return { ok: true };
  } catch (err) {
    return { ok: false, error: String(err) };
  }
});

ipcMain.handle("fs:createFile", async (_event, relativePath: string, content: string) => {
  try {
    const abs = resolveProjectPath(relativePath);
    await fs.mkdir(path.dirname(abs), { recursive: true });
    await fs.writeFile(abs, content, "utf-8");
    return { ok: true };
  } catch (err) {
    return { ok: false, error: String(err) };
  }
});

ipcMain.handle("fs:importFiles", async (_event, targetRelDir: string) => {
  if (!mainWindow) return { ok: false, error: "No window", files: [] };
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ["openFile", "openDirectory", "multiSelections"],
    title: "Import Assets",
  });
  if (result.canceled || result.filePaths.length === 0) {
    return { ok: true, files: [], canceled: true };
  }
  const targetDir = resolveProjectPath(targetRelDir);
  await fs.mkdir(targetDir, { recursive: true });
  const imported: string[] = [];
  for (const src of result.filePaths) {
    const dest = path.join(targetDir, path.basename(src));
    try {
      const stat = await fs.stat(src);
      if (stat.isDirectory()) {
        await fs.cp(src, dest, { recursive: true });
      } else {
        await fs.copyFile(src, dest);
      }
      imported.push(path.join(targetRelDir, path.basename(src)));
    } catch (err) {
      console.error(`Failed to import ${src}:`, err);
    }
  }
  return { ok: true, files: imported };
});

// Import files given their absolute OS paths (for drag-drop from Finder/Explorer)
ipcMain.handle("fs:importPaths", async (_event, targetRelDir: string, sourcePaths: string[]) => {
  if (!Array.isArray(sourcePaths) || sourcePaths.length === 0) {
    return { ok: true, files: [] };
  }
  const targetDir = resolveProjectPath(targetRelDir);
  await fs.mkdir(targetDir, { recursive: true });
  const imported: string[] = [];
  for (const src of sourcePaths) {
    const dest = path.join(targetDir, path.basename(src));
    try {
      const stat = await fs.stat(src);
      if (stat.isDirectory()) {
        await fs.cp(src, dest, { recursive: true });
      } else {
        await fs.copyFile(src, dest);
      }
      imported.push(path.join(targetRelDir, path.basename(src)));
    } catch (err) {
      console.error(`Failed to import ${src}:`, err);
    }
  }
  return { ok: true, files: imported };
});

// ── App Lifecycle ────────────────────────────────────────────────

app.whenReady().then(async () => {
  // Set Content-Security-Policy to suppress Electron security warning.
  // In dev mode Vite injects inline scripts for HMR, so we must allow 'unsafe-inline'.
  const isDev = !!(process.env.VITE_DEV_SERVER_URL);
  const scriptSrc = isDev
    ? "script-src 'self' 'unsafe-inline' http://localhost:*"
    : "script-src 'self'";
  session.defaultSession.webRequest.onHeadersReceived((details, callback) => {
    callback({
      responseHeaders: {
        ...details.responseHeaders,
        "Content-Security-Policy": [
          `default-src 'self'; ${scriptSrc}; style-src 'self' 'unsafe-inline'; connect-src 'self' ws://127.0.0.1:* http://localhost:*; img-src 'self' data:`,
        ],
        // Required for SharedArrayBuffer to be transferable via postMessage.
        "Cross-Origin-Opener-Policy": ["same-origin"],
        "Cross-Origin-Embedder-Policy": ["require-corp"],
      },
    });
  });

  // Determine whether to show the launcher or go straight to the editor.
  const cliProjectPath = getProjectPath();
  if (cliProjectPath) {
    currentProjectPath = cliProjectPath;
    launcherMode = false;
    // Also record in recent projects
    const name = readProjectName(cliProjectPath);
    addRecentProject(cliProjectPath, name);
  } else {
    launcherMode = true;
  }

  mainWindow = await createMainWindow();

  // When the renderer reloads (Vite HMR full-reload or manual refresh),
  // clean up stale viewport state and re-send engine connection status.
  mainWindow.webContents.on("did-finish-load", () => {
    // Stop the pixel streaming timer — the new page will re-attach if needed.
    if (surfaceRefreshTimer) {
      clearInterval(surfaceRefreshTimer);
      surfaceRefreshTimer = null;
    }
    ioSurfaceView?.detach();

    // Re-notify the new renderer page of the current engine state.
    if (engineClient?.connected) {
      mainWindow?.webContents.send("engine:connected");
    }
  });

  if (!launcherMode) {
    // Direct-to-editor: start engine immediately (existing flow)
    try {
      await startEngine();
      monitorEngineProcess();
      mainWindow.webContents.send("engine:connected");
    } catch (err) {
      console.error("[Main] Failed to start engine:", err);
      mainWindow.webContents.send("engine:error", String(err));
    }
  }
  // In launcher mode, the renderer will show the Launcher UI.
  // Engine will be started when the user picks a project via launcher:openProject.

  mainWindow.on("close", () => {
    // Close all popout windows when main window closes
    for (const [, { win }] of popoutWindows) {
      if (!win.isDestroyed()) win.close();
    }
    popoutWindows.clear();
    // Stop the IOSurface refresh timer before the window handle becomes invalid
    if (surfaceRefreshTimer) {
      clearInterval(surfaceRefreshTimer);
      surfaceRefreshTimer = null;
    }
    ioSurfaceView?.detach();
  });

  mainWindow.on("closed", () => {
    mainWindow = null;
  });
});

app.on("window-all-closed", () => {
  // Let before-quit handle engine cleanup; just trigger the quit.
  app.quit();
});

app.on("before-quit", (event) => {
  if (isQuitting) return; // Second call from our own app.quit() below — let it through
  isQuitting = true;
  // Pause quit until the engine subprocess is fully stopped.
  event.preventDefault();
  engineClient?.disconnect();
  engineProcess
    ?.stop()
    .finally(() => {
      app.quit(); // Resume quit now that engine is gone
    });
});
