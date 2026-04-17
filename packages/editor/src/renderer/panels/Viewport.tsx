import React, { useEffect, useRef, useCallback } from "react";
import { useLocalState } from "../store/local-state";
import { useI18n } from "../i18n";
import { keybindingService } from "../keybinding-service";
import { ViewCube } from "./ViewCube";
import { useConnectionStore, useSceneStore, useViewportSettingsStore, useMeshEditStore } from "../store";
import { ContextMenu, type MenuItem } from "../components/ContextMenu";
import { loadGizmoShortcuts } from "../store/shortcut-config";
import {
  IconCrosshair, IconClose, IconPlus, IconBox, IconCamera,
  IconLightPoint, IconLightSpot, IconLightSun, IconModel, IconFilledCircle, IconGrid,
} from "../components/Icons";
import { engine } from "../engine-client";
import {
  viewportAttachSurface, viewportUpdateSurface, viewportDetach,
  viewportUpdateBounds,
  onViewportOverlayActive, onViewportPixels, onViewportSharedBuffer,
} from "../citron-api";


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
  const fetchViewportSettings = useViewportSettingsStore((s) => s.fetchFromEngine);
  const [contextMenu, setContextMenu] = useLocalState<{ x: number; y: number; items: MenuItem[] } | null>(null);
  const selectedEntity = useSceneStore((s) => s.selectedEntity);
  const [modelDragOver, setModelDragOver] = useLocalState(false);
  const dropCountRef = useRef(0);

  // ── Native overlay state (macOS zero-copy) ──────────────────
  // When active, the CALayer in the native addon displays the IOSurface
  // directly — no WebGL canvas needed.  HTML overlays (ViewCube, metrics)
  // still render on top via Chromium.
  const [nativeOverlay, setNativeOverlay] = useLocalState(false);

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

  // Listen for native overlay activation from main process.
  useEffect(() => {
    const unsub = onViewportOverlayActive((active) => {
      setNativeOverlay(active);
    });
    return unsub;
  }, []);

  // When native overlay is active, the IOSurface child window sits BELOW the
  // browser window.  The viewport area CSS is transparent, letting the 3D scene
  // show through from behind.  React overlays (ViewCube, metrics) render
  // normally on top as part of the browser's composited content.

  // Report viewport bounds to main process so the native overlay CALayer
  // can be positioned to match the div.  Also clear ancestor backgrounds
  // so the IOSurface below shows through.
  useEffect(() => {
    if (!nativeOverlay || !ref.current) return;
    const el = ref.current;

    // Set chroma-key background on the viewport container itself.
    // The native side matches this exact color (#010201) and replaces
    // matching pixels with transparent, letting the 3D scene show through.
    // UI overlays (ViewCube, metrics) have different colors and are preserved.
    const savedElBg = el.style.background;
    el.style.setProperty("background", "#010201", "important");

    // Walk up ancestors and clear opaque backgrounds so the IOSurface
    // (behind the browser window) shows through the viewport area.
    const modified: { el: HTMLElement; saved: string }[] = [];
    let node: HTMLElement | null = el.parentElement;
    while (node) {
      const bg = getComputedStyle(node).backgroundColor;
      if (bg && bg !== "rgba(0, 0, 0, 0)" && bg !== "transparent") {
        modified.push({ el: node, saved: node.style.background });
        node.style.setProperty("background", "transparent", "important");
      }
      node = node.parentElement;
    }

    const report = () => {
      const rect = el.getBoundingClientRect();
      viewportUpdateBounds(rect.x, rect.y, rect.width, rect.height);
    };
    report(); // initial
    const ro = new ResizeObserver(report);
    ro.observe(el);
    window.addEventListener("resize", report);
    return () => {
      ro.disconnect();
      window.removeEventListener("resize", report);
      // Restore original backgrounds when overlay deactivates.
      el.style.background = savedElBg;
      for (const { el: n, saved } of modified) {
        n.style.background = saved;
      }
    };
  }, [nativeOverlay]);

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
    engine.call("viewport.sendInput", params as never).catch(() => {});
  }, []);

  // Track B key for box-select activation (Blender-style)
  const bKeyHeld = useRef(false);

  // Track last mouse position for delta calculation (movementX/Y is 0 without pointer lock)
  const lastMousePos = useRef<{ x: number; y: number } | null>(null);
  const dragging = useRef(false);

  // Throttle mousemove RPC to avoid flooding the engine (~60 fps cap)
  const lastMoveTime = useRef(0);

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
        engine.call("viewport.boxSelect", {
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
            // In mesh edit mode, element picking is handled engine-side via raycasting
            if (!useMeshEditStore.getState().active) {
              const mode = (e.shiftKey || e.ctrlKey || e.metaKey) ? "toggle" : "replace";
              engine.call("viewport.pick", { x: Math.round(x), y: Math.round(y), mode } as never).catch(() => {});
            }
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

    // Throttle RPC to ~60 fps (16ms) to avoid flooding the engine
    const now = performance.now();
    if (now - lastMoveTime.current >= 16) {
      lastMoveTime.current = now;
      sendInput({ type: "mousemove", x, y, deltaX, deltaY, shift: e.shiftKey, ctrl: e.ctrlKey || e.metaKey, alt: e.altKey });
    }

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
    engine
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
        { label: t.meshEdit.exitEditMode, shortcut: "Esc", onClick: () => meshState.exitEditMode() },
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
          icon: <IconCrosshair size={12} />,
          onClick: () => sendInput({ type: "keydown", key: "f", shift: false, ctrl: false, alt: false }),
        },
        { label: "---" },
        {
          label: t.contextMenu.duplicate,
          shortcut: "Ctrl+D",
          icon: <IconModel size={12} />,
          onClick: () => {
            engine.call("scene.duplicateEntity", { entityId } as never).catch(() => {});
          },
        },
        {
          label: t.contextMenu.delete,
          shortcut: "Del",
          icon: <IconClose size={12} />,
          onClick: () => {
            engine.call("scene.deleteEntity", { entityId } as never).catch(() => {});
          },
        },
      );

      items.push({ label: "---" });
    }

    // ── Add submenu (always available) ──
    items.push({
      label: t.contextMenu.add,
      icon: <IconPlus size={12} />,
      children: [
        { label: t.contextMenu.addEmpty, icon: <IconCrosshair size={12} />, onClick: () => spawnActor("empty") },
        { label: "---" },
        { label: t.contextMenu.addCube, icon: <IconBox size={12} />, onClick: () => spawnActor("cube") },
        { label: t.contextMenu.addSphere, icon: <IconFilledCircle size={12} />, onClick: () => spawnActor("sphere") },
        { label: t.contextMenu.addPlane, icon: <IconGrid size={12} />, onClick: () => spawnActor("plane") },
        { label: "---" },
        { label: t.contextMenu.addPointLight, icon: <IconLightPoint size={12} />, onClick: () => spawnActor("point_light") },
        { label: t.contextMenu.addSpotLight, icon: <IconLightSpot size={12} />, onClick: () => spawnActor("spot_light") },
        { label: t.contextMenu.addDirLight, icon: <IconLightSun size={12} />, onClick: () => spawnActor("directional_light") },
        { label: "---" },
        { label: t.contextMenu.addCamera, icon: <IconCamera size={12} />, onClick: () => spawnActor("camera") },
      ],
    });

    // ── Clear selection (when entity is selected) ──
    if (entityId != null) {
      items.push({ label: "---" });
      items.push({
        label: t.contextMenu.clearSelection,
        onClick: () => {
          engine.call("editor.setSelection", { entityIds: [] } as never).catch(() => {});
        },
      });
    }

    setContextMenu({ x: screenX, y: screenY, items });
  }, [t, sendInput]);

  const spawnActor = useCallback((kind: string) => {
    engine.call("scene.spawnActor", { kind } as never).catch(() => {});
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

  // Track which keys were consumed by gizmo shortcuts (prevent forwarding keyup to engine)
  const consumedGizmoKeys = useRef(new Set<string>());

  const handleKeyDown = useCallback((e: React.KeyboardEvent) => {
    // Escape exits mesh edit mode
    if (e.key === "Escape" && useMeshEditStore.getState().active) {
      e.preventDefault();
      useMeshEditStore.getState().exitEditMode();
      return;
    }

    if (useMeshEditStore.getState().active) {
      // ── Mesh edit mode: 1/2/3 switch selection mode ────────────────
      const modeMap: Record<string, "vertex" | "edge" | "face"> = { "1": "vertex", "2": "edge", "3": "face" };
      const mode = modeMap[e.key];
      if (mode) {
        e.preventDefault();
        useMeshEditStore.getState().setSelectionMode(mode);
        return;
      }
      // All other keys forwarded to engine
    } else {
      // ── Object mode: gizmo + entity shortcuts handled by keybinding service.
      // Skip forwarding these to engine to avoid double-processing.
      const k = e.key.toLowerCase();
      if (!e.ctrlKey && !e.metaKey && !e.altKey) {
        if (k === "delete" || k === "backspace" || k === "tab") return;
        const gizmoKeys = loadGizmoShortcuts();
        const gizmoKeySet = new Set([
          (gizmoKeys.select?.key ?? "q").toLowerCase(),
          (gizmoKeys.translate?.key ?? "w").toLowerCase(),
          (gizmoKeys.rotate?.key ?? "e").toLowerCase(),
          (gizmoKeys.scale?.key ?? "r").toLowerCase(),
        ]);
        if (gizmoKeySet.has(k)) return;
      }
    }

    const key = mapKeyFn(e);
    if (!key) return;
    // Prevent default browser/Electron behavior for keys we handle
    // Tab: prevents focus traversal; Delete/Backspace: prevents browser navigation
    if (key === "tab" || key === "delete" || key === "backspace") e.preventDefault();
    if (key === "b") bKeyHeld.current = true;
    sendInput({ type: "keydown", key, shift: e.shiftKey, ctrl: e.ctrlKey || e.metaKey, alt: e.altKey });
  }, [sendInput]);

  const handleKeyUp = useCallback((e: React.KeyboardEvent) => {
    const key = mapKeyFn(e);
    if (!key) return;
    // Don't forward keyup to engine for keys consumed by gizmo shortcuts
    const k = e.key.toLowerCase();
    if (consumedGizmoKeys.current.has(k)) {
      consumedGizmoKeys.current.delete(k);
      return;
    }
    if (key === "b") {
      bKeyHeld.current = false;
      // Cancel pending box select if B released before mouseup
      setBoxSelect(null);
    }
    sendInput({ type: "keyup", key, shift: e.shiftKey, ctrl: e.ctrlKey || e.metaKey, alt: e.altKey });
  }, [sendInput]);

  // Compute element size in **physical pixels** (matching DPR-scaled pick coords).
  const getSize = useCallback(() => {
    const el = ref.current;
    if (!el) return null;
    const rect = el.getBoundingClientRect();
    const w = Math.round(rect.width * dpr);
    const h = Math.round(rect.height * dpr);
    if (w <= 0 || h <= 0) return null;
    return { w, h };
  }, [dpr]);

  // Initialisation: tell the engine our viewport size and start pixel streaming.
  useEffect(() => {
    if (!connected) {
      if (surfaceIdRef.current) {
        viewportDetach().catch(() => {});
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
        await engine.call("viewport.setRect", {
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
          const res = await engine.call("viewport.getSurfaceId", {});
          if (res.surfaceId && res.surfaceId > 0) {
            surfaceIdRef.current = res.surfaceId;
            shmNameRef.current = res.shmName ?? undefined;
            const ok = await viewportAttachSurface(
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
    const el = ref.current;
    if (!el) return;

    const handleResize = () => {
      const size = getSize();
      if (!size) return;
      const last = lastSizeRef.current;
      if (size.w !== last.w || size.h !== last.h) {
        lastSizeRef.current = size;
        engine
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
              const res = await engine.call("viewport.getSurfaceId", {});
              if (res.surfaceId && res.surfaceId !== surfaceIdRef.current) {
                surfaceIdRef.current = res.surfaceId;
                shmNameRef.current = res.shmName ?? undefined;
                viewportUpdateSurface(
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
    };

    const ro = new ResizeObserver(handleResize);
    ro.observe(el);
    return () => ro.disconnect();
  }, [attached, getSize]);

  // Cleanup on unmount.
  useEffect(() => {
    return () => {
      viewportDetach().catch(() => {});
    };
  }, []);

  // Register viewport keybinding contexts with the central keybinding service.
  // Gizmo shortcuts (Q/W/E/R) are global-scope but suppressed in mesh edit mode.
  // Entity management (Delete/Backspace) and Tab forwarding are also registered.
  useEffect(() => {
    const gizmoKeys = loadGizmoShortcuts();
    const { changeGizmoMode } = useSceneStore.getState();

    // Gizmo context — active when NOT in mesh edit mode
    const unregGizmo = keybindingService.registerAt(0, {
      id: "viewport.gizmo",
      when: () => !useMeshEditStore.getState().active,
      bindings: [
        { id: "gizmo.select", combo: { key: gizmoKeys.select?.key ?? "q" }, handler: () => { changeGizmoMode("none"); return true; } },
        { id: "gizmo.translate", combo: { key: gizmoKeys.translate?.key ?? "w" }, handler: () => { changeGizmoMode("translate"); return true; } },
        { id: "gizmo.rotate", combo: { key: gizmoKeys.rotate?.key ?? "e" }, handler: () => { changeGizmoMode("rotate"); return true; } },
        { id: "gizmo.scale", combo: { key: gizmoKeys.scale?.key ?? "r" }, handler: () => { changeGizmoMode("scale"); return true; } },
        { id: "entity.delete", combo: { key: "delete" }, handler: () => {
          const { selectedEntity: sel, setSelectedEntity, refreshHierarchy } = useSceneStore.getState();
          if (sel != null) { engine.call("scene.deleteEntity", { entityId: sel }); setSelectedEntity(null); refreshHierarchy(); }
          return true;
        }},
        { id: "entity.backspace", combo: { key: "backspace" }, handler: () => {
          const { selectedEntity: sel, setSelectedEntity, refreshHierarchy } = useSceneStore.getState();
          if (sel != null) { engine.call("scene.deleteEntity", { entityId: sel }); setSelectedEntity(null); refreshHierarchy(); }
          return true;
        }},
        { id: "viewport.tab", combo: { key: "tab" }, handler: (e) => {
          engine.call("viewport.sendInput", {
            type: "keydown", key: "tab", shift: e.shiftKey, ctrl: e.ctrlKey || e.metaKey, alt: e.altKey,
          } as never).catch(() => {});
          return true;
        }},
      ],
    });

    return () => { unregGizmo(); };
  }, []);

  // WebGL pixel rendering — ONLY used when native overlay is not active.
  // When nativeOverlay is true, the CALayer displays the IOSurface directly
  // and no WebGL canvas / SAB polling is needed.
  //
  // Pixels arrive as BGRA from Vulkan/Metal readback; a fragment shader swaps
  // R↔B on the GPU, avoiding the slow per-pixel JS conversion.
  //
  // Two paths:
  //   A) SharedArrayBuffer (macOS fallback): renderer polls SAB via rAF + Atomics
  //   B) IPC fallback (Linux): renderer receives pixels via IPC callback
  useEffect(() => {
    if (!attached || nativeOverlay) return;
    const canvas = canvasRef.current;
    if (!canvas) return;

    const gl = canvas.getContext("webgl", { alpha: false, antialias: false, desynchronized: true, preserveDrawingBuffer: false });
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
    let lastUploadTime = 0;
    const MIN_UPLOAD_INTERVAL = 16; // Cap texture uploads to ~60 fps

    const unsubSAB = onViewportSharedBuffer((sab) => {
      sabRef = sab;
      sabHeader = new Uint32Array(sab, 0, 4); // [width, height, generation, readIndex]
      sabPixels = new Uint8Array(sab, 16);     // pixel data starts at byte 16
    });

    const tick = () => {
      if (sabHeader && sabPixels) {
        const gen = Atomics.load(sabHeader, 2);
        if (gen !== lastGeneration) {
          const now = performance.now();
          if (now - lastUploadTime >= MIN_UPLOAD_INTERVAL) {
            lastUploadTime = now;
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
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);

    // ── Path B: IPC fallback ─────────────────────────
    const unsub = onViewportPixels((pixels, width, height) => {
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
  }, [attached, nativeOverlay]);

  return (
    <div
      ref={ref}
      style={{
        ...styles.container,
        // When the native overlay is active, the IOSurface child window sits
        // BELOW this browser window.  Make the viewport transparent so the
        // 3D scene shows through.  React overlays render on top naturally.
        ...(nativeOverlay ? { background: "#010201" } : {}),
        ...(modelDragOver ? { outline: "2px dashed #89b4fa", outlineOffset: -2, background: "rgba(137,180,250,0.04)" } : {}),
      }}
      tabIndex={0}
      onMouseDown={handleMouseDown}
      onMouseUp={handleMouseUp}
      onMouseMove={handleMouseMove}
      onWheel={handleWheel}
      onContextMenu={handleContextMenu}
      onKeyDown={handleKeyDown}
      onKeyUp={handleKeyUp}
      onDragOver={(e) => {
        if (e.dataTransfer.types.includes("application/x-guava-asset-path")) {
          e.preventDefault();
          e.dataTransfer.dropEffect = "link";
        }
      }}
      onDragEnter={(e) => {
        if (e.dataTransfer.types.includes("application/x-guava-asset-path")) {
          dropCountRef.current++;
          setModelDragOver(true);
        }
      }}
      onDragLeave={() => {
        dropCountRef.current--;
        if (dropCountRef.current <= 0) {
          dropCountRef.current = 0;
          setModelDragOver(false);
        }
      }}
      onDrop={async (e) => {
        dropCountRef.current = 0;
        setModelDragOver(false);
        const assetPath = e.dataTransfer.getData("application/x-guava-asset-path");
        const assetType = e.dataTransfer.getData("application/x-guava-asset-type");
        if (!assetPath || assetType !== "model") return;
        e.preventDefault();
        try {
          await engine.call("assets.importModel", { sourcePath: assetPath });
        } catch (err) {
          console.error("Failed to import model:", err);
        }
      }}
    >
      <canvas ref={canvasRef} style={{ ...styles.canvas, ...(nativeOverlay ? { display: "none" } : {}) }} />
      {modelDragOver && (
        <div style={{
          position: "absolute", inset: 0,
          display: "flex", alignItems: "center", justifyContent: "center",
          background: "rgba(137,180,250,0.08)",
          pointerEvents: "none",
          zIndex: 10,
        }}>
          <span style={{ color: "#89b4fa", fontSize: 13, fontWeight: 500, letterSpacing: 0.3 }}>
            <IconModel size={18} color="#89b4fa" style={{ marginRight: 6 }} /> Drop model here
          </span>
        </div>
      )}
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
      {/* Floating overlays on top of the canvas / native overlay */}
      {connected && (
        <>
          <div style={styles.metricsOverlay}>
            <ViewportMetricsOverlay />
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

// ── Viewport FPS / Frame Time Overlay ────────────────────────────

function ViewportMetricsOverlay() {
  const fpsDisplay = useViewportSettingsStore((s) => s.fpsDisplay);
  const [metrics, setMetrics] = useLocalState<{ fps: number; frameTimeMs: number; drawCalls: number; triangles: number } | null>(null);

  useEffect(() => {
    const cleanup = engine.onNotification((event, data) => {
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
    display: "flex",
    alignItems: "baseline",
    gap: 3,
    background: "rgba(24, 24, 37, 0.92)",
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
  viewCubeOverlay: {
    position: "absolute",
    top: 4,
    right: 4,
    zIndex: 10,
  },
  metricsOverlay: {
    position: "absolute",
    bottom: 8,
    left: 8,
    zIndex: 10,
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
