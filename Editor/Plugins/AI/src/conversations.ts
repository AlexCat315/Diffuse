import { mkdir, readdir, readFile, rename, rm, writeFile, open } from "node:fs/promises";
import { join } from "node:path";

export interface Message { id: string; role: "user" | "assistant"; text: string; state?: "running" | "completed" | "cancelled" | "failed"; }
export interface Conversation {
  id: string; title: string; project?: string; messages: Message[];
  updatedAt: number; status: "idle" | "running" | "completed" | "cancelled" | "failed" | "interrupted";
  draft: string;
  skills?: string[];
}
export interface ModelConfig { format: string; baseURL: string; model: string; apiKey: string; }
export type Generate = (messages: Message[], signal: AbortSignal, delta: (text: string) => void) => Promise<void>;

/** Files are per conversation; background work never follows the selected conversation. */
export class Conversations {
  readonly active = new Map<string, { controller: AbortController; task: Promise<void> }>();
  #loaded = new Map<string, Conversation>();
  #writes = new Map<string, Promise<void>>();
  #closed = false;
  constructor(readonly directory: string) {}
  async list(): Promise<Conversation[]> {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const files = (await readdir(this.directory)).filter(name => /^[a-f0-9-]{36}\.json$/.test(name));
    const values = await Promise.all(files.map(async name => {
      try {
        const value: Conversation = JSON.parse(await readFile(join(this.directory, name), "utf8"));
        if (value.id + ".json" !== name || !Array.isArray(value.messages)) return undefined;
        if (this.active.has(value.id)) return this.#loaded.get(value.id) ?? value;
        if (value.status === "running" && !await this.isLocked(value.id)) {
          value.status = "interrupted";
          for (const message of value.messages) if (message.state === "running") message.state = "failed";
          await this.save(value);
        }
        return value;
      } catch { return undefined; }
    }));
    for (const value of this.#loaded.values()) if (this.active.has(value.id)) {
      const index = values.findIndex(v => v?.id === value.id); if (index >= 0) values[index] = value; else values.push(value);
    }
    return values.filter((v): v is Conversation => !!v).sort((a, b) => b.updatedAt - a.updatedAt);
  }
  async create(project?: string): Promise<Conversation> {
    if (this.#closed) throw new Error("AI plugin is disabled");
    const conversation: Conversation = { id: crypto.randomUUID(), title: "新会话", project: project || undefined, messages: [], draft: "", updatedAt: Date.now(), status: "idle" };
    await this.save(conversation); return conversation;
  }
  async get(id: string): Promise<Conversation | undefined> {
    if (!/^[a-f0-9-]{36}$/.test(id)) return undefined;
    if (this.active.has(id)) return this.#loaded.get(id);
    try { return JSON.parse(await readFile(join(this.directory, `${id}.json`), "utf8")); } catch { return undefined; }
  }
  async save(value: Conversation): Promise<void> {
    if (!this.active.has(value.id) && await this.isLocked(value.id)) throw new Error("此会话已在另一个项目中运行");
    this.#loaded.set(value.id, value);
    const serialized = JSON.stringify(value);
    const previous = this.#writes.get(value.id) ?? Promise.resolve();
    const write = previous.catch(() => {}).then(async () => {
      await mkdir(this.directory, { recursive: true, mode: 0o700 });
      const file = join(this.directory, `${value.id}.json`); const temporary = `${file}.${crypto.randomUUID()}.tmp`;
      try { await writeFile(temporary, serialized, { mode: 0o600 }); await rename(temporary, file); }
      finally { await rm(temporary, { force: true }); }
    });
    this.#writes.set(value.id, write);
    try { await write; } finally { if (this.#writes.get(value.id) === write) this.#writes.delete(value.id); }
  }
  async start(id: string, prompt: string, generate: Generate): Promise<void> {
    if (this.#closed) throw new Error("AI plugin is disabled");
    if (this.active.has(id)) throw new Error("此会话正在运行");
    const conversation = await this.get(id); if (!conversation || !prompt.trim()) throw new Error("会话或消息无效");
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const lockPath = join(this.directory, `${id}.lock`);
    await this.isLocked(id); // Remove a lock left by a crashed owner before acquiring it.
    // Lock ownership spans every project host using this application-level conversation directory.
    const lock = await open(lockPath, "wx", 0o600).catch(() => { throw new Error("此会话已在另一个项目中运行"); });
    await lock.writeFile(JSON.stringify({ pid: process.pid })); await lock.close();
    await rm(join(this.directory, `${id}.cancel`), { force: true });
    const controller = new AbortController();
    const answer: Message = { id: crypto.randomUUID(), role: "assistant", text: "", state: "running" };
    conversation.messages.push({ id: crypto.randomUUID(), role: "user", text: prompt }, answer);
    if (conversation.messages.length === 2) conversation.title = prompt.trim().slice(0, 48);
    conversation.status = "running"; conversation.draft = ""; conversation.updatedAt = Date.now();
    const slot = { controller, task: Promise.resolve() }; this.active.set(id, slot);
    try { await this.save(conversation); }
    catch (error) { this.active.delete(id); await rm(lockPath, { force: true }); throw error; }
    slot.task = (async () => {
      const cancellation = setInterval(() => {
        void readFile(join(this.directory, `${id}.cancel`)).then(() => controller.abort()).catch(() => {});
      }, 100);
      let lastSave = Date.now();
      try {
        controller.signal.throwIfAborted();
        await generate(conversation.messages.filter(message => message !== answer), controller.signal, text => {
          if (controller.signal.aborted) return;
          answer.text += text;
          if (Buffer.byteLength(answer.text) > 4 * 1024 * 1024) { controller.abort(); return; }
          if (Date.now() - lastSave > 300) { lastSave = Date.now(); void this.save(conversation).catch(() => controller.abort()); }
        });
        conversation.status = controller.signal.aborted ? "cancelled" : "completed";
      } catch (error) {
        conversation.status = controller.signal.aborted ? "cancelled" : "failed";
        if (!controller.signal.aborted) answer.text += `\n${error instanceof Error ? error.message : String(error)}`;
      } finally {
        clearInterval(cancellation);
        answer.state = conversation.status === "completed" ? "completed" : conversation.status === "cancelled" ? "cancelled" : "failed";
        conversation.updatedAt = Date.now();
        try { await this.save(conversation); } finally {
          this.active.delete(id); await rm(lockPath, { force: true });
          await rm(join(this.directory, `${id}.cancel`), { force: true });
        }
      }
    })();
  }
  async cancel(id: string): Promise<void> {
    if (!/^[a-f0-9-]{36}$/.test(id)) throw new Error("会话无效");
    const task = this.active.get(id);
    if (task) { task.controller.abort(); await task.task; }
    else if (await this.isLocked(id)) await writeFile(join(this.directory, `${id}.cancel`), "cancel", { mode: 0o600 });
  }
  async dispose(): Promise<void> {
    this.#closed = true;
    const tasks = [...this.active.values()]; tasks.forEach(value => value.controller.abort());
    await Promise.allSettled(tasks.map(value => value.task)); await Promise.allSettled(this.#writes.values());
  }
  private async isLocked(id: string): Promise<boolean> {
    const file = join(this.directory, `${id}.lock`);
    let content: string;
    try { content = await readFile(file, "utf8"); } catch (error: any) { if (error.code === "ENOENT") return false; throw error; }
    try {
      const { pid } = JSON.parse(content);
      if (!Number.isInteger(pid) || pid <= 0) return true;
      try { process.kill(pid, 0); return true; } catch { await rm(file, { force: true }); return false; }
    } catch { return true; } // The owner can still be writing a newly acquired lock.
  }
}
