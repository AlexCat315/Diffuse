import React, { useEffect, useRef, useState, useCallback } from "react";
import { useI18n } from "../i18n";
import { ViewCube } from "./ViewCube";
import { useConnectionStore, useSceneStore } from "../store";
import { ContextMenu, type MenuItem } from "../components/ContextMenu";

type ShadingMode = "solid" | "material" | "rendered" | "wireframe";

const SHADING_ICONS: Record<ShadingMode, string> = {
  solid: "◻",
  material: "◼",
  rendered: "◉",
  wireframe: "▦",
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
  const [attached, setAttached] = useState(false);
  const surfaceIdRef = useRef(0);
  const shmNameRef = useRef<string | undefined>(undefined);
  const lastSizeRef = useRef({ w: 0, h: 0 });
  const [shadingMode, setShadingMode] = useState<ShadingMode>("material");
  const [contextMenu, setContextMenu] = useState<{ x: number; y: number; items: MenuItem[] } | null>(null);
  const selectedEntity = useSceneStore((s) => s.selectedEntity);

  // Fetch current shading mode on connect
  useEffect(() => {
    if (!connected) return;
    window.guavaEngine.call("viewport.getRenderSettings", {})
      .then((res) => { if (res.shadingMode) setShadingMode(res.shadingMode as ShadingMode); })
      .catch(() => {});
  }, [connected]);

  const handleShadingChange = useCallback((mode: ShadingMode) => {
    setShadingMode(mode);
    window.guavaEngine.call("viewport.setRenderSettings", { shadingMode: mode } as never).catch(() => {});
  }, []);

  // ── Input forwarding to the engine ─────────────────────────────
  const dpr = window.devicePixelRatio || 1;

  const toViewportCoords = useCallback((e: React.MouseEvent) => {
    const el = ref.current;
    if (!el) return { x: 0, y: 0 };
    const rect = el.getBoundingClientRect();
    return { x: (e.clientX - rect.left) * dpr, y: (e.clientY - rect.top) * dpr };
  }, [dpr]);

  const sendInput = useCallback((params: Record<string, unknown>) => {
    window.guavaEngine.call("viewport.sendInput", params as never).catch(() => {});
  }, []);

  // Track mousedown position for click-to-pick detection
  const mouseDownPos = useRef<{ x: number; y: number } | null>(null);

  const handleMouseDown = useCallback((e: React.MouseEvent) => {
    const { x, y } = toViewportCoords(e);
    const btn = e.button === 0 ? "left" : e.button === 2 ? "right" : e.button === 1 ? "middle" : null;
    if (!btn) return;
    if (btn === "left") mouseDownPos.current = { x, y };
    sendInput({ type: "mousedown", x, y, button: btn, clicks: e.detail, shift: e.shiftKey, ctrl: e.ctrlKey || e.metaKey, alt: e.altKey });
  }, [toViewportCoords, sendInput]);

  const handleMouseUp = useCallback((e: React.MouseEvent) => {
    const { x, y } = toViewportCoords(e);
    const btn = e.button === 0 ? "left" : e.button === 2 ? "right" : e.button === 1 ? "middle" : null;
    if (!btn) return;
    sendInput({ type: "mouseup", x, y, button: btn, shift: e.shiftKey, ctrl: e.ctrlKey || e.metaKey, alt: e.altKey });

    // Click-to-pick: if LMB released close to where it was pressed, trigger entity pick
    if (btn === "left" && mouseDownPos.current && !e.altKey) {
      const dx = x - mouseDownPos.current.x;
      const dy = y - mouseDownPos.current.y;
      if (dx * dx + dy * dy < 16) { // < 4px movement
        const mode = (e.shiftKey || e.ctrlKey || e.metaKey) ? "toggle" : "replace";
        window.guavaEngine.call("viewport.pick", { x: Math.round(x), y: Math.round(y), mode } as never).catch(() => {});
      }
      mouseDownPos.current = null;
    }
  }, [toViewportCoords, sendInput]);

  const handleMouseMove = useCallback((e: React.MouseEvent) => {
    const { x, y } = toViewportCoords(e);
    sendInput({ type: "mousemove", x, y, deltaX: e.movementX * dpr, deltaY: e.movementY * dpr, shift: e.shiftKey, ctrl: e.ctrlKey || e.metaKey, alt: e.altKey });
  }, [toViewportCoords, sendInput, dpr]);

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
    const items: MenuItem[] = [];

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
        { label: "---" },
      );
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
    const key = mapKeyFn(e);
    if (!key) return;
    sendInput({ type: "keydown", key, shift: e.shiftKey, ctrl: e.ctrlKey || e.metaKey, alt: e.altKey });
  }, [sendInput]);

  const handleKeyUp = useCallback((e: React.KeyboardEvent) => {
    const key = mapKeyFn(e);
    if (!key) return;
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

    // ── Subscribe to pixel data ──────────────────────
    const unsub = window.guavaEngine.onViewportPixels((pixels, width, height) => {
      if (canvas.width !== width || canvas.height !== height) {
        canvas.width = width;
        canvas.height = height;
        gl.viewport(0, 0, width, height);
      }
      const src = new Uint8Array(
        pixels.buffer ?? pixels,
        (pixels as { byteOffset?: number }).byteOffset ?? 0,
        (pixels as { byteLength?: number }).byteLength ?? (width * height * 4),
      );
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, src);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    });

    return () => {
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
          <div style={styles.shadingOverlay}>
            {(["solid", "material", "rendered", "wireframe"] as ShadingMode[]).map((mode) => (
              <button
                key={mode}
                title={mode.charAt(0).toUpperCase() + mode.slice(1)}
                style={{
                  ...styles.shadingButton,
                  ...(shadingMode === mode ? styles.shadingButtonActive : {}),
                }}
                onClick={() => handleShadingChange(mode)}
              >
                {SHADING_ICONS[mode]}
              </button>
            ))}
          </div>
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
    borderColor: "#89b4fa",
    color: "#89b4fa",
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
