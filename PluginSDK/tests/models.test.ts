import { expect, test } from "bun:test";
import { generate } from "../../Editor/Plugins/AI/src/models.ts";

test("OpenAI-compatible streaming completes a tool round through the public backend", async () => {
  const requests: any[] = []; const invoked: any[] = [];
  const server = Bun.serve({ port: 0, async fetch(request) {
    const input = await request.json(); requests.push(input);
    const values = requests.length === 1
      ? [{ choices: [{ delta: { tool_calls: [{ index: 0, id: "call-1", function: { name: "read_project", arguments: '{"path":"hello.txt"}' } }] } }] }]
      : [{ choices: [{ delta: { content: "处理完成" } }] }];
    return new Response(values.map(value => `data: ${JSON.stringify(value)}\n\n`).join("") + "data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } });
  } });
  try {
    let text = "";
    await generate({ format: "openai-compatible", baseURL: server.url.toString(), apiKey: "test", model: "test" },
      [{ id: "1", role: "user", text: "read" }], new AbortController().signal, chunk => text += chunk, "instructions", {
        tools: [{ type: "function", function: { name: "read_project", description: "read", parameters: { type: "object" } } }],
        async invoke(name, input) { invoked.push({ name, input }); return { text: "hello" }; }
      }, 400);
    expect(text).toBe("处理完成"); expect(invoked).toEqual([{ name: "read_project", input: { path: "hello.txt" } }]);
    expect(requests[1].messages.at(-1).role).toBe("tool"); expect(requests[0].max_tokens).toBe(400);
  } finally { server.stop(true); }
});
