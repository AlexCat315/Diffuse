// @bun
// PluginSDK/src/services.ts
async function hostJob(context, permission, request, signal = context.signal) {
  signal.throwIfAborted();
  const started = await context.query(permission, { ...request, operation: request.operation ?? "start" });
  if (!started?.job)
    throw new Error("Host did not return a job");
  let completed = false;
  try {
    while (true) {
      signal.throwIfAborted();
      const result = await context.query(permission, { operation: "poll", job: started.job });
      if (result.status === "completed") {
        completed = true;
        return result.value;
      }
      if (result.status === "failed") {
        completed = true;
        throw new Error(result.error);
      }
      await new Promise((resolve, reject) => {
        const stop = () => {
          clearTimeout(timer);
          reject(signal.reason);
        };
        const timer = setTimeout(() => {
          signal.removeEventListener("abort", stop);
          resolve();
        }, 100);
        signal.addEventListener("abort", stop, { once: true });
        if (signal.aborted)
          stop();
      });
    }
  } finally {
    if (!completed)
      await context.query(permission, { operation: "cancel", job: started.job }).catch(() => {});
  }
}

// PluginSDK/src/index.ts
function capability(input, run, metadata = {}) {
  return { input, run, ...metadata };
}
function definePlugin(plugin) {
  return plugin;
}

// Editor/Plugins/AI/src/index.ts
import { mkdir as mkdir3, readFile as readFile3, writeFile as writeFile3, rename as rename2, rm as rm2 } from "fs/promises";
import { join as join3 } from "path";

// Editor/Plugins/AI/src/conversations.ts
import { mkdir, readdir, readFile, rename, rm, writeFile, open } from "fs/promises";
import { join } from "path";

class Conversations {
  directory;
  active = new Map;
  #loaded = new Map;
  #writes = new Map;
  #closed = false;
  constructor(directory) {
    this.directory = directory;
  }
  async list() {
    await mkdir(this.directory, { recursive: true, mode: 448 });
    const files = (await readdir(this.directory)).filter((name) => /^[a-f0-9-]{36}\.json$/.test(name));
    const values = await Promise.all(files.map(async (name) => {
      try {
        const value = JSON.parse(await readFile(join(this.directory, name), "utf8"));
        if (value.id + ".json" !== name || !Array.isArray(value.messages))
          return;
        if (this.active.has(value.id))
          return this.#loaded.get(value.id) ?? value;
        if (value.status === "running" && !await this.isLocked(value.id)) {
          value.status = "interrupted";
          for (const message of value.messages)
            if (message.state === "running")
              message.state = "failed";
          await this.save(value);
        }
        return value;
      } catch {
        return;
      }
    }));
    for (const value of this.#loaded.values())
      if (this.active.has(value.id)) {
        const index = values.findIndex((v) => v?.id === value.id);
        if (index >= 0)
          values[index] = value;
        else
          values.push(value);
      }
    return values.filter((v) => !!v).sort((a, b) => b.updatedAt - a.updatedAt);
  }
  async create(project) {
    if (this.#closed)
      throw new Error("AI plugin is disabled");
    const conversation = { id: crypto.randomUUID(), title: "\u65B0\u4F1A\u8BDD", project: project || undefined, messages: [], draft: "", updatedAt: Date.now(), status: "idle" };
    await this.save(conversation);
    return conversation;
  }
  async get(id) {
    if (!/^[a-f0-9-]{36}$/.test(id))
      return;
    if (this.active.has(id))
      return this.#loaded.get(id);
    try {
      return JSON.parse(await readFile(join(this.directory, `${id}.json`), "utf8"));
    } catch {
      return;
    }
  }
  async save(value) {
    if (!this.active.has(value.id) && await this.isLocked(value.id))
      throw new Error("\u6B64\u4F1A\u8BDD\u5DF2\u5728\u53E6\u4E00\u4E2A\u9879\u76EE\u4E2D\u8FD0\u884C");
    this.#loaded.set(value.id, value);
    const serialized = JSON.stringify(value);
    const previous = this.#writes.get(value.id) ?? Promise.resolve();
    const write = previous.catch(() => {}).then(async () => {
      await mkdir(this.directory, { recursive: true, mode: 448 });
      const file = join(this.directory, `${value.id}.json`);
      const temporary = `${file}.${crypto.randomUUID()}.tmp`;
      try {
        await writeFile(temporary, serialized, { mode: 384 });
        await rename(temporary, file);
      } finally {
        await rm(temporary, { force: true });
      }
    });
    this.#writes.set(value.id, write);
    try {
      await write;
    } finally {
      if (this.#writes.get(value.id) === write)
        this.#writes.delete(value.id);
    }
  }
  async start(id, prompt, generate) {
    if (this.#closed)
      throw new Error("AI plugin is disabled");
    if (this.active.has(id))
      throw new Error("\u6B64\u4F1A\u8BDD\u6B63\u5728\u8FD0\u884C");
    const conversation = await this.get(id);
    if (!conversation || !prompt.trim())
      throw new Error("\u4F1A\u8BDD\u6216\u6D88\u606F\u65E0\u6548");
    await mkdir(this.directory, { recursive: true, mode: 448 });
    const lockPath = join(this.directory, `${id}.lock`);
    await this.isLocked(id);
    const lock = await open(lockPath, "wx", 384).catch(() => {
      throw new Error("\u6B64\u4F1A\u8BDD\u5DF2\u5728\u53E6\u4E00\u4E2A\u9879\u76EE\u4E2D\u8FD0\u884C");
    });
    await lock.writeFile(JSON.stringify({ pid: process.pid }));
    await lock.close();
    const controller = new AbortController;
    const answer = { id: crypto.randomUUID(), role: "assistant", text: "", state: "running" };
    conversation.messages.push({ id: crypto.randomUUID(), role: "user", text: prompt }, answer);
    if (conversation.messages.length === 2)
      conversation.title = prompt.trim().slice(0, 48);
    conversation.status = "running";
    conversation.draft = "";
    conversation.updatedAt = Date.now();
    const slot = { controller, task: Promise.resolve() };
    this.active.set(id, slot);
    try {
      await this.save(conversation);
    } catch (error) {
      this.active.delete(id);
      await rm(lockPath, { force: true });
      throw error;
    }
    slot.task = (async () => {
      const cancellation = setInterval(() => {
        readFile(join(this.directory, `${id}.cancel`)).then(() => controller.abort()).catch(() => {});
      }, 100);
      let lastSave = Date.now();
      try {
        await generate(conversation.messages.filter((message) => message !== answer), controller.signal, (text) => {
          if (controller.signal.aborted)
            return;
          answer.text += text;
          if (Buffer.byteLength(answer.text) > 4 * 1024 * 1024) {
            controller.abort();
            return;
          }
          if (Date.now() - lastSave > 300) {
            lastSave = Date.now();
            this.save(conversation).catch(() => controller.abort());
          }
        });
        conversation.status = controller.signal.aborted ? "cancelled" : "completed";
      } catch (error) {
        conversation.status = controller.signal.aborted ? "cancelled" : "failed";
        if (!controller.signal.aborted)
          answer.text += `
${error instanceof Error ? error.message : String(error)}`;
      } finally {
        clearInterval(cancellation);
        answer.state = conversation.status === "completed" ? "completed" : conversation.status === "cancelled" ? "cancelled" : "failed";
        conversation.updatedAt = Date.now();
        try {
          await this.save(conversation);
        } finally {
          this.active.delete(id);
          await rm(lockPath, { force: true });
          await rm(join(this.directory, `${id}.cancel`), { force: true });
        }
      }
    })();
  }
  async cancel(id) {
    if (!/^[a-f0-9-]{36}$/.test(id))
      throw new Error("\u4F1A\u8BDD\u65E0\u6548");
    const task = this.active.get(id);
    if (task) {
      task.controller.abort();
      await task.task;
    } else if (await this.isLocked(id))
      await writeFile(join(this.directory, `${id}.cancel`), "cancel", { mode: 384 });
  }
  async dispose() {
    this.#closed = true;
    const tasks = [...this.active.values()];
    tasks.forEach((value) => value.controller.abort());
    await Promise.allSettled(tasks.map((value) => value.task));
    await Promise.allSettled(this.#writes.values());
  }
  async isLocked(id) {
    const file = join(this.directory, `${id}.lock`);
    let content;
    try {
      content = await readFile(file, "utf8");
    } catch (error) {
      if (error.code === "ENOENT")
        return false;
      throw error;
    }
    try {
      const { pid } = JSON.parse(content);
      if (!Number.isInteger(pid) || pid <= 0)
        return true;
      try {
        process.kill(pid, 0);
        return true;
      } catch {
        await rm(file, { force: true });
        return false;
      }
    } catch {
      return true;
    }
  }
}

// Editor/Plugins/AI/src/models.ts
async function* events(body) {
  const reader = body.getReader();
  const decoder = new TextDecoder;
  let buffer = "";
  try {
    while (true) {
      const { value, done } = await reader.read();
      buffer += decoder.decode(value, { stream: !done });
      buffer = buffer.replace(/\r\n/g, `
`);
      let end;
      while ((end = buffer.indexOf(`

`)) >= 0) {
        const block = buffer.slice(0, end);
        buffer = buffer.slice(end + 2);
        const data = block.split(`
`).filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trimStart()).join(`
`);
        if (data === "[DONE]")
          return;
        if (data)
          yield JSON.parse(data);
      }
      if (done)
        break;
      if (buffer.length > 1024 * 1024)
        throw new Error("Model event exceeds limit");
    }
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}
async function generate(config, messages, signal, delta, instructions = "", backend, maximumTokens = 8192) {
  if (!config.apiKey || !config.model)
    throw new Error("\u8BF7\u5148\u914D\u7F6E\u6A21\u578B\u548C API Key");
  const base = new URL(config.baseURL.endsWith("/") ? config.baseURL : config.baseURL + "/");
  if (!["https:", "http:"].includes(base.protocol) || base.username || base.password)
    throw new Error("\u6A21\u578B\u5730\u5740\u65E0\u6548");
  const anthropic = config.format === "anthropic";
  const headers = { "content-type": "application/json" };
  if (anthropic) {
    headers["x-api-key"] = config.apiKey;
    headers["anthropic-version"] = "2023-06-01";
  } else
    headers.authorization = `Bearer ${config.apiKey}`;
  const history = messages.map(({ role, text }) => ({ role, content: text }));
  for (let turn = 0;turn < 32; turn++) {
    signal.throwIfAborted();
    const tools = backend?.tools ?? [];
    const payload = anthropic ? {
      model: config.model,
      max_tokens: maximumTokens,
      messages: history,
      stream: true,
      ...instructions ? { system: instructions } : {},
      ...tools.length ? { tools: tools.map((tool) => ({ name: tool.function.name, description: tool.function.description, input_schema: tool.function.parameters })) } : {}
    } : {
      model: config.model,
      max_tokens: maximumTokens,
      messages: [...instructions ? [{ role: "system", content: instructions }] : [], ...history],
      stream: true,
      ...tools.length ? { tools: tools.map(({ readOnly, ...tool }) => tool) } : {}
    };
    const response = await fetch(new URL(anthropic ? "messages" : "chat/completions", base), { method: "POST", headers, body: JSON.stringify(payload), signal });
    if (!response.ok)
      throw new Error(`\u6A21\u578B\u8BF7\u6C42\u5931\u8D25 (${response.status}): ${(await response.text()).slice(0, 1000)}`);
    if (!response.body)
      throw new Error("\u6A21\u578B\u6CA1\u6709\u8FD4\u56DE\u54CD\u5E94\u6D41");
    let answer = "";
    const calls = new Map;
    for await (const event of events(response.body)) {
      if (signal.aborted)
        throw signal.reason;
      if (event.error || event.type === "error")
        throw new Error(event.error?.message ?? "\u6A21\u578B\u8FD4\u56DE\u9519\u8BEF");
      const text = anthropic ? event.delta?.text : event.choices?.[0]?.delta?.content;
      if (typeof text === "string") {
        answer += text;
        delta(text);
      }
      if (anthropic) {
        if (event.type === "content_block_start" && event.content_block?.type === "tool_use")
          calls.set(event.index, { id: event.content_block.id, name: event.content_block.name, arguments: "" });
        if (event.type === "content_block_delta" && event.delta?.type === "input_json_delta") {
          const call = calls.get(event.index);
          if (call)
            call.arguments += event.delta.partial_json;
        }
      } else {
        for (const chunk of event.choices?.[0]?.delta?.tool_calls ?? []) {
          const call = calls.get(chunk.index) ?? { id: "", name: "", arguments: "" };
          call.id += chunk.id ?? "";
          call.name += chunk.function?.name ?? "";
          call.arguments += chunk.function?.arguments ?? "";
          calls.set(chunk.index, call);
        }
      }
    }
    if (!calls.size)
      return;
    if (!backend)
      throw new Error("\u6A21\u578B\u8BF7\u6C42\u4E86\u672A\u63D0\u4F9B\u7684\u5DE5\u5177");
    const requested = [...calls.values()].map((call) => ({ ...call, input: JSON.parse(call.arguments || "{}") }));
    if (anthropic)
      history.push({ role: "assistant", content: [...answer ? [{ type: "text", text: answer }] : [], ...requested.map((call) => ({ type: "tool_use", id: call.id, name: call.name, input: call.input }))] });
    else
      history.push({ role: "assistant", content: answer || null, tool_calls: requested.map((call) => ({ id: call.id, type: "function", function: { name: call.name, arguments: call.arguments || "{}" } })) });
    const results = [];
    for (const call of requested) {
      signal.throwIfAborted();
      let value;
      try {
        if (!tools.some((tool) => tool.function.name === call.name))
          throw new Error("Unknown tool");
        value = await backend.invoke(call.name, call.input, signal);
      } catch (error) {
        if (signal.aborted)
          throw error;
        value = { error: error instanceof Error ? error.message : String(error) };
      }
      const content = JSON.stringify(value).slice(0, 200000);
      if (anthropic)
        results.push({ type: "tool_result", tool_use_id: call.id, content });
      else
        history.push({ role: "tool", tool_call_id: call.id, content });
    }
    if (anthropic)
      history.push({ role: "user", content: results });
  }
  throw new Error("\u6B64\u8F6E\u5DF2\u8FBE\u5230 32 \u6B21\u5DE5\u5177\u5FAA\u73AF\u4E0A\u9650");
}

// Editor/Plugins/AI/src/authoring.ts
import { mkdir as mkdir2, lstat, writeFile as writeFile2, readFile as readFile2 } from "fs/promises";
import { join as join2 } from "path";
var tool = (name, description, properties, required) => ({
  type: "function",
  function: { name, description, parameters: { type: "object", properties, required, additionalProperties: false } }
});
var string = { type: "string" };
var authoringTools = [
  tool("diffuse_plugin_guide", "Read the installed public TypeScript plugin SDK contract before creating a plugin.", {}, []),
  tool("diffuse_plugin_write", "Create or update one source file of a new plugin in the assistant's development directory. Read the SDK guide first.", { id: string, path: string, content: string }, ["id", "path", "content"]),
  tool("diffuse_plugin_build", "Build the plugin without executing it. Returns a .coveplugin package path for user review.", { id: string }, ["id"]),
  tool("diffuse_plugin_review", "Show the built plugin's installation review. The user chooses whether to enable its code.", { package: string }, ["package"])
];
async function authoring(name, input, context, signal) {
  signal.throwIfAborted();
  if (!context.sdkDirectory)
    throw new Error("The installed SDK is missing; run cove studio plugins prepare");
  if (name === "diffuse_plugin_guide")
    return {
      guide: await readFile2(join2(context.sdkDirectory, "README.md"), "utf8"),
      contract: await readFile2(join2(context.sdkDirectory, "index.ts"), "utf8")
    };
  const development = join2(context.storageDirectory, "development");
  const packages = join2(context.storageDirectory, "packages");
  if (name === "diffuse_plugin_review") {
    if (typeof input.package !== "string" || !input.package.startsWith(packages + "/") || !input.package.endsWith(".coveplugin") || input.package.includes(".."))
      throw new Error("Invalid built package");
    return hostJob(context, "diffuse:editor/host", { operation: "review", package: input.package }, signal);
  }
  if (typeof input.id !== "string" || !/^[a-z][a-z0-9.-]{2,63}$/.test(input.id))
    throw new Error("Invalid plugin id");
  const source = join2(development, input.id);
  if (name === "diffuse_plugin_write") {
    if (typeof input.path !== "string" || !/^(plugin\.json|src\/[a-zA-Z0-9_./-]+\.ts|resources\/[a-zA-Z0-9_./-]+)$/.test(input.path) || input.path.split("/").some((value) => !value || value === "." || value === "..") || typeof input.content !== "string" || Buffer.byteLength(input.content) > 1024 * 1024)
      throw new Error("Invalid source file");
    const segments = input.path.split("/");
    let directory = source;
    for (const segment of ["", ...segments.slice(0, -1)]) {
      directory = join2(directory, segment);
      await mkdir2(directory, { recursive: true });
      if ((await lstat(directory)).isSymbolicLink())
        throw new Error("Source symlinks are forbidden");
    }
    const file = join2(source, input.path);
    try {
      if ((await lstat(file)).isSymbolicLink())
        throw new Error("Source symlinks are forbidden");
    } catch (error) {
      if (error.code !== "ENOENT")
        throw error;
    }
    await writeFile2(file, input.content, { mode: 384 });
    return { path: file };
  }
  if (name !== "diffuse_plugin_build")
    throw new Error("Unknown authoring tool");
  await mkdir2(packages, { recursive: true });
  const output = join2(packages, `${input.id}-${crypto.randomUUID()}.coveplugin`);
  const process2 = Bun.spawn([globalThis.process.execPath, "--no-macros", join2(context.sdkDirectory, "cli.js"), "build", source, output], { stdout: "pipe", stderr: "pipe" });
  const abort = () => process2.kill();
  signal.addEventListener("abort", abort, { once: true });
  const timeout = setTimeout(abort, 30000);
  try {
    const [code, diagnostics] = await Promise.all([process2.exited, new Response(process2.stderr).text()]);
    signal.throwIfAborted();
    if (code !== 0)
      throw new Error(diagnostics.slice(0, 8000) || "Plugin build failed");
    return { package: output };
  } finally {
    clearTimeout(timeout);
    signal.removeEventListener("abort", abort);
  }
}

// Editor/Plugins/AI/src/extensions.ts
async function extensions(context, point) {
  return await context.query("cove:service/host", { operation: "extensions", point });
}
async function skillInstructions(context, selected) {
  const available = await extensions(context, "studio.ai.skills/v1");
  const sections = [];
  for (const skill of available.filter((skill) => selected.includes(`${skill.pluginID}.${skill.id}`))) {
    let instructions = skill.data.instructions ?? "";
    if (skill.data.resource) {
      const value = await context.query("cove:service/host", { operation: "resource", pluginID: skill.pluginID, id: skill.data.resource });
      instructions += value.text;
    }
    if (Buffer.byteLength(instructions) > 64 * 1024)
      throw new Error("Skill instructions exceed limit");
    sections.push(instructions);
  }
  return sections.join(`

`);
}
async function tools(context, workspace, conversation) {
  const native = workspace ? await context.query("diffuse:editor/host", { operation: "tools", workspace }) : [];
  const contributed = (await extensions(context, "studio.ai.tools/v1")).filter((value) => value.data.service && value.data.name && value.data.parameters);
  const byName = new Map(contributed.map((value) => [value.data.name, value]));
  return {
    tools: [...authoringTools, ...native, ...contributed.map((value) => ({
      type: "function",
      readOnly: value.data.readOnly ?? false,
      function: { name: value.data.name, description: value.data.description ?? value.data.title ?? value.id, parameters: value.data.parameters }
    }))],
    async invoke(name, input, signal) {
      if (authoringTools.some((tool) => tool.function.name === name))
        return authoring(name, input, context, signal);
      const extension = byName.get(name);
      if (extension)
        return hostJob(context, "cove:service/host", { service: extension.data.service, input: { conversation, workspace: workspace ?? "", arguments: input } }, signal);
      if (!workspace)
        throw new Error("\u6B64\u5DE5\u5177\u9700\u8981\u9879\u76EE");
      return hostJob(context, "diffuse:editor/host", { workspace, conversation, message: { action: "project_tool", tool_name: name, arguments: input } }, signal);
    }
  };
}
async function generateByService(context, config, messages, signal, delta, workspace, instructions = "") {
  const service = config.format.slice("service:".length);
  const invoke = (input, currentSignal = signal) => hostJob(context, "cove:service/host", { service, input }, currentSignal);
  const started = await invoke({ operation: "start", config, messages, workspace: workspace ?? "", instructions });
  if (!started.handle)
    throw new Error("Provider did not return a stream handle");
  let finished = false;
  try {
    while (true) {
      signal.throwIfAborted();
      const output = await invoke({ operation: "poll", handle: started.handle });
      for (const chunk of output.chunks ?? [])
        if (typeof chunk === "string")
          delta(chunk);
      if (output.error)
        throw new Error(output.error);
      if (output.done) {
        finished = true;
        return;
      }
      await Bun.sleep(100);
    }
  } finally {
    if (!finished)
      await invoke({ operation: "cancel", handle: started.handle }, new AbortController().signal).catch(() => {});
  }
}

// Editor/Plugins/AI/src/completions.ts
var jobs = new Map;
async function completion(request, host, config) {
  const input = JSON.parse(request);
  if (input.operation === "start") {
    if (jobs.size >= 32)
      throw new Error("Too many active completions");
    if (typeof input.prompt !== "string" || typeof input.instructions !== "string")
      throw new Error("Invalid completion");
    const handle = crypto.randomUUID();
    const job = { controller: new AbortController, task: Promise.resolve(), text: "", done: false, error: undefined };
    jobs.set(handle, job);
    const messages = [{ id: handle, role: "user", text: input.prompt }];
    const delta = (chunk) => {
      job.text += chunk;
    };
    job.task = (config.format.startsWith("service:") ? generateByService(host, config, messages, job.controller.signal, delta, undefined, input.instructions) : generate(config, messages, job.controller.signal, delta, input.instructions, undefined, Math.min(8192, Math.max(1, Number(input.maxTokens) || 8192)))).catch((error) => {
      job.error = error instanceof Error ? error.message : String(error);
    }).finally(() => {
      job.done = true;
    });
    return { handle };
  }
  const job = jobs.get(input.handle);
  if (!job)
    throw new Error("Completion is unavailable");
  if (input.operation === "cancel") {
    job.controller.abort();
    jobs.delete(input.handle);
    return null;
  }
  if (input.operation !== "poll")
    throw new Error("Unknown completion operation");
  if (job.done)
    jobs.delete(input.handle);
  return { done: job.done, text: job.text, ...job.error ? { error: job.error } : {} };
}
async function disposeCompletions() {
  const active = [...jobs.values()];
  active.forEach((job) => job.controller.abort());
  await Promise.allSettled(active.map((job) => job.task));
  jobs.clear();
}

// Editor/Plugins/AI/src/index.ts
var stores = new Map;
var text = (value, style = "body", tone = "normal") => ({ type: "text", text: value || " ", style, tone });
var column = (children, options = {}) => ({ type: "column", spacing: 8, children, ...options });
var row = (children, options = {}) => ({ type: "row", spacing: 8, children, ...options });
var button = (title, action, args = {}, style = "ghost") => ({ type: "button", title, action, arguments: args, style });
var field = (id, placeholder, value, secure = false) => ({ type: "textField", id, placeholder, ...value === undefined ? {} : { value }, secure });
var defaults = { format: "openai-compatible", baseURL: "https://api.deepseek.com/", model: "deepseek-chat", apiKey: "" };
async function configAt(directory) {
  try {
    return { ...defaults, ...JSON.parse(await readFile3(join3(directory, "model.json"), "utf8")) };
  } catch {
    return defaults;
  }
}
async function saveConfig(directory, config) {
  await mkdir3(directory, { recursive: true, mode: 448 });
  const destination = join3(directory, "model.json"), temporary = `${destination}.${crypto.randomUUID()}.tmp`;
  try {
    await writeFile3(temporary, JSON.stringify(config), { mode: 384 });
    await rename2(temporary, destination);
  } finally {
    await rm2(temporary, { force: true });
  }
}
function threadRow(thread, selected) {
  const suffix = thread.status === "running" ? " \xB7 \u8FD0\u884C\u4E2D" : thread.status === "failed" ? " \xB7 \u5931\u8D25" : "";
  return button(thread.title + suffix, "select", { id: thread.id }, thread.id === selected ? "secondary" : "ghost");
}
var src_default = definePlugin({
  async deactivate() {
    await disposeCompletions();
    await Promise.all([...stores.values()].map((store) => store.dispose()));
    stores.clear();
  },
  capabilities: {
    complete: capability({ record: { request: "string" } }, async (input, host) => completion(input.request, host, await configAt(host.storageDirectory))),
    view: capability({ record: { view: "string", state: "string", event: "string", context: "string" } }, async (input, host) => {
      const context = JSON.parse(input.context);
      if (!context.storage)
        throw new Error("Missing plugin storage context");
      let store = stores.get(context.storage);
      if (!store) {
        store = new Conversations(join3(context.storage, "conversations"));
        stores.set(context.storage, store);
      }
      const state = input.state ? JSON.parse(input.state) : {};
      const event = input.event ? JSON.parse(input.event) : undefined;
      let config = await configAt(context.storage);
      if (event)
        state.error = undefined;
      try {
        switch (event?.action) {
          case "new":
            state.selected = (await store.create(event.arguments?.project || undefined)).id;
            state.settings = false;
            break;
          case "select":
            state.selected = event.arguments.id;
            state.settings = false;
            break;
          case "settings":
            state.settings = !state.settings;
            break;
          case "draft": {
            if (state.selected) {
              const conversation = await store.get(state.selected);
              if (conversation && conversation.status !== "running") {
                conversation.draft = String(event.value ?? "");
                await store.save(conversation);
              }
            }
            break;
          }
          case "skill": {
            if (state.selected) {
              const conversation = await store.get(state.selected);
              if (conversation && conversation.status !== "running") {
                conversation.skills = event.value === "none" ? [] : [String(event.value)];
                await store.save(conversation);
              }
            }
            break;
          }
          case "configure": {
            const values = event.values ?? {};
            config = { format: values.format ?? config.format, baseURL: values.endpoint ?? config.baseURL, model: values.model ?? config.model, apiKey: values.key || config.apiKey };
            if (!config.model || !config.apiKey)
              throw new Error("\u8BF7\u586B\u5199\u6A21\u578B\u548C API Key");
            await saveConfig(context.storage, config);
            state.settings = false;
            break;
          }
          case "send": {
            if (!config.apiKey) {
              state.settings = true;
              throw new Error("\u8BF7\u5148\u914D\u7F6E\u6A21\u578B");
            }
            const prompt = String(event.values?.[`prompt-${state.selected ?? "new"}`] ?? event.value ?? "").trim();
            if (!prompt)
              break;
            if (!state.selected)
              state.selected = (await store.create(context.workspace || undefined)).id;
            const selected = await store.get(state.selected);
            if (!selected)
              throw new Error("\u4F1A\u8BDD\u4E0D\u5B58\u5728");
            const instructions = [selected.project ? `Current project directory: ${selected.project}` : "", await skillInstructions(host, selected.skills ?? [])].join(`

`);
            const backend = await tools(host, selected.project, selected.id);
            await store.start(selected.id, prompt, (messages, signal, delta) => config.format.startsWith("service:") ? generateByService(host, config, messages, signal, delta, selected.project, instructions) : generate(config, messages, signal, delta, instructions, backend));
            break;
          }
          case "cancel":
            if (state.selected)
              await store.cancel(state.selected);
            break;
        }
      } catch (error) {
        state.error = error instanceof Error ? error.message : String(error);
      }
      const threads = await store.list();
      const selected = threads.find((thread) => thread.id === state.selected);
      const providers = await extensions(host, "studio.ai.providers/v1");
      const skills = await extensions(host, "studio.ai.skills/v1");
      const standalone = threads.filter((thread) => !thread.project);
      const projects = new Map((context.projects ?? []).map((p) => [p.directory, p.name]));
      for (const thread of threads)
        if (thread.project && !projects.has(thread.project))
          projects.set(thread.project, thread.project.split(/[\\/]/).pop() ?? thread.project);
      const sidebar = column([
        text("Diffuse", "title"),
        button("\u65B0\u4F1A\u8BDD", "new", {}, "secondary"),
        button("\u6A21\u578B\u8BBE\u7F6E", "settings"),
        ...standalone.length ? [text("\u72EC\u7ACB\u4F1A\u8BDD", "caption", "muted"), ...standalone.map((thread) => threadRow(thread, state.selected))] : [],
        text("\u9879\u76EE", "caption", "muted"),
        ...[...projects].flatMap(([directory, name]) => [
          row([text(name, "strong"), button("\uFF0B", "new", { project: directory })]),
          ...threads.filter((thread) => thread.project === directory).map((thread) => threadRow(thread, state.selected))
        ])
      ], { padding: 16, flex: 1 });
      let center;
      if (state.settings) {
        center = column([
          text("\u6A21\u578B\u8BBE\u7F6E", "title"),
          { type: "select", id: "format", value: config.format.startsWith("service:") && !providers.some((value) => `service:${value.data.service}` === config.format) ? "openai-compatible" : config.format, options: [{ value: "openai-compatible", label: "OpenAI compatible" }, { value: "anthropic", label: "Anthropic" }, ...providers.filter((value) => value.data.service).map((value) => ({ value: `service:${value.data.service}`, label: value.data.title ?? value.id }))] },
          field("endpoint", "API \u5730\u5740\uFF08\u5305\u542B\u6240\u9700\u7684 /v1/ \u8DEF\u5F84\uFF09", config.baseURL),
          field("model", "\u6A21\u578B ID", config.model),
          field("key", "API Key", "", true),
          button("\u4FDD\u5B58", "configure", {}, "primary")
        ], { maxWidth: 720, padding: 24 });
      } else {
        const messages = selected?.messages ?? [];
        const history = messages.slice(-40).flatMap((message) => [
          text(message.role === "user" ? "\u4F60" : "AI", "caption", "muted"),
          ...Array.from({ length: Math.max(1, Math.ceil(Math.min(message.text.length, 40000) / 900)) }, (_, index) => text(message.text.slice(index * 1800, (index + 1) * 1800)))
        ]);
        center = column([
          ...messages.length ? [{ type: "scroll", child: column(history, { padding: 16, maxWidth: 820 }) }] : [{ type: "spacer" }, text("\u5F00\u59CB\u65B0\u7684\u5DE5\u4F5C", "title")],
          column([
            ...state.error ? [text(state.error, "caption", "danger")] : [],
            ...selected ? [text(selected.project ? projects.get(selected.project) ?? selected.project : "\u72EC\u7ACB\u4F1A\u8BDD", "caption", "muted")] : [],
            ...selected && skills.length ? [{ type: "select", id: "skill", value: skills.some((skill) => `${skill.pluginID}.${skill.id}` === selected.skills?.[0]) ? selected.skills[0] : "none", action: "skill", options: [{ value: "none", label: "Skill" }, ...skills.map((skill) => ({ value: `${skill.pluginID}.${skill.id}`, label: skill.data.title ?? skill.id }))] }] : [],
            { type: "textField", id: `prompt-${state.selected ?? "new"}`, placeholder: "\u63CF\u8FF0\u4F60\u60F3\u5B8C\u6210\u7684\u5DE5\u4F5C\u2026", multiline: true, minHeight: 88, submit: "send", change: "draft", value: selected?.draft ?? "" },
            row([text(config.model, "caption", "muted"), { type: "spacer" }, selected?.status === "running" ? button("\u505C\u6B62", "cancel", {}, "secondary") : button("\u53D1\u9001", "send", {}, "primary")])
          ], { padding: 16, background: "raised", cornerRadius: 20, maxWidth: 820 }),
          ...!messages.length ? [{ type: "spacer" }] : []
        ], { padding: 32, flex: 1, align: "center" });
      }
      return { state, ui: row([{ type: "scroll", child: sidebar, width: 260, background: "surface", cornerRadius: 16 }, center], { flex: 1 }), refreshAfterMilliseconds: 500 };
    })
  }
});
export {
  src_default as default
};
