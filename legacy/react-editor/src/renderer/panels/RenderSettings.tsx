import { useLocalState } from "../store/local-state";
import React, { useEffect, useCallback, useRef } from "react";
import type { RpcResult } from "../../shared/rpc-types";
import { rpc } from "../rpc";
import { useI18n } from "../i18n";
import { useConnectionStore, useViewportSettingsStore } from "../store";
import { useSyncedState } from "../store/synced-state";
import type { ShadingMode } from "../store/viewport-settings";
import { engine } from "../engine-client";

type RenderSettings = RpcResult<"viewport.getRenderSettings">;

interface PathTraceState {
  samples: number;
  bounces: number;
  resolutionScale: number;
}

interface RenderOutputState {
  preset: string;
  width: number;
  height: number;
  format: string;
  path: string;
}


export function RenderSettingsPanel() {
  const connected = useConnectionStore((s) => s.connected);
  const { t } = useI18n();
  const [settings, setSettings] = useLocalState<RenderSettings | null>(null);
  const [pathTrace, setPathTrace] = useSyncedState<PathTraceState>("render-settings", "pathTrace", { samples: 256, bounces: 8, resolutionScale: 1.0 });
  const [renderOutput, setRenderOutput] = useSyncedState<RenderOutputState>("render-settings", "renderOutput", { preset: "1080p", width: 1920, height: 1080, format: "png", path: "render_output" });
  const [transformSpace, setTransformSpace] = useSyncedState<"local" | "world">("render-settings", "transformSpace", "local");
  const shadingMode = useViewportSettingsStore((s) => s.shadingMode);
  const setShadingMode = useViewportSettingsStore((s) => s.setShadingMode);
  const fetchViewportSettings = useViewportSettingsStore((s) => s.fetchFromEngine);
  const commitTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);

  const fetchSettings = useCallback(async () => {
    if (!connected) return;
    try {
      const result = await engine.call("viewport.getRenderSettings", {});
      setSettings(result);
    } catch {
      // ignore
    }
    // Fetch shared viewport settings (shading mode, FPS) into Zustand store
    await fetchViewportSettings();
    try {
      const ext = await rpc("rendersettings.getSettings", {});
      setPathTrace(ext.pathTrace);
      setRenderOutput(ext.renderOutput);
      setTransformSpace(ext.transformSpace as "local" | "world");
    } catch {
      // ignore
    }
  }, [connected]);

  useEffect(() => {
    fetchSettings();
  }, [fetchSettings]);

  const commit = useCallback(
    (partial: Record<string, unknown>) => {
      setSettings((prev) => (prev ? { ...prev, ...partial } : prev));
      clearTimeout(commitTimer.current);
      commitTimer.current = setTimeout(() => {
        engine.call("viewport.setRenderSettings", partial as never).catch(() => {});
      }, 80);
    },
    [],
  );

  if (!connected || !settings) {
    return <div style={styles.container}><div style={styles.empty}>{t.common.notConnected}</div></div>;
  }

  const shadingLabels: Record<ShadingMode, string> = {
    solid: t.renderSettings.solid,
    material: t.renderSettings.material,
    rendered: t.renderSettings.rendered,
    wireframe: t.renderSettings.wireframe,
  };

  return (
    <div style={styles.container}>
      <div style={styles.header}>{t.renderSettings.title}</div>

      {/* Shading Mode */}
      <Section title={t.renderSettings.shading}>
        <div style={styles.buttonGroup}>
          {(["solid", "material", "rendered", "wireframe"] as ShadingMode[]).map((mode) => (
            <button
              key={mode}
              style={{
                ...styles.modeButton,
                ...(shadingMode === mode ? styles.modeButtonActive : {}),
              }}
              onClick={() => {
                setShadingMode(mode);
                commit({ shadingMode: mode });
              }}
            >
              {shadingLabels[mode]}
            </button>
          ))}
        </div>
      </Section>



      {/* Viewport Overlays */}
      <Section title={t.renderSettings.overlays}>
        <Toggle label={t.renderSettings.grid} value={settings.showGrid} onChange={(v) => commit({ showGrid: v })} />
        <Toggle label={t.renderSettings.bones} value={settings.showBones} onChange={(v) => commit({ showBones: v })} />
        <Toggle label={t.renderSettings.collision} value={settings.showCollision} onChange={(v) => commit({ showCollision: v })} />
      </Section>

      {/* Post-Processing */}
      <Section title={t.renderSettings.postProcessing}>
        <ToggleSlider
          label={t.renderSettings.bloom}
          enabled={settings.bloomEnabled}
          onToggle={(v) => commit({ bloomEnabled: v })}
          sliders={[
            { label: t.renderSettings.threshold, value: settings.bloomThreshold, min: 0, max: 5, step: 0.1, onChange: (v) => commit({ bloomThreshold: v }) },
            { label: t.renderSettings.intensity, value: settings.bloomIntensity, min: 0, max: 2, step: 0.05, onChange: (v) => commit({ bloomIntensity: v }) },
          ]}
        />
        <ToggleSlider
          label={t.renderSettings.exposure}
          enabled={settings.exposureEnabled}
          onToggle={(v) => commit({ exposureEnabled: v })}
          sliders={[
            { label: t.renderSettings.value, value: settings.exposure, min: 0.1, max: 10, step: 0.1, onChange: (v) => commit({ exposure: v }) },
          ]}
        />
        <ToggleSlider
          label={t.renderSettings.ssao}
          enabled={settings.ssaoEnabled}
          onToggle={(v) => commit({ ssaoEnabled: v })}
          sliders={[
            { label: t.renderSettings.radius, value: settings.ssaoRadius, min: 0.1, max: 5, step: 0.1, onChange: (v) => commit({ ssaoRadius: v }) },
            { label: t.renderSettings.intensity, value: settings.ssaoIntensity, min: 0, max: 3, step: 0.1, onChange: (v) => commit({ ssaoIntensity: v }) },
          ]}
        />
        <ToggleSlider
          label={t.renderSettings.dof}
          enabled={settings.dofEnabled}
          onToggle={(v) => commit({ dofEnabled: v })}
          sliders={[
            { label: t.renderSettings.focusDist, value: settings.dofFocusDistance, min: 0.1, max: 100, step: 0.5, onChange: (v) => commit({ dofFocusDistance: v }) },
            { label: t.renderSettings.focusRange, value: settings.dofFocusRange, min: 0.1, max: 50, step: 0.5, onChange: (v) => commit({ dofFocusRange: v }) },
          ]}
        />
        <Toggle label={t.renderSettings.fxaa} value={settings.fxaaEnabled} onChange={(v) => commit({ fxaaEnabled: v })} />
        <Toggle label={t.renderSettings.taa} value={settings.taaEnabled} onChange={(v) => commit({ taaEnabled: v })} />
        <Toggle label={t.renderSettings.contactShadows} value={settings.contactShadowsEnabled} onChange={(v) => commit({ contactShadowsEnabled: v })} />
      </Section>

      {/* Color Grading */}
      <Section title={t.renderSettings.colorGrading}>
        <ToggleSlider
          label={t.renderSettings.colorGrading}
          enabled={settings.colorGradingEnabled}
          onToggle={(v) => commit({ colorGradingEnabled: v })}
          sliders={[
            { label: t.renderSettings.saturation, value: settings.colorGradingSaturation, min: 0, max: 3, step: 0.05, onChange: (v) => commit({ colorGradingSaturation: v }) },
            { label: t.renderSettings.contrast, value: settings.colorGradingContrast, min: 0, max: 3, step: 0.05, onChange: (v) => commit({ colorGradingContrast: v }) },
            { label: t.renderSettings.gamma, value: settings.colorGradingGamma, min: 0.1, max: 3, step: 0.05, onChange: (v) => commit({ colorGradingGamma: v }) },
          ]}
        />
      </Section>

      {/* Transform Space */}
      <Section title={t.renderSettings.transformSpace}>
        <div style={styles.buttonGroup}>
          {(["local", "world"] as const).map((sp) => (
            <button
              key={sp}
              style={{
                ...styles.modeButton,
                ...(transformSpace === sp ? styles.modeButtonActive : {}),
              }}
              onClick={() => {
                setTransformSpace(sp);
                rpc("rendersettings.setTransformSpace", { space: sp }).catch(() => {});
              }}
            >
              {sp === "local" ? t.renderSettings.local : t.renderSettings.world}
            </button>
          ))}
        </div>
      </Section>

      {/* Path Tracing */}
      <Section title={t.renderSettings.pathTracing}>
        <div style={styles.sliderRow}>
          <span style={styles.sliderLabel}>{t.renderSettings.samples}</span>
          <input type="range" min={1} max={4096} step={1} value={pathTrace.samples}
            onChange={(e) => {
              const v = parseInt(e.target.value);
              setPathTrace((p) => ({ ...p, samples: v }));
              rpc("rendersettings.setPathTrace", { samples: v }).catch(() => {});
            }} style={styles.slider} />
          <span style={styles.sliderValue}>{pathTrace.samples}</span>
        </div>
        <div style={styles.sliderRow}>
          <span style={styles.sliderLabel}>{t.renderSettings.bounces}</span>
          <input type="range" min={1} max={32} step={1} value={pathTrace.bounces}
            onChange={(e) => {
              const v = parseInt(e.target.value);
              setPathTrace((p) => ({ ...p, bounces: v }));
              rpc("rendersettings.setPathTrace", { bounces: v }).catch(() => {});
            }} style={styles.slider} />
          <span style={styles.sliderValue}>{pathTrace.bounces}</span>
        </div>
        <div style={styles.sliderRow}>
          <span style={styles.sliderLabel}>{t.renderSettings.resolutionScale}</span>
          <input type="range" min={0.25} max={2.0} step={0.25} value={pathTrace.resolutionScale}
            onChange={(e) => {
              const v = parseFloat(e.target.value);
              setPathTrace((p) => ({ ...p, resolutionScale: v }));
              rpc("rendersettings.setPathTrace", { resolutionScale: v }).catch(() => {});
            }} style={styles.slider} />
          <span style={styles.sliderValue}>{pathTrace.resolutionScale.toFixed(2)}</span>
        </div>
        <div style={{ ...styles.buttonGroup, marginTop: 6 }}>
          {["preview", "low", "medium", "high", "ultra"].map((preset) => (
            <button key={preset} style={styles.modeButton}
              onClick={() => rpc("rendersettings.applyPtPreset", { preset }).then(() => fetchSettings()).catch(() => {})}
            >
              {preset.charAt(0).toUpperCase() + preset.slice(1)}
            </button>
          ))}
        </div>
      </Section>

      {/* Render Output */}
      <Section title={t.renderSettings.renderOutput}>
        <div style={styles.buttonGroup}>
          {["720p", "1080p", "1440p", "4k"].map((preset) => (
            <button key={preset}
              style={{ ...styles.modeButton, ...(renderOutput.preset === preset ? styles.modeButtonActive : {}) }}
              onClick={() => {
                rpc("rendersettings.setRenderOutput", { preset }).catch(() => {});
                fetchSettings();
              }}
            >
              {preset}
            </button>
          ))}
        </div>
        <div style={{ ...styles.sliderRow, marginTop: 6 }}>
          <span style={styles.sliderLabel}>{t.renderSettings.format}</span>
          <select value={renderOutput.format} style={styles.select}
            onChange={(e) => {
              setRenderOutput((o) => ({ ...o, format: e.target.value }));
              rpc("rendersettings.setRenderOutput", { format: e.target.value }).catch(() => {});
            }}>
            <option value="png">PNG</option>
            <option value="exr">EXR</option>
            <option value="jpg">JPG</option>
          </select>
        </div>
        <div style={{ fontSize: 11, color: "#6c7086", marginTop: 4 }}>
          {renderOutput.width}×{renderOutput.height} → {renderOutput.path}
        </div>
      </Section>
    </div>
  );
}

// ── Sub-components ───────────────────────────────────────────────

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div style={styles.section}>
      <div style={styles.sectionTitle}>{title}</div>
      {children}
    </div>
  );
}

function Toggle({ label, value, onChange }: { label: string; value: boolean; onChange: (v: boolean) => void }) {
  return (
    <label style={styles.toggleRow}>
      <input type="checkbox" checked={value} onChange={(e) => onChange(e.target.checked)} />
      <span>{label}</span>
    </label>
  );
}

interface SliderDef {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  onChange: (v: number) => void;
}

function ToggleSlider({
  label,
  enabled,
  onToggle,
  sliders,
}: {
  label: string;
  enabled: boolean;
  onToggle: (v: boolean) => void;
  sliders: SliderDef[];
}) {
  return (
    <div style={styles.toggleSliderBlock}>
      <label style={styles.toggleRow}>
        <input type="checkbox" checked={enabled} onChange={(e) => onToggle(e.target.checked)} />
        <span>{label}</span>
      </label>
      {enabled &&
        sliders.map((s) => (
          <div key={s.label} style={styles.sliderRow}>
            <span style={styles.sliderLabel}>{s.label}</span>
            <input
              type="range"
              min={s.min}
              max={s.max}
              step={s.step}
              value={s.value}
              onChange={(e) => s.onChange(parseFloat(e.target.value))}
              style={styles.slider}
            />
            <span style={styles.sliderValue}>{s.value.toFixed(2)}</span>
          </div>
        ))}
    </div>
  );
}

// ── Styles ───────────────────────────────────────────────────────

const styles: Record<string, React.CSSProperties> = {
  container: {
    padding: 8,
    color: "#cdd6f4",
    fontSize: 13,
    overflow: "auto",
    height: "100%",
  },
  header: {
    fontSize: 14,
    fontWeight: 600,
    marginBottom: 8,
    color: "#89b4fa",
  },
  empty: {
    opacity: 0.4,
    textAlign: "center",
    padding: 16,
  },
  section: {
    marginBottom: 12,
    borderBottom: "1px solid #313244",
    paddingBottom: 8,
  },
  sectionTitle: {
    fontSize: 11,
    textTransform: "uppercase" as const,
    color: "#6c7086",
    letterSpacing: 1,
    marginBottom: 6,
  },
  buttonGroup: {
    display: "flex",
    gap: 4,
  },
  modeButton: {
    flex: 1,
    padding: "4px 8px",
    border: "1px solid #45475a",
    borderRadius: 4,
    background: "#1e1e2e",
    color: "#cdd6f4",
    cursor: "pointer",
    fontSize: 11,
    textAlign: "center" as const,
  },
  modeButtonActive: {
    background: "#89b4fa",
    color: "#1e1e2e",
    border: "1px solid #89b4fa",
    fontWeight: 600,
  },
  toggleRow: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    padding: "3px 0",
    cursor: "pointer",
  },
  toggleSliderBlock: {
    marginBottom: 4,
  },
  sliderRow: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    paddingLeft: 24,
    marginTop: 2,
  },
  sliderLabel: {
    width: 70,
    fontSize: 11,
    color: "#a6adc8",
  },
  slider: {
    flex: 1,
    height: 4,
    accentColor: "#89b4fa",
  },
  sliderValue: {
    width: 40,
    fontSize: 11,
    color: "#a6adc8",
    textAlign: "right" as const,
  },
  select: {
    flex: 1,
    background: "#1e1e2e",
    border: "1px solid #45475a",
    borderRadius: 4,
    color: "#cdd6f4",
    padding: "2px 6px",
    fontSize: 11,
  },
};
