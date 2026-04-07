import React, { useEffect, useCallback, useRef, useState, type DragEvent } from "react";
import { useLocalState } from "../store/local-state";
import type { Transform, ComponentInfo, Vec3 } from "../../shared/rpc-types";
import type { ComponentField } from "../../shared/rpc-types";
import { useI18n } from "../i18n";
import { IconTriangleRight, IconTriangleDown } from "../components/Icons";
import { useSceneStore, useEntityCacheStore } from "../store";
import { useSyncedState } from "../store/synced-state";

export function Inspector() {
  const entityId = useSceneStore((s) => s.selectedEntity);
  const { t } = useI18n();
  const [transform, setTransform] = useLocalState<Transform | null>(null);
  const [components, setComponents] = useLocalState<ComponentInfo[]>([]);
  const [entityName, setEntityName] = useLocalState("");
  const [collapsedSections, setCollapsedSections] = useSyncedState<Set<string>>("inspector", "collapsedSections", new Set());
  const [showAddComponent, setShowAddComponent] = useState(false);

  const fetchEntityData = useCallback(async (eid: number) => {
    const data = await useEntityCacheStore.getState().fetchEntity(eid, true);
    if (data) {
      setTransform(data.transform);
      setComponents(data.components);
    }
  }, []);

  useEffect(() => {
    if (entityId == null) {
      setTransform(null);
      setComponents([]);
      setEntityName("");
      return;
    }
    fetchEntityData(entityId);
  }, [entityId, fetchEntityData]);

  const commitName = useCallback(() => {
    if (entityId != null && entityName.trim()) {
      window.guavaEngine.call("entity.setName", { entityId, name: entityName });
    }
  }, [entityId, entityName]);

  const commitTransform = useCallback(
    (partial: Partial<Transform>) => {
      if (entityId == null) return;
      window.guavaEngine.call("entity.setTransform", { entityId, transform: partial });
    },
    [entityId],
  );

  const toggleSection = (key: string) => {
    setCollapsedSections((prev) => {
      const next = new Set(prev);
      next.has(key) ? next.delete(key) : next.add(key);
      return next;
    });
  };

  const handleInspectorDrop = useCallback(
    async (e: React.DragEvent) => {
      const assetPath = e.dataTransfer.getData("application/x-guava-asset-path");
      const assetType = e.dataTransfer.getData("application/x-guava-asset-type");
      if (!assetPath || entityId == null) return;

      // Only auto-add Script component when dropping a script file
      if (assetType !== "script") return;
      e.preventDefault();

      const hasScript = components.some((c) => c.type.toLowerCase() === "script");
      if (!hasScript) {
        await window.guavaEngine.call("entity.addComponent", { entityId, componentType: "Script" });
      }
      // Assign the dropped script
      await window.guavaEngine.call("entity.setAssetField", {
        entityId,
        componentType: "Script",
        fieldName: "script",
        assetPath,
      });
      setTimeout(() => fetchEntityData(entityId), 150);
    },
    [entityId, components, fetchEntityData],
  );

  const handleInspectorDragOver = useCallback(
    (e: React.DragEvent) => {
      if (e.dataTransfer.types.includes("application/x-guava-asset-path")) {
        e.preventDefault();
        e.dataTransfer.dropEffect = "link";
      }
    },
    [],
  );

  if (entityId == null) {
    return (
      <div style={styles.container}>
        <div style={styles.header}>{t.inspector.title}</div>
        <div style={styles.empty}>{t.common.noEntitySelected}</div>
      </div>
    );
  }

  return (
    <div style={styles.container} onDragOver={handleInspectorDragOver} onDrop={handleInspectorDrop}>
      <div style={styles.header}>{t.inspector.title}</div>

      {/* Entity identity */}
      <div style={styles.section}>
        <div style={styles.sectionTitle}>{t.inspector.entityLabel} #{entityId}</div>
        <div style={styles.field}>
          <label style={styles.label}>{t.common.name}</label>
          <input
            type="text"
            value={entityName}
            onChange={(e) => setEntityName(e.target.value)}
            onBlur={commitName}
            onKeyDown={(e) => e.key === "Enter" && commitName()}
            style={styles.input}
            placeholder={t.inspector.entityNamePlaceholder}
          />
        </div>
      </div>

      {/* Transform */}
      {transform && (
        <CollapsibleSection
          title={t.inspector.transform}
          collapsed={collapsedSections.has("transform")}
          onToggle={() => toggleSection("transform")}
        >
          <Vec3Input
            label={t.inspector.position}
            value={transform.position}
            step={0.1}
            onChange={(v) => {
              setTransform((t) => t && { ...t, position: v });
              commitTransform({ position: v });
            }}
          />
          <Vec3Input
            label={t.inspector.rotation}
            value={transform.rotation as unknown as Vec3}
            step={1}
            onChange={(v) => {
              setTransform((t) => t && { ...t, rotation: { ...v, w: t.rotation.w } });
              commitTransform({ rotation: { ...v, w: transform.rotation.w } });
            }}
          />
          <Vec3Input
            label={t.inspector.scale}
            value={transform.scale}
            step={0.1}
            onChange={(v) => {
              setTransform((t) => t && { ...t, scale: v });
              commitTransform({ scale: v });
            }}
          />
        </CollapsibleSection>
      )}

      {/* Components */}
      {components.map((comp) => (
        <CollapsibleSection
          key={comp.type}
          title={comp.type}
          collapsed={collapsedSections.has(comp.type)}
          onToggle={() => toggleSection(comp.type)}
          onRemove={() => {
            window.guavaEngine.call("entity.removeComponent", { entityId, componentType: comp.type });
            setTimeout(() => fetchEntityData(entityId), 100);
          }}
        >
          {comp.fields.length === 0 ? (
            <div style={{ ...styles.empty, padding: 8 }}>{t.inspector.noEditableFields}</div>
          ) : (
            comp.fields.map((field) => (
              <FieldEditor
                key={field.name}
                entityId={entityId}
                componentType={comp.type}
                field={field as ComponentField}
                onFieldChanged={() => fetchEntityData(entityId)}
              />
            ))
          )}
          {/* Script parameters editor */}
          {comp.type === "Script" && (
            <ScriptParametersEditor entityId={entityId} />
          )}
        </CollapsibleSection>
      ))}

      {/* Add Component */}
      <AddComponentButton
        entityId={entityId}
        existingTypes={components.map((c) => c.type)}
        show={showAddComponent}
        onToggle={() => setShowAddComponent((v) => !v)}
        onAdded={() => {
          setShowAddComponent(false);
          fetchEntityData(entityId);
        }}
      />
    </div>
  );
}

// ── Collapsible section ──────────────────────────────────────────

function CollapsibleSection({
  title,
  collapsed,
  onToggle,
  onRemove,
  children,
}: {
  title: string;
  collapsed: boolean;
  onToggle: () => void;
  onRemove?: () => void;
  children: React.ReactNode;
}) {
  return (
    <div style={styles.section}>
      <div style={styles.sectionHeader} onClick={onToggle}>
        <span style={styles.arrow}>{collapsed ? <IconTriangleRight size={10} /> : <IconTriangleDown size={10} />}</span>
        <span style={{ ...styles.sectionTitle, flex: 1 }}>{title}</span>
        {onRemove && (
          <button
            style={styles.removeComponentBtn}
            title="Remove component"
            onClick={(e) => { e.stopPropagation(); onRemove(); }}
          >
            ✕
          </button>
        )}
      </div>
      {!collapsed && children}
    </div>
  );
}

// ── Editable Vec3 input ──────────────────────────────────────────

const AXES: { key: keyof Vec3; color: string; label: string }[] = [
  { key: "x", color: "#f38ba8", label: "X" },
  { key: "y", color: "#a6e3a1", label: "Y" },
  { key: "z", color: "#89b4fa", label: "Z" },
];

function Vec3Input({
  label,
  value,
  step = 0.1,
  onChange,
}: {
  label: string;
  value: Vec3;
  step?: number;
  onChange: (v: Vec3) => void;
}) {
  const [local, setLocal] = useLocalState(value);
  const commitTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);

  // Sync with external value when entity changes
  useEffect(() => {
    setLocal(value);
  }, [value.x, value.y, value.z]);

  const handleChange = (axis: keyof Vec3, raw: string) => {
    const n = parseFloat(raw);
    if (isNaN(n)) return;
    const next = { ...local, [axis]: n };
    setLocal(next);
    // Debounce RPC calls (150ms)
    clearTimeout(commitTimer.current);
    commitTimer.current = setTimeout(() => onChange(next), 150);
  };

  return (
    <div style={styles.field}>
      <label style={styles.label}>{label}</label>
      <div style={styles.vec3}>
        {AXES.map(({ key, color, label: axisLabel }) => (
          <div key={key} style={styles.axisGroup}>
            <span style={{ color, fontSize: 10, fontWeight: 700 }}>{axisLabel}</span>
            <input
              type="number"
              step={step}
              value={local[key].toFixed(step < 1 ? 2 : 0)}
              onChange={(e) => handleChange(key, e.target.value)}
              style={styles.numInput}
            />
          </div>
        ))}
      </div>
    </div>
  );
}

// ── Typed field editor — dispatches on fieldType ─────────────────

function FieldEditor({
  entityId,
  componentType,
  field,
  onFieldChanged,
}: {
  entityId: number;
  componentType: string;
  field: ComponentField;
  onFieldChanged: () => void;
}) {
  const commitTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);

  const commitField = useCallback(
    (value: unknown) => {
      clearTimeout(commitTimer.current);
      commitTimer.current = setTimeout(() => {
        window.guavaEngine.call("entity.setComponentField", {
          entityId,
          componentType,
          fieldName: field.name,
          value,
        });
      }, 150);
    },
    [entityId, componentType, field.name],
  );

  switch (field.fieldType) {
    case "float":
      return <FloatField label={field.name} value={field.value as number} onCommit={commitField} />;
    case "bool":
      return <BoolField label={field.name} value={field.value as boolean} onCommit={commitField} />;
    case "vec3":
      return (
        <Vec3Input
          label={field.name}
          value={field.value as Vec3}
          step={0.1}
          onChange={(v) => commitField(v)}
        />
      );
    case "color":
      return <ColorField label={field.name} value={field.value as Vec3 & { w: number }} onCommit={commitField} />;
    case "enum":
      return (
        <EnumField
          label={field.name}
          value={field.value as string}
          options={field.options ?? []}
          onCommit={commitField}
        />
      );
    case "asset_ref":
      return (
        <AssetRefField
          entityId={entityId}
          componentType={componentType}
          field={field}
          onChanged={onFieldChanged}
        />
      );
    case "string":
      // Sky environment_asset_id: show HDR file picker
      if (componentType === "Sky" && field.name === "environment_asset_id") {
        return (
          <SkyEnvironmentField
            entityId={entityId}
            field={field}
            onChanged={onFieldChanged}
          />
        );
      }
      return <StringField label={field.name} value={(field.value as string) ?? ""} onCommit={commitField} />;
    default:
      return (
        <div style={styles.field}>
          <label style={styles.label}>{field.name}</label>
          <span style={styles.value}>{JSON.stringify(field.value)}</span>
        </div>
      );
  }
}

// ── Float field ──────────────────────────────────────────────────

function FloatField({ label, value, onCommit }: { label: string; value: number; onCommit: (v: number) => void }) {
  const [local, setLocal] = useLocalState(value);
  useEffect(() => setLocal(value), [value]);

  return (
    <div style={styles.field}>
      <label style={styles.label}>{label}</label>
      <input
        type="number"
        step={0.01}
        value={local.toFixed(3)}
        onChange={(e) => {
          const n = parseFloat(e.target.value);
          if (!isNaN(n)) { setLocal(n); onCommit(n); }
        }}
        style={{ ...styles.numInput, flex: 1, marginLeft: 8 }}
      />
    </div>
  );
}

// ── Bool field ───────────────────────────────────────────────────

function BoolField({ label, value, onCommit }: { label: string; value: boolean; onCommit: (v: boolean) => void }) {
  return (
    <div style={styles.field}>
      <label style={styles.label}>{label}</label>
      <input
        type="checkbox"
        checked={value}
        onChange={(e) => onCommit(e.target.checked)}
        style={{ marginLeft: 8, accentColor: "#89b4fa" }}
      />
    </div>
  );
}

// ── Color field (vec4) ──────────────────────────────────────────

function ColorField({
  label,
  value,
  onCommit,
}: {
  label: string;
  value: { x: number; y: number; z: number; w: number };
  onCommit: (v: { x: number; y: number; z: number; w: number }) => void;
}) {
  const toHex = (v: { x: number; y: number; z: number }) => {
    const r = Math.round(Math.min(1, Math.max(0, v.x)) * 255);
    const g = Math.round(Math.min(1, Math.max(0, v.y)) * 255);
    const b = Math.round(Math.min(1, Math.max(0, v.z)) * 255);
    return `#${r.toString(16).padStart(2, "0")}${g.toString(16).padStart(2, "0")}${b.toString(16).padStart(2, "0")}`;
  };
  const fromHex = (hex: string) => {
    const r = parseInt(hex.slice(1, 3), 16) / 255;
    const g = parseInt(hex.slice(3, 5), 16) / 255;
    const b = parseInt(hex.slice(5, 7), 16) / 255;
    return { x: r, y: g, z: b, w: value.w };
  };

  return (
    <div style={styles.field}>
      <label style={styles.label}>{label}</label>
      <input
        type="color"
        value={toHex(value)}
        onChange={(e) => onCommit(fromHex(e.target.value))}
        style={{ marginLeft: 8, width: 32, height: 20, border: "none", background: "none", cursor: "pointer" }}
      />
      <span style={{ ...styles.value, marginLeft: 4, fontSize: 10 }}>{toHex(value)}</span>
    </div>
  );
}

// ── Enum field ──────────────────────────────────────────────────

function EnumField({
  label,
  value,
  options,
  onCommit,
}: {
  label: string;
  value: string;
  options: string[];
  onCommit: (v: string) => void;
}) {
  return (
    <div style={styles.field}>
      <label style={styles.label}>{label}</label>
      <select
        value={value}
        onChange={(e) => onCommit(e.target.value)}
        style={{
          ...styles.numInput,
          flex: 1,
          marginLeft: 8,
          appearance: "none",
          padding: "2px 6px",
        }}
      >
        {options.map((opt) => (
          <option key={opt} value={opt}>{opt}</option>
        ))}
      </select>
    </div>
  );
}

// ── Asset reference field ────────────────────────────────────────

function AssetRefField({
  entityId,
  componentType,
  field,
  onChanged,
}: {
  entityId: number;
  componentType: string;
  field: ComponentField;
  onChanged: () => void;
}) {
  const [options, setOptions] = useState<string[]>([]);
  const [dragOver, setDragOver] = useState(false);
  const currentValue = (field.value as string | null) ?? "";

  useEffect(() => {
    // Fetch available assets by type
    const assetType = field.assetType ?? "script";
    if (assetType === "script") {
      window.guavaEngine
        .call("script.listScripts", {})
        .then((res: { scripts?: { path: string }[] }) => {
          setOptions((res.scripts ?? []).map((s) => s.path));
        })
        .catch(() => {});
    } else {
      // For mesh/material/texture — browse assets directory
      window.guavaEngine
        .call("assets.list", { path: "" })
        .then((res: { entries?: { name: string; isDirectory: boolean }[] }) => {
          // Flatten — for now just show top-level files
          setOptions(
            (res.entries ?? [])
              .filter((e) => !e.isDirectory)
              .map((e) => e.name),
          );
        })
        .catch(() => {});
    }
  }, [field.assetType]);

  const commitAsset = (assetPath: string | undefined) => {
    window.guavaEngine.call("entity.setAssetField", {
      entityId,
      componentType,
      fieldName: field.name,
      assetPath,
    });
    setTimeout(onChanged, 100);
  };

  const handleDragOver = (e: DragEvent) => {
    if (e.dataTransfer.types.includes("application/x-guava-asset-path")) {
      e.preventDefault();
      e.dataTransfer.dropEffect = "link";
      setDragOver(true);
    }
  };

  const handleDragLeave = () => {
    setDragOver(false);
  };

  const handleDrop = (e: DragEvent) => {
    e.preventDefault();
    setDragOver(false);
    const assetPath = e.dataTransfer.getData("application/x-guava-asset-path");
    if (assetPath) {
      commitAsset(assetPath);
    }
  };

  return (
    <div
      style={{
        ...styles.field,
        ...(dragOver ? { outline: "1px solid #89b4fa", borderRadius: 3, background: "rgba(137,180,250,0.08)" } : {}),
      }}
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
      onDrop={handleDrop}
    >
      <label style={styles.label}>{field.name}</label>
      <select
        value={currentValue}
        onChange={(e) => commitAsset(e.target.value || undefined)}
        style={{
          ...styles.numInput,
          flex: 1,
          marginLeft: 8,
          appearance: "none",
          padding: "2px 6px",
        }}
      >
        <option value="">— none —</option>
        {options.map((opt) => (
          <option key={opt} value={opt}>
            {opt.split("/").pop() ?? opt}
          </option>
        ))}
      </select>
    </div>
  );
}

// ── String field ─────────────────────────────────────────────────

function StringField({ label, value, onCommit }: { label: string; value: string; onCommit: (v: string) => void }) {
  const [local, setLocal] = useLocalState(value);
  useEffect(() => setLocal(value), [value]);

  return (
    <div style={styles.field}>
      <label style={styles.label}>{label}</label>
      <input
        type="text"
        value={local}
        onChange={(e) => setLocal(e.target.value)}
        onBlur={() => onCommit(local)}
        onKeyDown={(e) => { if (e.key === "Enter") onCommit(local); }}
        style={{ ...styles.numInput, flex: 1, marginLeft: 8 }}
      />
    </div>
  );
}

// ── Sky environment HDR picker ───────────────────────────────────

interface HdrAssetEntry {
  name: string;
  path: string;   // e.g. "Content/environments/sky.hdr"
}

function SkyEnvironmentField({
  entityId,
  field,
  onChanged,
}: {
  entityId: number;
  field: ComponentField;
  onChanged: () => void;
}) {
  const [hdrFiles, setHdrFiles] = useState<HdrAssetEntry[]>([]);
  const [dragOver, setDragOver] = useState(false);
  const currentValue = (field.value as string) ?? "";
  const sourcePath = (field as ComponentField & { sourcePath?: string }).sourcePath ?? "";

  // Recursively find .hdr files in project Content directory
  useEffect(() => {
    const found: HdrAssetEntry[] = [];
    const scanDir = async (dirPath: string) => {
      try {
        const res = await window.guavaEngine.call("assets.list", { path: dirPath }) as {
          entries?: { name: string; path: string; isDirectory: boolean; assetType: string }[];
        };
        for (const entry of res.entries ?? []) {
          if (entry.isDirectory) {
            await scanDir(entry.path);
          } else if (entry.name.toLowerCase().endsWith(".hdr")) {
            found.push({ name: entry.name, path: entry.path });
          }
        }
      } catch { /* ignore */ }
    };
    scanDir("Content").then(() => setHdrFiles(found));
  }, []);

  const commitAsset = (assetPath: string | undefined) => {
    window.guavaEngine.call("entity.setAssetField", {
      entityId,
      componentType: "Sky",
      fieldName: "environment_asset_id",
      assetPath: assetPath ?? undefined,
    });
    setTimeout(onChanged, 150);
  };

  const handleDragOver = (e: DragEvent) => {
    if (e.dataTransfer.types.includes("application/x-guava-asset-path")) {
      e.preventDefault();
      e.dataTransfer.dropEffect = "link";
      setDragOver(true);
    }
  };

  const handleDragLeave = () => setDragOver(false);

  const handleDrop = (e: DragEvent) => {
    e.preventDefault();
    setDragOver(false);
    const assetPath = e.dataTransfer.getData("application/x-guava-asset-path");
    if (assetPath && assetPath.toLowerCase().endsWith(".hdr")) {
      commitAsset(assetPath);
    }
  };

  // Display: show file name if we have sourcePath, otherwise show truncated asset ID
  const displayValue = sourcePath
    ? sourcePath.split("/").pop() ?? sourcePath
    : currentValue
      ? currentValue.substring(0, 12) + "…"
      : "";

  return (
    <div
      style={{
        ...styles.field,
        flexDirection: "column",
        alignItems: "stretch",
        gap: 4,
        ...(dragOver ? { outline: "1px solid #89b4fa", borderRadius: 3, background: "rgba(137,180,250,0.08)" } : {}),
      }}
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
      onDrop={handleDrop}
    >
      <div style={{ display: "flex", alignItems: "center" }}>
        <label style={styles.label}>HDR 环境</label>
        <select
          value={sourcePath || currentValue}
          onChange={(e) => commitAsset(e.target.value || undefined)}
          style={{
            ...styles.numInput,
            flex: 1,
            marginLeft: 8,
            appearance: "none",
            padding: "2px 6px",
          }}
        >
          <option value="">— none —</option>
          {hdrFiles.map((f) => (
            <option key={f.path} value={f.path}>
              {f.name}
            </option>
          ))}
          {/* Show current value if it's an asset ID not matching any listed file */}
          {currentValue && !hdrFiles.some((f) => f.path === sourcePath) && sourcePath && (
            <option value={sourcePath}>{sourcePath.split("/").pop()}</option>
          )}
        </select>
      </div>
      {displayValue && (
        <div style={{ fontSize: 10, opacity: 0.5, paddingLeft: 4 }}>
          {sourcePath || currentValue}
        </div>
      )}
    </div>
  );
}

// ── Add Component button ─────────────────────────────────────────

const ALL_COMPONENT_TYPES = [
  "Camera", "Mesh", "SkinnedMesh", "Animator", "Rigidbody",
  "BoxCollider", "SphereCollider", "MeshCollider", "CapsuleCollider",
  "CharacterController", "Constraint", "Tag", "Sky",
  "Material", "Light", "Vfx", "Script", "AudioSource",
  "AudioListener", "NavAgent",
];

function AddComponentButton({
  entityId,
  existingTypes,
  show,
  onToggle,
  onAdded,
}: {
  entityId: number;
  existingTypes: string[];
  show: boolean;
  onToggle: () => void;
  onAdded: () => void;
}) {
  const available = ALL_COMPONENT_TYPES.filter(
    (t) => !existingTypes.some((e) => e.toLowerCase() === t.toLowerCase()),
  );

  const handleAdd = (type: string) => {
    window.guavaEngine.call("entity.addComponent", { entityId, componentType: type });
    setTimeout(onAdded, 100);
  };

  return (
    <div style={{ padding: "8px 12px" }}>
      <button
        onClick={onToggle}
        style={styles.addComponentBtn}
      >
        + Add Component
      </button>
      {show && (
        <div style={styles.addComponentDropdown}>
          {available.length === 0 ? (
            <div style={{ padding: 8, opacity: 0.5, fontSize: 11 }}>All components added</div>
          ) : (
            available.map((type) => (
              <div
                key={type}
                style={styles.addComponentItem}
                onClick={() => handleAdd(type)}
                onMouseEnter={(e) => (e.currentTarget.style.background = "#45475a")}
                onMouseLeave={(e) => (e.currentTarget.style.background = "transparent")}
              >
                {type}
              </div>
            ))
          )}
        </div>
      )}
    </div>
  );
}

// ── Script parameters editor ────────────────────────────────────

function ScriptParametersEditor({ entityId }: { entityId: number }) {
  const [params, setParams] = useState("");
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState("");
  const commitTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);

  useEffect(() => {
    window.guavaEngine
      .call("script.getEntityParameters", { entityId })
      .then((res: { parameters?: string | null }) => {
        const p = res.parameters ?? "";
        setParams(p);
        setDraft(p);
      })
      .catch(() => {});
  }, [entityId]);

  const saveParams = useCallback(
    (value: string) => {
      // Validate JSON before sending
      if (value.trim() && value.trim() !== "") {
        try {
          JSON.parse(value);
        } catch {
          return; // Invalid JSON — don't save
        }
      }
      clearTimeout(commitTimer.current);
      commitTimer.current = setTimeout(() => {
        window.guavaEngine.call("script.setEntityParameters", {
          entityId,
          parameters: value.trim() || "{}",
        });
        setParams(value);
        setEditing(false);
      }, 300);
    },
    [entityId],
  );

  return (
    <div style={{ padding: "4px 8px" }}>
      <div style={{ display: "flex", alignItems: "center", marginBottom: 4 }}>
        <span style={{ fontSize: 11, color: "#a6adc8", flex: 1 }}>Parameters</span>
        {!editing && (
          <button
            onClick={() => {
              setDraft(params || "{}");
              setEditing(true);
            }}
            style={{
              background: "none",
              border: "1px solid #45475a",
              borderRadius: 3,
              color: "#cdd6f4",
              fontSize: 10,
              padding: "1px 6px",
              cursor: "pointer",
            }}
          >
            Edit
          </button>
        )}
      </div>
      {editing ? (
        <div>
          <textarea
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            rows={4}
            style={{
              width: "100%",
              background: "#1e1e2e",
              color: "#cdd6f4",
              border: "1px solid #45475a",
              borderRadius: 3,
              fontFamily: "monospace",
              fontSize: 11,
              padding: 4,
              resize: "vertical",
              boxSizing: "border-box",
            }}
          />
          <div style={{ display: "flex", gap: 4, marginTop: 4 }}>
            <button
              onClick={() => saveParams(draft)}
              style={{
                background: "#89b4fa",
                border: "none",
                borderRadius: 3,
                color: "#1e1e2e",
                fontSize: 10,
                padding: "2px 8px",
                cursor: "pointer",
              }}
            >
              Save
            </button>
            <button
              onClick={() => {
                setDraft(params);
                setEditing(false);
              }}
              style={{
                background: "none",
                border: "1px solid #45475a",
                borderRadius: 3,
                color: "#cdd6f4",
                fontSize: 10,
                padding: "2px 8px",
                cursor: "pointer",
              }}
            >
              Cancel
            </button>
          </div>
        </div>
      ) : params ? (
        <pre
          style={{
            background: "#1e1e2e",
            borderRadius: 3,
            padding: 4,
            margin: 0,
            fontSize: 10,
            color: "#a6adc8",
            whiteSpace: "pre-wrap",
            wordBreak: "break-all",
            maxHeight: 100,
            overflow: "auto",
          }}
        >
          {params}
        </pre>
      ) : (
        <span style={{ fontSize: 10, color: "#585b70", fontStyle: "italic" }}>No parameters set</span>
      )}
    </div>
  );
}

// ── Styles ──────────────────────────────────────────────────────

const styles: Record<string, React.CSSProperties> = {
  container: { display: "flex", flexDirection: "column" },
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
  section: {
    borderBottom: "1px solid #313244",
    padding: "6px 12px",
  },
  sectionHeader: {
    display: "flex",
    alignItems: "center",
    gap: 4,
    cursor: "pointer",
    userSelect: "none",
    marginBottom: 4,
  },
  sectionTitle: {
    fontSize: 12,
    fontWeight: 600,
    color: "#cdd6f4",
  },
  arrow: {
    fontSize: 10,
    color: "#6c7086",
    width: 12,
  },
  field: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    padding: "3px 0",
    fontSize: 12,
  },
  label: {
    color: "#a6adc8",
    minWidth: 70,
    fontSize: 11,
  },
  value: {
    color: "#cdd6f4",
    fontSize: 12,
    fontFamily: "monospace",
  },
  vec3: {
    display: "flex",
    gap: 4,
    alignItems: "center",
    flex: 1,
    marginLeft: 8,
  },
  axisGroup: {
    display: "flex",
    alignItems: "center",
    gap: 2,
    flex: 1,
  },
  numInput: {
    background: "#313244",
    border: "1px solid #45475a",
    borderRadius: 3,
    color: "#cdd6f4",
    padding: "2px 4px",
    fontSize: 11,
    fontFamily: "monospace",
    width: "100%",
    outline: "none",
  },
  input: {
    background: "#313244",
    border: "1px solid #45475a",
    borderRadius: 3,
    color: "#cdd6f4",
    padding: "2px 6px",
    fontSize: 12,
    flex: 1,
    marginLeft: 8,
    outline: "none",
  },
  removeComponentBtn: {
    background: "transparent",
    border: "none",
    color: "#6c7086",
    cursor: "pointer",
    fontSize: 10,
    padding: "2px 4px",
    borderRadius: 3,
    lineHeight: 1,
  },
  addComponentBtn: {
    width: "100%",
    padding: "6px 0",
    background: "#313244",
    border: "1px solid #45475a",
    borderRadius: 4,
    color: "#a6adc8",
    fontSize: 12,
    cursor: "pointer",
    textAlign: "center" as const,
  },
  addComponentDropdown: {
    marginTop: 4,
    background: "#1e1e2e",
    border: "1px solid #45475a",
    borderRadius: 4,
    maxHeight: 200,
    overflowY: "auto" as const,
  },
  addComponentItem: {
    padding: "6px 10px",
    fontSize: 12,
    color: "#cdd6f4",
    cursor: "pointer",
  },
};
