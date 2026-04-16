;(function () {
  'use strict';

  const citron = window.citron;
  if (!citron) {
    console.error('[guava-bridge] window.citron not available');
    return;
  }

  const LOCAL_ENGINE_URL = 'ws://127.0.0.1:9100';

  function createEmitter() {
    const listeners = new Map();
    return {
      on(event, callback) {
        if (!listeners.has(event)) listeners.set(event, new Set());
        listeners.get(event).add(callback);
        return () => {
          const bucket = listeners.get(event);
          if (!bucket) return;
          bucket.delete(callback);
          if (bucket.size === 0) listeners.delete(event);
        };
      },
      emit(event, ...args) {
        const bucket = listeners.get(event);
        if (!bucket) return;
        for (const callback of bucket) {
          try {
            callback(...args);
          } catch (error) {
            console.error('[guava-bridge] listener error for', event, error);
          }
        }
      },
    };
  }

  class EngineRpcBridge {
    constructor() {
      this._targetUrl = LOCAL_ENGINE_URL;
      this._socket = null;
      this._nextId = 1;
      this._pending = new Map();
      this._events = createEmitter();
      this._manualClose = false;
      this._reconnectTimer = null;
      this._connected = false;
    }

    isConnected() {
      return this._connected && this._socket && this._socket.readyState === WebSocket.OPEN;
    }

    onConnected(callback) {
      return this._events.on('connected', callback);
    }

    onDisconnected(callback) {
      return this._events.on('disconnected', callback);
    }

    onError(callback) {
      return this._events.on('error', callback);
    }

    onNotification(callback) {
      return this._events.on('notification', callback);
    }

    async connect(url) {
      if (url) this._targetUrl = url;
      if (this.isConnected() && this._targetUrl === url) return;
      this._manualClose = false;
      if (this._socket && this._socket.readyState === WebSocket.CONNECTING) return;
      if (this._socket && this._socket.readyState === WebSocket.OPEN) this._socket.close();

      return new Promise((resolve, reject) => {
        let settled = false;
        const socket = new WebSocket(this._targetUrl);
        this._socket = socket;

        socket.addEventListener('open', () => {
          this._connected = true;
          settled = true;
          this._clearReconnect();
          this._events.emit('connected');
          resolve();
        });

        socket.addEventListener('message', (event) => {
          this._handleMessage(event.data);
        });

        socket.addEventListener('error', () => {
          const error = new Error('Failed to connect to engine');
          this._events.emit('error', error.message);
          if (!settled) {
            settled = true;
            reject(error);
          }
        });

        socket.addEventListener('close', (event) => {
          const wasConnected = this._connected;
          this._connected = false;
          this._rejectPending(new Error('Engine disconnected'));
          if (wasConnected || !this._manualClose) {
            this._events.emit('disconnected', { code: event.code || null, restarting: !this._manualClose });
          }
          if (!this._manualClose) {
            this._scheduleReconnect();
          }
          if (!settled) {
            settled = true;
            reject(new Error('Connection closed before ready'));
          }
        });
      });
    }

    disconnect() {
      this._manualClose = true;
      this._clearReconnect();
      this._rejectPending(new Error('Engine connection reset'));
      if (this._socket) {
        this._socket.close();
        this._socket = null;
      }
      this._connected = false;
    }

    async call(method, params) {
      if (!this.isConnected()) {
        throw new Error('Engine not connected');
      }

      const id = this._nextId++;
      const payload = JSON.stringify({
        jsonrpc: '2.0',
        id,
        method,
        params: params || {},
      });

      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          this._pending.delete(id);
          reject(new Error('RPC timeout: ' + method));
        }, 10000);

        this._pending.set(id, { resolve, reject, timer });
        this._socket.send(payload);
      });
    }

    async test(url) {
      return new Promise((resolve) => {
        let settled = false;
        const socket = new WebSocket(url);
        const done = (value) => {
          if (settled) return;
          settled = true;
          try { socket.close(); } catch (_) {}
          resolve(value);
        };

        const timeout = setTimeout(() => done({ ok: false, error: 'Connection timeout (5s)' }), 5000);

        socket.addEventListener('open', () => {
          socket.send(JSON.stringify({
            jsonrpc: '2.0',
            id: 1,
            method: 'editor.getCapabilities',
            params: {},
          }));
        });

        socket.addEventListener('message', (event) => {
          clearTimeout(timeout);
          try {
            const msg = JSON.parse(event.data);
            if (msg.error) {
              done({ ok: false, error: msg.error.message || 'RPC error' });
              return;
            }
            done({ ok: true, version: msg.result && msg.result.version });
          } catch (error) {
            done({ ok: false, error: String(error) });
          }
        });

        socket.addEventListener('error', () => {
          clearTimeout(timeout);
          done({ ok: false, error: 'Failed to connect to server' });
        });
      });
    }

    _handleMessage(raw) {
      let message;
      try {
        message = JSON.parse(raw);
      } catch (_error) {
        return;
      }

      if (message && typeof message.id === 'number') {
        const pending = this._pending.get(message.id);
        if (!pending) return;
        clearTimeout(pending.timer);
        this._pending.delete(message.id);
        if (message.error) {
          pending.reject(new Error(message.error.message || 'RPC error'));
        } else {
          pending.resolve(message.result);
        }
        return;
      }

      if (message && typeof message.method === 'string') {
        this._events.emit('notification', message.method, message.params);
      }
    }

    _rejectPending(error) {
      for (const pending of this._pending.values()) {
        clearTimeout(pending.timer);
        pending.reject(error);
      }
      this._pending.clear();
    }

    _scheduleReconnect() {
      if (this._reconnectTimer) return;
      this._reconnectTimer = setTimeout(() => {
        this._reconnectTimer = null;
        this.connect(this._targetUrl).catch(() => {
          this._scheduleReconnect();
        });
      }, 1500);
    }

    _clearReconnect() {
      if (!this._reconnectTimer) return;
      clearTimeout(this._reconnectTimer);
      this._reconnectTimer = null;
    }
  }

  const engine = new EngineRpcBridge();

  function currentPlatform() {
    const platform = (navigator.platform || '').toLowerCase();
    if (platform.includes('mac')) return 'darwin';
    if (platform.includes('win')) return 'win32';
    return 'linux';
  }

  async function browseFolder() {
    try {
      const result = await citron.invoke('dialog.open', {
        directory: true,
        multiple: false,
        title: 'Select Folder',
      });
      const paths = result && Array.isArray(result.paths) ? result.paths : [];
      return paths[0] || null;
    } catch (error) {
      if (error && error.name === 'DialogCancelled') return null;
      throw error;
    }
  }

  async function importPaths(targetRelDir, sourcePaths) {
    return citron.invoke('fs.importPaths', {
      targetDir: targetRelDir,
      sourcePaths: sourcePaths || [],
    });
  }

  async function ensureModeConnection() {
    const mode = await citron.invoke('launcher.getAppMode');
    if (mode === 'editor' && !engine.isConnected()) {
      engine.connect(LOCAL_ENGINE_URL).catch(() => {});
    }
    return mode;
  }

  window.guavaEngine = {
    platform: currentPlatform(),

    async getAppMode() {
      return ensureModeConnection();
    },

    getRecentProjects() {
      return citron.invoke('launcher.getRecentProjects');
    },

    removeRecentProject(projectPath) {
      return citron.invoke('launcher.removeRecentProject', { projectPath });
    },

    browseFolder,

    getTemplates() {
      return citron.invoke('launcher.getTemplates');
    },

    async openProject(projectPath) {
      const result = await citron.invoke('launcher.openProject', { projectPath });
      if (result && result.ok) {
        engine.connect(LOCAL_ENGINE_URL).catch(() => {});
      }
      return result;
    },

    async createProject(projectPath, projectName, templateId) {
      const result = await citron.invoke('launcher.createProject', {
        projectPath,
        projectName,
        templateId,
      });
      if (result && result.ok) {
        engine.connect(LOCAL_ENGINE_URL).catch(() => {});
      }
      return result;
    },

    call(method, params) {
      return engine.call(method, params || {});
    },

    async getStatus() {
      const mode = await citron.invoke('launcher.getAppMode');
      return {
        engineRunning: mode === 'editor',
        rpcConnected: engine.isConnected(),
      };
    },

    onEvent(callback) {
      return engine.onNotification((event, data) => callback(event, data));
    },

    onConnected(callback) {
      return engine.onConnected(callback);
    },

    onError(callback) {
      return engine.onError((error) => callback(String(error)));
    },

    onDisconnected(callback) {
      return engine.onDisconnected(callback);
    },

    viewportAttachSurface(surfaceId, x, y, w, h, shmName) {
      return citron.invoke('viewport.attachSurface', { surfaceId, x, y, w, h, shmName });
    },

    viewportUpdateSurface(surfaceId, shmName, width, height) {
      return citron.invoke('viewport.updateSurface', { surfaceId, shmName, width, height });
    },

    viewportDetach() {
      return citron.invoke('viewport.detach');
    },

    viewportUpdateBounds(x, y, w, h) {
      citron.invoke('viewport.updateBounds', { x, y, w, h }).catch(() => {});
    },

    viewportUpdateExclusions(rects) {
      citron.invoke('viewport.updateExclusions', { rects }).catch(() => {});
    },

    onViewportOverlayActive(callback) {
      return citron.on('viewport.overlayActive', callback);
    },

    onViewportPixels(callback) {
      return citron.on('viewport.pixels', (data) => callback(data.pixels, data.width, data.height));
    },

    onViewportSharedBuffer(callback) {
      return citron.on('viewport.sharedBuffer', callback);
    },

    testRemoteConnection(url) {
      return engine.test(url);
    },

    async connectToServer(url) {
      if (url === 'local') {
        try {
          await engine.connect(LOCAL_ENGINE_URL);
          return { ok: true };
        } catch (error) {
          return { ok: false, error: String(error) };
        }
      }

      const tested = await engine.test(url);
      if (!tested.ok) return tested;
      try {
        await engine.connect(url);
        return { ok: true };
      } catch (error) {
        return { ok: false, error: String(error) };
      }
    },

    async popoutPanel(panelId, options = {}) {
      try {
        const url = `${window.location.origin}${window.location.pathname}?popout=${encodeURIComponent(panelId)}`;
        const result = await window.__citron__.invoke("window.create", {
          url,
          title: options.title || `Guava — ${panelId}`,
          width: options.width || 800,
          height: options.height || 600,
        });
        return result ? 1 : -1;
      } catch {
        return -1;
      }
    },

    closePopout() {
      // Close current window if it's a popout
      if (new URLSearchParams(window.location.search).has("popout")) {
        window.__citron__.invoke("window.close");
      }
      return Promise.resolve();
    },

    isPopoutWindow() {
      return new URLSearchParams(window.location.search).has("popout");
    },

    getPopoutPanels() {
      return [];
    },

    onPopoutClosed() {
      return () => {};
    },

    onInitState() {
      return () => {};
    },

    async buildPackage(opts) {
      const options = { ...(opts || {}) };
      if (options.choosePath) {
        const folder = await browseFolder();
        if (!folder) return { ok: false, error: 'Cancelled' };
        options.outputDir = folder;
        delete options.choosePath;
      }
      return citron.invoke('build.package', options);
    },

    cancelBuild() {
      return citron.invoke('build.cancel');
    },

    runBuiltGame(appPath) {
      return citron.invoke('build.run', { appPath });
    },

    onBuildProgress(callback) {
      return citron.on('build.progress', callback);
    },

    fsMkdir(relativePath) {
      return citron.invoke('fs.mkdir', { path: relativePath });
    },

    fsRename(oldPath, newPath) {
      return citron.invoke('fs.rename', { oldPath, newPath });
    },

    fsDelete(relativePath) {
      return citron.invoke('fs.delete', { path: relativePath });
    },

    fsCreateFile(relativePath, content) {
      return citron.invoke('fs.createFile', { path: relativePath, content });
    },

    async fsImportFiles(targetRelDir) {
      try {
        const result = await citron.invoke('dialog.open', {
          multiple: true,
          directory: false,
          title: 'Import Assets',
        });
        const paths = result && Array.isArray(result.paths) ? result.paths : [];
        if (paths.length === 0) {
          return { ok: true, files: [], canceled: true };
        }
        return importPaths(targetRelDir, paths);
      } catch (error) {
        if (error && error.name === 'DialogCancelled') {
          return { ok: true, files: [], canceled: true };
        }
        throw error;
      }
    },

    fsImportPaths(targetRelDir, sourcePaths) {
      return importPaths(targetRelDir, sourcePaths);
    },

    onImportProgress(callback) {
      return citron.on('fs.importProgress', callback);
    },
  };

  ensureModeConnection().catch(() => {});
})();
