/**
 * WebSocket JSON-RPC client for the Guava Engine.
 *
 * Manages connection lifecycle, RPC calls with timeout,
 * and engine notification event dispatching.
 */

const LOCAL_ENGINE_URL = 'ws://127.0.0.1:9100';
const RPC_TIMEOUT_MS = 10_000;
const RECONNECT_DELAY_MS = 1_500;

type Listener<T extends unknown[] = unknown[]> = (...args: T) => void;

class Emitter {
  private listeners = new Map<string, Set<Listener>>();

  on(event: string, cb: Listener): () => void {
    if (!this.listeners.has(event)) this.listeners.set(event, new Set());
    this.listeners.get(event)!.add(cb);
    return () => {
      const bucket = this.listeners.get(event);
      if (!bucket) return;
      bucket.delete(cb);
      if (bucket.size === 0) this.listeners.delete(event);
    };
  }

  emit(event: string, ...args: unknown[]) {
    const bucket = this.listeners.get(event);
    if (!bucket) return;
    for (const cb of bucket) {
      try { cb(...args); } catch (e) { console.error('[engine]', event, e); }
    }
  }
}

interface PendingCall {
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

class EngineClient {
  private targetUrl = LOCAL_ENGINE_URL;
  private socket: WebSocket | null = null;
  private nextId = 1;
  private pending = new Map<number, PendingCall>();
  private events = new Emitter();
  private manualClose = false;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private _connected = false;

  get connected(): boolean {
    return this._connected && this.socket?.readyState === WebSocket.OPEN;
  }

  // ── Lifecycle events ──

  onConnected(cb: () => void) { return this.events.on('connected', cb); }
  onDisconnected(cb: (info: { code: number | null; restarting: boolean }) => void) {
    return this.events.on('disconnected', cb as Listener);
  }
  onError(cb: (error: string) => void) { return this.events.on('error', cb as Listener); }
  onNotification(cb: (event: string, data?: unknown) => void) {
    return this.events.on('notification', cb as Listener);
  }

  // ── Connection ──

  async connect(url?: string): Promise<void> {
    if (url) this.targetUrl = url;
    if (this.connected && this.targetUrl === url) return;
    this.manualClose = false;
    if (this.socket?.readyState === WebSocket.CONNECTING) return;
    if (this.socket?.readyState === WebSocket.OPEN) this.socket.close();

    return new Promise((resolve, reject) => {
      let settled = false;
      const socket = new WebSocket(this.targetUrl);
      this.socket = socket;

      socket.addEventListener('open', () => {
        this._connected = true;
        settled = true;
        this.clearReconnect();
        this.events.emit('connected');
        resolve();
      });

      socket.addEventListener('message', (e) => this.handleMessage(e.data as string));

      socket.addEventListener('error', () => {
        this.events.emit('error', 'Failed to connect to engine');
        if (!settled) { settled = true; reject(new Error('Failed to connect to engine')); }
      });

      socket.addEventListener('close', (e) => {
        const wasConnected = this._connected;
        this._connected = false;
        this.rejectPending(new Error('Engine disconnected'));
        if (wasConnected || !this.manualClose) {
          this.events.emit('disconnected', { code: e.code ?? null, restarting: !this.manualClose });
        }
        if (!this.manualClose) this.scheduleReconnect();
        if (!settled) { settled = true; reject(new Error('Connection closed before ready')); }
      });
    });
  }

  disconnect() {
    this.manualClose = true;
    this.clearReconnect();
    this.rejectPending(new Error('Engine connection reset'));
    if (this.socket) { this.socket.close(); this.socket = null; }
    this._connected = false;
  }

  // ── RPC ──

  async call(method: string, params?: Record<string, unknown>): Promise<unknown> {
    if (!this.connected) throw new Error('Engine not connected');
    const id = this.nextId++;
    this.socket!.send(JSON.stringify({ jsonrpc: '2.0', id, method, params: params ?? {} }));

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`RPC timeout: ${method}`));
      }, RPC_TIMEOUT_MS);
      this.pending.set(id, { resolve, reject, timer });
    });
  }

  async test(url: string): Promise<{ ok: boolean; version?: string; error?: string }> {
    return new Promise((resolve) => {
      let settled = false;
      const socket = new WebSocket(url);
      const done = (v: { ok: boolean; version?: string; error?: string }) => {
        if (settled) return;
        settled = true;
        try { socket.close(); } catch {}
        resolve(v);
      };
      const timeout = setTimeout(() => done({ ok: false, error: 'Connection timeout (5s)' }), 5000);
      socket.addEventListener('open', () => {
        socket.send(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'editor.getCapabilities', params: {} }));
      });
      socket.addEventListener('message', (e) => {
        clearTimeout(timeout);
        try {
          const msg = JSON.parse(e.data as string);
          if (msg.error) { done({ ok: false, error: msg.error.message ?? 'RPC error' }); return; }
          done({ ok: true, version: msg.result?.version });
        } catch (err) { done({ ok: false, error: String(err) }); }
      });
      socket.addEventListener('error', () => { clearTimeout(timeout); done({ ok: false, error: 'Failed to connect' }); });
    });
  }

  getStatus(): { engineRunning: boolean; rpcConnected: boolean } {
    return { engineRunning: true, rpcConnected: this.connected };
  }

  // ── Internal ──

  private handleMessage(raw: string) {
    let msg: { id?: number; method?: string; params?: unknown; result?: unknown; error?: { message?: string } };
    try { msg = JSON.parse(raw); } catch { return; }

    if (typeof msg.id === 'number') {
      const p = this.pending.get(msg.id);
      if (!p) return;
      clearTimeout(p.timer);
      this.pending.delete(msg.id);
      if (msg.error) p.reject(new Error(msg.error.message ?? 'RPC error'));
      else p.resolve(msg.result);
      return;
    }
    if (typeof msg.method === 'string') {
      this.events.emit('notification', msg.method, msg.params);
    }
  }

  private rejectPending(error: Error) {
    for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(error); }
    this.pending.clear();
  }

  private scheduleReconnect() {
    if (this.reconnectTimer) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect().catch(() => this.scheduleReconnect());
    }, RECONNECT_DELAY_MS);
  }

  private clearReconnect() {
    if (!this.reconnectTimer) return;
    clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
  }
}

/** Singleton engine client instance. */
export const engine = new EngineClient();
