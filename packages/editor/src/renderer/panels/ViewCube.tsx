import { useLocalState } from "../store/local-state";
import React, { useRef, useEffect, useCallback, useMemo } from "react";
import { useConnectionStore } from "../store";


type Quat = [number, number, number, number]; // x,y,z,w
type Vec3 = [number, number, number];

// ── Constants ────────────────────────────────────────────────────────────

const SIZE = 80;           // Gizmo diameter in CSS px
const HALF = SIZE / 2;
const AXIS_LEN = 26;       // Length of each axis line in px
const DOT_R_POS = 7;       // Positive-end dot radius
const DOT_R_NEG = 4;       // Negative-end dot radius (dimmed)
const LABEL_OFFSET = 14;   // Label distance past the dot

interface AxisDef {
  name: string;
  color: string;
  dir: Vec3;       // Engine-space direction (+X, +Y, +Z)
  lookAxis: Vec3;  // Camera look-along axis when clicking positive endpoint
}

const AXES: AxisDef[] = [
  { name: "X", color: "#f38ba8", dir: [1, 0, 0],  lookAxis: [-1, 0, 0] },
  { name: "Y", color: "#a6e3a1", dir: [0, 1, 0],  lookAxis: [0, -1, 0] },
  { name: "Z", color: "#89b4fa", dir: [0, 0, 1],  lookAxis: [0, 0, -1] },
];

// ── Math helpers ─────────────────────────────────────────────────────────

function quatToMat3(q: Quat): number[] {
  const [x, y, z, w] = q;
  const x2 = x + x, y2 = y + y, z2 = z + z;
  const xx = x * x2, xy = x * y2, xz = x * z2;
  const yy = y * y2, yz = y * z2, zz = z * z2;
  const wx = w * x2, wy = w * y2, wz = w * z2;
  // Row-major 3x3
  return [
    1 - yy - zz, xy - wz,     xz + wy,
    xy + wz,     1 - xx - zz,  yz - wx,
    xz - wy,     yz + wx,     1 - xx - yy,
  ];
}

function applyMat3(m: number[], v: Vec3): Vec3 {
  return [
    m[0] * v[0] + m[1] * v[1] + m[2] * v[2],
    m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
    m[6] * v[0] + m[7] * v[1] + m[8] * v[2],
  ];
}

// ── Component ────────────────────────────────────────────────────────────

export function ViewCube() {
  const connected = useConnectionStore((s) => s.connected);
  const [rot, setRot] = useLocalState<Quat>([0, 0, 0, 1]);
  const [hovered, setHovered] = useLocalState<string | null>(null);
  const dragRef = useRef<{ sx: number; sy: number; dragging: boolean }>({
    sx: 0, sy: 0, dragging: false,
  });

  // Track camera rotation via requestAnimationFrame (one in-flight RPC at a time)
  useEffect(() => {
    if (!connected) return;
    let cancelled = false;
    let pending = false;
    const tick = () => {
      if (cancelled) return;
      if (!pending) {
        pending = true;
        window.guavaEngine.call("camera.getState", {}).then((res) => {
          if (res.rotation) {
            setRot([res.rotation.x, res.rotation.y, res.rotation.z, res.rotation.w]);
          }
          pending = false;
        }).catch(() => { pending = false; });
      }
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
    return () => { cancelled = true; };
  }, [connected]);

  // Project axes to 2D using camera rotation
  const projectedAxes = useMemo(() => {
    const mat = quatToMat3(rot);
    return AXES.map((ax) => {
      const r = applyMat3(mat, ax.dir);
      // r is in view space: x=right, y=up (engine), z=towards camera
      // Convert to screen: x=right, y=DOWN, z=depth (for sorting)
      const sx = r[0];
      const sy = -r[1];  // flip Y: engine up → screen down
      const sz = r[2];   // depth: positive = towards camera
      return { ...ax, sx, sy, sz };
    });
  }, [rot]);

  // Sort by depth (back-to-front) so foreground axes render on top
  const sortedAxes = useMemo(() => {
    return [...projectedAxes].sort((a, b) => a.sz - b.sz);
  }, [projectedAxes]);

  // Click axis endpoint → snap camera
  const handleAxisClick = useCallback((axName: string, positive: boolean) => {
    if (!connected || dragRef.current.dragging) return;
    const ax = AXES.find((a) => a.name === axName);
    if (!ax) return;
    const look = positive
      ? ax.lookAxis
      : [ax.lookAxis[0] * -1, ax.lookAxis[1] * -1, ax.lookAxis[2] * -1] as Vec3;
    window.guavaEngine.call("camera.lookAlongAxis", {
      axisX: look[0], axisY: look[1], axisZ: look[2],
    } as never).catch(() => {});
  }, [connected]);

  // Drag to orbit
  const handleMouseDown = useCallback((e: React.MouseEvent) => {
    e.stopPropagation(); // prevent viewport container from intercepting
    dragRef.current = { sx: e.clientX, sy: e.clientY, dragging: false };
    const onMove = (ev: MouseEvent) => {
      const dx = ev.clientX - dragRef.current.sx;
      const dy = ev.clientY - dragRef.current.sy;
      if (!dragRef.current.dragging && dx * dx + dy * dy > 9) {
        dragRef.current.dragging = true;
      }
      if (dragRef.current.dragging) {
        window.guavaEngine.call("camera.orbit", {
          deltaYaw: -(ev.clientX - dragRef.current.sx) * 0.008,
          deltaPitch: (ev.clientY - dragRef.current.sy) * 0.008,
        } as never).catch(() => {});
        dragRef.current.sx = ev.clientX;
        dragRef.current.sy = ev.clientY;
      }
    };
    const onUp = () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  }, []);

  if (!connected) return null;

  return (
    <svg
      width={SIZE}
      height={SIZE}
      viewBox={`0 0 ${SIZE} ${SIZE}`}
      style={svgStyle}
      onMouseDown={handleMouseDown}
    >
      {/* Background circle */}
      <circle cx={HALF} cy={HALF} r={HALF - 2} fill="rgba(17,17,27,0.55)" stroke="rgba(49,50,68,0.5)" strokeWidth={1} />

      {/* Render axes back-to-front */}
      {sortedAxes.map((ax) => {
        const x1 = HALF;
        const y1 = HALF;
        // Positive endpoint
        const px = HALF + ax.sx * AXIS_LEN;
        const py = HALF + ax.sy * AXIS_LEN;
        // Negative endpoint (opposite side, shorter)
        const nx = HALF - ax.sx * (AXIS_LEN * 0.55);
        const ny = HALF - ax.sy * (AXIS_LEN * 0.55);

        // Depth-based opacity for 3D feel
        const posOpacity = 0.6 + Math.max(0, ax.sz) * 0.4; // 0.6–1.0
        const negOpacity = 0.25 + Math.max(0, -ax.sz) * 0.25; // 0.25–0.5

        const isHoveredPos = hovered === `+${ax.name}`;
        const isHoveredNeg = hovered === `-${ax.name}`;

        return (
          <g key={ax.name}>
            {/* Axis line */}
            <line
              x1={nx} y1={ny} x2={px} y2={py}
              stroke={ax.color}
              strokeWidth={1.8}
              strokeLinecap="round"
              opacity={posOpacity * 0.7}
            />

            {/* Negative endpoint (small dimmed dot) */}
            <circle
              cx={nx} cy={ny}
              r={isHoveredNeg ? DOT_R_NEG + 1.5 : DOT_R_NEG}
              fill="none"
              stroke={ax.color}
              strokeWidth={1.2}
              opacity={negOpacity}
              style={{ cursor: "pointer", transition: "r 0.12s" }}
              onMouseEnter={() => setHovered(`-${ax.name}`)}
              onMouseLeave={() => setHovered(null)}
              onClick={(e) => { e.stopPropagation(); handleAxisClick(ax.name, false); }}
            />

            {/* Positive endpoint (solid colored dot) */}
            <circle
              cx={px} cy={py}
              r={isHoveredPos ? DOT_R_POS + 2 : DOT_R_POS}
              fill={ax.color}
              opacity={posOpacity}
              style={{ cursor: "pointer", transition: "r 0.12s" }}
              onMouseEnter={() => setHovered(`+${ax.name}`)}
              onMouseLeave={() => setHovered(null)}
              onClick={(e) => { e.stopPropagation(); handleAxisClick(ax.name, true); }}
            />

            {/* Label on positive end */}
            <text
              x={HALF + ax.sx * (AXIS_LEN + LABEL_OFFSET)}
              y={HALF + ax.sy * (AXIS_LEN + LABEL_OFFSET) + 3.5}
              fill={ax.color}
              fontSize={9}
              fontWeight={700}
              fontFamily="system-ui, sans-serif"
              textAnchor="middle"
              opacity={posOpacity}
              style={{ pointerEvents: "none", userSelect: "none" }}
            >
              {ax.name}
            </text>
          </g>
        );
      })}

      {/* Center dot */}
      <circle cx={HALF} cy={HALF} r={2} fill="rgba(205,214,244,0.4)" />
    </svg>
  );
}

// ── Style ────────────────────────────────────────────────────────────────

const svgStyle: React.CSSProperties = {
  cursor: "pointer",
  userSelect: "none",
  overflow: "visible",
};
