import React, { useEffect, useState, useCallback, useRef } from "react";
import { rpc } from "../rpc";
import { IconTriangleRight, IconTriangleDown } from "../components/Icons";
import { useConnectionStore } from "../store";
import { usePanelSetting } from "../store/panel-settings";
import { useI18n } from "../i18n";

// ── Types ───────────────────────────────────────────────────────

interface VfxEntityInfo {
  entityId: number;
  name: string;
  kind: string;
}

interface VfxConfig {
  kind: string;
  looping: boolean;
  emissionRate: number;
  particleLifetime: number;
  speed: number;
  maxParticles: number;
  radius: number;
  spread: number;
  size: number;
  colorR: number;
  colorG: number;
  colorB: number;
}

interface CurveState {
  emissionStart: number;
  emissionMid: number;
  emissionEnd: number;
  sizeStart: number;
  sizeMid: number;
  sizeEnd: number;
  colorGradientStart: [number, number, number];
  colorGradientEnd: [number, number, number];
  previewT: number;
}

const VFX_KINDS = ["fountain", "orbit"] as const;

const PRESETS: Record<string, Partial<VfxConfig>> = {
  fountain: {
    kind: "fountain", looping: true, emissionRate: 18, particleLifetime: 1.2,
    speed: 2.6, maxParticles: 28, radius: 0.42, spread: 0.38, size: 0.11,
    colorR: 1.0, colorG: 0.58, colorB: 0.26,
  },
  orbit: {
    kind: "orbit", looping: true, emissionRate: 12, particleLifetime: 1.8,
    speed: 1.2, maxParticles: 20, radius: 0.72, spread: 0.18, size: 0.1,
    colorR: 0.42, colorG: 0.82, colorB: 1.0,
  },
};

const defaultCurves = (): CurveState => ({
  emissionStart: 1, emissionMid: 1, emissionEnd: 1,
  sizeStart: 1, sizeMid: 1, sizeEnd: 1,
  colorGradientStart: [1, 1, 1],
  colorGradientEnd: [1, 1, 1],
  previewT: 0,
});

function sampleCurve(start: number, mid: number, end: number, t: number): number {
  return t < 0.5
    ? start + (mid - start) * (t * 2)
    : mid + (end - mid) * ((t - 0.5) * 2);
}

function lerpColor(a: [number, number, number], b: [number, number, number], t: number): [number, number, number] {
  return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
}

function colorToHex(r: number, g: number, b: number): string {
  const toHex = (v: number) => Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16).padStart(2, "0");
  return `#${toHex(r)}${toHex(g)}${toHex(b)}`;
}

function hexToRGB(hex: string): [number, number, number] {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16 & 255) / 255, (n >> 8 & 255) / 255, (n & 255) / 255];
}

// ── Main Component ──────────────────────────────────────────────

export function ParticleEditor() {
  const connected = useConnectionStore((s) => s.connected);
  const { t } = useI18n();
  const [entities, setEntities] = useState<VfxEntityInfo[]>([]);
  const [selectedId, setSelectedId] = useState<number | null>(null);
  const [config, setConfig] = useState<VfxConfig | null>(null);
  const [curves, setCurves] = useState<CurveState>(defaultCurves);
  const [collapsed, setCollapsed] = usePanelSetting<Set<string>>("particle-editor", "collapsed", new Set(["emission", "gradient", "sizeCurve"]));
  const [playing, setPlaying] = useState(false);
  const [simSpeed, setSimSpeed] = usePanelSetting("particle-editor", "simSpeed", 1.0);
  const commitTimer = useRef<ReturnType<typeof setTimeout>>(undefined);

  // ── Fetch entities ──────────────────────────────────────────

  const fetchEntities = useCallback(async () => {
    if (!connected) return;
    try {
      const r = await rpc("particle.listVfxEntities", {});
      setEntities(r.entities as unknown as VfxEntityInfo[]);
    } catch { /* ignore */ }
  }, [connected]);

  useEffect(() => { fetchEntities(); }, [fetchEntities]);

  // ── Fetch config for selected entity ────────────────────────

  const fetchConfig = useCallback(async (eid: number) => {
    if (!connected) return;
    try {
      const r = await rpc("particle.getConfig", { entityId: eid });
      if (r.found && r.config) {
        setConfig(r.config as unknown as VfxConfig);
      } else {
        setConfig(null);
      }
    } catch { setConfig(null); }
  }, [connected]);

  useEffect(() => {
    if (selectedId != null) fetchConfig(selectedId);
    else setConfig(null);
  }, [selectedId, fetchConfig]);

  // ── Commit changes (debounced) ──────────────────────────────

  const commit = useCallback((partial: Partial<VfxConfig>) => {
    setConfig((prev) => (prev ? { ...prev, ...partial } : prev));
    if (selectedId == null) return;
    clearTimeout(commitTimer.current);
    const eid = selectedId;
    commitTimer.current = setTimeout(() => {
      rpc("particle.setConfig", { entityId: eid, ...partial } as never).catch(() => {});
    }, 80);
  }, [selectedId]);

  // ── Apply preset ────────────────────────────────────────────

  const applyPreset = useCallback(async (preset: string) => {
    if (selectedId == null) return;
    try {
      await rpc("particle.applyPreset", { entityId: selectedId, preset });
      await fetchConfig(selectedId);
      setCurves(defaultCurves());
    } catch { /* ignore */ }
  }, [selectedId, fetchConfig]);

  // ── Toggle collapse ─────────────────────────────────────────

  const toggle = (key: string) => {
    setCollapsed((prev) => {
      const next = new Set(prev);
      next.has(key) ? next.delete(key) : next.add(key);
      return next;
    });
  };

  // ── No connection ───────────────────────────────────────────

  if (!connected) {
    return (
      <div style={styles.container}>
        <div style={styles.header}>{t.particle.title}</div>
        <div style={styles.empty}>{t.particle.notConnected}</div>
      </div>
    );
  }

  return (
    <div style={styles.container}>
      <div style={styles.header}>{t.particle.title}</div>

      {/* ── Entity selector ─────────────────────────────── */}
      <div style={styles.section}>
        <div style={styles.sectionHeader}>
          <span style={styles.sectionTitle}>{t.particle.vfxEntities}</span>
          <button style={styles.btn} onClick={fetchEntities}>{t.particle.refresh}</button>
        </div>
        {entities.length === 0 ? (
          <div style={{ padding: "8px 0", opacity: 0.4, fontSize: 12 }}>{t.particle.noEntities}</div>
        ) : (
          <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
            {entities.map((e) => (
              <div
                key={e.entityId}
                onClick={() => setSelectedId(e.entityId)}
                style={{
                  ...styles.entityItem,
                  background: selectedId === e.entityId ? "#45475a" : "transparent",
                }}
              >
                <span style={{ color: "#cdd6f4", fontSize: 12 }}>{e.name}</span>
                <span style={styles.kindBadge}>{e.kind}</span>
              </div>
            ))}
          </div>
        )}
      </div>

      {config == null ? (
        <div style={styles.empty}>{t.particle.selectEntity}</div>
      ) : (
        <>
          {/* ── Toolbar ──────────────────────────────────── */}
          <div style={{ ...styles.section, display: "flex", alignItems: "center", gap: 8 }}>
            <button style={styles.btn} onClick={() => setPlaying((p) => !p)}>
              {playing ? t.particle.pause : t.particle.play}
            </button>
            <button style={styles.btn} onClick={() => { setPlaying(false); setCurves((c) => ({ ...c, previewT: 0 })); }}>
              {t.particle.reset}
            </button>
            <label style={{ fontSize: 11, color: "#a6adc8" }}>{t.particle.speed}</label>
            <input
              type="range" min={0.1} max={5} step={0.1} value={simSpeed}
              onChange={(e) => setSimSpeed(parseFloat(e.target.value))}
              style={{ ...styles.slider, width: 80 }}
            />
            <span style={styles.sliderValue}>{simSpeed.toFixed(1)}x</span>
            <select
              style={styles.select}
              value=""
              onChange={(e) => { if (e.target.value) applyPreset(e.target.value); }}
            >
              <option value="">{t.particle.preset}…</option>
              {VFX_KINDS.map((k) => <option key={k} value={k}>{k}</option>)}
            </select>
          </div>

          {/* ── Preview info ─────────────────────────────── */}
          <div style={{ ...styles.section, fontSize: 11, color: "#a6adc8", display: "flex", gap: 16 }}>
            <span>{t.particle.particles}: {config.maxParticles}</span>
            <span>{t.particle.rate}: {config.emissionRate.toFixed(1)}/s</span>
            <span>{t.particle.lifetime}: {config.particleLifetime.toFixed(2)}s</span>
          </div>

          {/* ── Parameters ───────────────────────────────── */}
          <div style={styles.section}>
            <div style={{ ...styles.sectionHeader, cursor: "pointer" }} onClick={() => toggle("params")}>
              <span style={styles.arrow}>{collapsed.has("params") ? <IconTriangleRight size={10} /> : <IconTriangleDown size={10} />}</span>
              <span style={styles.sectionTitle}>{t.particle.parameters}</span>
            </div>
            {!collapsed.has("params") && (
              <>
                <Field label={t.particle.kind}>
                  <select
                    style={styles.select}
                    value={config.kind}
                    onChange={(e) => commit({ kind: e.target.value })}
                  >
                    {VFX_KINDS.map((k) => <option key={k} value={k}>{k}</option>)}
                  </select>
                </Field>
                <ToggleField
                  label={t.particle.looping}
                  value={config.looping}
                  onChange={(v) => commit({ looping: v })}
                />
                <SliderField label={t.particle.emissionRate} value={config.emissionRate} min={1} max={200} step={1} onChange={(v) => commit({ emissionRate: v })} />
                <SliderField label={t.particle.particleLifetime} value={config.particleLifetime} min={0.1} max={10} step={0.1} onChange={(v) => commit({ particleLifetime: v })} />
                <SliderField label={t.particle.speedParam} value={config.speed} min={0.1} max={20} step={0.1} onChange={(v) => commit({ speed: v })} />
                <IntSliderField label={t.particle.maxParticles} value={config.maxParticles} min={1} max={1000} step={1} onChange={(v) => commit({ maxParticles: v })} />
                <SliderField label={t.particle.radius} value={config.radius} min={0} max={5} step={0.05} onChange={(v) => commit({ radius: v })} />
                <SliderField label={t.particle.spread} value={config.spread} min={0} max={3.14159} step={0.05} onChange={(v) => commit({ spread: v })} />
                <SliderField label={t.particle.size} value={config.size} min={0.01} max={2} step={0.01} onChange={(v) => commit({ size: v })} />
                <Field label={t.particle.color}>
                  <input
                    type="color"
                    value={colorToHex(config.colorR, config.colorG, config.colorB)}
                    onChange={(e) => {
                      const [r, g, b] = hexToRGB(e.target.value);
                      commit({ colorR: r, colorG: g, colorB: b });
                    }}
                    style={{ width: 40, height: 22, border: "none", background: "transparent", cursor: "pointer" }}
                  />
                  <span style={styles.sliderValue}>
                    {config.colorR.toFixed(2)}, {config.colorG.toFixed(2)}, {config.colorB.toFixed(2)}
                  </span>
                </Field>
              </>
            )}
          </div>

          {/* ── Advanced Curves ───────────────────────────── */}
          <div style={styles.section}>
            <div style={styles.sectionTitle}>{t.particle.advancedCurves}</div>
            <SliderField
              label={t.particle.previewT}
              value={curves.previewT}
              min={0} max={1} step={0.01}
              onChange={(v) => setCurves((c) => ({ ...c, previewT: v }))}
            />

            {/* Emission Curve */}
            <CurveSection
              title={t.particle.emissionCurve}
              collapsed={collapsed.has("emission")}
              onToggle={() => toggle("emission")}
            >
              <SliderField label={t.particle.curveStart} value={curves.emissionStart} min={0} max={5} step={0.01} onChange={(v) => setCurves((c) => ({ ...c, emissionStart: v }))} />
              <SliderField label={t.particle.curveMid} value={curves.emissionMid} min={0} max={5} step={0.01} onChange={(v) => setCurves((c) => ({ ...c, emissionMid: v }))} />
              <SliderField label={t.particle.curveEnd} value={curves.emissionEnd} min={0} max={5} step={0.01} onChange={(v) => setCurves((c) => ({ ...c, emissionEnd: v }))} />
              <div style={{ fontSize: 11, color: "#a6adc8", padding: "2px 0" }}>
                {t.particle.sampledRate}: {(config.emissionRate * sampleCurve(curves.emissionStart, curves.emissionMid, curves.emissionEnd, curves.previewT)).toFixed(2)}/s
              </div>
            </CurveSection>

            {/* Color Gradient */}
            <CurveSection
              title={t.particle.colorGradient}
              collapsed={collapsed.has("gradient")}
              onToggle={() => toggle("gradient")}
            >
              <Field label={t.particle.startColor}>
                <input
                  type="color"
                  value={colorToHex(...curves.colorGradientStart)}
                  onChange={(e) => setCurves((c) => ({ ...c, colorGradientStart: hexToRGB(e.target.value) }))}
                  style={{ width: 40, height: 22, border: "none", background: "transparent", cursor: "pointer" }}
                />
              </Field>
              <Field label={t.particle.endColor}>
                <input
                  type="color"
                  value={colorToHex(...curves.colorGradientEnd)}
                  onChange={(e) => setCurves((c) => ({ ...c, colorGradientEnd: hexToRGB(e.target.value) }))}
                  style={{ width: 40, height: 22, border: "none", background: "transparent", cursor: "pointer" }}
                />
              </Field>
              {(() => {
                const sampled = lerpColor(curves.colorGradientStart, curves.colorGradientEnd, curves.previewT);
                return (
                  <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "2px 0" }}>
                    <div style={{ width: 24, height: 16, borderRadius: 3, background: colorToHex(...sampled) }} />
                    <span style={{ fontSize: 11, color: "#a6adc8" }}>{t.particle.sampled}</span>
                    <button style={styles.btn} onClick={() => commit({ colorR: sampled[0], colorG: sampled[1], colorB: sampled[2] })}>
                      {t.particle.applyToBase}
                    </button>
                  </div>
                );
              })()}
            </CurveSection>

            {/* Size Curve */}
            <CurveSection
              title={t.particle.sizeCurve}
              collapsed={collapsed.has("sizeCurve")}
              onToggle={() => toggle("sizeCurve")}
            >
              <SliderField label={t.particle.curveStart} value={curves.sizeStart} min={0.01} max={5} step={0.01} onChange={(v) => setCurves((c) => ({ ...c, sizeStart: v }))} />
              <SliderField label={t.particle.curveMid} value={curves.sizeMid} min={0.01} max={5} step={0.01} onChange={(v) => setCurves((c) => ({ ...c, sizeMid: v }))} />
              <SliderField label={t.particle.curveEnd} value={curves.sizeEnd} min={0.01} max={5} step={0.01} onChange={(v) => setCurves((c) => ({ ...c, sizeEnd: v }))} />
              {(() => {
                const sampledSize = Math.max(config.size * sampleCurve(curves.sizeStart, curves.sizeMid, curves.sizeEnd, curves.previewT), 0.01);
                return (
                  <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "2px 0" }}>
                    <span style={{ fontSize: 11, color: "#a6adc8" }}>{t.particle.sampledSize}: {sampledSize.toFixed(3)}</span>
                    <button style={styles.btn} onClick={() => commit({ size: sampledSize })}>
                      {t.particle.applyToBase}
                    </button>
                  </div>
                );
              })()}
            </CurveSection>
          </div>
        </>
      )}
    </div>
  );
}

// ── Sub-components ──────────────────────────────────────────────

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div style={styles.field}>
      <label style={styles.label}>{label}</label>
      {children}
    </div>
  );
}

function SliderField({ label, value, min, max, step, onChange }: {
  label: string; value: number; min: number; max: number; step: number; onChange: (v: number) => void;
}) {
  return (
    <div style={styles.field}>
      <label style={styles.label}>{label}</label>
      <input type="range" min={min} max={max} step={step} value={value}
        onChange={(e) => onChange(parseFloat(e.target.value))} style={styles.slider} />
      <span style={styles.sliderValue}>{value.toFixed(step < 1 ? Math.max(2, -Math.floor(Math.log10(step))) : 0)}</span>
    </div>
  );
}

function IntSliderField({ label, value, min, max, step, onChange }: {
  label: string; value: number; min: number; max: number; step: number; onChange: (v: number) => void;
}) {
  return (
    <div style={styles.field}>
      <label style={styles.label}>{label}</label>
      <input type="range" min={min} max={max} step={step} value={value}
        onChange={(e) => onChange(parseInt(e.target.value, 10))} style={styles.slider} />
      <span style={styles.sliderValue}>{value}</span>
    </div>
  );
}

function ToggleField({ label, value, onChange }: { label: string; value: boolean; onChange: (v: boolean) => void }) {
  return (
    <div style={styles.field}>
      <label style={styles.label}>{label}</label>
      <input type="checkbox" checked={value} onChange={(e) => onChange(e.target.checked)} style={{ accentColor: "#89b4fa" }} />
    </div>
  );
}

function CurveSection({ title, collapsed, onToggle, children }: {
  title: string; collapsed: boolean; onToggle: () => void; children: React.ReactNode;
}) {
  return (
    <div style={{ marginTop: 4 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 4, cursor: "pointer", userSelect: "none" }} onClick={onToggle}>
        <span style={styles.arrow}>{collapsed ? <IconTriangleRight size={10} /> : <IconTriangleDown size={10} />}</span>
        <span style={{ fontSize: 12, fontWeight: 600, color: "#cdd6f4" }}>{title}</span>
      </div>
      {!collapsed && <div style={{ paddingLeft: 16 }}>{children}</div>}
    </div>
  );
}

// ── Styles ──────────────────────────────────────────────────────

const styles: Record<string, React.CSSProperties> = {
  container: { display: "flex", flexDirection: "column", overflowY: "auto", height: "100%" },
  header: {
    padding: "8px 12px", borderBottom: "1px solid #313244",
    fontSize: 12, fontWeight: 600, textTransform: "uppercase",
    letterSpacing: 0.5, color: "#a6adc8",
  },
  empty: { padding: 24, textAlign: "center", opacity: 0.4, fontSize: 13 },
  section: { borderBottom: "1px solid #313244", padding: "6px 12px" },
  sectionHeader: { display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 4 },
  sectionTitle: { fontSize: 12, fontWeight: 600, color: "#cdd6f4" },
  arrow: { fontSize: 10, color: "#6c7086", width: 12 },
  field: { display: "flex", alignItems: "center", padding: "2px 0", fontSize: 12, gap: 6 },
  label: { color: "#a6adc8", minWidth: 100, fontSize: 11 },
  slider: { flex: 1, accentColor: "#89b4fa", height: 4 },
  sliderValue: { color: "#cdd6f4", fontSize: 10, fontFamily: "monospace", minWidth: 40, textAlign: "right" as const },
  select: {
    background: "#313244", border: "1px solid #45475a", borderRadius: 3,
    color: "#cdd6f4", padding: "2px 6px", fontSize: 11, outline: "none",
  },
  btn: {
    background: "#313244", border: "1px solid #45475a", borderRadius: 3,
    color: "#cdd6f4", padding: "2px 8px", fontSize: 11, cursor: "pointer",
  },
  entityItem: {
    display: "flex", justifyContent: "space-between", alignItems: "center",
    padding: "4px 8px", borderRadius: 3, cursor: "pointer",
  },
  kindBadge: {
    fontSize: 10, padding: "1px 6px", borderRadius: 8,
    background: "#45475a", color: "#89b4fa",
  },
};
