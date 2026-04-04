import { useState, useEffect, useCallback } from "react";
import { rpc } from "../rpc";

interface PhysicsVizSettings {
  drawMode: string;
  opacity: number;
  velocityScale: number;
  wireframeOnly: boolean;
  showCollisionShapes: boolean;
  showRigidbodies: boolean;
  showTriggers: boolean;
  showConstraints: boolean;
  showVelocityVectors: boolean;
  showSleepState: boolean;
  showAabbs: boolean;
  colorStatic: number[];
  colorDynamic: number[];
  colorKinematic: number[];
  colorTrigger: number[];
  colorSleeping: number[];
  colorConstraint: number[];
}

const drawModes = ["off", "selection_only", "all"] as const;
const drawModeLabels: Record<string, string> = {
  off: "Off",
  selection_only: "Selection Only",
  all: "All",
};

const toggleKeys = [
  { key: "wireframeOnly", label: "Wireframe" },
  { key: "showCollisionShapes", label: "Collision Shapes" },
  { key: "showRigidbodies", label: "Rigidbodies" },
  { key: "showTriggers", label: "Triggers" },
  { key: "showConstraints", label: "Constraints" },
  { key: "showVelocityVectors", label: "Velocity Vectors" },
  { key: "showSleepState", label: "Sleep State" },
  { key: "showAabbs", label: "AABBs" },
] as const;

const colorKeys = [
  { key: "static", label: "Static" },
  { key: "dynamic", label: "Dynamic" },
  { key: "kinematic", label: "Kinematic" },
  { key: "trigger", label: "Trigger" },
  { key: "sleeping", label: "Sleeping" },
  { key: "constraint", label: "Constraint" },
] as const;

function rgbaToHex(c: number[]): string {
  const r = Math.round((c[0] ?? 0) * 255);
  const g = Math.round((c[1] ?? 0) * 255);
  const b = Math.round((c[2] ?? 0) * 255);
  return `#${r.toString(16).padStart(2, "0")}${g.toString(16).padStart(2, "0")}${b.toString(16).padStart(2, "0")}`;
}

function hexToRgba(hex: string, alpha: number): [number, number, number, number] {
  const r = parseInt(hex.slice(1, 3), 16) / 255;
  const g = parseInt(hex.slice(3, 5), 16) / 255;
  const b = parseInt(hex.slice(5, 7), 16) / 255;
  return [r, g, b, alpha];
}

interface PhysicsVisualizationProps {
  connected: boolean;
}

export function PhysicsVisualization({ connected }: PhysicsVisualizationProps) {
  const [settings, setSettings] = useState<PhysicsVizSettings | null>(null);

  const refresh = useCallback(async () => {
    try {
      const res = (await rpc("physicsviz.getSettings", {})) as PhysicsVizSettings;
      setSettings(res);
    } catch {
      /* offline */
    }
  }, []);

  useEffect(() => {
    refresh();
    const id = setInterval(refresh, 2000);
    return () => clearInterval(id);
  }, [refresh]);

  if (!settings) return <div className="panel-empty">Loading…</div>;

  const setDrawMode = async (mode: string) => {
    await rpc("physicsviz.setDrawMode", { mode });
    refresh();
  };

  const setToggle = async (key: string, value: boolean) => {
    await rpc("physicsviz.setToggle", { key, value });
    refresh();
  };

  const setFloat = async (key: string, value: number) => {
    await rpc("physicsviz.setFloat", { key, value });
    refresh();
  };

  const setColor = async (key: string, hex: string, alpha: number) => {
    const [r, g, b, a] = hexToRgba(hex, alpha);
    await rpc("physicsviz.setColor", { key, r, g, b, a });
    refresh();
  };

  const active = settings.drawMode !== "off";

  return (
    <div style={{ padding: 8, fontSize: 13 }}>
      <div style={{ marginBottom: 8 }}>
        <label style={{ marginRight: 8 }}>Draw Mode</label>
        <select value={settings.drawMode} onChange={(e) => setDrawMode(e.target.value)}>
          {drawModes.map((m) => (
            <option key={m} value={m}>{drawModeLabels[m]}</option>
          ))}
        </select>
      </div>

      {active && (
        <>
          <div style={{ marginBottom: 6 }}>
            <label>Opacity</label>
            <input
              type="range" min={0} max={1} step={0.01}
              value={settings.opacity}
              onChange={(e) => setFloat("opacity", parseFloat(e.target.value))}
              style={{ width: "100%" }}
            />
            <span style={{ float: "right" }}>{settings.opacity.toFixed(2)}</span>
          </div>

          <h4 style={{ margin: "8px 0 4px" }}>Show</h4>
          {toggleKeys.map(({ key, label }) => (
            <label key={key} style={{ display: "block", marginBottom: 2 }}>
              <input
                type="checkbox"
                checked={(settings as unknown as Record<string, unknown>)[key] as boolean}
                onChange={(e) => setToggle(key, e.target.checked)}
              />
              {" "}{label}
            </label>
          ))}

          {settings.showVelocityVectors && (
            <div style={{ marginTop: 4 }}>
              <label>Velocity Scale</label>
              <input
                type="range" min={0.1} max={10} step={0.1}
                value={settings.velocityScale}
                onChange={(e) => setFloat("velocityScale", parseFloat(e.target.value))}
                style={{ width: "100%" }}
              />
              <span style={{ float: "right" }}>{settings.velocityScale.toFixed(1)}</span>
            </div>
          )}

          <h4 style={{ margin: "8px 0 4px" }}>Colors</h4>
          {colorKeys.map(({ key, label }) => {
            const c = (settings as unknown as Record<string, number[]>)[`color${key.charAt(0).toUpperCase() + key.slice(1)}`] ?? [0, 0, 0, 1];
            return (
              <div key={key} style={{ display: "flex", alignItems: "center", marginBottom: 2 }}>
                <input
                  type="color"
                  value={rgbaToHex(c)}
                  onChange={(e) => setColor(key, e.target.value, c[3] ?? 0.8)}
                  style={{ marginRight: 6 }}
                />
                <span>{label}</span>
              </div>
            );
          })}
        </>
      )}
    </div>
  );
}
