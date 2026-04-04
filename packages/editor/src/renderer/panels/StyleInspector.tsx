import React, { useEffect, useState, useCallback, useRef } from "react";
import { useI18n } from "../i18n";
import { useConnectionStore } from "../store";

interface StyleParamSchema {
  name: string;
  displayName: string;
  paramType: string;
  defaultValue: number;
  minValue: number;
  maxValue: number;
}

interface StyleParamValue {
  name: string;
  value: number;
}

interface ActiveStyleInfo {
  name: string;
  displayName: string;
  meshProgram: string;
  shadowProgram?: string;
  source: string;
  path?: string;
  disabledPasses: string[];
  configSchema: StyleParamSchema[];
  paramValues: StyleParamValue[];
}

interface StyleListItem {
  name: string;
  displayName: string;
  source: string;
  isActive: boolean;
}


export function StyleInspector() {
  const connected = useConnectionStore((s) => s.connected);
  const { t } = useI18n();
  const [active, setActive] = useState<ActiveStyleInfo | null>(null);
  const [styles, setStyles] = useState<StyleListItem[]>([]);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const refresh = useCallback(async () => {
    if (!connected) return;
    try {
      const [activeRes, listRes] = await Promise.all([
        window.guavaEngine.call("style.getActiveStyle", {}),
        window.guavaEngine.call("style.listStyles", {}),
      ]);
      setActive(activeRes);
      setStyles(listRes.styles);
    } catch {
      /* ignore */
    }
  }, [connected]);

  useEffect(() => {
    refresh();
    timerRef.current = setInterval(refresh, 2000);
    return () => {
      if (timerRef.current) clearInterval(timerRef.current);
    };
  }, [refresh]);

  const handleStyleSwitch = async (name: string) => {
    try {
      await window.guavaEngine.call("style.setActiveStyle", { name });
      refresh();
    } catch {
      /* ignore */
    }
  };

  const handleParamChange = async (paramName: string, value: number) => {
    if (!active) return;
    try {
      await window.guavaEngine.call("style.setParam", {
        styleName: active.name,
        paramName,
        value,
      });
      setActive((prev) =>
        prev
          ? {
              ...prev,
              paramValues: prev.paramValues.map((pv) =>
                pv.name === paramName ? { ...pv, value } : pv
              ),
            }
          : null
      );
    } catch {
      /* ignore */
    }
  };

  const getParamValue = (name: string, defaultValue: number): number => {
    if (!active) return defaultValue;
    const pv = active.paramValues.find((p) => p.name === name);
    return pv !== undefined ? pv.value : defaultValue;
  };

  if (!active) {
    return <div style={panelStyles.container}>Loading...</div>;
  }

  return (
    <div style={panelStyles.container}>
      {/* Style selector */}
      <div style={panelStyles.section}>
        <div style={panelStyles.sectionTitle}>{t.style.activeStyle}</div>
        <select
          style={panelStyles.select}
          value={active.name}
          onChange={(e) => handleStyleSwitch(e.target.value)}
        >
          {styles.map((s) => (
            <option key={s.name} value={s.name}>
              {s.displayName} ({s.source})
            </option>
          ))}
        </select>
      </div>

      {/* Style info */}
      <div style={panelStyles.section}>
        <div style={panelStyles.row}>
          <span style={panelStyles.label}>{t.style.meshProgram}</span>
          <span style={panelStyles.value}>{active.meshProgram}</span>
        </div>
        <div style={panelStyles.row}>
          <span style={panelStyles.label}>{t.style.shadowProgram}</span>
          <span style={panelStyles.value}>
            {active.shadowProgram || "(none)"}
          </span>
        </div>
        {active.path && (
          <div style={panelStyles.row}>
            <span style={panelStyles.label}>{t.style.path}</span>
            <span style={panelStyles.value}>{active.path}</span>
          </div>
        )}
      </div>

      {/* Disabled passes */}
      {active.disabledPasses.length > 0 && (
        <div style={panelStyles.section}>
          <div style={panelStyles.sectionTitle}>{t.style.disabledPasses}</div>
          {active.disabledPasses.map((pass) => (
            <div key={pass} style={panelStyles.listItem}>
              {pass}
            </div>
          ))}
        </div>
      )}

      {/* Parameters */}
      {active.configSchema.length > 0 && (
        <div style={panelStyles.section}>
          <div style={panelStyles.sectionTitle}>{t.style.parameters}</div>
          {active.configSchema.map((param) => {
            const val = getParamValue(param.name, param.defaultValue);
            if (param.paramType === "float") {
              return (
                <div key={param.name} style={panelStyles.paramRow}>
                  <span style={panelStyles.paramLabel}>
                    {param.displayName}
                  </span>
                  <input
                    type="range"
                    min={param.minValue}
                    max={param.maxValue}
                    step={(param.maxValue - param.minValue) / 100}
                    value={val}
                    onChange={(e) =>
                      handleParamChange(param.name, parseFloat(e.target.value))
                    }
                    style={panelStyles.slider}
                  />
                  <span style={panelStyles.paramValue}>{val.toFixed(2)}</span>
                </div>
              );
            } else if (param.paramType === "boolean") {
              return (
                <div key={param.name} style={panelStyles.paramRow}>
                  <span style={panelStyles.paramLabel}>
                    {param.displayName}
                  </span>
                  <input
                    type="checkbox"
                    checked={val >= 0.5}
                    onChange={(e) =>
                      handleParamChange(
                        param.name,
                        e.target.checked ? 1.0 : 0.0
                      )
                    }
                  />
                </div>
              );
            } else {
              return (
                <div key={param.name} style={panelStyles.paramRow}>
                  <span style={panelStyles.paramLabel}>
                    {param.displayName}
                  </span>
                  <span style={panelStyles.paramValue}>
                    {param.paramType} (TODO)
                  </span>
                </div>
              );
            }
          })}
        </div>
      )}
    </div>
  );
}

const panelStyles: Record<string, React.CSSProperties> = {
  container: {
    padding: 8,
    height: "100%",
    overflow: "auto",
    fontFamily: "monospace",
    fontSize: 12,
    color: "#ccc",
  },
  section: { marginBottom: 12 },
  sectionTitle: {
    color: "#aaa",
    fontSize: 11,
    textTransform: "uppercase" as const,
    marginBottom: 4,
    borderBottom: "1px solid #444",
    paddingBottom: 2,
  },
  row: {
    display: "flex",
    justifyContent: "space-between",
    padding: "2px 0",
  },
  label: { color: "#888" },
  value: { color: "#ddd" },
  listItem: { padding: "2px 8px", color: "#ccc" },
  select: {
    width: "100%",
    padding: "4px 8px",
    background: "#2a2a2a",
    border: "1px solid #555",
    color: "#ccc",
    borderRadius: 3,
  },
  paramRow: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    padding: "3px 0",
  },
  paramLabel: { flex: "0 0 120px", color: "#aaa", fontSize: 11 },
  slider: { flex: 1 },
  paramValue: { flex: "0 0 50px", textAlign: "right" as const, fontSize: 11 },
};
