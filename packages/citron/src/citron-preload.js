// citron-preload.js — Compatibility bridge: maps window.citron → window.guavaEngine.
//
// This script is injected by Citron's CEF shell after window.citron is available.
// It creates window.guavaEngine with the same API surface as the Electron preload,
// so the React frontend works unmodified.
//
// Communication model:
//   JS → Native:  window.citron.postMessage(jsonString)
//   Native → JS:  window.citron._handleNative(jsonString) — overridden here
//
// Messages from JS carry: { jsonrpc: "2.0", id, method, params }
// Responses from native:  { jsonrpc: "2.0", id, result } or { id, error }
// Push events from native: { type: "engine.event", event, data }
//                          { type: "engine.connected" }
//                          { type: "engine.error", error }
//                          { type: "engine.disconnected", info }
//                          { type: "rpc.response", id, result?, error? }

(function () {
  "use strict";

  if (window.guavaEngine) return; // Already initialized (e.g. Electron)

  const citron = window.citron;
  if (!citron) {
    console.error("[citron-preload] window.citron not found — bridge not injected?");
    return;
  }

  // ── Make page background transparent for Metal composition ───────────
  // In Citron, the Metal shader alpha-blends CEF output over the 3D scene.
  // Wherever the CEF pixel has alpha=0 the scene shows through.
  //
  // Strategy:
  //  1. html/body/#root → transparent (CEF background_color is already 0)
  //  2. All FlexLayout structural containers in the ancestor chain of the
  //     viewport → transparent (layout, tabset-selected, tab)
  //  3. Every panel root (.flexlayout__tab >) gets an explicit #1e1e2e
  //     background so non-viewport panels remain opaque.
  //  4. The Viewport component sets inline background:transparent when
  //     native overlay is active, which overrides rule 3 (inline > CSS).
  const injectTransparentCSS = () => {
    const style = document.createElement("style");
    style.textContent = [
      "html, body, #root { background: transparent !important; }",
      ".flexlayout__layout,",
      ".flexlayout__tabset-selected,",
      ".flexlayout__tab {",
      "  background: transparent !important;",
      "}",
      "/* Give every panel content root an opaque background. */",
      "/* Viewport overrides this via inline style when nativeOverlay is active. */",
      ".flexlayout__tab > * { background-color: #1e1e2e; }",
    ].join("\n");
    document.head.appendChild(style);
  };
  if (document.head) {
    injectTransparentCSS();
  } else {
    document.addEventListener("DOMContentLoaded", injectTransparentCSS, { once: true });
  }

  // ── Pending RPC calls ────────────────────────────────────────────────
  let nextId = 1;
  const pending = new Map(); // id → { resolve, reject, timer }

  function rpcCall(method, params) {
    return new Promise((resolve, reject) => {
      const id = nextId++;
      const msg = JSON.stringify({
        jsonrpc: "2.0",
        id,
        method,
        params: params !== undefined ? params : {},
      });
      const timer = setTimeout(() => {
        if (pending.has(id)) {
          pending.delete(id);
          reject(new Error(`RPC timeout: ${method} (id=${id})`));
        }
      }, 30000);
      pending.set(id, { resolve, reject, timer });
      citron.postMessage(msg);
    });
  }

  // ── Event listeners ──────────────────────────────────────────────────
  const eventListeners = new Map(); // type → Set<callback>

  function addListener(type, callback) {
    if (!eventListeners.has(type)) eventListeners.set(type, new Set());
    eventListeners.get(type).add(callback);
    return () => {
      const set = eventListeners.get(type);
      if (set) {
        set.delete(callback);
        if (set.size === 0) eventListeners.delete(type);
      }
    };
  }

  function emit(type, ...args) {
    const set = eventListeners.get(type);
    if (set) {
      for (const cb of set) {
        try {
          cb(...args);
        } catch (e) {
          console.error(`[citron-preload] listener error (${type}):`, e);
        }
      }
    }
  }

  // ── Connection state ─────────────────────────────────────────────────
  let engineConnected = false;

  // ── Native → JS message handler ──────────────────────────────────────
  citron._handleNative = function (raw) {
    let msg;
    try {
      msg = typeof raw === "string" ? JSON.parse(raw) : raw;
    } catch (e) {
      console.warn("[citron-preload] invalid message from native:", raw);
      return;
    }

    // JSON-RPC response (has "id" field) — from engine via native relay
    if (msg.id !== undefined && (msg.result !== undefined || msg.error !== undefined)) {
      const entry = pending.get(msg.id);
      if (entry) {
        pending.delete(msg.id);
        clearTimeout(entry.timer);
        if (msg.error) {
          entry.reject(
            new Error(
              typeof msg.error === "object"
                ? msg.error.message || JSON.stringify(msg.error)
                : String(msg.error)
            )
          );
        } else {
          entry.resolve(msg.result);
        }
      }
      return;
    }

    // Typed push messages from native
    switch (msg.type) {
      case "engine.connected":
        engineConnected = true;
        emit("connected");
        break;
      case "engine.disconnected":
        engineConnected = false;
        emit("disconnected", msg.info || { code: null, restarting: false });
        break;
      case "engine.error":
        emit("error", msg.error || "unknown");
        break;
      case "engine.event":
        emit("event", msg.event, msg.data);
        break;
      case "engine.status":
        // Response to getStatus — handled via pending
        break;
      default:
        console.log("[citron-preload] unhandled native message:", msg.type, msg);
    }
  };

  // ── Build window.guavaEngine ─────────────────────────────────────────

  window.guavaEngine = {
    platform: citron.platform || "darwin",

    // ── Launcher ─────────────────────────────────────────────────────
    // Citron skips the launcher — always in editor mode.
    getAppMode: () => Promise.resolve("editor"),
    getRecentProjects: () => Promise.resolve([]),
    removeRecentProject: () => Promise.resolve(),
    browseFolder: () => Promise.resolve(null),
    getTemplates: () => Promise.resolve([]),
    openProject: () => Promise.resolve({ ok: true }),
    createProject: () => Promise.resolve({ ok: true }),

    // ── Engine RPC ───────────────────────────────────────────────────
    call: (method, params) => rpcCall(method, params),

    getStatus: () =>
      Promise.resolve({
        engineRunning: engineConnected,
        rpcConnected: engineConnected,
      }),

    onEvent: (callback) => addListener("event", callback),
    onConnected: (callback) => addListener("connected", callback),
    onError: (callback) => addListener("error", callback),
    onDisconnected: (callback) => addListener("disconnected", callback),

    // ── Viewport ─────────────────────────────────────────────────────
    // In Citron, the 3D scene is composited natively via Metal.
    // These Electron-specific pixel transport methods become lightweight.

    viewportAttachSurface: (surfaceId, x, y, w, h, _shmName) => {
      // Citron handles IOSurface attachment natively — just update viewport rect.
      citron.postMessage(
        JSON.stringify({
          jsonrpc: "2.0",
          method: "viewport.attachSurface",
          params: { surfaceId, x, y, w, h },
        })
      );
      return Promise.resolve(true);
    },

    viewportUpdateSurface: (surfaceId, _shmName, width, height) => {
      citron.postMessage(
        JSON.stringify({
          jsonrpc: "2.0",
          method: "viewport.updateSurface",
          params: { surfaceId, width, height },
        })
      );
      return Promise.resolve();
    },

    viewportDetach: () => {
      citron.postMessage(
        JSON.stringify({
          jsonrpc: "2.0",
          method: "viewport.detach",
          params: {},
        })
      );
      return Promise.resolve();
    },

    viewportUpdateBounds: (x, y, w, h) => {
      // Update the Citron shell viewport rect for Metal composition.
      citron.postMessage(
        JSON.stringify({
          jsonrpc: "2.0",
          method: "viewport.updateBounds",
          params: { x, y, w, h },
        })
      );
    },

    viewportUpdateExclusions: (_rects) => {
      // Not needed in Citron — no overlay mask to manipulate.
    },

    onViewportOverlayActive: (_callback) => {
      // Citron always uses native composition — overlay is always "active".
      // Fire immediately so the React component knows.
      setTimeout(() => _callback(true), 0);
      return () => {};
    },

    onViewportPixels: (_callback) => {
      // No pixel streaming in Citron — Metal handles it natively.
      return () => {};
    },

    onViewportSharedBuffer: (_callback) => {
      // No SharedArrayBuffer fallback needed.
      return () => {};
    },

    // ── Remote connection ────────────────────────────────────────────
    testRemoteConnection: (url) => rpcCall("settings.testRemoteConnection", { url }),
    connectToServer: (url) => rpcCall("settings.connectToServer", { url }),

    // ── Multi-window popout ──────────────────────────────────────────
    // Stub for now — single window in Citron.
    popoutPanel: () => Promise.resolve(0),
    closePopout: () => Promise.resolve(),
    isPopoutWindow: () => false,
    getPopoutPanels: () => [],
    onPopoutClosed: () => () => {},
    onInitState: () => () => {},

    // ── Build / Package ──────────────────────────────────────────────
    // These require native file system access — forward via citron.invoke.
    buildPackage: (opts) => rpcCall("build.package", opts || {}),
    cancelBuild: () => rpcCall("build.cancel", {}),
    runBuiltGame: (appPath) => rpcCall("build.run", { appPath }),
    onBuildProgress: (callback) => addListener("build.progress", callback),

    // ── File System (project-scoped) ─────────────────────────────────
    fsMkdir: (relativePath) => rpcCall("fs.mkdir", { path: relativePath }),
    fsRename: (oldPath, newPath) => rpcCall("fs.rename", { oldPath, newPath }),
    fsDelete: (relativePath) => rpcCall("fs.delete", { path: relativePath }),
    fsCreateFile: (relativePath, content) =>
      rpcCall("fs.createFile", { path: relativePath, content }),
    fsImportFiles: (targetRelDir) =>
      rpcCall("fs.importFiles", { targetDir: targetRelDir }),
    fsImportPaths: (targetRelDir, sourcePaths) =>
      rpcCall("fs.importPaths", { targetDir: targetRelDir, sourcePaths }),
    onImportProgress: (callback) => addListener("fs.importProgress", callback),
  };

  console.log("[citron-preload] window.guavaEngine bridge ready (Citron native)");
})();
