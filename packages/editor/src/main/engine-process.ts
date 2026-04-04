import { ChildProcess, spawn } from "child_process";
import path from "path";
import { EventEmitter } from "events";

export interface EngineProcessOptions {
  /** Path to guava-engine binary */
  engineBinary: string;
  /** Project path to open */
  projectPath?: string;
  /** RPC server port */
  port?: number;
  /** Additional CLI arguments */
  extraArgs?: string[];
}

/**
 * Manages the engine child process lifecycle.
 * Spawns guava-engine in --editor-server mode and monitors health.
 */
export class EngineProcess extends EventEmitter {
  private proc: ChildProcess | null = null;
  private _running = false;

  constructor(private options: EngineProcessOptions) {
    super();
  }

  get running(): boolean {
    return this._running;
  }

  /**
   * Spawn the engine process in editor-server mode.
   */
  start(): void {
    if (this._running) {
      throw new Error("Engine process already running");
    }

    const args = ["--editor-server"];

    if (this.options.port) {
      args.push("--editor-port", String(this.options.port));
    }

    if (this.options.projectPath) {
      args.push("--project-path", this.options.projectPath);
    }

    if (this.options.extraArgs) {
      args.push(...this.options.extraArgs);
    }

    console.log(
      `[EngineProcess] Spawning: ${this.options.engineBinary} ${args.join(" ")}`,
    );

    this.proc = spawn(this.options.engineBinary, args, {
      cwd: path.dirname(this.options.engineBinary),
      stdio: ["pipe", "pipe", "pipe"],
    });

    this._running = true;

    this.proc.stdout?.on("data", (data: Buffer) => {
      const text = data.toString().trim();
      if (text) {
        console.log(`[Engine] ${text}`);
        this.emit("stdout", text);

        // Detect when RPC server is ready
        if (text.includes("Editor RPC server listening")) {
          this.emit("ready");
        }
      }
    });

    this.proc.stderr?.on("data", (data: Buffer) => {
      const text = data.toString().trim();
      if (text) {
        console.error(`[Engine:err] ${text}`);
        this.emit("stderr", text);
      }
    });

    this.proc.on("exit", (code: number | null) => {
      this._running = false;
      console.log(`[EngineProcess] Engine exited with code ${code}`);
      this.emit("exit", code);
    });

    this.proc.on("error", (err: Error) => {
      this._running = false;
      console.error("[EngineProcess] Failed to start engine:", err.message);
      this.emit("error", err);
    });
  }

  /**
   * Gracefully stop the engine process.
   */
  async stop(): Promise<void> {
    if (!this.proc || !this._running) return;

    return new Promise<void>((resolve) => {
      const forceKillTimer = setTimeout(() => {
        if (this._running && this.proc) {
          console.warn("[EngineProcess] Force killing engine");
          this.proc.kill("SIGKILL");
        }
        resolve();
      }, 5000);

      this.proc!.once("exit", () => {
        clearTimeout(forceKillTimer);
        resolve();
      });

      // Send SIGTERM for graceful shutdown
      this.proc!.kill("SIGTERM");
    });
  }
}
