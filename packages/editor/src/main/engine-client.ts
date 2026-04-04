import WebSocket from "ws";
import {
  JsonRpcRequest,
  JsonRpcResponse,
  JsonRpcNotification,
  RpcMethods,
  SubscriptionEvents,
} from "../shared/rpc-types";

type SubscriptionHandler<K extends keyof SubscriptionEvents> = (
  data: SubscriptionEvents[K],
) => void;

/**
 * Type-safe WebSocket JSON-RPC 2.0 client for communicating with the engine.
 */
export class EngineClient {
  private ws: WebSocket | null = null;
  private nextId = 1;
  private pending = new Map<
    number,
    {
      resolve: (value: unknown) => void;
      reject: (error: Error) => void;
      timer: ReturnType<typeof setTimeout>;
    }
  >();
  private subscriptions = new Map<string, Set<(data: unknown) => void>>();
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private _connected = false;

  constructor(
    private url: string,
    private options: { timeout?: number; reconnectInterval?: number; onReconnected?: () => void } = {},
  ) {}

  get connected(): boolean {
    return this._connected;
  }

  /**
   * Establish WebSocket connection to the engine RPC server.
   */
  async connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(this.url);

      this.ws.on("open", () => {
        this._connected = true;
        this.clearReconnectTimer();
        resolve();
      });

      this.ws.on("message", (data: WebSocket.Data) => {
        this.handleMessage(data);
      });

      this.ws.on("close", () => {
        this._connected = false;
        this.rejectAllPending(new Error("Connection closed"));
        this.scheduleReconnect();
      });

      this.ws.on("error", (err: Error) => {
        if (!this._connected) {
          reject(err);
        }
      });
    });
  }

  /**
   * Send a typed RPC request and await the response.
   */
  async call<M extends keyof RpcMethods>(
    method: M,
    params: RpcMethods[M]["params"],
  ): Promise<RpcMethods[M]["result"]> {
    if (!this.ws || !this._connected) {
      throw new Error("Not connected to engine");
    }

    const id = this.nextId++;
    const request: JsonRpcRequest = {
      jsonrpc: "2.0",
      id,
      method: method as string,
      params: params as Record<string, unknown>,
    };

    return new Promise((resolve, reject) => {
      const timeout = this.options.timeout ?? 10000;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`RPC timeout: ${method as string}`));
      }, timeout);

      this.pending.set(id, {
        resolve: resolve as (v: unknown) => void,
        reject,
        timer,
      });
      this.ws!.send(JSON.stringify(request));
    });
  }

  /**
   * Subscribe to engine push notifications.
   */
  on<K extends keyof SubscriptionEvents>(
    event: K,
    handler: SubscriptionHandler<K>,
  ): () => void {
    if (!this.subscriptions.has(event)) {
      this.subscriptions.set(event, new Set());
    }
    const handlers = this.subscriptions.get(event)!;
    handlers.add(handler as (data: unknown) => void);

    // Return unsubscribe function
    return () => {
      handlers.delete(handler as (data: unknown) => void);
    };
  }

  /**
   * Gracefully disconnect from the engine.
   */
  disconnect(): void {
    this.clearReconnectTimer();
    this.rejectAllPending(new Error("Client disconnected"));
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
    this._connected = false;
  }

  // ── Private ────────────────────────────────────────────────────────

  private handleMessage(data: WebSocket.Data): void {
    let msg: JsonRpcResponse | JsonRpcNotification;
    try {
      msg = JSON.parse(data.toString());
    } catch {
      console.error("[EngineClient] Invalid JSON from engine");
      return;
    }

    // Response to a pending request
    if ("id" in msg && msg.id != null) {
      const response = msg as JsonRpcResponse;
      const pending = this.pending.get(response.id as number);
      if (pending) {
        this.pending.delete(response.id as number);
        clearTimeout(pending.timer);
        if (response.error) {
          pending.reject(
            new Error(`RPC error ${response.error.code}: ${response.error.message}`),
          );
        } else {
          pending.resolve(response.result);
        }
      }
      return;
    }

    // Subscription notification from engine
    const notification = msg as JsonRpcNotification;
    const handlers = this.subscriptions.get(notification.method);
    if (handlers) {
      for (const handler of handlers) {
        try {
          handler(notification.params);
        } catch (e) {
          console.error(`[EngineClient] Subscription handler error for ${notification.method}:`, e);
        }
      }
    }
  }

  private rejectAllPending(error: Error): void {
    for (const [id, pending] of this.pending) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer) return;
    const interval = this.options.reconnectInterval ?? 2000;
    this.reconnectTimer = setTimeout(async () => {
      this.reconnectTimer = null;
      try {
        console.log("[EngineClient] Attempting reconnect...");
        await this.connect();
        console.log("[EngineClient] Reconnected");
        this.options.onReconnected?.();
      } catch {
        console.warn("[EngineClient] Reconnect failed, retrying...");
        this.scheduleReconnect();
      }
    }, interval);
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }
}
