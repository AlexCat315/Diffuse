import React, { useEffect, useState, useCallback, useRef } from "react";
import { rpc } from "../rpc";
import { IconTriangleRight, IconTriangleDown } from "../components/Icons";

// ── Types ───────────────────────────────────────────────────────

interface MaterialState {
  hasMaterial: boolean;
  name?: string;
  shading?: string;
  baseColor?: number[];
  emissive?: number[];
  metallic?: number;
  roughness?: number;
  alphaCutoff?: number;
  doubleSided?: boolean;
  useIBL?: boolean;
  iblIntensity?: number;
  texBaseColor?: number;
  texMetallicRoughness?: number;
  texNormal?: number;
  texOcclusion?: number;
  texEmissive?: number;
  isShared?: boolean;
  materialHandle?: number;
  parentHandle?: number;
  generation?: number;
  previewPrimitive?: string;
}

interface TextureEntry {
  handle: number;
  name: string;
  width: number;
  height: number;
}

interface MaterialEditorProps {
  entityId: number | null;
}

// ── Constants ───────────────────────────────────────────────────

const SHADING_MODES = ["unlit", "lambert", "pbr_metallic_roughness"];

const TEXTURE_SLOTS = [
  { key: "base_color", label: "Base Color" },
  { key: "metallic_roughness", label: "Metallic/Roughness" },
  { key: "normal", label: "Normal" },
  { key: "occlusion", label: "Occlusion" },
  { key: "emissive", label: "Emissive" },
] as const;

type TextureSlotKey = (typeof TEXTURE_SLOTS)[number]["key"];

function texHandleKey(slot: TextureSlotKey): keyof MaterialState {
  const map: Record<TextureSlotKey, keyof MaterialState> = {
    base_color: "texBaseColor",
    metallic_roughness: "texMetallicRoughness",
    normal: "texNormal",
    occlusion: "texOcclusion",
    emissive: "texEmissive",
  };
  return map[slot];
}

// ── Helpers ─────────────────────────────────────────────────────

function toHex(c: number[]): string {
  const r = Math.round(Math.min(1, Math.max(0, c[0])) * 255);
  const g = Math.round(Math.min(1, Math.max(0, c[1])) * 255);
  const b = Math.round(Math.min(1, Math.max(0, c[2])) * 255);
  return `#${r.toString(16).padStart(2, "0")}${g.toString(16).padStart(2, "0")}${b.toString(16).padStart(2, "0")}`;
}

function fromHex(hex: string, alpha?: number): number[] {
  const r = parseInt(hex.slice(1, 3), 16) / 255;
  const g = parseInt(hex.slice(3, 5), 16) / 255;
  const b = parseInt(hex.slice(5, 7), 16) / 255;
  return alpha !== undefined ? [r, g, b, alpha] : [r, g, b];
}

// ── Main Component ──────────────────────────────────────────────

export function MaterialEditor({ entityId }: MaterialEditorProps) {
  const [state, setState] = useState<MaterialState | null>(null);
  const [textures, setTextures] = useState<TextureEntry[]>([]);
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const commitTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);

  const fetchState = useCallback(async (eid: number) => {
    try {
      const result = await rpc("material.getState", { entityId: eid });
      setState(result as unknown as MaterialState);
    } catch {
      setState(null);
    }
  }, []);

  const fetchTextures = useCallback(async () => {
    try {
      const result = await rpc("material.listTextures", {} as never);
      setTextures((result as unknown as { textures: TextureEntry[] }).textures ?? []);
    } catch {
      /* ignore */
    }
  }, []);

  useEffect(() => {
    if (entityId == null) {
      setState(null);
      return;
    }
    fetchState(entityId);
    fetchTextures();
  }, [entityId, fetchState, fetchTextures]);

  const toggle = (key: string) => {
    setCollapsed((prev) => {
      const next = new Set(prev);
      next.has(key) ? next.delete(key) : next.add(key);
      return next;
    });
  };

  // ── Commit helpers (debounced) ──────────────────────────────

  const commitScalar = useCallback(
    (property: string, value: number) => {
      if (entityId == null) return;
      clearTimeout(commitTimer.current);
      commitTimer.current = setTimeout(() => {
        rpc("material.setScalar", { entityId, property, value });
      }, 150);
    },
    [entityId],
  );

  const commitFlag = useCallback(
    (property: string, value: boolean) => {
      if (entityId == null) return;
      rpc("material.setFlag", { entityId, property, value });
    },
    [entityId],
  );

  const commitColor = useCallback(
    (property: string, value: number[]) => {
      if (entityId == null) return;
      clearTimeout(commitTimer.current);
      commitTimer.current = setTimeout(() => {
        rpc("material.setColor", { entityId, property, value: value as unknown as never });
      }, 150);
    },
    [entityId],
  );

  const commitShading = useCallback(
    (mode: string) => {
      if (entityId == null) return;
      rpc("material.setShading", { entityId, mode }).then(() => fetchState(entityId));
    },
    [entityId, fetchState],
  );

  const commitTexture = useCallback(
    (slot: string, textureHandle: number) => {
      if (entityId == null) return;
      rpc("material.assignTexture", { entityId, slot, textureHandle }).then(() => fetchState(entityId));
    },
    [entityId, fetchState],
  );

  const clearTexture = useCallback(
    (slot: string) => {
      if (entityId == null) return;
      rpc("material.clearTexture", { entityId, slot }).then(() => fetchState(entityId));
    },
    [entityId, fetchState],
  );

  const makeUnique = useCallback(() => {
    if (entityId == null) return;
    rpc("material.makeUnique", { entityId }).then(() => fetchState(entityId));
  }, [entityId, fetchState]);

  // ── Render ──────────────────────────────────────────────────

  if (entityId == null) {
    return (
      <div style={styles.container}>
        <div style={styles.header}>Material</div>
        <div style={styles.empty}>No entity selected</div>
      </div>
    );
  }

  if (!state || !state.hasMaterial) {
    return (
      <div style={styles.container}>
        <div style={styles.header}>Material</div>
        <div style={styles.empty}>No material component</div>
      </div>
    );
  }

  const isPBR = state.shading === "pbr_metallic_roughness";

  return (
    <div style={styles.container}>
      <div style={styles.header}>
        <span>Material</span>
        {state.isShared && (
          <button style={styles.sharedBadge} onClick={makeUnique} title="Material is shared — click to make unique">
            Shared
          </button>
        )}
      </div>

      {/* ── Shading ────────────────────────────────────────── */}
      <Section title="Shading" collapsed={collapsed.has("shading")} onToggle={() => toggle("shading")}>
        <div style={styles.field}>
          <label style={styles.label}>Mode</label>
          <select
            value={state.shading ?? "pbr_metallic_roughness"}
            onChange={(e) => {
              setState((s) => s && { ...s, shading: e.target.value });
              commitShading(e.target.value);
            }}
            style={styles.select}
          >
            {SHADING_MODES.map((m) => (
              <option key={m} value={m}>
                {m}
              </option>
            ))}
          </select>
        </div>
      </Section>

      {/* ── Colors ─────────────────────────────────────────── */}
      <Section title="Colors" collapsed={collapsed.has("colors")} onToggle={() => toggle("colors")}>
        {state.baseColor && (
          <ColorRow
            label="Base Color"
            value={state.baseColor}
            hasAlpha
            onChange={(v) => {
              setState((s) => s && { ...s, baseColor: v });
              commitColor("base_color", v);
            }}
          />
        )}
        {state.emissive && (
          <ColorRow
            label="Emissive"
            value={state.emissive}
            onChange={(v) => {
              setState((s) => s && { ...s, emissive: v });
              commitColor("emissive", v);
            }}
          />
        )}
      </Section>

      {/* ── PBR Parameters ─────────────────────────────────── */}
      {isPBR && (
        <Section title="PBR" collapsed={collapsed.has("pbr")} onToggle={() => toggle("pbr")}>
          <SliderRow
            label="Metallic"
            value={state.metallic ?? 0}
            min={0}
            max={1}
            step={0.01}
            onChange={(v) => {
              setState((s) => s && { ...s, metallic: v });
              commitScalar("metallic", v);
            }}
          />
          <SliderRow
            label="Roughness"
            value={state.roughness ?? 0.5}
            min={0}
            max={1}
            step={0.01}
            onChange={(v) => {
              setState((s) => s && { ...s, roughness: v });
              commitScalar("roughness", v);
            }}
          />
          <SliderRow
            label="Alpha Cutoff"
            value={state.alphaCutoff ?? 0.5}
            min={0}
            max={1}
            step={0.01}
            onChange={(v) => {
              setState((s) => s && { ...s, alphaCutoff: v });
              commitScalar("alpha_cutoff", v);
            }}
          />
        </Section>
      )}

      {/* ── Flags ──────────────────────────────────────────── */}
      <Section title="Flags" collapsed={collapsed.has("flags")} onToggle={() => toggle("flags")}>
        <CheckboxRow
          label="Double-Sided"
          value={state.doubleSided ?? false}
          onChange={(v) => {
            setState((s) => s && { ...s, doubleSided: v });
            commitFlag("double_sided", v);
          }}
        />
        <CheckboxRow
          label="Use IBL"
          value={state.useIBL ?? false}
          onChange={(v) => {
            setState((s) => s && { ...s, useIBL: v });
            commitFlag("use_ibl", v);
          }}
        />
        {state.useIBL && (
          <SliderRow
            label="IBL Intensity"
            value={state.iblIntensity ?? 1.0}
            min={0}
            max={5}
            step={0.01}
            onChange={(v) => {
              setState((s) => s && { ...s, iblIntensity: v });
              commitScalar("ibl_intensity", v);
            }}
          />
        )}
      </Section>

      {/* ── Textures ───────────────────────────────────────── */}
      <Section title="Textures" collapsed={collapsed.has("textures")} onToggle={() => toggle("textures")}>
        {TEXTURE_SLOTS.map(({ key, label }) => {
          const handleVal = state[texHandleKey(key)] as number | undefined;
          return (
            <TextureSlotRow
              key={key}
              label={label}
              currentHandle={handleVal && handleVal > 0 ? handleVal : undefined}
              textures={textures}
              onAssign={(h) => commitTexture(key, h)}
              onClear={() => clearTexture(key)}
            />
          );
        })}
      </Section>

      {/* ── Info ───────────────────────────────────────────── */}
      {state.materialHandle != null && (
        <div style={{ ...styles.section, opacity: 0.5, fontSize: 10, fontFamily: "monospace" }}>
          handle: {state.materialHandle}
          {state.parentHandle ? ` (parent: ${state.parentHandle})` : ""}
          {state.generation != null ? ` gen:${state.generation}` : ""}
        </div>
      )}
    </div>
  );
}

// ── Sub-components ──────────────────────────────────────────────

function Section({
  title,
  collapsed,
  onToggle,
  children,
}: {
  title: string;
  collapsed: boolean;
  onToggle: () => void;
  children: React.ReactNode;
}) {
  return (
    <div style={styles.section}>
      <div style={styles.sectionHeader} onClick={onToggle}>
        <span style={styles.arrow}>{collapsed ? <IconTriangleRight size={10} /> : <IconTriangleDown size={10} />}</span>
        <span style={styles.sectionTitle}>{title}</span>
      </div>
      {!collapsed && children}
    </div>
  );
}

function SliderRow({
  label,
  value,
  min,
  max,
  step,
  onChange,
}: {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  onChange: (v: number) => void;
}) {
  return (
    <div style={styles.field}>
      <label style={styles.label}>{label}</label>
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(e) => onChange(parseFloat(e.target.value))}
        style={styles.slider}
      />
      <span style={styles.sliderValue}>{value.toFixed(2)}</span>
    </div>
  );
}

function CheckboxRow({
  label,
  value,
  onChange,
}: {
  label: string;
  value: boolean;
  onChange: (v: boolean) => void;
}) {
  return (
    <div style={styles.field}>
      <label style={styles.label}>{label}</label>
      <input
        type="checkbox"
        checked={value}
        onChange={(e) => onChange(e.target.checked)}
        style={{ marginLeft: 8, accentColor: "#89b4fa" }}
      />
    </div>
  );
}

function ColorRow({
  label,
  value,
  hasAlpha,
  onChange,
}: {
  label: string;
  value: number[];
  hasAlpha?: boolean;
  onChange: (v: number[]) => void;
}) {
  const hex = toHex(value);
  return (
    <div style={styles.field}>
      <label style={styles.label}>{label}</label>
      <input
        type="color"
        value={hex}
        onChange={(e) => {
          const c = fromHex(e.target.value, hasAlpha ? value[3] : undefined);
          onChange(c);
        }}
        style={{ marginLeft: 8, width: 32, height: 20, border: "none", background: "none", cursor: "pointer" }}
      />
      <span style={{ ...styles.mono, marginLeft: 4, fontSize: 10 }}>{hex}</span>
      {hasAlpha && (
        <>
          <span style={{ ...styles.mono, marginLeft: 8, fontSize: 10 }}>A</span>
          <input
            type="number"
            min={0}
            max={1}
            step={0.01}
            value={(value[3] ?? 1).toFixed(2)}
            onChange={(e) => {
              const a = parseFloat(e.target.value);
              if (!isNaN(a)) onChange([value[0], value[1], value[2], a]);
            }}
            style={{ ...styles.numInput, width: 50, marginLeft: 4 }}
          />
        </>
      )}
    </div>
  );
}

function TextureSlotRow({
  label,
  currentHandle,
  textures,
  onAssign,
  onClear,
}: {
  label: string;
  currentHandle?: number;
  textures: TextureEntry[];
  onAssign: (h: number) => void;
  onClear: () => void;
}) {
  const current = textures.find((t) => t.handle === currentHandle);
  return (
    <div style={{ ...styles.field, flexWrap: "wrap" }}>
      <label style={{ ...styles.label, minWidth: 100 }}>{label}</label>
      <select
        value={currentHandle ?? 0}
        onChange={(e) => {
          const v = parseInt(e.target.value, 10);
          if (v === 0) onClear();
          else onAssign(v);
        }}
        style={{ ...styles.select, flex: 1 }}
      >
        <option value={0}>— None —</option>
        {textures.map((tex) => (
          <option key={tex.handle} value={tex.handle}>
            {tex.name} ({tex.width}×{tex.height})
          </option>
        ))}
      </select>
      {current && (
        <button style={styles.clearBtn} onClick={onClear} title="Clear texture">
          ×
        </button>
      )}
    </div>
  );
}

// ── Styles ──────────────────────────────────────────────────────

const styles: Record<string, React.CSSProperties> = {
  container: { display: "flex", flexDirection: "column" },
  header: {
    padding: "8px 12px",
    borderBottom: "1px solid #313244",
    fontSize: 12,
    fontWeight: 600,
    textTransform: "uppercase",
    letterSpacing: 0.5,
    color: "#a6adc8",
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
  },
  empty: { padding: 24, textAlign: "center", opacity: 0.4, fontSize: 13 },
  section: { borderBottom: "1px solid #313244", padding: "6px 12px" },
  sectionHeader: {
    display: "flex",
    alignItems: "center",
    gap: 4,
    cursor: "pointer",
    userSelect: "none",
    marginBottom: 4,
  },
  sectionTitle: { fontSize: 12, fontWeight: 600, color: "#cdd6f4" },
  arrow: { fontSize: 10, color: "#6c7086", width: 12 },
  field: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    padding: "3px 0",
    fontSize: 12,
  },
  label: { color: "#a6adc8", minWidth: 70, fontSize: 11 },
  mono: { color: "#cdd6f4", fontSize: 12, fontFamily: "monospace" },
  numInput: {
    background: "#313244",
    border: "1px solid #45475a",
    borderRadius: 3,
    color: "#cdd6f4",
    padding: "2px 4px",
    fontSize: 11,
    fontFamily: "monospace",
    outline: "none",
  },
  select: {
    background: "#313244",
    border: "1px solid #45475a",
    borderRadius: 3,
    color: "#cdd6f4",
    padding: "2px 6px",
    fontSize: 11,
    flex: 1,
    marginLeft: 8,
    outline: "none",
    appearance: "none" as const,
  },
  slider: {
    flex: 1,
    marginLeft: 8,
    accentColor: "#89b4fa",
    height: 4,
  },
  sliderValue: {
    color: "#cdd6f4",
    fontSize: 10,
    fontFamily: "monospace",
    minWidth: 36,
    textAlign: "right" as const,
    marginLeft: 6,
  },
  sharedBadge: {
    background: "#f9e2af",
    color: "#1e1e2e",
    border: "none",
    borderRadius: 3,
    fontSize: 9,
    fontWeight: 700,
    padding: "1px 6px",
    cursor: "pointer",
    textTransform: "uppercase" as const,
    letterSpacing: 0.5,
  },
  clearBtn: {
    background: "#45475a",
    color: "#f38ba8",
    border: "none",
    borderRadius: 3,
    fontSize: 14,
    lineHeight: "16px",
    width: 20,
    cursor: "pointer",
    marginLeft: 4,
    padding: 0,
  },
};
