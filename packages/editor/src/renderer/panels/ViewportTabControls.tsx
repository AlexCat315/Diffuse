import React, { useCallback } from "react";
import { useViewportSettingsStore } from "../store";
import type { ShadingMode } from "../store/viewport-settings";
import {
  IconShadingSolid,
  IconShadingMaterial,
  IconShadingRendered,
  IconShadingWireframe,
} from "../components/Icons";
import { useI18n } from "../i18n";

const SHADING_ICONS: Record<ShadingMode, React.FC<{ size?: number; color?: string }>> = {
  solid: IconShadingSolid,
  material: IconShadingMaterial,
  rendered: IconShadingRendered,
  wireframe: IconShadingWireframe,
};

/**
 * Shading mode selector rendered in the Viewport panel's tab header (via
 * flexlayout onRenderTabSet). Stays out of the canvas so it's never occluded.
 */
export function ViewportTabControls() {
  const shadingMode = useViewportSettingsStore((s) => s.shadingMode);
  const setShadingMode = useViewportSettingsStore((s) => s.setShadingMode);
  const { t } = useI18n();

  const handleChange = useCallback(
    (mode: ShadingMode) => setShadingMode(mode),
    [setShadingMode],
  );

  const labels: Record<ShadingMode, string> = {
    solid: t.renderSettings.solid,
    material: t.renderSettings.material,
    rendered: t.renderSettings.rendered,
    wireframe: t.renderSettings.wireframe,
  };

  return (
    <div
      style={styles.container}
      onMouseDown={(e) => e.stopPropagation()}
      onPointerDown={(e) => e.stopPropagation()}
    >
      {(["solid", "material", "rendered", "wireframe"] as ShadingMode[]).map((mode) => {
        const Icon = SHADING_ICONS[mode];
        const active = shadingMode === mode;
        return (
          <button
            key={mode}
            title={labels[mode]}
            style={{ ...styles.btn, ...(active ? styles.btnActive : {}) }}
            onClick={() => handleChange(mode)}
          >
            <Icon size={13} color={active ? "#89b4fa" : "#a6adc8"} />
          </button>
        );
      })}
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  container: {
    display: "flex",
    alignItems: "center",
    gap: 1,
    padding: "0 6px",
  },
  btn: {
    background: "transparent",
    border: "1px solid transparent",
    borderRadius: 4,
    cursor: "pointer",
    padding: "3px 6px",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    minWidth: 24,
    transition: "all 0.1s",
  },
  btnActive: {
    background: "rgba(69, 71, 90, 0.8)",
    border: "1px solid rgba(137, 180, 250, 0.5)",
  },
};
