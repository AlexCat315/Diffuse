import { useLocalState } from "../store/local-state";
import React, { useEffect, useCallback, useRef } from "react";
import { useI18n } from "../i18n";
import { useConnectionStore } from "../store";

interface PluginInfo {
  name: string;
  pluginType: string;
  source: string;
  lifecycle: string;
  lastError?: string;
}


export function PluginManager() {
  const connected = useConnectionStore((s) => s.connected);
  const { t } = useI18n();
  const [plugins, setPlugins] = useLocalState<PluginInfo[]>([]);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const refresh = useCallback(async () => {
    if (!connected) return;
    try {
      const res = await window.guavaEngine.call("plugin.list", {});
      setPlugins(res.plugins);
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

  const handleEnable = async (name: string) => {
    try {
      await window.guavaEngine.call("plugin.enable", { name });
      refresh();
    } catch {
      /* ignore */
    }
  };

  const handleDisable = async (name: string) => {
    try {
      await window.guavaEngine.call("plugin.disable", { name });
      refresh();
    } catch {
      /* ignore */
    }
  };

  const handleUnload = async (name: string) => {
    try {
      await window.guavaEngine.call("plugin.unload", { name });
      refresh();
    } catch {
      /* ignore */
    }
  };

  const handleRescan = async () => {
    try {
      await window.guavaEngine.call("plugin.rescan", {});
      refresh();
    } catch {
      /* ignore */
    }
  };

  const lifecycleColor = (lc: string) => {
    switch (lc) {
      case "enabled":
        return "#4caf50";
      case "loaded":
        return "#90caf9";
      case "unloaded":
        return "#888";
      case "load_error":
        return "#ef5350";
      default:
        return "#aaa";
    }
  };

  return (
    <div style={styles.container}>
      <div style={styles.toolbar}>
        <button style={styles.button} onClick={handleRescan}>
          {t.plugins.rescanButton}
        </button>
        <span style={styles.count}>{plugins.length} {t.plugins.countSuffix}</span>
      </div>
      <table style={styles.table}>
        <thead>
          <tr>
            <th style={styles.th}>{t.plugins.columnName}</th>
            <th style={styles.th}>{t.plugins.columnType}</th>
            <th style={styles.th}>{t.plugins.columnSource}</th>
            <th style={styles.th}>{t.plugins.columnState}</th>
            <th style={styles.th}>{t.plugins.columnActions}</th>
            <th style={styles.th}>{t.plugins.columnError}</th>
          </tr>
        </thead>
        <tbody>
          {plugins.map((p) => (
            <tr key={p.name} style={styles.row}>
              <td style={styles.td}>{p.name}</td>
              <td style={styles.td}>{p.pluginType}</td>
              <td style={styles.td}>{p.source}</td>
              <td style={styles.td}>
                <span style={{ color: lifecycleColor(p.lifecycle) }}>
                  {p.lifecycle}
                </span>
              </td>
              <td style={styles.td}>
                {p.lifecycle === "loaded" && (
                  <button
                    style={styles.actionBtn}
                    onClick={() => handleEnable(p.name)}
                  >
                    {t.plugins.enable}
                  </button>
                )}
                {p.lifecycle === "enabled" && (
                  <button
                    style={styles.actionBtn}
                    onClick={() => handleDisable(p.name)}
                  >
                    {t.plugins.disable}
                  </button>
                )}
                {p.lifecycle !== "load_error" && (
                  <button
                    style={styles.actionBtn}
                    onClick={() => handleUnload(p.name)}
                  >
                    {t.plugins.unload}
                  </button>
                )}
              </td>
              <td style={{ ...styles.td, color: "#ef5350" }}>
                {p.lastError || "—"}
              </td>
            </tr>
          ))}
          {plugins.length === 0 && (
            <tr>
              <td colSpan={6} style={{ ...styles.td, textAlign: "center" }}>
                {t.plugins.noPluginsFound}
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  container: {
    padding: 8,
    height: "100%",
    overflow: "auto",
    fontFamily: "monospace",
    fontSize: 12,
    color: "#ccc",
  },
  toolbar: {
    display: "flex",
    alignItems: "center",
    gap: 12,
    marginBottom: 8,
  },
  button: {
    padding: "4px 12px",
    background: "#3a3a3a",
    border: "1px solid #555",
    color: "#ccc",
    borderRadius: 3,
    cursor: "pointer",
  },
  count: { color: "#888", fontSize: 11 },
  table: { width: "100%", borderCollapse: "collapse" as const },
  th: {
    textAlign: "left" as const,
    padding: "4px 8px",
    borderBottom: "1px solid #444",
    color: "#aaa",
    fontSize: 11,
  },
  td: { padding: "4px 8px", borderBottom: "1px solid #333" },
  row: {},
  actionBtn: {
    padding: "2px 8px",
    marginRight: 4,
    background: "#2a2a2a",
    border: "1px solid #555",
    color: "#ccc",
    borderRadius: 3,
    cursor: "pointer",
    fontSize: 11,
  },
};
