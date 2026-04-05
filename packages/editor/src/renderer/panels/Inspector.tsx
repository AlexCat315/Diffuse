import React, { useEffect, useCallback, useRef } from "react";
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

  if (entityId == null) {
    return (
      <div style={styles.container}>
        <div style={styles.header}>{t.inspector.title}</div>
        <div style={styles.empty}>{t.common.noEntitySelected}</div>
      </div>
    );
  }

  return (
    <div style={styles.container}>
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
        </CollapsibleSection>
      ))}
    </div>
  );
}

// ── Collapsible section ──────────────────────────────────────────

function CollapsibleSection({
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
};
