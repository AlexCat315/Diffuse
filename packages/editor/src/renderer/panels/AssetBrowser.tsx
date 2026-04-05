import React, { useEffect, useCallback } from "react";
import { useLocalState } from "../store/local-state";
import type { AssetEntry } from "../../shared/rpc-types";
import { useI18n } from "../i18n";
import { useSyncedState } from "../store/synced-state";
import {
  IconFolder, IconModel, IconTexture, IconShader, IconScene,
  IconScript, IconAudio, IconMaterial, IconFile, IconArrowUp, IconRefresh,
} from "../components/Icons";
import { useConnectionStore } from "../store";


const ASSET_ICONS: Record<string, React.ComponentType<{ size?: number; color?: string }>> = {
  folder: IconFolder,
  model: IconModel,
  texture: IconTexture,
  shader: IconShader,
  scene: IconScene,
  script: IconScript,
  audio: IconAudio,
  material: IconMaterial,
  unknown: IconFile,
};

export function AssetBrowser() {
  const connected = useConnectionStore((s) => s.connected);
  const { t } = useI18n();
  const [currentPath, setCurrentPath] = useSyncedState("asset-browser", "currentPath", "assets");
  const [entries, setEntries] = useLocalState<AssetEntry[]>([]);
  const [loading, setLoading] = useLocalState(false);

  const fetchDir = useCallback(
    async (path: string) => {
      if (!connected) return;
      setLoading(true);
      try {
        const result = await window.guavaEngine.call("assets.list", { path });
        setEntries(result.entries);
        setCurrentPath(result.path);
      } catch {
        setEntries([]);
      } finally {
        setLoading(false);
      }
    },
    [connected],
  );

  useEffect(() => {
    fetchDir(currentPath);
  }, [connected]);

  const handleClick = useCallback(
    (entry: AssetEntry) => {
      if (entry.isDirectory) {
        fetchDir(entry.path);
      }
    },
    [fetchDir],
  );

  const handleNavigateUp = useCallback(() => {
    const parent = currentPath.includes("/")
      ? currentPath.substring(0, currentPath.lastIndexOf("/"))
      : currentPath;
    if (parent !== currentPath && parent.length > 0) {
      fetchDir(parent);
    }
  }, [currentPath, fetchDir]);

  const pathParts = currentPath.split("/");

  return (
    <div style={styles.container}>
      <div style={styles.header}>
        <span style={styles.title}>{t.assets.title}</span>
        <button style={styles.refreshBtn} onClick={() => fetchDir(currentPath)} title={t.assets.refreshTooltip}>
          <IconRefresh size={14} />
        </button>
      </div>

      {/* Breadcrumbs */}
      <div style={styles.breadcrumbs}>
        {pathParts.map((part, i) => {
          const path = pathParts.slice(0, i + 1).join("/");
          return (
            <React.Fragment key={path}>
              {i > 0 && <span style={styles.breadcrumbSep}>/</span>}
              <span
                style={{
                  ...styles.breadcrumb,
                  ...(i === pathParts.length - 1 ? styles.breadcrumbActive : {}),
                }}
                onClick={() => fetchDir(path)}
              >
                {part}
              </span>
            </React.Fragment>
          );
        })}
      </div>

      {/* File list */}
      <div style={styles.list}>
        {currentPath !== "assets" && (
          <div style={styles.entry} onClick={handleNavigateUp}>
            <span style={styles.icon}><IconArrowUp size={14} /></span>
            <span style={styles.entryName}>{t.assets.parentDirectory}</span>
          </div>
        )}
        {loading ? (
          <div style={styles.empty}>{t.common.loading}</div>
        ) : entries.length === 0 ? (
          <div style={styles.empty}>{t.assets.emptyDirectory}</div>
        ) : (
          entries.map((entry) => (
            <div
              key={entry.name}
              style={styles.entry}
              onClick={() => handleClick(entry)}
              onMouseEnter={(e) => (e.currentTarget.style.background = "#313244")}
              onMouseLeave={(e) => (e.currentTarget.style.background = "transparent")}
            >
              <span style={styles.icon}>
                {React.createElement(ASSET_ICONS[entry.assetType ?? "unknown"] ?? IconFile, { size: 14 })}
              </span>
              <span style={styles.entryName}>{entry.name}</span>
              {!entry.isDirectory && entry.assetType && (
                <span style={styles.assetType}>{entry.assetType}</span>
              )}
            </div>
          ))
        )}
      </div>
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  container: {
    display: "flex",
    flexDirection: "column",
    height: "100%",
    color: "#cdd6f4",
    fontSize: 13,
  },
  header: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    padding: "8px 12px 4px",
  },
  title: {
    fontSize: 14,
    fontWeight: 600,
    color: "#89b4fa",
  },
  refreshBtn: {
    background: "transparent",
    border: "none",
    color: "#a6adc8",
    cursor: "pointer",
    fontSize: 14,
    padding: "2px 6px",
    borderRadius: 4,
  },
  breadcrumbs: {
    display: "flex",
    alignItems: "center",
    padding: "2px 12px 6px",
    fontSize: 11,
    flexWrap: "wrap" as const,
    gap: 2,
  },
  breadcrumb: {
    color: "#6c7086",
    cursor: "pointer",
    padding: "1px 4px",
    borderRadius: 3,
  },
  breadcrumbActive: {
    color: "#cdd6f4",
  },
  breadcrumbSep: {
    color: "#45475a",
    margin: "0 1px",
  },
  list: {
    flex: 1,
    overflow: "auto",
    paddingBottom: 8,
  },
  entry: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    padding: "4px 12px",
    cursor: "pointer",
    borderRadius: 0,
    transition: "background 0.1s",
  },
  icon: {
    fontSize: 14,
    width: 20,
    textAlign: "center" as const,
  },
  entryName: {
    flex: 1,
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap" as const,
  },
  assetType: {
    fontSize: 10,
    color: "#6c7086",
    textTransform: "uppercase" as const,
    letterSpacing: 0.5,
  },
  empty: {
    padding: 16,
    textAlign: "center" as const,
    opacity: 0.4,
  },
};
