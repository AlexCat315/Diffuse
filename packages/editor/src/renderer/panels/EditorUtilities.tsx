import React, { useEffect, useState, useCallback } from "react";
import { useI18n } from "../i18n";
import { IconClose, IconRefresh } from "../components/Icons";
import { rpc } from "../rpc";

type EditorUtilityStatus = "ready" | "load_error" | "init_error" | "update_error";

interface EditorUtilitySnapshot {
  handle: number;
  name: string;
  description: string;
  sourcePath: string;
  status: EditorUtilityStatus;
  open: boolean;
  lastError: string;
}

interface EditorUtilitiesProps {
  connected: boolean;
}

export function EditorUtilities({ connected }: EditorUtilitiesProps) {
  const { t } = useI18n();
  const [utilities, setUtilities] = useState<EditorUtilitySnapshot[]>([]);
  const [runtimeAvailable, setRuntimeAvailable] = useState(true);
  const [loading, setLoading] = useState(false);

  const fetchUtilities = useCallback(async () => {
    if (!connected) return;
    setLoading(true);
    try {
      const result = await rpc("utilities.list", {}) as {
        utilities: EditorUtilitySnapshot[];
      };
      setRuntimeAvailable(true);
      setUtilities(result.utilities ?? []);
    } catch {
      setRuntimeAvailable(false);
      setUtilities([]);
    } finally {
      setLoading(false);
    }
  }, [connected]);

  useEffect(() => {
    fetchUtilities();
    const interval = setInterval(fetchUtilities, 3000);
    return () => clearInterval(interval);
  }, [fetchUtilities]);

  const handleToggleOpen = useCallback(async (handle: number, open: boolean) => {
    try {
      await rpc("utilities.setOpen", { handle, open });
      setUtilities((prev) =>
        prev.map((u) => (u.handle === handle ? { ...u, open } : u))
      );
    } catch {
      /* ignore */
    }
  }, []);

  const handleUnload = useCallback(async (handle: number) => {
    try {
      await rpc("utilities.remove", { handle });
      setUtilities((prev) => prev.filter((u) => u.handle !== handle));
    } catch {
      /* ignore */
    }
  }, []);

  const statusLabel = (status: EditorUtilityStatus): string => {
    const labels: Record<EditorUtilityStatus, string> = {
      ready: t.editorUtilities.statusReady,
      load_error: t.editorUtilities.statusLoadError,
      init_error: t.editorUtilities.statusInitError,
      update_error: t.editorUtilities.statusUpdateError,
    };
    return labels[status];
  };

  const statusColor = (status: EditorUtilityStatus): string => {
    switch (status) {
      case "ready": return "#a6e3a1";
      case "load_error": return "#f38ba8";
      case "init_error": return "#fab387";
      case "update_error": return "#f9e2af";
    }
  };

  if (!runtimeAvailable) {
    return (
      <div style={styles.container}>
        <div style={styles.emptyState}>{t.editorUtilities.runtimeUnavailable}</div>
      </div>
    );
  }

  if (!loading && utilities.length === 0) {
    return (
      <div style={styles.container}>
        <div style={styles.header}>
          <span style={styles.title}>{t.editorUtilities.title}</span>
          <button style={styles.iconBtn} onClick={fetchUtilities} title={t.assets.refreshTooltip}>
            <IconRefresh size={14} />
          </button>
        </div>
        <div style={styles.emptyState}>{t.editorUtilities.noUtilitiesLoaded}</div>
      </div>
    );
  }

  const openUtilities = utilities.filter((u) => u.open);

  return (
    <div style={styles.container}>
      {/* ── Header ──────────────────────────────────────── */}
      <div style={styles.header}>
        <span style={styles.title}>{t.editorUtilities.title}</span>
        <button style={styles.iconBtn} onClick={fetchUtilities} title={t.assets.refreshTooltip}>
          <IconRefresh size={14} />
        </button>
      </div>

      {/* ── Registry: Loaded Utilities ──────────────────── */}
      <div style={styles.sectionLabel}>{t.editorUtilities.loadedUtilities}</div>
      <div style={styles.registry}>
        {utilities.map((util, i) => (
          <div key={util.handle} style={styles.registryItem}>
            {i > 0 && <div style={styles.divider} />}
            <div style={styles.utilName}>{util.name}</div>
            {util.description && (
              <div style={styles.utilDescription}>{util.description}</div>
            )}
            {util.sourcePath && (
              <div style={styles.metaRow}>
                <span style={styles.metaLabel}>{t.editorUtilities.source}</span>
                <span style={styles.metaValue}>{util.sourcePath}</span>
              </div>
            )}
            <div style={styles.metaRow}>
              <span style={styles.metaLabel}>{t.editorUtilities.status}</span>
              <span style={{ ...styles.statusBadge, color: statusColor(util.status) }}>
                {statusLabel(util.status)}
              </span>
            </div>
            {util.lastError && util.status !== "ready" && (
              <div style={styles.errorText}>{util.lastError}</div>
            )}
            <div style={styles.actionRow}>
              <label style={styles.checkboxLabel}>
                <input
                  type="checkbox"
                  checked={util.open}
                  onChange={(e) => handleToggleOpen(util.handle, e.target.checked)}
                  style={styles.checkbox}
                />
                {t.editorUtilities.open}
              </label>
              <button style={styles.unloadBtn} onClick={() => handleUnload(util.handle)}>
                <IconClose size={10} />
                <span>{t.editorUtilities.unload}</span>
              </button>
            </div>
          </div>
        ))}
      </div>

      {/* ── Panel Content ───────────────────────────────── */}
      <div style={styles.divider} />
      <div style={styles.sectionLabel}>{t.editorUtilities.panelContent}</div>
      {openUtilities.length === 0 ? (
        <div style={styles.emptyState}>{t.editorUtilities.noPanelsOpen}</div>
      ) : (
        <div style={styles.panelContent}>
          {openUtilities.map((util) => (
            <div key={util.handle} style={styles.panelEntry}>
              <div style={styles.panelHeader}>{util.name}</div>
              {util.description && (
                <div style={styles.utilDescription}>{util.description}</div>
              )}
              <div style={styles.metaRow}>
                <span style={styles.metaLabel}>{t.editorUtilities.status}</span>
                <span style={{ ...styles.statusBadge, color: statusColor(util.status) }}>
                  {statusLabel(util.status)}
                </span>
              </div>
              {util.lastError && util.status !== "ready" && (
                <div style={styles.errorText}>{util.lastError}</div>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  container: {
    height: "100%",
    display: "flex",
    flexDirection: "column",
    overflow: "auto",
    fontSize: 12,
    color: "#cdd6f4",
  },
  header: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    padding: "6px 10px",
    background: "#181825",
    borderBottom: "1px solid #313244",
  },
  title: {
    fontWeight: 600,
    fontSize: 12,
  },
  iconBtn: {
    background: "none",
    border: "none",
    color: "#6c7086",
    cursor: "pointer",
    padding: 4,
    borderRadius: 3,
    display: "flex",
    alignItems: "center",
  },
  sectionLabel: {
    padding: "6px 10px 2px",
    fontSize: 11,
    fontWeight: 600,
    color: "#a6adc8",
    textTransform: "uppercase" as const,
    letterSpacing: 0.5,
  },
  registry: {
    padding: "0 10px 6px",
  },
  registryItem: {
    padding: "6px 0",
  },
  divider: {
    height: 1,
    background: "#313244",
    margin: "4px 0",
  },
  utilName: {
    fontWeight: 600,
    fontSize: 12,
    color: "#cdd6f4",
    marginBottom: 2,
  },
  utilDescription: {
    fontSize: 11,
    color: "#a6adc8",
    marginBottom: 4,
    lineHeight: 1.4,
  },
  metaRow: {
    display: "flex",
    alignItems: "center",
    gap: 6,
    fontSize: 11,
    marginBottom: 2,
  },
  metaLabel: {
    color: "#6c7086",
    minWidth: 50,
  },
  metaValue: {
    color: "#a6adc8",
    fontFamily: "monospace",
    fontSize: 10,
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap" as const,
  },
  statusBadge: {
    fontWeight: 600,
    fontSize: 10,
    textTransform: "uppercase" as const,
  },
  errorText: {
    fontSize: 10,
    color: "#f38ba8",
    padding: "4px 6px",
    background: "rgba(243, 139, 168, 0.1)",
    borderRadius: 3,
    marginTop: 4,
    lineHeight: 1.4,
    fontFamily: "monospace",
  },
  actionRow: {
    display: "flex",
    alignItems: "center",
    gap: 12,
    marginTop: 4,
  },
  checkboxLabel: {
    display: "flex",
    alignItems: "center",
    gap: 4,
    fontSize: 11,
    color: "#cdd6f4",
    cursor: "pointer",
  },
  checkbox: {
    margin: 0,
    cursor: "pointer",
  },
  unloadBtn: {
    display: "flex",
    alignItems: "center",
    gap: 4,
    background: "none",
    border: "1px solid #45475a",
    borderRadius: 3,
    color: "#f38ba8",
    cursor: "pointer",
    padding: "2px 8px",
    fontSize: 10,
  },
  panelContent: {
    flex: 1,
    padding: "0 10px",
    overflow: "auto",
  },
  panelEntry: {
    padding: "8px 0",
    borderBottom: "1px solid #313244",
  },
  panelHeader: {
    fontWeight: 600,
    fontSize: 12,
    color: "#89b4fa",
    marginBottom: 4,
  },
  emptyState: {
    padding: "16px 10px",
    textAlign: "center" as const,
    color: "#6c7086",
    fontSize: 11,
    lineHeight: 1.6,
  },
};
