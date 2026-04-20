import { useLocalState } from "../store/local-state";
import React, { useEffect, useCallback, useRef } from "react";
import { rpc } from "../rpc";
import { IconTriangleRight, IconTriangleDown } from "../components/Icons";
import { useConnectionStore } from "../store";
import { useI18n } from "../i18n";
import { useSyncedState } from "../store/synced-state";

// ── Types ───────────────────────────────────────────────────────

interface PPState {
  // Bloom
  bloomEnabled: boolean;
  bloomThreshold: number;
  bloomIntensity: number;
  // Exposure
  exposureEnabled: boolean;
  exposure: number;
  // SSAO
  ssaoEnabled: boolean;
  ssaoRadius: number;
  ssaoIntensity: number;
  ssaoBias: number;
  ssaoPower: number;
  // FXAA
  fxaaEnabled: boolean;
  // TAA
  taaEnabled: boolean;
  taaBlendFactor: number;
  taaMotionBlurScale: number;
  taaFeedbackMin: number;
  taaFeedbackMax: number;
  // Contact Shadows
  contactShadowsEnabled: boolean;
  contactShadowsDistance: number;
  contactShadowsThickness: number;
  contactShadowsIntensity: number;
  contactShadowsBias: number;
  contactShadowsSteps: number;
  // SSR
  ssrEnabled: boolean;
  ssrIntensity: number;
  ssrRayStep: number;
  ssrMaxDistance: number;
  ssrThickness: number;
  ssrFadeDistance: number;
  ssrEdgeFade: number;
  ssrRoughnessBlur: number;
  // SSGI
  ssgiEnabled: boolean;
  ssgiRadius: number;
  ssgiIntensity: number;
  ssgiBias: number;
  ssgiRayCount: number;
  ssgiStepCount: number;
  // Color Grading
  colorGradingEnabled: boolean;
  colorGradingSaturation: number;
  colorGradingContrast: number;
  colorGradingGamma: number;
  // DOF
  dofEnabled: boolean;
  dofFocusDistance: number;
  dofFocusRange: number;
  dofBlurRadius: number;
  dofBokehRadius: number;
  dofNearBlur: number;
  dofFarBlur: number;
  dofQuality: number;
  // LUT
  lutEnabled: boolean;
  lutIntensity: number;
  lutPreset: string;
  // Volumetric Fog
  volumetricFogEnabled: boolean;
  volumetricFogDensity: number;
  volumetricFogHeightFalloff: number;
  volumetricFogMaxDistance: number;
  // RT Shadows
  rtShadowsEnabled: boolean;
  rtShadowSamples: number;
  rtShadowStrength: number;
  rtShadowSoftness: number;
  rtShadowResolutionScale: number;
}


const LUT_PRESETS = ["neutral", "warm", "cool", "filmic"];

// ── Main Component ──────────────────────────────────────────────

export function PostProcessEditor() {
  const connected = useConnectionStore((s) => s.connected);
  const { t } = useI18n();
  const [state, setState] = useLocalState<PPState | null>(null);
  const [collapsed, setCollapsed] = useSyncedState<Set<string>>("post-process", "collapsed", new Set());
  const commitTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);

  const fetchState = useCallback(async () => {
    if (!connected) return;
    try {
      const result = await rpc("viewport.getRenderSettings", {});
      setState(result as unknown as PPState);
    } catch {
      /* ignore */
    }
  }, [connected]);

  useEffect(() => {
    fetchState();
  }, [fetchState]);

  const commit = useCallback((partial: Record<string, unknown>) => {
    setState((prev) => (prev ? { ...prev, ...partial } : prev));
    clearTimeout(commitTimer.current);
    commitTimer.current = setTimeout(() => {
      rpc("viewport.setRenderSettings", partial as never).catch(() => {});
    }, 80);
  }, []);

  const toggle = (key: string) => {
    setCollapsed((prev) => {
      const next = new Set(prev);
      next.has(key) ? next.delete(key) : next.add(key);
      return next;
    });
  };

  if (!connected || !state) {
    return (
      <div style={styles.container}>
        <div style={styles.header}>{t.postProcess.title}</div>
        <div style={styles.empty}>{t.postProcess.notConnected}</div>
      </div>
    );
  }

  return (
    <div style={styles.container}>
      <div style={styles.header}>{t.postProcess.title}</div>

      {/* ── Bloom ──────────────────────────────────────────── */}
      <EffectSection
        title={t.postProcess.bloom}
        enabled={state.bloomEnabled}
        onToggle={(v) => commit({ bloomEnabled: v })}
        collapsed={collapsed.has("bloom")}
        onCollapse={() => toggle("bloom")}
      >
        <Slider label={t.postProcess.bloomThreshold} value={state.bloomThreshold} min={0} max={5} step={0.1} onChange={(v) => commit({ bloomThreshold: v })} />
        <Slider label={t.postProcess.bloomIntensity} value={state.bloomIntensity} min={0} max={2} step={0.05} onChange={(v) => commit({ bloomIntensity: v })} />
      </EffectSection>

      {/* ── Exposure ───────────────────────────────────────── */}
      <EffectSection
        title={t.postProcess.exposure}
        enabled={state.exposureEnabled}
        onToggle={(v) => commit({ exposureEnabled: v })}
        collapsed={collapsed.has("exposure")}
        onCollapse={() => toggle("exposure")}
      >
        <Slider label={t.postProcess.exposureValue} value={state.exposure} min={0.1} max={10} step={0.1} onChange={(v) => commit({ exposure: v })} />
      </EffectSection>

      {/* ── SSAO ───────────────────────────────────────────── */}
      <EffectSection
        title={t.postProcess.ssao}
        enabled={state.ssaoEnabled}
        onToggle={(v) => commit({ ssaoEnabled: v })}
        collapsed={collapsed.has("ssao")}
        onCollapse={() => toggle("ssao")}
      >
        <Slider label={t.postProcess.ssaoRadius} value={state.ssaoRadius} min={0.1} max={5} step={0.1} onChange={(v) => commit({ ssaoRadius: v })} />
        <Slider label={t.postProcess.ssaoBias} value={state.ssaoBias} min={0} max={0.1} step={0.005} onChange={(v) => commit({ ssaoBias: v })} />
        <Slider label={t.postProcess.ssaoIntensity} value={state.ssaoIntensity} min={0} max={3} step={0.1} onChange={(v) => commit({ ssaoIntensity: v })} />
        <Slider label={t.postProcess.ssaoPower} value={state.ssaoPower} min={0.5} max={5} step={0.1} onChange={(v) => commit({ ssaoPower: v })} />
      </EffectSection>

      {/* ── SSGI ───────────────────────────────────────────── */}
      <EffectSection
        title={t.postProcess.ssgi}
        enabled={state.ssgiEnabled}
        onToggle={(v) => commit({ ssgiEnabled: v })}
        collapsed={collapsed.has("ssgi")}
        onCollapse={() => toggle("ssgi")}
      >
        <Slider label={t.postProcess.ssgiRadius} value={state.ssgiRadius} min={0.5} max={10} step={0.5} onChange={(v) => commit({ ssgiRadius: v })} />
        <Slider label={t.postProcess.ssgiIntensity} value={state.ssgiIntensity} min={0} max={3} step={0.1} onChange={(v) => commit({ ssgiIntensity: v })} />
        <Slider label={t.postProcess.ssgiBias} value={state.ssgiBias} min={0} max={0.2} step={0.01} onChange={(v) => commit({ ssgiBias: v })} />
        <IntSlider label={t.postProcess.ssgiRayCount} value={state.ssgiRayCount} min={1} max={32} step={1} onChange={(v) => commit({ ssgiRayCount: v })} />
        <IntSlider label={t.postProcess.ssgiStepCount} value={state.ssgiStepCount} min={1} max={32} step={1} onChange={(v) => commit({ ssgiStepCount: v })} />
      </EffectSection>

      {/* ── SSR ────────────────────────────────────────────── */}
      <EffectSection
        title={t.postProcess.ssr}
        enabled={state.ssrEnabled}
        onToggle={(v) => commit({ ssrEnabled: v })}
        collapsed={collapsed.has("ssr")}
        onCollapse={() => toggle("ssr")}
      >
        <Slider label={t.postProcess.ssrIntensity} value={state.ssrIntensity} min={0} max={1} step={0.05} onChange={(v) => commit({ ssrIntensity: v })} />
        <Slider label={t.postProcess.ssrRayStep} value={state.ssrRayStep} min={0.01} max={1} step={0.01} onChange={(v) => commit({ ssrRayStep: v })} />
        <Slider label={t.postProcess.ssrMaxDistance} value={state.ssrMaxDistance} min={1} max={500} step={5} onChange={(v) => commit({ ssrMaxDistance: v })} />
        <Slider label={t.postProcess.ssrThickness} value={state.ssrThickness} min={0.01} max={5} step={0.05} onChange={(v) => commit({ ssrThickness: v })} />
        <Slider label={t.postProcess.ssrFadeDistance} value={state.ssrFadeDistance} min={0} max={50} step={1} onChange={(v) => commit({ ssrFadeDistance: v })} />
        <Slider label={t.postProcess.ssrEdgeFade} value={state.ssrEdgeFade} min={0} max={1} step={0.05} onChange={(v) => commit({ ssrEdgeFade: v })} />
        <Slider label={t.postProcess.ssrRoughnessBlur} value={state.ssrRoughnessBlur} min={0} max={2} step={0.1} onChange={(v) => commit({ ssrRoughnessBlur: v })} />
      </EffectSection>

      {/* ── Anti-Aliasing ──────────────────────────────────── */}
      <Section title={t.postProcess.antiAliasing} collapsed={collapsed.has("aa")} onToggle={() => toggle("aa")}>
        <Toggle label={t.postProcess.fxaa} value={state.fxaaEnabled} onChange={(v) => commit({ fxaaEnabled: v })} />
        <Toggle label={t.postProcess.taa} value={state.taaEnabled} onChange={(v) => commit({ taaEnabled: v })} />
        {state.taaEnabled && (
          <>
            <Slider label={t.postProcess.taaBlendFactor} value={state.taaBlendFactor} min={0.01} max={0.5} step={0.01} onChange={(v) => commit({ taaBlendFactor: v })} />
            <Slider label={t.postProcess.taaMotionBlurScale} value={state.taaMotionBlurScale} min={0} max={3} step={0.1} onChange={(v) => commit({ taaMotionBlurScale: v })} />
            <Slider label={t.postProcess.taaFeedbackMin} value={state.taaFeedbackMin} min={0.5} max={1} step={0.01} onChange={(v) => commit({ taaFeedbackMin: v })} />
            <Slider label={t.postProcess.taaFeedbackMax} value={state.taaFeedbackMax} min={0.5} max={1} step={0.01} onChange={(v) => commit({ taaFeedbackMax: v })} />
          </>
        )}
      </Section>

      {/* ── Contact Shadows ────────────────────────────────── */}
      <EffectSection
        title={t.postProcess.contactShadows}
        enabled={state.contactShadowsEnabled}
        onToggle={(v) => commit({ contactShadowsEnabled: v })}
        collapsed={collapsed.has("contactShadows")}
        onCollapse={() => toggle("contactShadows")}
      >
        <Slider label={t.postProcess.csDistance} value={state.contactShadowsDistance} min={0.01} max={2} step={0.01} onChange={(v) => commit({ contactShadowsDistance: v })} />
        <Slider label={t.postProcess.csThickness} value={state.contactShadowsThickness} min={0.001} max={0.5} step={0.005} onChange={(v) => commit({ contactShadowsThickness: v })} />
        <Slider label={t.postProcess.csIntensity} value={state.contactShadowsIntensity} min={0} max={1} step={0.05} onChange={(v) => commit({ contactShadowsIntensity: v })} />
        <Slider label={t.postProcess.csBias} value={state.contactShadowsBias} min={0} max={0.1} step={0.005} onChange={(v) => commit({ contactShadowsBias: v })} />
        <IntSlider label={t.postProcess.csSteps} value={state.contactShadowsSteps} min={4} max={64} step={4} onChange={(v) => commit({ contactShadowsSteps: v })} />
      </EffectSection>

      {/* ── DOF ────────────────────────────────────────────── */}
      <EffectSection
        title={t.postProcess.dof}
        enabled={state.dofEnabled}
        onToggle={(v) => commit({ dofEnabled: v })}
        collapsed={collapsed.has("dof")}
        onCollapse={() => toggle("dof")}
      >
        <Slider label={t.postProcess.dofFocusDistance} value={state.dofFocusDistance} min={0.1} max={200} step={0.5} onChange={(v) => commit({ dofFocusDistance: v })} />
        <Slider label={t.postProcess.dofFocusRange} value={state.dofFocusRange} min={0.1} max={100} step={0.5} onChange={(v) => commit({ dofFocusRange: v })} />
        <Slider label={t.postProcess.dofBlurRadius} value={state.dofBlurRadius} min={0} max={30} step={0.5} onChange={(v) => commit({ dofBlurRadius: v })} />
        <Slider label={t.postProcess.dofBokehRadius} value={state.dofBokehRadius} min={0} max={15} step={0.5} onChange={(v) => commit({ dofBokehRadius: v })} />
        <Slider label={t.postProcess.dofNearBlur} value={state.dofNearBlur} min={0} max={50} step={0.5} onChange={(v) => commit({ dofNearBlur: v })} />
        <Slider label={t.postProcess.dofFarBlur} value={state.dofFarBlur} min={0} max={500} step={5} onChange={(v) => commit({ dofFarBlur: v })} />
        <IntSlider label={t.postProcess.dofQuality} value={state.dofQuality} min={1} max={16} step={1} onChange={(v) => commit({ dofQuality: v })} />
      </EffectSection>

      {/* ── Color Grading ──────────────────────────────────── */}
      <EffectSection
        title={t.postProcess.colorGrading}
        enabled={state.colorGradingEnabled}
        onToggle={(v) => commit({ colorGradingEnabled: v })}
        collapsed={collapsed.has("colorGrading")}
        onCollapse={() => toggle("colorGrading")}
      >
        <Slider label={t.postProcess.cgSaturation} value={state.colorGradingSaturation} min={0} max={3} step={0.05} onChange={(v) => commit({ colorGradingSaturation: v })} />
        <Slider label={t.postProcess.cgContrast} value={state.colorGradingContrast} min={0} max={3} step={0.05} onChange={(v) => commit({ colorGradingContrast: v })} />
        <Slider label={t.postProcess.cgGamma} value={state.colorGradingGamma} min={0.1} max={3} step={0.05} onChange={(v) => commit({ colorGradingGamma: v })} />
      </EffectSection>

      {/* ── LUT Tonemapping ────────────────────────────────── */}
      <EffectSection
        title={t.postProcess.lut}
        enabled={state.lutEnabled}
        onToggle={(v) => commit({ lutEnabled: v })}
        collapsed={collapsed.has("lut")}
        onCollapse={() => toggle("lut")}
      >
        <Slider label={t.postProcess.lutIntensity} value={state.lutIntensity} min={0} max={2} step={0.05} onChange={(v) => commit({ lutIntensity: v })} />
        <div style={styles.field}>
          <label style={styles.label}>{t.postProcess.lutPreset}</label>
          <select
            value={state.lutPreset}
            onChange={(e) => commit({ lutPreset: e.target.value })}
            style={styles.select}
          >
            {LUT_PRESETS.map((p) => (
              <option key={p} value={p}>{p}</option>
            ))}
          </select>
        </div>
      </EffectSection>

      {/* ── Volumetric Fog ─────────────────────────────────── */}
      <EffectSection
        title={t.postProcess.volumetricFog}
        enabled={state.volumetricFogEnabled}
        onToggle={(v) => commit({ volumetricFogEnabled: v })}
        collapsed={collapsed.has("fog")}
        onCollapse={() => toggle("fog")}
      >
        <Slider label={t.postProcess.vfDensity} value={state.volumetricFogDensity} min={0} max={0.5} step={0.005} onChange={(v) => commit({ volumetricFogDensity: v })} />
        <Slider label={t.postProcess.vfHeightFalloff} value={state.volumetricFogHeightFalloff} min={0} max={1} step={0.01} onChange={(v) => commit({ volumetricFogHeightFalloff: v })} />
        <Slider label={t.postProcess.vfMaxDistance} value={state.volumetricFogMaxDistance} min={1} max={500} step={5} onChange={(v) => commit({ volumetricFogMaxDistance: v })} />
      </EffectSection>

      {/* ── RT Shadows ─────────────────────────────────────── */}
      <EffectSection
        title={t.postProcess.rtShadows}
        enabled={state.rtShadowsEnabled}
        onToggle={(v) => commit({ rtShadowsEnabled: v })}
        collapsed={collapsed.has("rtShadows")}
        onCollapse={() => toggle("rtShadows")}
      >
        <IntSlider label={t.postProcess.rtSamples} value={state.rtShadowSamples} min={1} max={64} step={1} onChange={(v) => commit({ rtShadowSamples: v })} />
        <Slider label={t.postProcess.rtStrength} value={state.rtShadowStrength} min={0} max={1} step={0.05} onChange={(v) => commit({ rtShadowStrength: v })} />
        <Slider label={t.postProcess.rtSoftness} value={state.rtShadowSoftness} min={0} max={0.1} step={0.001} onChange={(v) => commit({ rtShadowSoftness: v })} />
        <Slider label={t.postProcess.rtResolutionScale} value={state.rtShadowResolutionScale} min={0.25} max={2} step={0.25} onChange={(v) => commit({ rtShadowResolutionScale: v })} />
      </EffectSection>
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

function EffectSection({
  title,
  enabled,
  onToggle,
  collapsed,
  onCollapse,
  children,
}: {
  title: string;
  enabled: boolean;
  onToggle: (v: boolean) => void;
  collapsed: boolean;
  onCollapse: () => void;
  children: React.ReactNode;
}) {
  return (
    <div style={styles.section}>
      <div style={styles.sectionHeader}>
        <div style={{ display: "flex", alignItems: "center", gap: 4, cursor: "pointer", flex: 1 }} onClick={onCollapse}>
          <span style={styles.arrow}>{collapsed ? <IconTriangleRight size={10} /> : <IconTriangleDown size={10} />}</span>
          <span style={{ ...styles.sectionTitle, opacity: enabled ? 1 : 0.5 }}>{title}</span>
        </div>
        <input
          type="checkbox"
          checked={enabled}
          onChange={(e) => onToggle(e.target.checked)}
          style={{ accentColor: "#89b4fa" }}
          onClick={(e) => e.stopPropagation()}
        />
      </div>
      {!collapsed && enabled && children}
    </div>
  );
}

function Slider({
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
      <span style={styles.sliderValue}>{value.toFixed(step < 1 ? Math.max(2, -Math.floor(Math.log10(step))) : 0)}</span>
    </div>
  );
}

function IntSlider({
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
        onChange={(e) => onChange(parseInt(e.target.value, 10))}
        style={styles.slider}
      />
      <span style={styles.sliderValue}>{value}</span>
    </div>
  );
}

function Toggle({
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
        style={{ accentColor: "#89b4fa" }}
      />
    </div>
  );
}

// ── Styles ──────────────────────────────────────────────────────

const styles: Record<string, React.CSSProperties> = {
  container: { display: "flex", flexDirection: "column", overflowY: "auto" },
  header: {
    padding: "8px 12px",
    borderBottom: "1px solid #313244",
    fontSize: 12,
    fontWeight: 600,
    textTransform: "uppercase",
    letterSpacing: 0.5,
    color: "#a6adc8",
  },
  empty: { padding: 24, textAlign: "center", opacity: 0.4, fontSize: 13 },
  section: { borderBottom: "1px solid #313244", padding: "6px 12px" },
  sectionHeader: {
    display: "flex",
    alignItems: "center",
    gap: 4,
    userSelect: "none",
    marginBottom: 4,
  },
  sectionTitle: { fontSize: 12, fontWeight: 600, color: "#cdd6f4" },
  arrow: { fontSize: 10, color: "#6c7086", width: 12 },
  field: {
    display: "flex",
    alignItems: "center",
    padding: "2px 0",
    fontSize: 12,
    gap: 6,
  },
  label: { color: "#a6adc8", minWidth: 90, fontSize: 11 },
  slider: { flex: 1, accentColor: "#89b4fa", height: 4 },
  sliderValue: {
    color: "#cdd6f4",
    fontSize: 10,
    fontFamily: "monospace",
    minWidth: 40,
    textAlign: "right" as const,
  },
  select: {
    background: "#313244",
    border: "1px solid #45475a",
    borderRadius: 3,
    color: "#cdd6f4",
    padding: "2px 6px",
    fontSize: 11,
    flex: 1,
    outline: "none",
    appearance: "none" as const,
  },
};
