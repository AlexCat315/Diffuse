import { WASI, File, OpenFile, ConsoleStdout } from "./wasi/index.js";

const surface = document.querySelector("#surface");
const textInput = document.createElement("textarea");
textInput.id = "textInput"; textInput.setAttribute("aria-label", "Counter note input");
textInput.style.cssText = "position:fixed;left:0;top:0;width:1px;height:1px;opacity:0;pointer-events:none";
textInput.tabIndex = -1; document.body.append(textInput);
const status = document.querySelector("#status");
const decoder = new TextDecoder();
const encoder = new TextEncoder();
let wasm, renderer, lastFrame, scheduled = false, inspectorPort;
const atlas = { width: 0, height: 0, pixels: null, revision: 0, update: null };

function updateAtlas(frame) {
  if (atlas.width !== frame.atlasWidth || atlas.height !== frame.atlasHeight) {
    atlas.width = frame.atlasWidth; atlas.height = frame.atlasHeight;
    atlas.pixels = new Uint8Array(atlas.width * atlas.height);
  }
  atlas.update = frame.atlasUpdate;
  if (!atlas.update) return;
  const [x, y, width, height] = atlas.update;
  const pixels = readBytes(wasm.guava_atlas(), wasm.guava_atlas_size());
  if (pixels.length !== width * height) throw new Error("Invalid font atlas update");
  for (let row = 0; row < height; row++) {
    atlas.pixels.set(pixels.subarray(row * width, (row + 1) * width), (y + row) * atlas.width + x);
  }
  atlas.revision++;
}

function findNode(node, name) {
  if (!node) return;
  if (node.debugName === name) return node;
  for (const child of node.children) { const found = findNode(child, name); if (found) return found; }
}

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
function post(envelope) { if (!envelope) return; inspectorPort?.postMessage({ kind: "message", data: JSON.stringify(envelope) }); }

function schedule() {
  if (scheduled) return;
  scheduled = true;
  requestAnimationFrame(() => {
    scheduled = false;
    const width = surface.clientWidth, height = surface.clientHeight;
    wasm.guava_set_scale(window.devicePixelRatio || 1);
    wasm.guava_render(width, height);
    lastFrame = readJSON(wasm.guava_snapshot(), wasm.guava_snapshot_size());
    updateAtlas(lastFrame);
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
    if (lastFrame.focused === "counter.note") {
      const frame = findNode(lastFrame.tree.root, "counter.note")?.absoluteFrame;
      if (frame) {
        const rect = surface.getBoundingClientRect();
        textInput.style.left = `${rect.left + frame.x + Math.min(frame.w - 20, 16 + lastFrame.noteWidth)}px`;
        textInput.style.top = `${rect.top + frame.y + 12}px`;
        textInput.style.height = "24px";
      }
      if (document.activeElement === surface) textInput.focus({preventScroll:true});
    }
    document.querySelector("#stats").textContent = `count=${lastFrame.count} · ${lastFrame.vertices} vertices · ${lastFrame.batches.length} batches · ${lastFrame.fontCount} fonts · FreeType/HarfBuzz`;
    wasm.guava_events();
    for (const event of response()) post(event);
  });
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
    const fontTexture = device.createTexture({ size: [2048, 2048], format: "r8unorm", usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
    const fontBindGroup = device.createBindGroup({ layout: pipeline.getBindGroupLayout(0), entries: [
      { binding: 0, resource: { buffer: uniform } }, { binding: 1, resource: fontTexture.createView() },
      { binding: 2, resource: device.createSampler({ magFilter: "linear", minFilter: "linear" }) },
    ] });
    let atlasRevision = -1;
    let vertexBuffer, indexBuffer, vertexCapacity = 0, indexCapacity = 0;
    status.textContent = "Swift Wasm · WebGPU";
    // Keep the GPU resources alive for the renderer's lifetime.
    return { backend: "webgpu", gpu, adapter, device, get lost() { return deviceLost; }, draw(frame, vertices, indices) {
      if (atlasRevision !== atlas.revision) {
        const update = atlasRevision < 0 ? [0, 0, atlas.width, atlas.height] : atlas.update;
        if (update) {
          const [x, y, width, height] = update;
          device.queue.writeTexture({ texture: fontTexture, origin: [x, y] },
            atlas.pixels.subarray(y * atlas.width + x), { bytesPerRow: atlas.width }, [width, height]);
        }
        atlasRevision = atlas.revision;
      }
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
        pass.setBindGroup(0, batch.textureID === 1 ? fontBindGroup : bindGroup);
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
    const alphaCanvas = document.createElement("canvas");
    const tinted = new Map();
    let atlasRevision = -1;
    function fontSource(color) {
      if (!tinted.has(color)) {
        // Bound the cache; these are alpha textures tinted by vertex RGBA.
        if (tinted.size >= 8) tinted.delete(tinted.keys().next().value);
        const source = document.createElement("canvas");
        source.width = atlas.width; source.height = atlas.height;
        const context = source.getContext("2d");
        context.fillStyle = `rgb(${color & 255},${(color >>> 8) & 255},${(color >>> 16) & 255})`;
        context.fillRect(0, 0, source.width, source.height);
        context.globalCompositeOperation = "destination-in";
        context.drawImage(alphaCanvas, 0, 0);
        tinted.set(color, source);
      }
      return tinted.get(color);
    }
    return { backend: "canvas2d", draw(frame, vertices, indices) {
      if (atlasRevision !== atlas.revision) {
        const update = atlasRevision < 0 ? [0, 0, atlas.width, atlas.height] : atlas.update;
        if (atlasRevision < 0) { alphaCanvas.width = atlas.width; alphaCanvas.height = atlas.height; }
        if (update) {
          const [x, y, width, height] = update;
          const data = new ImageData(width, height);
          for (let row = 0; row < height; row++) for (let col = 0; col < width; col++) {
            const offset = (row * width + col) * 4;
            data.data[offset] = data.data[offset + 1] = data.data[offset + 2] = 255;
            data.data[offset + 3] = Math.round(255 * Math.pow(atlas.pixels[(y + row) * atlas.width + x + col] / 255, 0.75));
          }
          alphaCanvas.getContext("2d").putImageData(data, x, y);
        }
        tinted.clear(); atlasRevision = atlas.revision;
      }
      const ratio = window.devicePixelRatio || 1;
      canvas.width = Math.round(surface.clientWidth * ratio); canvas.height = Math.round(surface.clientHeight * ratio);
      const context = canvas.getContext("2d"); context.setTransform(ratio, 0, 0, ratio, 0, 0);
      const data = new DataView(vertices.buffer);
      for (const batch of frame.batches) {
        context.save();
        if (batch.clip) { context.beginPath(); context.rect(...batch.clip); context.clip(); }
        if (batch.textureID === 1) {
          // DrawList.addGlyphQuad emits two triangles per rectangular glyph.
          // Consume their positions and atlas UVs without invoking Canvas fonts.
          for (let i = batch.offset; i < batch.offset + batch.count; i += 6) {
            const a = indices[i] * 20, b = indices[i + 2] * 20;
            const x = data.getFloat32(a, true), y = data.getFloat32(a + 4, true);
            const width = data.getFloat32(b, true) - x, height = data.getFloat32(b + 4, true) - y;
            const u = data.getFloat32(a + 8, true) * atlas.width, v = data.getFloat32(a + 12, true) * atlas.height;
            const sourceWidth = data.getFloat32(b + 8, true) * atlas.width - u;
            const sourceHeight = data.getFloat32(b + 12, true) * atlas.height - v;
            const color = data.getUint32(a + 16, true);
            context.globalAlpha = (color >>> 24) / 255;
            context.drawImage(fontSource(color), u, v, sourceWidth, sourceHeight, x, y, width, height);
          }
          context.restore(); continue;
        }
        let pathColor;
        for (let i = batch.offset; i < batch.offset + batch.count; i += 3) {
          const start = indices[i] * 20;
          const color = data.getUint32(start + 16, true);
          // Merge opaque triangles so shared internal edges have no AA seams.
          // Translucent triangles keep their original source-over ordering.
          if (pathColor !== color || (color >>> 24) !== 255) {
            if (pathColor !== undefined) context.fill();
            context.beginPath();
            context.fillStyle = `rgba(${color & 255},${(color >>> 8) & 255},${(color >>> 16) & 255},${(color >>> 24) / 255})`;
            pathColor = color;
          }
          for (let j = 0; j < 3; j++) {
            const p = indices[i + j] * 20, x = data.getFloat32(p, true), y = data.getFloat32(p + 4, true);
            if (j === 0) context.moveTo(x, y); else context.lineTo(x, y);
          }
          context.closePath();
        }
        if (pathColor !== undefined) context.fill();
        context.restore();
      }
    } };
}

try {
  const wasi = new WASI([], [], [new OpenFile(new File([])), ConsoleStdout.lineBuffered(console.log), ConsoleStdout.lineBuffered(console.error)]);
  const module = await WebAssembly.compile(await (await fetch("./guava.wasm")).arrayBuffer());
  const instance = await WebAssembly.instantiate(module, { wasi_snapshot_preview1: wasi.wasiImport });
  wasi.initialize(instance); wasm = instance.exports;
  for (const font of ["NotoSans.ttf", "NotoSansCJKsc.otf", "NotoSansArabic.ttf", "NotoSansDevanagari.ttf", "NotoEmoji.ttf"]) {
    const result = await fetch(`./fonts/${font}`);
    if (!result.ok) throw new Error(`Cannot load font ${font}: HTTP ${result.status}`);
    const bytes = new Uint8Array(await result.arrayBuffer());
    const pointer = wasm.guava_font_alloc(bytes.length);
    if (!pointer) throw new Error(`Font exceeds the 32 MiB limit: ${font}`);
    try {
      new Uint8Array(wasm.memory.buffer, pointer >>> 0, bytes.length).set(bytes);
      if (!wasm.guava_font_load(pointer, bytes.length)) throw new Error(`Invalid font: ${font}`);
    } finally { wasm.guava_free(pointer); }
  }
  // The first call initializes Swift's lazily-created shared prototype.
  wasm.guava_render(surface.clientWidth, surface.clientHeight);
  // Preserve the initial full/dirty upload before the next render marks it clean.
  updateAtlas(readJSON(wasm.guava_snapshot(), wasm.guava_snapshot_size()));
  renderer = await makeRenderer(decoder.decode(readBytes(wasm.guava_shader(), wasm.guava_shader_size())));
  if (renderer.lost) {
    if (new URLSearchParams(location.search).get("renderer") === "webgpu") throw new Error("WebGPU device lost during initialization");
    renderer = makeCanvasRenderer();
  }
  for (const id of ["increment", "reset", "theme"]) {
    document.getElementById(id).addEventListener("click", () => {
      const rect = findNode(lastFrame?.tree.root, `counter.${id}`)?.absoluteFrame;
      if (rect) wasm.guava_pointer(3, rect.x + rect.w / 2, rect.y + rect.h / 2);
      schedule();
    });
  }
  surface.tabIndex = 0;
  const point = event => { const rect = surface.getBoundingClientRect(); return [event.clientX - rect.left, event.clientY - rect.top]; };
  surface.addEventListener("pointermove", event => { wasm.guava_pointer(0, ...point(event)); schedule(); });
  surface.addEventListener("pointerleave", () => { wasm.guava_pointer(0, -1, -1); schedule(); });
  surface.addEventListener("pointerdown", event => {
    if (event.button !== 0) return;
    surface.focus({preventScroll:true}); surface.setPointerCapture(event.pointerId);
    wasm.guava_pointer(1, ...point(event)); schedule();
  });
  surface.addEventListener("pointerup", event => {
    if (event.button !== 0) return;
    wasm.guava_pointer(2, ...point(event));
    if (surface.hasPointerCapture(event.pointerId)) surface.releasePointerCapture(event.pointerId);
    schedule();
  });
  surface.addEventListener("pointercancel", () => { wasm.guava_pointer(2, -1, -1); schedule(); });
  function sendText(string, editing = false) {
    const bytes = encoder.encode(string);
    const pointer = wasm.guava_alloc(Math.max(1, bytes.length));
    if (!pointer) return;
    try {
      new Uint8Array(wasm.memory.buffer, pointer >>> 0, bytes.length).set(bytes);
      wasm.guava_text(pointer, bytes.length, editing ? 1 : 0); schedule();
    } finally { wasm.guava_free(pointer); }
  }
  let composing = false, skipCompositionInput = false;
  textInput.addEventListener("compositionstart", () => { composing = true; });
  textInput.addEventListener("compositionupdate", event => sendText(event.data, true));
  textInput.addEventListener("compositionend", event => {
    composing = false; sendText(event.data); textInput.value = "";
    skipCompositionInput = true; setTimeout(() => { skipCompositionInput = false; }, 0);
  });
  textInput.addEventListener("input", event => {
    if (composing || event.isComposing || skipCompositionInput) return;
    sendText(event.data ?? textInput.value); textInput.value = "";
  });
  textInput.addEventListener("blur", () => { if (composing) sendText("", true); composing = false; textInput.value = ""; });
  const codes = { Enter:40, Escape:41, Backspace:42, Tab:43, Space:44, ArrowRight:79, ArrowLeft:80, ArrowDown:81, ArrowUp:82 };
  for (const target of [surface, textInput]) for (const name of ["keydown", "keyup"]) target.addEventListener(name, event => {
    if (composing || event.isComposing) return;
    const code = codes[event.code];
    if (!code) return;
    event.preventDefault();
    const modifiers = (event.shiftKey ? 1 : 0) | (event.ctrlKey ? 4 : 0) | (event.altKey ? 16 : 0) | (event.metaKey ? 64 : 0);
    wasm.guava_key(code, modifiers, name === "keydown" ? 1 : 0, event.repeat ? 1 : 0);
    if (target === textInput && code === 43) surface.focus({preventScroll:true});
    schedule();
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
  window.guavaDebug = {
    get snapshot() { return lastFrame; }, get backend() { return renderer.backend; },
    get gpuInfo() {
      const info = renderer.adapter?.info;
      return info ? { vendor: info.vendor, architecture: info.architecture, device: info.device,
        description: info.description, isFallbackAdapter: info.isFallbackAdapter, lost: renderer.lost } : null;
    },
    request(envelope) { const result = dispatch(envelope); schedule(); return result; },
  };
  try {
    const saved = sessionStorage.getItem("guava.dev.checkpoint");
    if (saved) {
      const restored = dispatch({type:"state.restore", id:0, payload:JSON.parse(saved)});
      if (restored.type.endsWith(".err")) console.warn("Previous development state could not be restored", restored.payload);
      sessionStorage.removeItem("guava.dev.checkpoint");
    }
  } catch (error) { console.warn("Development state restore failed", error); }
  fetch("./dev-mode.json").then(result => result.ok ? result.json() : null).then(mode => {
    if (!mode?.enabled) return;
    const events = new EventSource("/__guava_events");
    events.onopen = () => { window.guavaDevConnected = true; };
    const overlay = document.createElement("pre");
    overlay.style.cssText = "position:fixed;bottom:0;left:0;right:0;max-height:45vh;overflow:auto;background:#251b22;color:#ffe0e5;padding:16px;z-index:1000;white-space:pre-wrap";
    overlay.hidden = true; document.body.append(overlay);
    events.onmessage = event => {
      const message = JSON.parse(event.data);
      if (message.type === "building") { overlay.textContent="Compiling Swift…"; overlay.hidden=false; }
      if (message.type === "error") { overlay.textContent=message.message; overlay.hidden=false; }
      if (message.type === "ready") {
        const checkpoint = dispatch({type:"state.checkpoint",id:0}).payload;
        sessionStorage.setItem("guava.dev.checkpoint", JSON.stringify(checkpoint));
        location.assign("/" + location.search);
      }
    };
  }).catch(error => console.warn("Development reload unavailable", error));
  schedule();
} catch (error) { status.textContent = "Prototype failed to load"; console.error(error); document.querySelector("#stats").textContent = String(error); }
