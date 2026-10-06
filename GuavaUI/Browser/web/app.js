import { WASI, File, OpenFile, ConsoleStdout } from "./wasi/index.js";

const surface = document.querySelector("#surface");
const status = document.querySelector("#status");
const decoder = new TextDecoder();
const encoder = new TextEncoder();
let wasm, renderer, lastFrame, scheduled = false, inspectorPort;

function readBytes(pointer, size) {
  // Copy before another Wasm call can grow memory or replace an export buffer.
  return new Uint8Array(wasm.memory.buffer, pointer >>> 0, size).slice();
}
function readJSON(pointer, size) { return JSON.parse(decoder.decode(readBytes(pointer, size))); }
function response() { return readJSON(wasm.guava_response(), wasm.guava_response_size()); }
function dispatch(envelope) {
  const bytes = encoder.encode(JSON.stringify(envelope));
  const pointer = wasm.guava_alloc(bytes.length);
  if (!pointer) throw new Error("DevTools message exceeds the 1 MiB limit");
  try {
    new Uint8Array(wasm.memory.buffer, pointer >>> 0, bytes.length).set(bytes);
    wasm.guava_dispatch(pointer, bytes.length);
    return response();
  } finally { wasm.guava_free(pointer); }
}
function post(envelope) { inspectorPort?.postMessage({ kind: "message", data: JSON.stringify(envelope) }); }

function schedule() {
  if (scheduled) return;
  scheduled = true;
  requestAnimationFrame(() => {
    scheduled = false;
    const width = surface.clientWidth, height = surface.clientHeight;
    wasm.guava_render(width, height);
    lastFrame = readJSON(wasm.guava_snapshot(), wasm.guava_snapshot_size());
    const vertices = readBytes(wasm.guava_vertices(), wasm.guava_vertex_bytes());
    const indexCount = wasm.guava_index_count();
    const indices = new Uint32Array(readBytes(wasm.guava_indices(), indexCount * 4).buffer);
    try {
      renderer.draw(lastFrame, vertices, indices);
    } catch (error) {
      if (renderer.backend !== "webgpu" || new URLSearchParams(location.search).get("renderer") === "webgpu") throw error;
      console.warn("WebGPU presentation failed:", error.message);
      renderer = makeCanvasRenderer();
      renderer.draw(lastFrame, vertices, indices);
    }
    drawLabels(lastFrame);
    document.querySelector("#stats").textContent = `count=${lastFrame.count} · ${lastFrame.vertices} vertices · ${lastFrame.indices} indices · ${lastFrame.batches.length} batches`;
    wasm.guava_events();
    for (const event of response()) post(event);
  });
}

function drawLabels(frame) {
  const canvas = document.querySelector("#labels");
  const ratio = window.devicePixelRatio || 1;
  canvas.width = Math.round(surface.clientWidth * ratio);
  canvas.height = Math.round(surface.clientHeight * ratio);
  const context = canvas.getContext("2d");
  context.setTransform(ratio, 0, 0, ratio, 0, 0);
  for (const label of frame.labels) {
    context.font = `${label.size}px system-ui,sans-serif`;
    context.fillStyle = label.color;
    context.fillText(label.text, label.x, label.y);
  }
}

async function makeRenderer(shader) {
  try {
    if (new URLSearchParams(location.search).get("renderer") === "canvas2d") throw new Error("Canvas2D requested");
    const gpu = navigator.gpu;
    const adapter = await gpu?.requestAdapter();
    if (!adapter) throw new Error("No WebGPU adapter");
    const device = await adapter.requestDevice();
    let deviceLost = false;
    device.addEventListener("uncapturederror", (event) => console.error("WebGPU:", event.error.message));
    device.lost.then((info) => {
      deviceLost = true;
      console.warn("WebGPU device lost:", info.message);
      if (renderer?.device !== device) return;
      if (new URLSearchParams(location.search).get("renderer") === "webgpu") {
        status.textContent = "WebGPU device lost";
      } else {
        renderer = makeCanvasRenderer();
        schedule();
      }
    });
    const format = gpu.getPreferredCanvasFormat();
    const module = device.createShaderModule({ code: shader });
    const pipeline = await device.createRenderPipelineAsync({
      layout: "auto",
      vertex: { module, entryPoint: "vs_main", buffers: [{ arrayStride: 20, attributes: [
        { shaderLocation: 0, offset: 0, format: "float32x2" },
        { shaderLocation: 1, offset: 8, format: "float32x2" },
        { shaderLocation: 2, offset: 16, format: "unorm8x4" },
      ] }] },
      fragment: { module, entryPoint: "fs_main", targets: [{ format, blend: {
        color: { srcFactor: "src-alpha", dstFactor: "one-minus-src-alpha", operation: "add" },
        alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" },
      } }] }, primitive: { topology: "triangle-list" },
    });
    const canvas = document.querySelector("#gpu");
    const context = canvas.getContext("webgpu");
    context.configure({ device, format, alphaMode: "premultiplied" });
    const uniform = device.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    const texture = device.createTexture({ size: [1, 1], format: "r8unorm", usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
    device.queue.writeTexture({ texture }, new Uint8Array([255]), { bytesPerRow: 1 }, [1, 1]);
    const bindGroup = device.createBindGroup({ layout: pipeline.getBindGroupLayout(0), entries: [
      { binding: 0, resource: { buffer: uniform } }, { binding: 1, resource: texture.createView() },
      { binding: 2, resource: device.createSampler({ magFilter: "linear", minFilter: "linear" }) },
    ] });
    let vertexBuffer, indexBuffer, vertexCapacity = 0, indexCapacity = 0;
    status.textContent = "Swift Wasm · WebGPU";
    // Keep the GPU resources alive for the renderer's lifetime.
    return { backend: "webgpu", gpu, adapter, device, get lost() { return deviceLost; }, draw(frame, vertices, indices) {
      const ratio = window.devicePixelRatio || 1;
      canvas.width = Math.max(1, Math.round(surface.clientWidth * ratio));
      canvas.height = Math.max(1, Math.round(surface.clientHeight * ratio));
      if (vertices.byteLength > vertexCapacity) {
        vertexBuffer?.destroy(); vertexCapacity = vertices.byteLength;
        vertexBuffer = device.createBuffer({ size: vertexCapacity, usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST });
      }
      if (indices.byteLength > indexCapacity) {
        indexBuffer?.destroy(); indexCapacity = indices.byteLength;
        indexBuffer = device.createBuffer({ size: indexCapacity, usage: GPUBufferUsage.INDEX | GPUBufferUsage.COPY_DST });
      }
      device.queue.writeBuffer(vertexBuffer, 0, vertices);
      device.queue.writeBuffer(indexBuffer, 0, indices);
      device.queue.writeBuffer(uniform, 0, new Float32Array([frame.width, frame.height, 0, 0]));
      const commands = device.createCommandEncoder();
      const pass = commands.beginRenderPass({ colorAttachments: [{ view: context.getCurrentTexture().createView(), loadOp: "clear", storeOp: "store", clearValue: { r: 0, g: 0, b: 0, a: 0 } }] });
      pass.setPipeline(pipeline); pass.setBindGroup(0, bindGroup);
      pass.setVertexBuffer(0, vertexBuffer); pass.setIndexBuffer(indexBuffer, "uint32");
      for (const batch of frame.batches) {
        const clip = batch.clip || [0, 0, frame.width, frame.height];
        const x = Math.max(0, Math.floor(clip[0] * ratio)), y = Math.max(0, Math.floor(clip[1] * ratio));
        const right = Math.min(canvas.width, Math.ceil((clip[0] + clip[2]) * ratio));
        const bottom = Math.min(canvas.height, Math.ceil((clip[1] + clip[3]) * ratio));
        if (right <= x || bottom <= y) continue;
        pass.setScissorRect(x, y, right - x, bottom - y);
        pass.drawIndexed(batch.count, 1, batch.offset);
      }
      pass.end(); device.queue.submit([commands.finish()]);
    } };
  } catch (error) {
    if (new URLSearchParams(location.search).get("renderer") === "webgpu") throw error;
    console.info("Using Canvas2D geometry adapter:", error.message);
    return makeCanvasRenderer();
  }

}

function makeCanvasRenderer() {
    document.querySelector("#gpu").hidden = true;
    const canvas = document.querySelector("#fallback"); canvas.hidden = false;
    status.textContent = "Swift Wasm · Canvas2D fallback";
    return { backend: "canvas2d", draw(frame, vertices, indices) {
      const ratio = window.devicePixelRatio || 1;
      canvas.width = Math.round(surface.clientWidth * ratio); canvas.height = Math.round(surface.clientHeight * ratio);
      const context = canvas.getContext("2d"); context.setTransform(ratio, 0, 0, ratio, 0, 0);
      const data = new DataView(vertices.buffer);
      for (const batch of frame.batches) {
        context.save();
        if (batch.clip) { context.beginPath(); context.rect(...batch.clip); context.clip(); }
        for (let i = batch.offset; i < batch.offset + batch.count; i += 3) {
          const start = indices[i] * 20;
          const color = data.getUint32(start + 16, true);
          context.fillStyle = `rgba(${color & 255},${(color >>> 8) & 255},${(color >>> 16) & 255},${(color >>> 24) / 255})`;
          context.beginPath();
          for (let j = 0; j < 3; j++) {
            const p = indices[i + j] * 20, x = data.getFloat32(p, true), y = data.getFloat32(p + 4, true);
            if (j === 0) context.moveTo(x, y); else context.lineTo(x, y);
          }
          context.closePath(); context.fill();
        }
        context.restore();
      }
    } };
}

try {
  const wasi = new WASI([], [], [new OpenFile(new File([])), ConsoleStdout.lineBuffered(console.log), ConsoleStdout.lineBuffered(console.error)]);
  const module = await WebAssembly.compile(await (await fetch("./guava.wasm")).arrayBuffer());
  const instance = await WebAssembly.instantiate(module, { wasi_snapshot_preview1: wasi.wasiImport });
  wasi.initialize(instance); wasm = instance.exports;
  // The first call initializes Swift's lazily-created shared prototype.
  wasm.guava_render(surface.clientWidth, surface.clientHeight);
  renderer = await makeRenderer(decoder.decode(readBytes(wasm.guava_shader(), wasm.guava_shader_size())));
  if (renderer.lost) {
    if (new URLSearchParams(location.search).get("renderer") === "webgpu") throw new Error("WebGPU device lost during initialization");
    renderer = makeCanvasRenderer();
  }
  for (const [id, x, y] of [["increment", 40, 260], ["reset", () => surface.clientWidth - 40, 260], ["theme", 40, 320]]) {
    document.getElementById(id).addEventListener("click", () => { wasm.guava_pointer(1, typeof x === "function" ? x() : x, y); schedule(); });
  }
  surface.addEventListener("pointermove", (event) => {
    const rect = surface.getBoundingClientRect(); wasm.guava_pointer(0, event.clientX - rect.left, event.clientY - rect.top); schedule();
  });
  surface.addEventListener("pointerleave", () => { wasm.guava_pointer(0, -1, -1); schedule(); });
  surface.addEventListener("pointerdown", (event) => {
    if (event.button !== 0) return;
    const rect = surface.getBoundingClientRect(); wasm.guava_pointer(1, event.clientX - rect.left, event.clientY - rect.top); schedule();
  });
  new ResizeObserver(schedule).observe(surface);
  window.addEventListener("message", (event) => {
    const iframe = document.querySelector("#inspector");
    if (event.origin !== location.origin || event.source !== iframe.contentWindow) return;
    if (event.data?.type === "guava.devtools.probe") {
      iframe.contentWindow.postMessage({ type: "guava.devtools.ready" }, location.origin);
      return;
    }
    if (event.data?.type !== "guava.devtools.connect" || !event.ports[0]) return;
    if (inspectorPort) { dispatch({ type: "bye" }); inspectorPort.close(); }
    inspectorPort = event.ports[0];
    const port = inspectorPort;
    port.addEventListener("message", (event) => {
      if (inspectorPort !== port) return;
      if (event.data?.kind === "close") {
        dispatch({ type: "bye" }); port.close(); inspectorPort = undefined; schedule();
      } else if (event.data?.kind === "message") {
        try { post(dispatch(JSON.parse(event.data.data))); schedule(); }
        catch (error) { post({ type: "request.err", payload: { code: "bad_request", message: String(error) } }); }
      }
    });
    port.start(); port.postMessage({ kind: "open" }); wasm.guava_hello(); post(response()); schedule();
  });
  const ready = () => document.querySelector("#inspector").contentWindow.postMessage({ type: "guava.devtools.ready" }, location.origin);
  document.querySelector("#inspector").addEventListener("load", ready);
  ready();
  window.guavaDebug = { get snapshot() { return lastFrame; }, get backend() { return renderer.backend; }, request(envelope) { const result = dispatch(envelope); schedule(); return result; } };
  schedule();
} catch (error) { status.textContent = "Prototype failed to load"; console.error(error); document.querySelector("#stats").textContent = String(error); }
