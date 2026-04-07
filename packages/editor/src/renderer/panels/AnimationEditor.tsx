import React, { useEffect, useCallback, useRef } from "react";
import { useLocalState } from "../store/local-state";
import { rpc } from "../rpc";
import { useConnectionStore, useSceneStore } from "../store";
import { useI18n } from "../i18n";
import { IconClose, IconPlay, IconForward } from "../components/Icons";
import type {
  AnimGraphState,
  AnimGraphTransition,
  AnimTransitionCondition,
  AnimGraphParameter,
  AnimClipTrack,
} from "../../shared/rpc-types.generated";

// ── Types ───────────────────────────────────────────────────────

interface AnimState {
  hasAnimator: boolean;
  hasGraph: boolean;
  graphName?: string;
  currentState?: number;
  nextState?: number;
  blendFactor?: number;
  transitionTime?: number;
  transitionDuration?: number;
  defaultState?: number;
  states?: AnimGraphState[];
  transitions?: AnimGraphTransition[];
  parameters?: AnimGraphParameter[];
  clipTracks?: AnimClipTrack[];
  clipDuration?: number;
  sampleTime?: number;
}

const EMPTY_STATE: AnimState = { hasAnimator: false, hasGraph: false };

// ── Color Constants ─────────────────────────────────────────────

const STATE_COLORS = {
  default: "#2d5440",
  current: "#38624d",
  next: "#5e4a29",
  selected: "#3a4d69",
  normal: "#333640",
};

const TRACK_TYPE_COLORS: Record<string, string> = {
  translation: "#89b4fa",
  rotation: "#f9e2af",
  scale: "#a6e3a1",
};

const CONDITION_LABELS: Record<string, string> = {
  time_elapsed: "≥",
  time_remaining: "≤",
  parameter: "P",
};

// ═════════════════════════════════════════════════════════════════
//  AnimationEditor Panel
// ═════════════════════════════════════════════════════════════════

export function AnimationEditor() {
  const { t } = useI18n();
  const connected = useConnectionStore((s) => s.connected);
  const selectedEntity = useSceneStore((s) => s.selectedEntity);

  const [state, setState] = useLocalState<AnimState>(EMPTY_STATE);
  const [selectedStateIdx, setSelectedStateIdx] = useLocalState<number | null>(null);
  const [selectedTransIdx, setSelectedTransIdx] = useLocalState<number | null>(null);
  const [selectedCondIdx, setSelectedCondIdx] = useLocalState<number | null>(null);

  // Editing buffers
  const [editStateName, setEditStateName] = useLocalState("");
  const [editSpeed, setEditSpeed] = useLocalState("1.0");
  const [editLoop, setEditLoop] = useLocalState(true);
  const [editDuration, setEditDuration] = useLocalState("0.0");

  const [newTransFrom, setNewTransFrom] = useLocalState(0);
  const [newTransTo, setNewTransTo] = useLocalState(1);
  const [newTransDuration, setNewTransDuration] = useLocalState("0.2");
  const [newTransTrigger, setNewTransTrigger] = useLocalState("0.25");

  const pollRef = useRef<ReturnType<typeof setInterval>>(undefined);
  const ta = t.animationEditor;

  // ── Polling ─────────────────────────────────────────────────

  const refresh = useCallback(async () => {
    if (!connected || selectedEntity == null) {
      setState(EMPTY_STATE);
      return;
    }
    try {
      const s = await rpc("animation.getState", { entityId: selectedEntity });
      setState(s);
    } catch {
      setState(EMPTY_STATE);
    }
  }, [connected, selectedEntity]);

  useEffect(() => {
    refresh();
    pollRef.current = setInterval(refresh, 500);
    return () => clearInterval(pollRef.current);
  }, [refresh]);

  // Reset selection when entity changes
  useEffect(() => {
    setSelectedStateIdx(null);
    setSelectedTransIdx(null);
    setSelectedCondIdx(null);
  }, [selectedEntity]);

  // Sync edit buffers when state selection changes
  useEffect(() => {
    if (selectedStateIdx != null && state.states) {
      const st = state.states.find((s) => s.index === selectedStateIdx);
      if (st) {
        setEditStateName(st.name);
        setEditSpeed(String(st.speed));
        setEditLoop(st.loop);
        setEditDuration(String(st.duration));
      }
    }
  }, [selectedStateIdx, state.states]);

  if (!connected) {
    return <Placeholder text={ta.notConnected} />;
  }
  if (selectedEntity == null || !state.hasAnimator) {
    return <Placeholder text={ta.noAnimator} />;
  }

  const entityId = selectedEntity;
  const { states = [], transitions = [], parameters = [], clipTracks = [] } = state;

  // ── Callbacks ───────────────────────────────────────────────

  const addState = async () => {
    const r = await rpc("animation.addState", { entityId });
    setSelectedStateIdx(r.index);
    refresh();
  };

  const removeState = async (idx: number) => {
    await rpc("animation.removeState", { entityId, stateIndex: idx });
    if (selectedStateIdx === idx) setSelectedStateIdx(null);
    refresh();
  };

  const commitState = async (field: string, value: unknown) => {
    if (selectedStateIdx == null) return;
    await rpc("animation.updateState", { entityId, stateIndex: selectedStateIdx, [field]: value } as never);
    refresh();
  };

  const setDefault = async (idx: number) => {
    await rpc("animation.setDefaultState", { entityId, stateIndex: idx });
    refresh();
  };

  const activateNow = async (idx: number) => {
    await rpc("animation.activateState", { entityId, stateIndex: idx });
    refresh();
  };

  const addTransition = async () => {
    if (newTransFrom === newTransTo) return;
    const r = await rpc("animation.addTransition", {
      entityId,
      fromState: newTransFrom,
      toState: newTransTo,
      duration: parseFloat(newTransDuration) || 0.2,
      triggerTime: parseFloat(newTransTrigger) || 0.25,
    });
    setSelectedTransIdx(r.index);
    refresh();
  };

  const removeTransition = async (idx: number) => {
    await rpc("animation.removeTransition", { entityId, transitionIndex: idx });
    if (selectedTransIdx === idx) setSelectedTransIdx(null);
    refresh();
  };

  const updateTransition = async (idx: number, field: string, value: unknown) => {
    await rpc("animation.updateTransition", { entityId, transitionIndex: idx, [field]: value } as never);
    refresh();
  };

  const addCondition = async (transIdx: number, condType: string) => {
    const r = await rpc("animation.addCondition", {
      entityId,
      transitionIndex: transIdx,
      conditionType: condType,
      threshold: 0.25,
    });
    setSelectedCondIdx(r.index);
    refresh();
  };

  const removeCondition = async (transIdx: number, condIdx: number) => {
    await rpc("animation.removeCondition", { entityId, transitionIndex: transIdx, conditionIndex: condIdx });
    if (selectedCondIdx === condIdx) setSelectedCondIdx(null);
    refresh();
  };

  const updateCondition = async (transIdx: number, condIdx: number, updates: Record<string, unknown>) => {
    await rpc("animation.updateCondition", { entityId, transitionIndex: transIdx, conditionIndex: condIdx, ...updates } as never);
    refresh();
  };

  const setParam = async (paramIdx: number, param: AnimGraphParameter, value: number | boolean) => {
    const payload: Record<string, unknown> = { entityId, parameterIndex: paramIdx };
    if (param.paramType === "float") payload.floatValue = value;
    else if (param.paramType === "bool") payload.boolValue = value;
    else if (param.paramType === "int") payload.intValue = Math.round(value as number);
    await rpc("animation.setParameter", payload as never);
    refresh();
  };

  // ── Render ──────────────────────────────────────────────────

  if (!state.hasGraph) {
    return <Placeholder text={ta.noGraph} />;
  }

  return (
    <div style={styles.container}>
      {/* ── Runtime Header ───────────────────────── */}
      <Section title={ta.graphName + ": " + (state.graphName ?? "—")}>
        <div style={styles.runtimeGrid}>
          <RuntimeRow label={ta.currentState} value={stateName(states, state.currentState)} color="#5cd6a0" />
          <RuntimeRow label={ta.nextState} value={stateName(states, state.nextState)} color="#ecc45c" />
          {state.nextState != null && (
            <RuntimeRow
              label={ta.transitionProgress}
              value={`${((state.blendFactor ?? 0) * 100).toFixed(0)}% (${(state.transitionTime ?? 0).toFixed(2)}s / ${(state.transitionDuration ?? 0).toFixed(2)}s)`}
            />
          )}
          {state.sampleTime != null && (
            <RuntimeRow label={ta.sampleTime} value={`${state.sampleTime.toFixed(3)}s`} />
          )}
        </div>
      </Section>

      {/* ── State Graph Overview ─────────────────── */}
      <Section title={ta.states}>
        <div style={styles.stateGrid}>
          {states.map((s) => (
            <button
              key={s.index}
              onClick={() => setSelectedStateIdx(s.index)}
              style={{
                ...styles.stateCard,
                background: s.isCurrent
                  ? STATE_COLORS.current
                  : s.isNext
                    ? STATE_COLORS.next
                    : s.isDefault
                      ? STATE_COLORS.default
                      : selectedStateIdx === s.index
                        ? STATE_COLORS.selected
                        : STATE_COLORS.normal,
                border: selectedStateIdx === s.index ? "1px solid #89b4fa" : "1px solid transparent",
              }}
            >
              <span style={styles.stateLabel}>{s.name}</span>
              <span style={styles.stateBadge}>
                {s.isDefault && <><IconPlay size={8} /> </>}
                {s.isCurrent && <><IconPlay size={8} color="#a6e3a1" /> </>}
                {s.isNext && <><IconForward size={8} /> </>}
              </span>
            </button>
          ))}
        </div>
        <div style={styles.row}>
          <SmallButton onClick={addState}>{ta.addState}</SmallButton>
        </div>
      </Section>

      {/* ── State Editor ─────────────────────────── */}
      {selectedStateIdx != null && (() => {
        const st = states.find((s) => s.index === selectedStateIdx);
        if (!st) return <div style={styles.muted}>{ta.selectState}</div>;
        return (
          <Section title={`${ta.states}: ${st.name}`}>
            <PropRow label={ta.stateName}>
              <input
                style={styles.input}
                value={editStateName}
                onChange={(e) => setEditStateName(e.target.value)}
                onBlur={() => commitState("name", editStateName)}
                onKeyDown={(e) => e.key === "Enter" && commitState("name", editStateName)}
              />
            </PropRow>
            <PropRow label={ta.clip}>
              <span style={styles.valueText}>{st.clipName ?? "—"}</span>
            </PropRow>
            <PropRow label={ta.speed}>
              <input
                type="number"
                style={styles.inputSmall}
                value={editSpeed}
                step={0.1}
                onChange={(e) => setEditSpeed(e.target.value)}
                onBlur={() => commitState("speed", parseFloat(editSpeed) || 1.0)}
              />
            </PropRow>
            <PropRow label={ta.loop}>
              <input
                type="checkbox"
                checked={editLoop}
                onChange={(e) => {
                  setEditLoop(e.target.checked);
                  commitState("loop", e.target.checked);
                }}
              />
            </PropRow>
            <PropRow label={ta.duration}>
              <input
                type="number"
                style={styles.inputSmall}
                value={editDuration}
                step={0.1}
                onChange={(e) => setEditDuration(e.target.value)}
                onBlur={() => commitState("duration", parseFloat(editDuration) || 0)}
              />
            </PropRow>
            <PropRow label={ta.defaultState}>
              <span style={styles.valueText}>{st.isDefault ? "Yes" : "No"}</span>
            </PropRow>
            <div style={styles.row}>
              <SmallButton onClick={() => setDefault(st.index)}>{ta.setDefault}</SmallButton>
              <SmallButton onClick={() => activateNow(st.index)}>{ta.activateNow}</SmallButton>
              <SmallButton onClick={() => removeState(st.index)} danger>{ta.removeState}</SmallButton>
            </div>
          </Section>
        );
      })()}

      {/* ── Parameters ───────────────────────────── */}
      {parameters.length > 0 && (
        <Section title={ta.parameters}>
          {parameters.map((p) => (
            <PropRow key={p.index} label={p.name}>
              {p.paramType === "bool" ? (
                <input
                  type="checkbox"
                  checked={p.boolValue ?? false}
                  onChange={(e) => setParam(p.index, p, e.target.checked)}
                />
              ) : (
                <input
                  type="number"
                  style={styles.inputSmall}
                  value={p.paramType === "int" ? (p.intValue ?? 0) : (p.floatValue ?? 0)}
                  step={p.paramType === "int" ? 1 : 0.01}
                  onChange={(e) => setParam(p.index, p, parseFloat(e.target.value) || 0)}
                />
              )}
            </PropRow>
          ))}
        </Section>
      )}

      {/* ── Transitions ──────────────────────────── */}
      <Section title={ta.transitions}>
        {transitions.length === 0 ? (
          <div style={styles.muted}>{ta.noTransitions}</div>
        ) : (
          <div style={styles.list}>
            {transitions.map((tr) => (
              <div
                key={tr.index}
                onClick={() => {
                  setSelectedTransIdx(tr.index);
                  setSelectedCondIdx(null);
                }}
                style={{
                  ...styles.listItem,
                  background: selectedTransIdx === tr.index ? "#3a4d69" : undefined,
                }}
              >
                <span>
                  {tr.fromStateName} → {tr.toStateName}
                  <span style={styles.dimText}> ({tr.duration.toFixed(2)}s)</span>
                </span>
                <span style={styles.condBadges}>
                  {tr.conditions.map((c) => (
                    <span key={c.index} style={styles.condBadge} title={conditionSummary(c)}>
                      {CONDITION_LABELS[c.conditionType] ?? "?"}
                    </span>
                  ))}
                </span>
              </div>
            ))}
          </div>
        )}

        {/* New transition controls */}
        {states.length >= 2 && (
          <div style={styles.newTransRow}>
            <select style={styles.select} value={newTransFrom} onChange={(e) => setNewTransFrom(Number(e.target.value))}>
              {states.map((s) => <option key={s.index} value={s.index}>{s.name}</option>)}
            </select>
            <span style={styles.arrow}>→</span>
            <select style={styles.select} value={newTransTo} onChange={(e) => setNewTransTo(Number(e.target.value))}>
              {states.map((s) => <option key={s.index} value={s.index}>{s.name}</option>)}
            </select>
            <SmallButton onClick={addTransition}>{ta.addTransition}</SmallButton>
          </div>
        )}
      </Section>

      {/* ── Transition Detail ────────────────────── */}
      {selectedTransIdx != null && (() => {
        const tr = transitions.find((t) => t.index === selectedTransIdx);
        if (!tr) return null;
        return (
          <Section title={`${tr.fromStateName} → ${tr.toStateName}`}>
            <PropRow label={ta.fromState}>
              <select
                style={styles.select}
                value={tr.fromState}
                onChange={(e) => updateTransition(tr.index, "fromState", Number(e.target.value))}
              >
                {states.map((s) => <option key={s.index} value={s.index}>{s.name}</option>)}
              </select>
            </PropRow>
            <PropRow label={ta.toState}>
              <select
                style={styles.select}
                value={tr.toState}
                onChange={(e) => updateTransition(tr.index, "toState", Number(e.target.value))}
              >
                {states.map((s) => <option key={s.index} value={s.index}>{s.name}</option>)}
              </select>
            </PropRow>
            <PropRow label={ta.blendDuration}>
              <input
                type="number"
                style={styles.inputSmall}
                defaultValue={tr.duration}
                step={0.01}
                onBlur={(e) => updateTransition(tr.index, "duration", parseFloat(e.target.value) || 0)}
              />
            </PropRow>

            {/* Conditions */}
            <div style={styles.subSection}>
              <div style={styles.subHeader}>
                <span>{ta.conditions}</span>
                <SmallButton onClick={() => addCondition(tr.index, "time_elapsed")}>{ta.addCondition}</SmallButton>
              </div>
              {tr.conditions.length === 0 ? (
                <div style={styles.muted}>{ta.noConditions}</div>
              ) : (
                tr.conditions.map((c) => (
                  <ConditionRow
                    key={c.index}
                    condition={c}
                    selected={selectedCondIdx === c.index}
                    onClick={() => setSelectedCondIdx(c.index)}
                    onUpdate={(updates) => updateCondition(tr.index, c.index, updates)}
                    onRemove={() => removeCondition(tr.index, c.index)}
                    ta={ta}
                    parameters={parameters}
                  />
                ))
              )}
            </div>

            <div style={{ ...styles.row, marginTop: 8 }}>
              <SmallButton onClick={() => removeTransition(tr.index)} danger>{ta.removeTransition}</SmallButton>
            </div>
          </Section>
        );
      })()}

      {/* ── Clip Tracks ──────────────────────────── */}
      {clipTracks.length > 0 && (
        <Section title={`${ta.clipTracks}${state.clipDuration != null ? ` (${state.clipDuration.toFixed(2)}s)` : ""}`}>
          <div style={styles.trackList}>
            {clipTracks.map((tr) => (
              <div key={tr.index} style={styles.trackRow}>
                <span
                  style={{ ...styles.trackDot, background: TRACK_TYPE_COLORS[tr.trackType] ?? "#cdd6f4" }}
                />
                <span style={styles.trackName}>{tr.name}</span>
                <span style={styles.dimText}>{tr.keyframeCount} kf</span>
              </div>
            ))}
          </div>
        </Section>
      )}
    </div>
  );
}

// ═════════════════════════════════════════════════════════════════
//  Sub-components
// ═════════════════════════════════════════════════════════════════

function Placeholder({ text }: { text: string }) {
  return <div style={styles.placeholder}>{text}</div>;
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div style={styles.section}>
      <div style={styles.sectionTitle}>{title}</div>
      {children}
    </div>
  );
}

function PropRow({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div style={styles.propRow}>
      <span style={styles.propLabel}>{label}</span>
      <div style={styles.propValue}>{children}</div>
    </div>
  );
}

function SmallButton({
  onClick,
  children,
  danger,
}: {
  onClick: () => void;
  children: React.ReactNode;
  danger?: boolean;
}) {
  return (
    <button onClick={onClick} style={{ ...styles.btn, ...(danger ? styles.btnDanger : {}) }}>
      {children}
    </button>
  );
}

function RuntimeRow({ label, value, color }: { label: string; value: string; color?: string }) {
  return (
    <div style={styles.runtimeRow}>
      <span style={styles.runtimeLabel}>{label}</span>
      <span style={{ ...styles.runtimeValue, color: color ?? "#cdd6f4" }}>{value}</span>
    </div>
  );
}

interface ConditionRowProps {
  condition: AnimTransitionCondition;
  selected: boolean;
  onClick: () => void;
  onUpdate: (updates: Record<string, unknown>) => void;
  onRemove: () => void;
  ta: Record<string, string>;
  parameters: AnimGraphParameter[];
}

function ConditionRow({ condition: c, selected, onClick, onUpdate, onRemove, ta, parameters }: ConditionRowProps) {
  return (
    <div
      onClick={onClick}
      style={{
        ...styles.condRow,
        background: selected ? "#3a4d69" : undefined,
      }}
    >
      <div style={styles.condMain}>
        <select
          style={styles.selectSm}
          value={c.conditionType}
          onChange={(e) => onUpdate({ conditionType: e.target.value })}
        >
          <option value="time_elapsed">{ta.timeElapsed}</option>
          <option value="time_remaining">{ta.timeRemaining}</option>
          <option value="parameter">{ta.parameter}</option>
        </select>

        {c.conditionType === "parameter" && (
          <>
            {parameters.length > 0 ? (
              <select
                style={styles.selectSm}
                value={c.parameterName ?? ""}
                onChange={(e) => onUpdate({ parameterName: e.target.value })}
              >
                {parameters.map((p) => (
                  <option key={p.index} value={p.name}>{p.name}</option>
                ))}
              </select>
            ) : (
              <input
                style={styles.inputXs}
                defaultValue={c.parameterName ?? ""}
                placeholder={ta.parameterName}
                onBlur={(e) => onUpdate({ parameterName: e.target.value })}
              />
            )}
            <select
              style={styles.selectXs}
              value={c.comparison ?? "=="}
              onChange={(e) => onUpdate({ comparison: e.target.value })}
            >
              <option value="<">&lt;</option>
              <option value=">">&gt;</option>
              <option value="==">==</option>
            </select>
          </>
        )}

        <input
          type="number"
          style={styles.inputXs}
          defaultValue={c.threshold}
          step={0.01}
          onBlur={(e) => onUpdate({ threshold: parseFloat(e.target.value) || 0 })}
        />

        <button style={styles.removeBtn} onClick={(e) => { e.stopPropagation(); onRemove(); }}><IconClose size={10} /></button>
      </div>
    </div>
  );
}

// ── Helpers ──────────────────────────────────────────────────────

function stateName(states: AnimGraphState[], idx?: number): string {
  if (idx == null) return "—";
  const s = states.find((s) => s.index === idx);
  return s?.name ?? "—";
}

function conditionSummary(c: AnimTransitionCondition): string {
  switch (c.conditionType) {
    case "time_elapsed":
      return `time ≥ ${c.threshold.toFixed(2)}s`;
    case "time_remaining":
      return `remaining ≤ ${c.threshold.toFixed(2)}s`;
    case "parameter":
      return `${c.parameterName ?? "?"} ${c.comparison ?? "=="} ${c.threshold.toFixed(2)}`;
    default:
      return c.conditionType;
  }
}

// ═════════════════════════════════════════════════════════════════
//  Styles
// ═════════════════════════════════════════════════════════════════

const styles: Record<string, React.CSSProperties> = {
  container: {
    display: "flex",
    flexDirection: "column",
    gap: 2,
    padding: 8,
    height: "100%",
    overflow: "auto",
    fontFamily: "var(--vscode-editor-font-family, monospace)",
    fontSize: 12,
    color: "#cdd6f4",
  },
  placeholder: {
    padding: 16,
    color: "#6c7086",
    textAlign: "center",
    fontSize: 12,
  },
  section: {
    background: "#1e1e2e",
    borderRadius: 4,
    padding: 8,
    marginBottom: 4,
  },
  sectionTitle: {
    fontSize: 11,
    fontWeight: 600,
    color: "#89b4fa",
    textTransform: "uppercase",
    letterSpacing: 0.5,
    marginBottom: 6,
    borderBottom: "1px solid #313244",
    paddingBottom: 4,
  },
  subSection: {
    marginTop: 8,
    paddingTop: 6,
    borderTop: "1px solid #313244",
  },
  subHeader: {
    display: "flex",
    justifyContent: "space-between",
    alignItems: "center",
    marginBottom: 4,
    fontSize: 11,
    fontWeight: 600,
    color: "#a6adc8",
  },
  runtimeGrid: {
    display: "flex",
    flexDirection: "column",
    gap: 2,
  },
  runtimeRow: {
    display: "flex",
    justifyContent: "space-between",
    padding: "2px 0",
  },
  runtimeLabel: {
    color: "#a6adc8",
    fontSize: 11,
  },
  runtimeValue: {
    fontWeight: 500,
    fontSize: 11,
  },
  stateGrid: {
    display: "flex",
    flexWrap: "wrap",
    gap: 4,
    marginBottom: 6,
  },
  stateCard: {
    padding: "6px 10px",
    borderRadius: 4,
    border: "1px solid transparent",
    cursor: "pointer",
    color: "#cdd6f4",
    fontSize: 11,
    display: "flex",
    flexDirection: "column",
    alignItems: "flex-start",
    minWidth: 90,
    transition: "background 0.1s",
  },
  stateLabel: {
    fontWeight: 500,
  },
  stateBadge: {
    fontSize: 9,
    color: "#a6adc8",
    marginTop: 1,
  },
  propRow: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    padding: "2px 0",
    minHeight: 22,
  },
  propLabel: {
    color: "#a6adc8",
    fontSize: 11,
    minWidth: 80,
    flexShrink: 0,
  },
  propValue: {
    flex: 1,
    display: "flex",
    alignItems: "center",
  },
  valueText: {
    fontSize: 11,
    color: "#cdd6f4",
  },
  input: {
    width: "100%",
    padding: "2px 6px",
    background: "#313244",
    border: "1px solid #45475a",
    borderRadius: 3,
    color: "#cdd6f4",
    fontSize: 11,
    outline: "none",
  },
  inputSmall: {
    width: 80,
    padding: "2px 6px",
    background: "#313244",
    border: "1px solid #45475a",
    borderRadius: 3,
    color: "#cdd6f4",
    fontSize: 11,
    outline: "none",
  },
  inputXs: {
    width: 56,
    padding: "2px 4px",
    background: "#313244",
    border: "1px solid #45475a",
    borderRadius: 3,
    color: "#cdd6f4",
    fontSize: 10,
    outline: "none",
  },
  row: {
    display: "flex",
    gap: 4,
    marginTop: 4,
  },
  btn: {
    padding: "3px 8px",
    background: "#313244",
    border: "1px solid #45475a",
    borderRadius: 3,
    color: "#cdd6f4",
    fontSize: 10,
    cursor: "pointer",
  },
  btnDanger: {
    border: "1px solid #f38ba8",
    color: "#f38ba8",
  },
  list: {
    display: "flex",
    flexDirection: "column",
    gap: 1,
    maxHeight: 160,
    overflow: "auto",
  },
  listItem: {
    display: "flex",
    justifyContent: "space-between",
    alignItems: "center",
    padding: "4px 8px",
    borderRadius: 3,
    cursor: "pointer",
    fontSize: 11,
  },
  dimText: {
    color: "#6c7086",
    fontSize: 10,
    marginLeft: 4,
  },
  condBadges: {
    display: "flex",
    gap: 2,
  },
  condBadge: {
    background: "#45475a",
    padding: "1px 4px",
    borderRadius: 2,
    fontSize: 9,
    color: "#a6adc8",
  },
  newTransRow: {
    display: "flex",
    alignItems: "center",
    gap: 4,
    marginTop: 6,
    flexWrap: "wrap",
  },
  select: {
    padding: "2px 4px",
    background: "#313244",
    border: "1px solid #45475a",
    borderRadius: 3,
    color: "#cdd6f4",
    fontSize: 11,
    outline: "none",
  },
  selectSm: {
    padding: "1px 3px",
    background: "#313244",
    border: "1px solid #45475a",
    borderRadius: 3,
    color: "#cdd6f4",
    fontSize: 10,
    outline: "none",
  },
  selectXs: {
    padding: "1px 2px",
    background: "#313244",
    border: "1px solid #45475a",
    borderRadius: 3,
    color: "#cdd6f4",
    fontSize: 10,
    outline: "none",
    width: 36,
  },
  arrow: {
    color: "#6c7086",
    fontSize: 12,
  },
  condRow: {
    padding: "4px 6px",
    borderRadius: 3,
    cursor: "pointer",
    marginBottom: 2,
  },
  condMain: {
    display: "flex",
    alignItems: "center",
    gap: 4,
    flexWrap: "wrap",
  },
  removeBtn: {
    background: "none",
    border: "none",
    color: "#f38ba8",
    cursor: "pointer",
    fontSize: 10,
    padding: "0 2px",
    marginLeft: "auto",
  },
  trackList: {
    display: "flex",
    flexDirection: "column",
    gap: 2,
  },
  trackRow: {
    display: "flex",
    alignItems: "center",
    gap: 6,
    padding: "2px 4px",
    fontSize: 11,
  },
  trackDot: {
    width: 8,
    height: 8,
    borderRadius: "50%",
    flexShrink: 0,
  },
  trackName: {
    flex: 1,
  },
  muted: {
    color: "#6c7086",
    fontSize: 11,
    padding: "4px 0",
  },
};
