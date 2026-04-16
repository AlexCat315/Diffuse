import React, { useEffect, useCallback } from "react";
import { useLocalState } from "../store/local-state";
import type { EntityNode, ComponentField } from "../../shared/rpc-types";
import { useConnectionStore, useSceneStore, useEntityCacheStore } from "../store";
import { IconLightSun, IconCheck } from "../components/Icons";
import { engine } from "../engine-client";

// ── Types ────────────────────────────────────────────────────────

interface HdrAssetEntry {
  name: string;
  path: string;
}

interface SkyState {
  entityId: number;
  environmentAssetId: string;
  sourcePath: string;
  intensity: number;
  enabled: boolean;
}

// ── SkyPanel ─────────────────────────────────────────────────────

export function SkyPanel() {
  const connected = useConnectionStore((s) => s.connected);
  const hierarchy = useSceneStore((s) => s.hierarchy);
  const [sky, setSky] = useLocalState<SkyState | null>(null);
  const [hdrFiles, setHdrFiles] = useLocalState<HdrAssetEntry[]>([]);
  const [loading, setLoading] = useLocalState(false);
  const [dragOver, setDragOver] = useLocalState(false);

  // Scan project for .hdr files
  useEffect(() => {
    if (!connected) return;
    const found: HdrAssetEntry[] = [];
    const scanDir = async (dirPath: string) => {
      try {
        const res = (await engine.call("assets.list", { path: dirPath })) as {
          entries?: { name: string; path: string; isDirectory: boolean; assetType: string }[];
        };
        for (const entry of res.entries ?? []) {
          if (entry.isDirectory) {
            await scanDir(entry.path);
          } else if (entry.name.toLowerCase().endsWith(".hdr")) {
            found.push({ name: entry.name, path: entry.path });
          }
        }
      } catch {
        /* ignore */
      }
    };
    scanDir("Content").then(() => setHdrFiles(found));
  }, [connected]);

  // Find first entity with Sky component
  const findSkyEntity = useCallback((): number | null => {
    const search = (nodes: EntityNode[]): number | null => {
      for (const node of nodes) {
        // We can't peek components from hierarchy alone, but entity names containing "Sky"
        // are a heuristic; we'll do a proper check via cache.
        const cached = useEntityCacheStore.getState().getCached(node.id);
        if (cached?.components.some((c) => c.type === "Sky")) return node.id;
        const found = search(node.children);
        if (found != null) return found;
      }
      return null;
    };
    return search(hierarchy);
  }, [hierarchy]);

  // Fetch Sky state from engine
  const refreshSky = useCallback(async () => {
    if (!connected) return;

    // First: try to find an entity with Sky component from cache
    let skyEntityId = findSkyEntity();
    console.log('[SkyPanel] refreshSky: findSkyEntity from cache =', skyEntityId, 'hierarchy nodes =', hierarchy.length);

    // If not in cache, scan all entities (depth-first) by fetching their components
    if (skyEntityId == null) {
      const scanAll = async (nodes: EntityNode[]): Promise<number | null> => {
        for (const node of nodes) {
          const data = await useEntityCacheStore.getState().fetchEntity(node.id, false);
          if (data?.components.some((c) => c.type === "Sky")) return node.id;
          const found = await scanAll(node.children);
          if (found != null) return found;
        }
        return null;
      };
      skyEntityId = await scanAll(hierarchy);
      console.log('[SkyPanel] refreshSky: scanAll result =', skyEntityId);
    }

    if (skyEntityId == null) {
      console.warn('[SkyPanel] refreshSky: no Sky entity found anywhere, setting sky=null');
      setSky(null);
      return;
    }

    // Fetch latest component data
    const data = await useEntityCacheStore.getState().fetchEntity(skyEntityId, true);
    console.log('[SkyPanel] refreshSky: fetchEntity(', skyEntityId, ') =', data ? `${data.components.length} components: [${data.components.map(c => c.type).join(', ')}]` : 'null');
    if (!data) {
      console.warn('[SkyPanel] refreshSky: fetchEntity returned null for entity', skyEntityId);
      setSky(null);
      return;
    }
    const skyComp = data.components.find((c) => c.type === "Sky");
    if (!skyComp) {
      console.warn('[SkyPanel] refreshSky: entity', skyEntityId, 'has no Sky component in data');
      setSky(null);
      return;
    }

    const envField = skyComp.fields.find((f) => f.name === "environment_asset_id");
    const intensityField = skyComp.fields.find((f) => f.name === "intensity");
    const enabledField = skyComp.fields.find((f) => f.name === "enabled");

    setSky({
      entityId: skyEntityId,
      environmentAssetId: (envField?.value as string) ?? "",
      sourcePath: (envField as ComponentField & { sourcePath?: string })?.sourcePath ?? "",
      intensity: (intensityField?.value as number) ?? 1.0,
      enabled: (enabledField?.value as boolean) ?? true,
    });
  }, [connected, hierarchy, findSkyEntity]);

  useEffect(() => {
    refreshSky();
  }, [refreshSky]);

  // Create a Sky entity if none exists
  const handleCreate = useCallback(async () => {
    if (!connected) return;
    setLoading(true);
    try {
      const result = await engine.call("scene.createEntity", { name: "Sky" });
      await engine.call("entity.addComponent", {
        entityId: result.entityId,
        componentType: "Sky",
      });
      await useSceneStore.getState().refreshHierarchy();
      // Small delay to let engine process
      setTimeout(() => refreshSky(), 200);
    } catch (e) {
      console.error("Failed to create Sky entity:", e);
    } finally {
      setLoading(false);
    }
  }, [connected, refreshSky]);

  // Set HDR environment
  const commitAsset = useCallback(
    (assetPath: string | undefined) => {
      if (!sky) return;
      console.log('[SkyPanel] commitAsset: calling setAssetField with path =', assetPath, 'entityId =', sky.entityId);
      engine
        .call("entity.setAssetField", {
          entityId: sky.entityId,
          componentType: "Sky",
          fieldName: "environment_asset_id",
          assetPath: assetPath || undefined,
        })
        .then((result: unknown) => {
          console.log('[SkyPanel] commitAsset: setAssetField succeeded, result =', result);
          setTimeout(refreshSky, 200);
        })
        .catch((err: unknown) => {
          console.error('[SkyPanel] commitAsset: setAssetField FAILED:', err);
          // Still refresh to show current state
          setTimeout(refreshSky, 200);
        });
    },
    [sky, refreshSky],
  );

  // Set intensity
  const commitIntensity = useCallback(
    (value: number) => {
      if (!sky) return;
      engine.call("entity.setComponentField", {
        entityId: sky.entityId,
        componentType: "Sky",
        fieldName: "intensity",
        value,
      });
      setSky((prev) => (prev ? { ...prev, intensity: value } : null));
    },
    [sky],
  );

  // Toggle enabled
  const commitEnabled = useCallback(
    (value: boolean) => {
      if (!sky) return;
      engine.call("entity.setComponentField", {
        entityId: sky.entityId,
        componentType: "Sky",
        fieldName: "enabled",
        value,
      });
      setSky((prev) => (prev ? { ...prev, enabled: value } : null));
    },
    [sky],
  );

  // Drag-drop HDR
  const handleDragOver = (e: React.DragEvent) => {
    if (e.dataTransfer.types.includes("application/x-guava-asset-path")) {
      e.preventDefault();
      e.dataTransfer.dropEffect = "link";
      setDragOver(true);
    }
  };
  const handleDragLeave = () => setDragOver(false);
  const handleDrop = (e: React.DragEvent) => {
    e.preventDefault();
    setDragOver(false);
    const assetPath = e.dataTransfer.getData("application/x-guava-asset-path");
    if (assetPath && assetPath.toLowerCase().endsWith(".hdr")) {
      commitAsset(assetPath);
    }
  };

  if (!connected) {
    return (
      <div style={styles.container}>
        <div style={styles.header}>Sky Environment</div>
        <div style={styles.empty}>Not connected</div>
      </div>
    );
  }

  // No Sky entity yet — show creation prompt
  if (!sky) {
    return (
      <div style={styles.container}>
        <div style={styles.header}>Sky Environment</div>
        <div style={styles.emptyState}>
          <div style={styles.emptyIcon}><IconLightSun size={28} color="#f9e2af" /></div>
          <div style={styles.emptyText}>No sky environment configured</div>
          <button style={styles.createButton} onClick={handleCreate} disabled={loading}>
            {loading ? "Creating…" : "Add Sky Environment"}
          </button>
        </div>
      </div>
    );
  }

  const displayName = sky.sourcePath
    ? sky.sourcePath.split("/").pop() ?? sky.sourcePath
    : sky.environmentAssetId
      ? sky.environmentAssetId.substring(0, 12) + "…"
      : "";

  return (
    <div
      style={{
        ...styles.container,
        ...(dragOver ? { outline: "2px dashed #89b4fa", outlineOffset: -2, background: "rgba(137,180,250,0.04)" } : {}),
      }}
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
      onDrop={handleDrop}
    >
      <div style={styles.header}>Sky Environment</div>

      {/* Enable toggle */}
      <div style={styles.toggleRow} onClick={() => commitEnabled(!sky.enabled)}>
        <div
          style={{
            ...styles.checkbox,
            ...(sky.enabled ? styles.checkboxActive : {}),
          }}
        >
          {sky.enabled && <IconCheck size={10} />}
        </div>
        <span>Enabled</span>
      </div>

      {/* HDR picker */}
      <div style={styles.section}>
        <div style={styles.sectionTitle}>HDR Environment</div>
        <select
          value={sky.sourcePath || sky.environmentAssetId}
          onChange={(e) => commitAsset(e.target.value || undefined)}
          style={styles.select}
        >
          <option value="">— none —</option>
          {hdrFiles.map((f) => (
            <option key={f.path} value={f.path}>
              {f.name}
            </option>
          ))}
          {sky.environmentAssetId &&
            !hdrFiles.some((f) => f.path === sky.sourcePath) &&
            sky.sourcePath && (
              <option value={sky.sourcePath}>{sky.sourcePath.split("/").pop()}</option>
            )}
        </select>
        {displayName && (
          <div style={styles.pathHint}>{sky.sourcePath || sky.environmentAssetId}</div>
        )}
      </div>

      {/* Intensity slider */}
      <div style={styles.section}>
        <div style={styles.sectionTitle}>Intensity</div>
        <div style={styles.sliderRow}>
          <input
            type="range"
            min={0}
            max={10}
            step={0.01}
            value={sky.intensity}
            onChange={(e) => setSky((prev) => (prev ? { ...prev, intensity: parseFloat(e.target.value) } : null))}
            onMouseUp={(e) => commitIntensity(parseFloat((e.target as HTMLInputElement).value))}
            style={styles.slider}
          />
          <input
            type="number"
            min={0}
            max={10}
            step={0.01}
            value={sky.intensity}
            onChange={(e) => {
              const v = parseFloat(e.target.value);
              if (!isNaN(v)) {
                setSky((prev) => (prev ? { ...prev, intensity: v } : null));
              }
            }}
            onBlur={(e) => {
              const v = parseFloat(e.target.value);
              if (!isNaN(v)) commitIntensity(v);
            }}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                const v = parseFloat((e.target as HTMLInputElement).value);
                if (!isNaN(v)) commitIntensity(v);
              }
            }}
            style={styles.numInput}
          />
        </div>
      </div>
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
  emptyState: {
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    justifyContent: "center",
    gap: 12,
    padding: "32px 16px",
  },
  emptyIcon: {
    fontSize: 32,
    opacity: 0.6,
  },
  emptyText: {
    fontSize: 13,
    opacity: 0.5,
  },
  createButton: {
    padding: "6px 16px",
    borderRadius: 4,
    border: "1px solid #89b4fa",
    background: "transparent",
    color: "#89b4fa",
    cursor: "pointer",
    fontSize: 12,
    fontWeight: 500,
  },
  section: {
    marginBottom: 12,
    paddingBottom: 8,
  },
  sectionTitle: {
    fontSize: 11,
    textTransform: "uppercase" as const,
    color: "#6c7086",
    letterSpacing: 1,
    marginBottom: 6,
  },
  toggleRow: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    padding: "4px 0",
    marginBottom: 8,
    cursor: "pointer",
    userSelect: "none",
  },
  checkbox: {
    width: 14,
    height: 14,
    borderRadius: 3,
    border: "1px solid #45475a",
    background: "#1e1e2e",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    fontSize: 10,
    color: "#1e1e2e",
    flexShrink: 0,
  },
  checkboxActive: {
    background: "#89b4fa",
    borderColor: "#89b4fa",
  },
  select: {
    width: "100%",
    padding: "4px 6px",
    borderRadius: 3,
    border: "1px solid #45475a",
    background: "#1e1e2e",
    color: "#cdd6f4",
    fontSize: 12,
    appearance: "none" as const,
  },
  pathHint: {
    fontSize: 10,
    opacity: 0.4,
    marginTop: 4,
    wordBreak: "break-all",
  },
  sliderRow: {
    display: "flex",
    alignItems: "center",
    gap: 8,
  },
  slider: {
    flex: 1,
    accentColor: "#89b4fa",
  },
  numInput: {
    width: 56,
    padding: "2px 4px",
    borderRadius: 3,
    border: "1px solid #45475a",
    background: "#1e1e2e",
    color: "#cdd6f4",
    fontSize: 12,
    textAlign: "right" as const,
  },
};
