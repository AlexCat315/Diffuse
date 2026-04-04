import React, { useState, useCallback } from "react";
import { useConnectionStore } from "../store";
import { useI18n } from "../i18n";

/** Actor categories with static entries — no RPC needed for the catalog. */
const categories = [
  {
    id: "basics",
    label: "Basics",
    entries: [
      { kind: "empty", label: "Empty", desc: "Empty entity" },
      { kind: "camera", label: "Camera", desc: "Camera entity" },
    ],
  },
  {
    id: "lights",
    label: "Lights",
    entries: [
      { kind: "point_light", label: "Point Light", desc: "Omnidirectional" },
      { kind: "spot_light", label: "Spot Light", desc: "Cone beam" },
      {
        kind: "directional_light",
        label: "Dir Light",
        desc: "Sun-like parallel",
      },
    ],
  },
  {
    id: "shapes",
    label: "Shapes",
    entries: [
      { kind: "cube", label: "Cube", desc: "Box primitive" },
      { kind: "sphere", label: "Sphere", desc: "Sphere primitive" },
      { kind: "plane", label: "Plane", desc: "Flat plane" },
    ],
  },
  {
    id: "vfx",
    label: "VFX",
    entries: [
      { kind: "vfx_fountain", label: "Fountain", desc: "Particle fountain" },
      { kind: "vfx_orbit", label: "Orbit", desc: "Orbiting particles" },
    ],
  },
] as const;


export function PlaceActors() {
  const connected = useConnectionStore((s) => s.connected);
  const { t } = useI18n();
  const [activeCategory, setActiveCategory] = useState("basics");
  const [filter, setFilter] = useState("");
  const [spawning, setSpawning] = useState(false);

  const handleSpawn = useCallback(
    async (kind: string) => {
      if (!connected || spawning) return;
      setSpawning(true);
      try {
        const res = await window.guavaEngine.call("scene.spawnActor", {
          kind,
        });
        // Optionally select the new entity
        if (res.entityId) {
          await window.guavaEngine.call("editor.setSelection", {
            entityIds: [res.entityId],
          });
        }
      } catch {
        /* ignore */
      } finally {
        setSpawning(false);
      }
    },
    [connected, spawning]
  );

  const category = categories.find((c) => c.id === activeCategory)!;
  const filtered = filter
    ? category.entries.filter(
        (e) =>
          e.label.toLowerCase().includes(filter.toLowerCase()) ||
          e.desc.toLowerCase().includes(filter.toLowerCase())
      )
    : category.entries;

  const catLabels: Record<string, string> = {
    basics: t.placeActors.categoryBasics,
    lights: t.placeActors.categoryLights,
    shapes: t.placeActors.categoryShapes,
    vfx: t.placeActors.categoryVfx,
  };
  const entryLabels: Record<string, string> = {
    empty: t.placeActors.actorEmpty,
    camera: t.placeActors.actorCamera,
    point_light: t.placeActors.lightPoint,
    spot_light: t.placeActors.lightSpot,
    directional_light: t.placeActors.lightDirectional,
    cube: t.placeActors.shapeCube,
    sphere: t.placeActors.shapeSphere,
    plane: t.placeActors.shapePlane,
    vfx_fountain: t.placeActors.vfxParticle,
    vfx_orbit: t.placeActors.vfxParticle,
  };
  const entryDescs: Record<string, string> = {
    empty: t.placeActors.descEmpty,
    camera: t.placeActors.descCamera,
    point_light: t.placeActors.descLightPoint,
    spot_light: t.placeActors.descLightSpot,
    directional_light: t.placeActors.descLightDirectional,
    cube: t.placeActors.descShapeCube,
    sphere: t.placeActors.descShapeSphere,
    plane: t.placeActors.descShapePlane,
    vfx_fountain: t.placeActors.descVfxParticle,
    vfx_orbit: t.placeActors.descVfxParticle,
  };

  return (
    <div style={styles.container}>
      {/* Category tabs */}
      <div style={styles.tabBar}>
        {categories.map((cat) => (
          <button
            key={cat.id}
            style={{
              ...styles.tab,
              ...(activeCategory === cat.id ? styles.tabActive : {}),
            }}
            onClick={() => setActiveCategory(cat.id)}
          >
            {catLabels[cat.id] ?? cat.label}
          </button>
        ))}
      </div>

      {/* Search */}
      <input
        type="text"
        placeholder={t.placeActors.searchPlaceholder}
        value={filter}
        onChange={(e) => setFilter(e.target.value)}
        style={styles.search}
      />

      {/* Actor list */}
      <div style={styles.list}>
        {(filtered as readonly { kind: string; label: string; desc: string }[]).map((entry) => (
          <button
            key={entry.kind}
            style={styles.card}
            onClick={() => handleSpawn(entry.kind)}
            disabled={spawning}
          >
            <div style={styles.cardLabel}>{entryLabels[entry.kind] ?? entry.label}</div>
            <div style={styles.cardDesc}>{entryDescs[entry.kind] ?? entry.desc}</div>
          </button>
        ))}
        {filtered.length === 0 && (
          <div style={styles.empty}>No matching actors</div>
        )}
      </div>
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  container: {
    padding: 8,
    height: "100%",
    display: "flex",
    flexDirection: "column",
    fontFamily: "monospace",
    fontSize: 12,
    color: "#ccc",
  },
  tabBar: { display: "flex", gap: 4, marginBottom: 8 },
  tab: {
    flex: 1,
    padding: "6px 0",
    background: "#2a2a2a",
    border: "1px solid #444",
    color: "#aaa",
    borderRadius: 3,
    cursor: "pointer",
    fontSize: 11,
    textAlign: "center" as const,
  },
  tabActive: {
    background: "#3a5a8a",
    color: "#fff",
    borderColor: "#4a7abf",
  },
  search: {
    width: "100%",
    padding: "4px 8px",
    marginBottom: 8,
    background: "#1e1e1e",
    border: "1px solid #444",
    color: "#ccc",
    borderRadius: 3,
    boxSizing: "border-box" as const,
  },
  list: { flex: 1, overflow: "auto", display: "flex", flexDirection: "column" as const, gap: 4 },
  card: {
    display: "flex",
    flexDirection: "column" as const,
    alignItems: "flex-start",
    padding: "8px 12px",
    background: "#2a2a2a",
    border: "1px solid #444",
    borderRadius: 4,
    cursor: "pointer",
    textAlign: "left" as const,
    color: "#ccc",
  },
  cardLabel: { fontWeight: "bold" as const, marginBottom: 2 },
  cardDesc: { fontSize: 10, color: "#888" },
  empty: { textAlign: "center" as const, color: "#666", padding: 16 },
};
