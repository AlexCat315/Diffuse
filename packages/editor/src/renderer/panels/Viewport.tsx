import React, { useEffect, useRef, useCallback } from "react";
import { useLocalState } from "../store/local-state";
import { useI18n } from "../i18n";
import { ViewCube } from "./ViewCube";
import { useConnectionStore, useSceneStore, useViewportSettingsStore, useMeshEditStore } from "../store";
import type { ShadingMode } from "../store/viewport-settings";
import { ContextMenu, type MenuItem } from "../components/ContextMenu";
import {
  IconShadingSolid,
  IconShadingMaterial,
  IconShadingRendered,
  IconShadingWireframe,
} from "../components/Icons";
import { MeshEditToolbar } from "./MeshEditToolbar";

const SHADING_ICON_COMPONENTS: Record<ShadingMode, React.FC<{ size?: number; color?: string }>> = {
  solid: IconShadingSolid,
  material: IconShadingMaterial,
  rendered: IconShadingRendered,
  wireframe: IconShadingWireframe,
};


/**
 * Viewport panel — cross-platform engine viewport display.
 *
 * Both macOS (IOSurface) and Linux (POSIX shm) use the same pixel streaming
 * approach: the native addon reads raw BGRA pixels from the shared surface,
 * the main process pushes them to the renderer via IPC, and this component
 * draws them on a <canvas> element.
 *
 * Flow:
 *  1. On connect, tell the engine the desired viewport size (viewport.setRect).
 *  2. Poll viewport.getSurfaceId to get the surfaceId (and optional shmName).
 *  3. Pass the surface id to the main process to start pixel streaming.
 *  4. Main process calls refresh() at ~60 fps, pushes pixels via "viewport:pixels".
 *  5. On resize, re-notify the engine and poll for the new surface id.
 */
export function Viewport() {
  const connected = useConnectionStore((s) => s.connected);
  const { t } = useI18n();
  const ref = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [attached, setAttached] = useLocalState(false);
  const surfaceIdRef = useRef(0);
  const shmNameRef = useRef<string | undefined>(undefined);
  const lastSizeRef = useRef({ w: 0, h: 0 });
  const shadingMode = useViewportSettingsStore((s) => s.shadingMode);
  const setShadingMode = useViewportSettingsStore((s) => s.setShadingMode);
  const fetchViewportSettings = useViewportSettingsStore((s) => s.fetchFromEngine);
  const [contextMenu, setContextMenu] = useLocalState<{ x: number; y: number; items: MenuItem[] } | null>(null);
  const selectedEntity = useSceneStore((s) => s.selectedEntity);

  // ── Box selection state ──────────────────────────────────────
  const [boxSelect, setBoxSelect] = useLocalState<{
    startX: number; startY: number;  // viewport-pixel coords at mousedown
    curX: number; curY: number;      // current viewport-pixel coords
    cssStart: { x: number; y: number }; // CSS coords relative to container
    cssCur: { x: number; y: number };
    active: boolean;  // true once drag exceeds threshold
    shift: boolean;   // toggle mode if shift held
  } | null>(null);

  // Fetch current shading mode on connect
  useEffect(() => {
    if (!connected) return;
    fetchViewportSettings();
  }, [connected, fetchViewportSettings]);

  const handleShadingChange = useCallback((mode: ShadingMode) => {
    const prevMode = useViewportSettingsStore.getState().shadingMode;
    setShadingMode(mode);

    // Wireframe mode = mesh edit mode
    if (mode === "wireframe" && prevMode !== "wireframe") {
      const mesh = useMeshEditStore.getState();
      if (!mesh.active) mesh.enterEditMode();
    } else if (mode !== "wireframe" && prevMode === "wireframe") {
      const mesh = useMeshEditStore.getState();
      if (mesh.active) mesh.exitEditMode();
    }
  }, [setShadingMode]);

  // ── Input forwarding to the engine ─────────────────────────────
  const dpr = window.devicePixelRatio || 1;

  const toViewportCoords = useCallback((e: React.MouseEvent) => {
    const el = ref.current;
    if (!el) return { x: 0, y: 0 };
    const rect = el.getBoundingClientRect();
    return { x: (e.clientX - rect.left) * dpr, y: (e.clientY - rect.top) * dpr };
  }, [dpr]);

  const toCssCoords = useCallback((e: React.MouseEvent) => {
    const el = ref.current;
    if (!el) return { x: 0, y: 0 };
    const rect = el.getBoundingClientRect();
    return { x: e.clientX - rect.left, y: e.clientY - rect.top };
  }, []);

  const sendInput = useCallback((params: Record<string, unknown>) => {
    window.guavaEngine.call("viewport.sendInput", params as never).catch(() => {});
  }, []);

  // Track B key for box-select activation (Blender-style)
  const bKeyHeld = useRef(false);

  // Track last mouse position for delta calculation (movementX/Y is 0 without pointer lock)
  const lastMousePos = useRef<{ x: number; y: number } | null>(null);
  const dragging = useRef(false);

  // Track mousedown position for click-to-pick detection
  const mouseDownPos = useRef<{ x: number; y: number } | null>(null);

  const handleMouseDown = useCallback((e: React.MouseEvent) => {
    const { x, y } = toViewportCoords(e);
    const btn = e.button === 0 ? "left" : e.button === 2 ? "right" : e.button === 1 ? "middle" : null;
    if (!btn) return;
    if (btn === "left") {
      mouseDownPos.current = { x, y };
      // Start tracking box select only when B key is held (Blender-style)
      if (bKeyHeld.current && !e.altKey) {
        const css = toCssCoords(e);
        setBoxSelect({
          startX: x, startY: y, curX: x, curY: y,
          cssStart: css, cssCur: css,
          active: false,
          shift: e.shiftKey || e.ctrlKey || e.metaKey,
        });
      }
    }
    dragging.current = true;
    lastMousePos.current = { x, y };
    // Close context menu on any click
    setContextMenu(null);
    sendInput({ type: "mousedown", x, y, button: btn, clicks: e.detail, shift: e.shiftKey, ctrl: e.ctrlKey || e.metaKey, alt: e.altKey });
  }, [toViewportCoords, toCssCoords, sendInput]);

  const handleMouseUp = useCallback((e: React.MouseEvent) => {
    const { x, y } = toViewportCoords(e);
    const btn = e.button === 0 ? "left" : e.button === 2 ? "right" : e.button === 1 ? "middle" : null;
    if (!btn) return;
    sendInput({ type: "mouseup", x, y, button: btn, shift: e.shiftKey, ctrl: e.ctrlKey || e.metaKey, alt: e.altKey });
    dragging.current = false;
    lastMousePos.current = null;

    if (btn === "left") {
      // Finalise box selection or click-to-pick
      if (boxSelect?.active) {
        const mode = boxSelect.shift ? "toggle" : "replace";
        window.guavaEngine.call("viewport.boxSelect", {
          x1: Math.round(Math.min(boxSelect.startX, x)),
          y1: Math.round(Math.min(boxSelect.startY, y)),
          x2: Math.round(Math.max(boxSelect.startX, x)),
          y2: Math.round(Math.max(boxSelect.startY, y)),
          mode,
        } as never).catch(() => {});
        setBoxSelect(null);
      } else {
        setBoxSelect(null);
        // Click-to-pick: if LMB released close to where it was pressed
        if (mouseDownPos.current && !e.altKey) {
          const dx = x - mouseDownPos.current.x;
          const dy = y - mouseDownPos.current.y;
          if (dx * dx + dy * dy < 16) {
            const mode = (e.shiftKey || e.ctrlKey || e.metaKey) ? "toggle" : "replace";
            window.guavaEngine.call("viewport.pick", { x: Math.round(x), y: Math.round(y), mode } as never).catch(() => {});
          }
        }
      }
      mouseDownPos.current = null;
    }
  }, [toViewportCoords, sendInput, boxSelect]);

  const handleMouseMove = useCallback((e: React.MouseEvent) => {
    const { x, y } = toViewportCoords(e);

    // Calculate delta: prefer movementX/Y, fall back to position diff when dragging
    let deltaX = e.movementX * dpr;
    let deltaY = e.movementY * dpr;
    if (dragging.current && deltaX === 0 && deltaY === 0 && lastMousePos.current) {
      deltaX = x - lastMousePos.current.x;
      deltaY = y - lastMousePos.current.y;
    }
    lastMousePos.current = { x, y };

    sendInput({ type: "mousemove", x, y, deltaX, deltaY, shift: e.shiftKey, ctrl: e.ctrlKey || e.metaKey, alt: e.altKey });

    // Update box selection
    setBoxSelect((prev) => {
      if (!prev) return null;
      const css = toCssCoords(e);
      const dx = x - prev.startX;
      const dy = y - prev.startY;
      const active = prev.active || (dx * dx + dy * dy > 64); // > ~8px threshold
      return { ...prev, curX: x, curY: y, cssCur: css, active };
    });
  }, [toViewportCoords, toCssCoords, sendInput, dpr]);

  const handleWheel = useCallback((e: React.WheelEvent) => {
    sendInput({ type: "wheel", deltaX: -e.deltaX / 120, deltaY: -e.deltaY / 120, shift: e.shiftKey, ctrl: e.ctrlKey || e.metaKey, alt: e.altKey });
  }, [sendInput]);

  const handleContextMenu = useCallback((e: React.MouseEvent) => {
    e.preventDefault();
    const { x, y } = toViewportCoords(e);
    const screenX = e.clientX;
    const screenY = e.clientY;

    // Pick entity at cursor position, then build menu
    window.guavaEngine
      .call("viewport.pick", { x: Math.round(x), y: Math.round(y), mode: "replace" } as never)
      .then(() => {
        // Give a tiny delay for selection state to propagate
        setTimeout(() => buildContextMenu(screenX, screenY), 50);
      })
      .catch(() => {
        buildContextMenu(screenX, screenY);
      });
  }, [toViewportCoords]);

  const buildContextMenu = useCallback((screenX: number, screenY: number) => {
    const entityId = useSceneStore.getState().selectedEntity;
    const meshState = useMeshEditStore.getState();
    const items: MenuItem[] = [];

    // ── Mesh edit operations (when in edit mode) ──
    if (meshState.active) {
      items.push(
        { label: t.meshEdit.extrude, shortcut: "E", onClick: () => meshState.extrude() },
        { label: t.meshEdit.inset, shortcut: "I", onClick: () => meshState.inset() },
        { label: t.meshEdit.bevel, shortcut: "B", onClick: () => meshState.bevel() },
        { label: t.meshEdit.loopCut, shortcut: "Ctrl+R", onClick: () => meshState.loopCut() },
        { label: "---" },
        { label: t.meshEdit.merge, shortcut: "M", onClick: () => meshState.merge() },
        { label: t.meshEdit.delete, shortcut: "X", onClick: () => meshState.deleteMesh() },
        { label: t.meshEdit.duplicate, shortcut: "Shift+D", onClick: () => meshState.duplicate() },
        { label: t.meshEdit.separate, onClick: () => meshState.separate() },
        { label: "---" },
        { label: t.meshEdit.recalcNormals, onClick: () => meshState.recalcNormals() },
        { label: t.meshEdit.pivotToSelection, onClick: () => meshState.pivotToSelection() },
        { label: "---" },
        { label: t.meshEdit.exitEditMode, shortcut: "Esc", onClick: () => {
          meshState.exitEditMode();
          if (useViewportSettingsStore.getState().shadingMode === "wireframe") {
            setShadingMode("solid");
          }
        }},
      );
      setContextMenu({ x: screenX, y: screenY, items });
      return;
    }

    // ── Entity operations (when an entity is selected) ──
    if (entityId != null) {
      items.push(
        {
          label: t.contextMenu.focusSelection,
          shortcut: "F",
          icon: "⊕",
          onClick: () => sendInput({ type: "keydown", key: "f", shift: false, ctrl: false, alt: false }),
        },
        { label: "---" },
        {
          label: t.contextMenu.duplicate,
          shortcut: "Ctrl+D",
          icon: "❏",
          onClick: () => {
            window.guavaEngine.call("scene.duplicateEntity", { entityId } as never).catch(() => {});
          },
        },
        {
          label: t.contextMenu.delete,
          shortcut: "Del",
          icon: "✕",
          onClick: () => {
            window.guavaEngine.call("scene.deleteEntity", { entityId } as never).catch(() => {});
          },
        },
      );

      // Enter edit mode option (when a mesh entity is selected)
      if (meshState.canEnterEditMode) {
        items.push(
          { label: "---" },
          {
            label: t.meshEdit.enterEditMode,
            shortcut: "DblClick",
            onClick: () => meshState.enterEditMode(),
          },
        );
      }

      items.push({ label: "---" });
    }

    // ── Add submenu (always available) ──
    items.push({
      label: t.contextMenu.add,
      icon: "+",
      children: [
        { label: t.contextMenu.addEmpty, icon: "○", onClick: () => spawnActor("empty") },
        { label: "---" },
        { label: t.contextMenu.addCube, icon: "□", onClick: () => spawnActor("cube") },
        { label: t.contextMenu.addSphere, icon: "◎", onClick: () => spawnActor("sphere") },
        { label: t.contextMenu.addPlane, icon: "▬", onClick: () => spawnActor("plane") },
        { label: "---" },
        { label: t.contextMenu.addPointLight, icon: "💡", onClick: () => spawnActor("point_light") },
        { label: t.contextMenu.addSpotLight, icon: "🔦", onClick: () => spawnActor("spot_light") },
        { label: t.contextMenu.addDirLight, icon: "☀", onClick: () => spawnActor("directional_light") },
        { label: "---" },
        { label: t.contextMenu.addCamera, icon: "📷", onClick: () => spawnActor("camera") },
      ],
    });

    // ── Clear selection (when entity is selected) ──
    if (entityId != null) {
      items.push({ label: "---" });
      items.push({
        label: t.contextMenu.clearSelection,
        onClick: () => {
          window.guavaEngine.call("editor.setSelection", { entityIds: [] } as never).catch(() => {});
        },
      });
    }

    setContextMenu({ x: screenX, y: screenY, items });
  }, [t, sendInput]);

  const spawnActor = useCallback((kind: string) => {
    window.guavaEngine.call("scene.spawnActor", { kind } as never).catch(() => {});
  }, []);

  const mapKeyFn = (e: React.KeyboardEvent): string | null => {
    const k = e.key.toLowerCase();
    const m: Record<string, string> = { arrowup: "up", arrowdown: "down", arrowleft: "left", arrowright: "right", " ": "space", ".": "period" };
    if (m[k]) return m[k];
    if (/^[a-z0-9]$/.test(k)) return k;
    if (/^f([1-9]|1[0-2])$/.test(k)) return k;
    if (["tab", "delete", "backspace", "shift", "control", "alt", "escape"].includes(k)) return k === "control" ? "ctrl" : k;
    return null;
  };

  const handleKeyDown = useCallback((e: React.KeyboardEvent) => {
    // Escape exits mesh edit mode and switches back from wireframe
    if (e.key === "Escape" && useMeshEditStore.getState().active) {
      e.preventDefault();
      useMeshEditStore.getState().exitEditMode();
      if (useViewportSettingsStore.getState().shadingMode === "wireframe") {
        setShadingMode("solid");
      }
      return;
    }
    // 1/2/3 switch selection mode in edit mode (Blender-style)
    if (useMeshEditStore.getState().active) {
      const modeMap: Record<string, "vertex" | "edge" | "face"> = { "1": "vertex", "2": "edge", "3": "face" };
      const mode = modeMap[e.key];
      if (mode) {
        e.preventDefault();
        useMeshEditStore.getState().setSelectionMode(mode);
        return;
      }
    }
    const key = mapKeyFn(e);
    if (!key) return;
    if (key === "b") bKeyHeld.current = true;
    sendInput({ type: "keydown", key, shift: e.shiftKey, ctrl: e.ctrlKey || e.metaKey, alt: e.altKey });
  }, [sendInput]);

  const handleKeyUp = useCallback((e: React.KeyboardEvent) => {
    const key = mapKeyFn(e);
    if (!key) return;
    if (key === "b") {
      bKeyHeld.current = false;
      // Cancel pending box select if B released before mouseup
      setBoxSelect(null);
    }
    sendInput({ type: "keyup", key, shift: e.shiftKey, ctrl: e.ctrlKey || e.metaKey, alt: e.altKey });
  }, [sendInput]);

  // Compute element size (width, height) in CSS points.
  const getSize = useCallback(() => {
    const el = ref.current;
    if (!el) return null;
    const rect = el.getBoundingClientRect();
    const w = Math.round(rect.width);
    const h = Math.round(rect.height);
    if (w <= 0 || h <= 0) return null;
    return { w, h };
  }, []);

  // Initialisation: tell the engine our viewport size and start pixel streaming.
  useEffect(() => {
    if (!connected) {
      if (surfaceIdRef.current) {
        window.guavaEngine.viewportDetach().catch(() => {});
        setAttached(false);
      }
      surfaceIdRef.current = 0;
      return;
    }

    // Don't re-init if already attached.
    if (attached) return;

    let cancelled = false;

    const init = async () => {
      // Wait for the element to be laid out.
      let size = getSize();
      for (let wait = 0; !size && wait < 20 && !cancelled; wait++) {
        await new Promise((r) => requestAnimationFrame(r));
        size = getSize();
      }
      if (!size || cancelled) return;

      // Tell the engine the desired viewport dimensions.
      try {
        await window.guavaEngine.call("viewport.setRect", {
          x: 0,
          y: 0,
          width: size.w,
          height: size.h,
        });
      } catch {
        // Engine may not be fully ready yet — retry is handled below.
      }

      // Wait a short moment for the engine to create the surface.
      await new Promise((r) => setTimeout(r, 500));
      if (cancelled) return;

      // Poll until a valid surfaceId is available.
      for (let attempt = 0; attempt < 20 && !cancelled; attempt++) {
        try {
          const res = await window.guavaEngine.call("viewport.getSurfaceId", {});
          if (res.surfaceId && res.surfaceId > 0) {
            surfaceIdRef.current = res.surfaceId;
            shmNameRef.current = res.shmName ?? undefined;
            const ok = await window.guavaEngine.viewportAttachSurface(
              res.surfaceId,
              0,
              0,
              size.w,
              size.h,
              res.shmName ?? undefined,
            );
            if (ok) {
              lastSizeRef.current = size;
              setAttached(true);
              return;
            }
          }
        } catch {
          // Engine not ready yet — keep polling.
        }
        await new Promise((r) => setTimeout(r, 250));
      }
    };

    init();

    return () => {
      cancelled = true;
    };
  }, [connected, attached, getSize]);

  // Track size changes and notify the engine to resize + recreate surface.
  useEffect(() => {
    if (!attached) return;

    let raf: number;

    const tick = () => {
      const size = getSize();
      if (size) {
        const last = lastSizeRef.current;
        if (size.w !== last.w || size.h !== last.h) {
          lastSizeRef.current = size;
          window.guavaEngine
            .call("viewport.setRect", {
              x: 0,
              y: 0,
              width: size.w,
              height: size.h,
            })
            .then(async () => {
              // Give the engine a moment to recreate the surface, then
              // poll for the new surface id.
              await new Promise((r) => setTimeout(r, 100));
              try {
                const res = await window.guavaEngine.call("viewport.getSurfaceId", {});
                if (res.surfaceId && res.surfaceId !== surfaceIdRef.current) {
                  surfaceIdRef.current = res.surfaceId;
                  shmNameRef.current = res.shmName ?? undefined;
                  window.guavaEngine.viewportUpdateSurface(
                    res.surfaceId,
                    res.shmName ?? undefined,
                    res.width,
                    res.height,
                  );
                }
              } catch {
                // Best-effort.
              }
            })
            .catch(() => {});
        }
      }
      raf = requestAnimationFrame(tick);
    };

    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [attached, getSize]);

  // Cleanup on unmount.
  useEffect(() => {
    return () => {
      window.guavaEngine.viewportDetach().catch(() => {});
    };
  }, []);

  // WebGL pixel rendering: subscribe to viewport:pixels and display via GPU.
  // Pixels arrive as BGRA from Vulkan/Metal readback; a fragment shader swaps
  // R↔B on the GPU, avoiding the slow per-pixel JS conversion.
  //
  // Two paths:
  //   A) SharedArrayBuffer (macOS): renderer polls SAB via rAF + Atomics
  //   B) IPC fallback (Linux): renderer receives pixels via IPC callback
  useEffect(() => {
    if (!attached) return;
    const canvas = canvasRef.current;
    if (!canvas) return;

    const gl = canvas.getContext("webgl", { alpha: false, antialias: false, preserveDrawingBuffer: true });
    if (!gl) {
      console.error("[Viewport] WebGL unavailable — pixel display disabled");
      return;
    }

    // ── Shaders ──────────────────────────────────────
    const compile = (type: number, src: string) => {
      const s = gl.createShader(type)!;
      gl.shaderSource(s, src);
      gl.compileShader(s);
      return s;
    };
    const vs = compile(gl.VERTEX_SHADER, `
      attribute vec2 aPos;
      varying vec2 vUV;
      void main() {
        vUV = aPos * 0.5 + 0.5;
        vUV.y = 1.0 - vUV.y;
        gl_Position = vec4(aPos, 0.0, 1.0);
      }
    `);
    const fs = compile(gl.FRAGMENT_SHADER, `
      precision mediump float;
      varying vec2 vUV;
      uniform sampler2D uTex;
      void main() {
        vec4 c = texture2D(uTex, vUV);
        gl_FragColor = vec4(c.b, c.g, c.r, c.a);
      }
    `);
    const prog = gl.createProgram()!;
    gl.attachShader(prog, vs);
    gl.attachShader(prog, fs);
    gl.linkProgram(prog);
    gl.useProgram(prog);

    // ── Fullscreen quad ──────────────────────────────
    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    const aPos = gl.getAttribLocation(prog, "aPos");
    gl.enableVertexAttribArray(aPos);
    gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 0, 0);

    // ── Texture ──────────────────────────────────────
    const tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

    // ── Upload helper ────────────────────────────────
    let texW = 0, texH = 0;  // track current texture dimensions
    const uploadAndDraw = (pixels: Uint8Array, width: number, height: number) => {
      if (canvas.width !== width || canvas.height !== height) {
        canvas.width = width;
        canvas.height = height;
        gl.viewport(0, 0, width, height);
      }
      if (width === texW && height === texH) {
        // Same size: sub-image update avoids texture reallocation
        gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
      } else {
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
        texW = width;
        texH = height;
      }
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    };

    // ── Path A: SharedArrayBuffer (zero-IPC, rAF polling) ──
    let sabRef: SharedArrayBuffer | null = null;
    let sabHeader: Uint32Array | null = null;
    let sabPixels: Uint8Array | null = null;
    let lastGeneration = 0;
    let raf = 0;

    const unsubSAB = window.guavaEngine.onViewportSharedBuffer((sab) => {
      sabRef = sab;
      sabHeader = new Uint32Array(sab, 0, 4); // [width, height, generation, readIndex]
      sabPixels = new Uint8Array(sab, 16);     // pixel data starts at byte 16
    });

    const tick = () => {
      if (sabHeader && sabPixels) {
        const gen = Atomics.load(sabHeader, 2);
        if (gen !== lastGeneration) {
          lastGeneration = gen;
          const width = sabHeader[0];
          const height = sabHeader[1];
          const bufIdx = sabHeader[3]; // ping-pong: which buffer to read (0 or 1)
          if (width > 0 && height > 0) {
            // Double-buffered: each buffer is half of the pixel region.
            const maxPixelBytes = (sabRef!.byteLength - 16) / 2;
            const offset = 16 + bufIdx * maxPixelBytes;
            const src = new Uint8Array(sabRef!, offset, width * height * 4);
            uploadAndDraw(src, width, height);
          }
        }
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);

    // ── Path B: IPC fallback ─────────────────────────
    const unsub = window.guavaEngine.onViewportPixels((pixels, width, height) => {
      // Skip IPC path if SAB is active
      if (sabHeader) return;
      const src = new Uint8Array(
        pixels.buffer ?? pixels,
        (pixels as { byteOffset?: number }).byteOffset ?? 0,
        (pixels as { byteLength?: number }).byteLength ?? (width * height * 4),
      );
      uploadAndDraw(src, width, height);
    });

    return () => {
      cancelAnimationFrame(raf);
      unsubSAB();
      unsub();
      gl.deleteTexture(tex);
      gl.deleteBuffer(buf);
      gl.deleteProgram(prog);
      gl.deleteShader(vs);
      gl.deleteShader(fs);
    };
  }, [attached]);

  return (
    <div
      ref={ref}
      style={styles.container}
      tabIndex={0}
      onMouseDown={handleMouseDown}
      onMouseUp={handleMouseUp}
      onMouseMove={handleMouseMove}
      onWheel={handleWheel}
      onContextMenu={handleContextMenu}
      onKeyDown={handleKeyDown}
      onKeyUp={handleKeyUp}
    >
      <canvas ref={canvasRef} style={styles.canvas} />
      {boxSelect?.active && (() => {
        const left = Math.min(boxSelect.cssStart.x, boxSelect.cssCur.x);
        const top = Math.min(boxSelect.cssStart.y, boxSelect.cssCur.y);
        const w = Math.abs(boxSelect.cssCur.x - boxSelect.cssStart.x);
        const h = Math.abs(boxSelect.cssCur.y - boxSelect.cssStart.y);
        return (
          <div style={{
            position: "absolute",
            left, top, width: w, height: h,
            border: "1px solid rgba(137, 180, 250, 0.8)",
            background: "rgba(137, 180, 250, 0.12)",
            pointerEvents: "none",
            zIndex: 20,
          }} />
        );
      })()}
      {!attached && (
        <div style={styles.placeholder}>
          <p style={{ margin: 0, fontSize: 14 }}>{t.viewport.title}</p>
          <p style={{ margin: "4px 0 0", fontSize: 12, opacity: 0.5 }}>
            {connected ? t.viewport.syncingEngine : t.viewport.waitingForEngine}
          </p>
        </div>
      )}
      {/* Floating overlays on top of the canvas */}
      {connected && (
        <>
          <div
            style={styles.shadingOverlay}
            onMouseDown={(e) => e.stopPropagation()}
            onPointerDown={(e) => e.stopPropagation()}
          >
            {(["solid", "material", "rendered", "wireframe"] as ShadingMode[]).map((mode) => {
              const Icon = SHADING_ICON_COMPONENTS[mode];
              const labels: Record<ShadingMode, string> = {
                solid: t.renderSettings.solid,
                material: t.renderSettings.material,
                rendered: t.renderSettings.rendered,
                wireframe: t.renderSettings.wireframe,
              };
              return (
                <button
                  key={mode}
                  title={labels[mode]}
                  style={{
                    ...styles.shadingButton,
                    ...(shadingMode === mode ? styles.shadingButtonActive : {}),
                  }}
                  onClick={() => handleShadingChange(mode)}
                >
                  <Icon size={14} color={shadingMode === mode ? "#89b4fa" : "#cdd6f4"} />
                </button>
              );
            })}
          </div>
          <MeshEditToolbar />
          <ViewportMetricsOverlay />
          <div style={styles.viewCubeOverlay}>
            <ViewCube />
          </div>
        </>
      )}
      {contextMenu && (
        <ContextMenu
          x={contextMenu.x}
          y={contextMenu.y}
          items={contextMenu.items}
          onClose={() => setContextMenu(null)}
        />
      )}
    </div>
  );
}

// ── Viewport FPS / Frame Time Overlay ────────────────────────────

function ViewportMetricsOverlay() {
  const fpsDisplay = useViewportSettingsStore((s) => s.fpsDisplay);
  const [metrics, setMetrics] = useLocalState<{ fps: number; frameTimeMs: number; drawCalls: number; triangles: number } | null>(null);

  useEffect(() => {
    const cleanup = window.guavaEngine.onEvent((event, data) => {
      if (event === "on:viewport.metrics") {
        setMetrics(data as { fps: number; frameTimeMs: number; drawCalls: number; triangles: number });
      }
    });
    return cleanup;
  }, []);

  if (!metrics || fpsDisplay === "none") return null;

  const fpsColor = metrics.fps >= 55 ? "#a6e3a1" : metrics.fps >= 30 ? "#f9e2af" : "#f38ba8";

  return (
    <div style={metricsStyles.container}>
      <span style={{ ...metricsStyles.value, color: fpsColor }}>{metrics.fps}</span>
      <span style={metricsStyles.label}>FPS</span>
      <span style={metricsStyles.sep} />
      <span style={metricsStyles.value}>{metrics.frameTimeMs}</span>
      <span style={metricsStyles.label}>ms</span>
      <span style={metricsStyles.sep} />
      <span style={metricsStyles.value}>{formatK(metrics.drawCalls)}</span>
      <span style={metricsStyles.label}>DC</span>
      <span style={metricsStyles.sep} />
      <span style={metricsStyles.value}>{formatK(metrics.triangles)}</span>
      <span style={metricsStyles.label}>Tri</span>
    </div>
  );
}

function formatK(n: number): string {
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(1) + "M";
  if (n >= 1_000) return (n / 1_000).toFixed(1) + "K";
  return String(n);
}

const metricsStyles: Record<string, React.CSSProperties> = {
  container: {
    position: "absolute",
    bottom: 8,
    left: 8,
    zIndex: 10,
    display: "flex",
    alignItems: "baseline",
    gap: 3,
    background: "rgba(24, 24, 37, 0.75)",
    backdropFilter: "blur(8px)",
    WebkitBackdropFilter: "blur(8px)",
    borderRadius: 6,
    padding: "3px 8px",
    boxShadow: "0 2px 8px rgba(0,0,0,0.3)",
    border: "1px solid rgba(69, 71, 90, 0.4)",
    fontFamily: "monospace",
    fontSize: 11,
    color: "#a6adc8",
    pointerEvents: "none",
  },
  value: { fontWeight: 600, fontSize: 12 },
  label: { fontSize: 9, opacity: 0.6, marginRight: 2 },
  sep: { width: 1, height: 10, background: "rgba(69, 71, 90, 0.6)", margin: "0 2px", alignSelf: "center" },
};

const styles: Record<string, React.CSSProperties> = {
  container: {
    width: "100%",
    height: "100%",
    position: "relative",
    overflow: "hidden",
    background: "#11111b",
  },
  canvas: {
    position: "absolute",
    inset: 0,
    width: "100%",
    height: "100%",
    imageRendering: "pixelated",
  },
  shadingOverlay: {
    position: "absolute",
    top: 8,
    left: 8,
    zIndex: 10,
    display: "flex",
    gap: 2,
    background: "rgba(24, 24, 37, 0.75)",
    backdropFilter: "blur(8px)",
    WebkitBackdropFilter: "blur(8px)",
    borderRadius: 6,
    padding: "3px 4px",
    boxShadow: "0 2px 8px rgba(0,0,0,0.3)",
    border: "1px solid rgba(69, 71, 90, 0.4)",
  },
  viewCubeOverlay: {
    position: "absolute",
    top: 4,
    right: 4,
    zIndex: 10,
  },
  shadingButton: {
    background: "transparent",
    border: "1px solid transparent",
    borderRadius: 4,
    color: "#a6adc8",
    cursor: "pointer",
    padding: "4px 8px",
    fontSize: 13,
    lineHeight: "1",
    minWidth: 28,
    textAlign: "center" as const,
    transition: "all 0.1s",
  },
  shadingButtonActive: {
    background: "rgba(69, 71, 90, 0.8)",
    border: "1px solid #89b4fa",
    color: "#89b4fa",
  },
  toolbarSeparator: {
    width: 1,
    alignSelf: "stretch",
    margin: "2px 4px",
    background: "rgba(69, 71, 90, 0.6)",
  },
  placeholder: {
    position: "absolute",
    inset: 0,
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    justifyContent: "center",
    color: "#cdd6f4",
    opacity: 0.3,
    pointerEvents: "none",
  },
};
