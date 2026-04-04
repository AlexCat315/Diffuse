import React, { useCallback, useEffect, useRef, useState, useMemo } from "react";
import {
  ReactFlow,
  Background,
  Controls,
  MiniMap,
  type Node,
  type Edge,
  type OnNodesChange,
  type OnEdgesChange,
  type OnConnect,
  type Connection,
  applyNodeChanges,
  applyEdgeChanges,
  Handle,
  Position,
  type NodeProps,
} from "@xyflow/react";
import "@xyflow/react/dist/style.css";

import { rpc } from "../rpc";
import { useSceneStore } from "../store";
import { useConnectionStore } from "../store";
import { useI18n } from "../i18n";
import type {
  MaterialGraphNodeInfo,
  MaterialGraphConnectionInfo,
  MaterialGraphOutputInfo,
} from "../../shared/rpc-types";

// ── Node kind metadata ──────────────────────────────────────────

const NODE_KIND_COLORS: Record<string, string> = {
  input_parameter: "#4a9eff",
  constant: "#8b8b8b",
  texture_sample: "#e67e22",
  math_add: "#2ecc71",
  math_multiply: "#27ae60",
  split_channels: "#9b59b6",
  normal_map: "#7f8cff",
  output: "#e74c3c",
};

const NODE_KINDS = [
  "input_parameter",
  "constant",
  "texture_sample",
  "math_add",
  "math_multiply",
  "split_channels",
  "normal_map",
  "output",
] as const;

const MATERIAL_CHANNELS = [
  "base_color",
  "metallic",
  "roughness",
  "normal",
  "occlusion",
  "emissive",
  "alpha_cutoff",
] as const;

// ── Custom node component ───────────────────────────────────────

function MaterialNode({ data }: NodeProps) {
  const nodeData = data as unknown as MaterialGraphNodeInfo & { label: string };
  const color = NODE_KIND_COLORS[nodeData.kind] ?? "#555";
  const kindLabel = nodeData.kind.replace(/_/g, " ");

  return (
    <div
      style={{
        background: "#1e1e2e",
        border: `2px solid ${color}`,
        borderRadius: 8,
        padding: 0,
        minWidth: 160,
        fontSize: 12,
        color: "#cdd6f4",
        boxShadow: "0 2px 8px rgba(0,0,0,0.4)",
      }}
    >
      {/* Header */}
      <div
        style={{
          background: color,
          borderRadius: "6px 6px 0 0",
          padding: "4px 10px",
          fontWeight: 600,
          fontSize: 11,
          textTransform: "uppercase",
          letterSpacing: 0.5,
          color: "#fff",
        }}
      >
        {kindLabel}
      </div>

      {/* Body */}
      <div style={{ padding: "6px 10px" }}>
        {nodeData.channel && (
          <div style={{ color: "#a6adc8", fontSize: 10, marginBottom: 2 }}>
            {nodeData.channel}
          </div>
        )}
        {nodeData.kind === "constant" && (
          <div style={{ fontSize: 10, color: "#80ff80" }}>
            {nodeData.valueKind === "scalar" && `${nodeData.scalar.toFixed(3)}`}
            {nodeData.valueKind === "vec2" && `[${nodeData.vec2.map((v: number) => v.toFixed(2)).join(", ")}]`}
            {nodeData.valueKind === "vec3" && `[${nodeData.vec3.map((v: number) => v.toFixed(2)).join(", ")}]`}
            {nodeData.valueKind === "vec4" && `[${nodeData.vec4.map((v: number) => v.toFixed(2)).join(", ")}]`}
          </div>
        )}
        {nodeData.kind === "texture_sample" && nodeData.textureHandle != null && (
          <div style={{ fontSize: 10, color: "#f9e2af" }}>
            tex #{nodeData.textureHandle}
          </div>
        )}
        <div style={{ fontSize: 9, color: "#585b70", marginTop: 2 }}>
          out: {nodeData.outputType}
        </div>
      </div>

      {/* Handles */}
      {nodeData.kind !== "output" && (
        <Handle
          type="source"
          position={Position.Right}
          style={{ background: "#f38ba8", width: 10, height: 10, borderRadius: "50%" }}
        />
      )}
      {nodeData.kind !== "input_parameter" && (
        <Handle
          type="target"
          position={Position.Left}
          style={{ background: "#a6e3a1", width: 10, height: 10, borderRadius: "50%" }}
        />
      )}
    </div>
  );
}

const nodeTypes = { materialNode: MaterialNode };

// ── Editor state ────────────────────────────────────────────────

interface GraphState {
  nodes: MaterialGraphNodeInfo[];
  connections: MaterialGraphConnectionInfo[];
  outputs: MaterialGraphOutputInfo[];
}

// ── Helper: convert engine graph → React Flow nodes/edges ───────

function toFlowNodes(nodes: MaterialGraphNodeInfo[]): Node[] {
  return nodes.map((n) => ({
    id: String(n.id),
    type: "materialNode",
    position: { x: n.posX, y: n.posY },
    data: { ...n, label: n.kind },
  }));
}

function toFlowEdges(connections: MaterialGraphConnectionInfo[]): Edge[] {
  return connections.map((c, i) => ({
    id: `e-${c.fromNodeId}-${c.fromSlot}-${c.toNodeId}-${c.toSlot}`,
    source: String(c.fromNodeId),
    target: String(c.toNodeId),
    sourceHandle: null,
    targetHandle: null,
    style: { stroke: "#6c7086", strokeWidth: 2 },
    animated: true,
  }));
}

// ── Main component ──────────────────────────────────────────────

export function MaterialGraphEditor() {
  const { t } = useI18n();
  const selectedEntity = useSceneStore((s) => s.selectedEntity);
  const connected = useConnectionStore((s) => s.connected);

  const [graphState, setGraphState] = useState<GraphState | null>(null);
  const [hasGraph, setHasGraph] = useState(false);
  const [flowNodes, setFlowNodes] = useState<Node[]>([]);
  const [flowEdges, setFlowEdges] = useState<Edge[]>([]);
  const [selectedNode, setSelectedNode] = useState<MaterialGraphNodeInfo | null>(null);
  const [addMenuOpen, setAddMenuOpen] = useState(false);

  const pollingRef = useRef<ReturnType<typeof setInterval> | undefined>(undefined);

  // ── Fetch graph state ───────────────────────────────────────

  const fetchGraph = useCallback(async () => {
    if (!connected || selectedEntity == null) {
      setGraphState(null);
      setHasGraph(false);
      return;
    }
    try {
      const res = await rpc("material.getGraph", { entityId: selectedEntity });
      if (!res.hasGraph) {
        setGraphState(null);
        setHasGraph(false);
        return;
      }
      setHasGraph(true);
      const gs: GraphState = {
        nodes: res.nodes ?? [],
        connections: res.connections ?? [],
        outputs: res.outputs ?? [],
      };
      setGraphState(gs);
      setFlowNodes(toFlowNodes(gs.nodes));
      setFlowEdges(toFlowEdges(gs.connections));
    } catch {
      setGraphState(null);
      setHasGraph(false);
    }
  }, [connected, selectedEntity]);

  useEffect(() => {
    fetchGraph();
    pollingRef.current = setInterval(fetchGraph, 2000);
    return () => clearInterval(pollingRef.current);
  }, [fetchGraph]);

  // ── React Flow handlers ─────────────────────────────────────

  const onNodesChange: OnNodesChange = useCallback(
    (changes) => {
      setFlowNodes((nds) => applyNodeChanges(changes, nds));
    },
    [],
  );

  const onEdgesChange: OnEdgesChange = useCallback(
    (changes) => {
      setFlowEdges((eds) => applyEdgeChanges(changes, eds));
    },
    [],
  );

  const onNodeDragStop = useCallback(
    (_event: React.MouseEvent, node: Node) => {
      if (selectedEntity == null) return;
      rpc("material.setNodePosition", {
        entityId: selectedEntity,
        nodeId: Number(node.id),
        posX: node.position.x,
        posY: node.position.y,
      }).catch(() => {});
    },
    [selectedEntity],
  );

  const onConnect: OnConnect = useCallback(
    (connection: Connection) => {
      if (selectedEntity == null) return;
      rpc("material.addGraphConnection", {
        entityId: selectedEntity,
        fromNodeId: Number(connection.source),
        toNodeId: Number(connection.target),
      })
        .then(() => fetchGraph())
        .catch(() => {});
    },
    [selectedEntity, fetchGraph],
  );

  const onNodeClick = useCallback(
    (_event: React.MouseEvent, node: Node) => {
      if (!graphState) return;
      const info = graphState.nodes.find((n) => n.id === Number(node.id));
      setSelectedNode(info ?? null);
    },
    [graphState],
  );

  // ── Actions ─────────────────────────────────────────────────

  const addNode = useCallback(
    (kind: string) => {
      if (selectedEntity == null) return;
      rpc("material.addGraphNode", {
        entityId: selectedEntity,
        kind,
        posX: 200 + Math.random() * 200,
        posY: 100 + Math.random() * 200,
      })
        .then(() => fetchGraph())
        .catch(() => {});
      setAddMenuOpen(false);
    },
    [selectedEntity, fetchGraph],
  );

  const removeNode = useCallback(
    (nodeId: number) => {
      if (selectedEntity == null) return;
      rpc("material.removeGraphNode", { entityId: selectedEntity, nodeId })
        .then(() => {
          setSelectedNode(null);
          fetchGraph();
        })
        .catch(() => {});
    },
    [selectedEntity, fetchGraph],
  );

  const updateNode = useCallback(
    (nodeId: number, updates: Record<string, unknown>) => {
      if (selectedEntity == null) return;
      rpc("material.updateGraphNode", {
        entityId: selectedEntity,
        nodeId,
        ...updates,
      } as never)
        .then(() => fetchGraph())
        .catch(() => {});
    },
    [selectedEntity, fetchGraph],
  );

  const setOutput = useCallback(
    (channel: string, sourceNodeId: number) => {
      if (selectedEntity == null) return;
      rpc("material.setGraphOutput", {
        entityId: selectedEntity,
        channel,
        sourceNodeId,
      })
        .then(() => fetchGraph())
        .catch(() => {});
    },
    [selectedEntity, fetchGraph],
  );

  const removeOutput = useCallback(
    (channel: string) => {
      if (selectedEntity == null) return;
      rpc("material.removeGraphOutput", { entityId: selectedEntity, channel })
        .then(() => fetchGraph())
        .catch(() => {});
    },
    [selectedEntity, fetchGraph],
  );

  // ── Early returns ─────────────────────────────────────────

  if (!connected) {
    return <div style={styles.placeholder}>{t.app.connectingToEngine}</div>;
  }

  if (selectedEntity == null) {
    return <div style={styles.placeholder}>{t.materialGraph.noEntity}</div>;
  }

  if (!hasGraph) {
    return <div style={styles.placeholder}>{t.materialGraph.noGraph}</div>;
  }

  // ── Render ────────────────────────────────────────────────

  return (
    <div style={{ width: "100%", height: "100%", display: "flex", flexDirection: "column" }}>
      {/* Toolbar */}
      <div style={styles.toolbar}>
        <span style={styles.toolbarTitle}>{t.materialGraph.title}</span>
        <div style={{ position: "relative" }}>
          <button
            style={styles.toolbarBtn}
            onClick={() => setAddMenuOpen(!addMenuOpen)}
          >
            + {t.materialGraph.addNode}
          </button>
          {addMenuOpen && (
            <div style={styles.dropdown}>
              {NODE_KINDS.map((kind) => (
                <button
                  key={kind}
                  style={styles.dropdownItem}
                  onClick={() => addNode(kind)}
                >
                  <span
                    style={{
                      display: "inline-block",
                      width: 8,
                      height: 8,
                      borderRadius: "50%",
                      background: NODE_KIND_COLORS[kind],
                      marginRight: 6,
                    }}
                  />
                  {kind.replace(/_/g, " ")}
                </button>
              ))}
            </div>
          )}
        </div>
      </div>

      <div style={{ flex: 1, display: "flex" }}>
        {/* Graph canvas */}
        <div style={{ flex: 1, position: "relative" }}>
          <ReactFlow
            nodes={flowNodes}
            edges={flowEdges}
            onNodesChange={onNodesChange}
            onEdgesChange={onEdgesChange}
            onConnect={onConnect}
            onNodeClick={onNodeClick}
            onNodeDragStop={onNodeDragStop}
            nodeTypes={nodeTypes}
            fitView
            colorMode="dark"
            proOptions={{ hideAttribution: true }}
          >
            <Background gap={24} size={1} color="#313244" />
            <Controls position="bottom-left" />
            <MiniMap
              nodeColor={(node) => {
                const kind = (node.data as unknown as MaterialGraphNodeInfo)?.kind;
                return NODE_KIND_COLORS[kind] ?? "#555";
              }}
              style={{ background: "#181825" }}
            />
          </ReactFlow>
        </div>

        {/* Side panel */}
        <div style={styles.sidePanel}>
          {/* Outputs section */}
          <div style={styles.section}>
            <div style={styles.sectionHeader}>{t.materialGraph.outputs}</div>
            {graphState?.outputs.map((o) => (
              <div key={o.channel} style={styles.outputRow}>
                <span style={styles.outputChannel}>{o.channel}</span>
                <span style={styles.outputArrow}>←</span>
                <span style={styles.outputSource}>node #{o.sourceNodeId}</span>
                <button
                  style={styles.removeBtn}
                  onClick={() => removeOutput(o.channel)}
                  title={t.materialGraph.removeOutput}
                >
                  ✕
                </button>
              </div>
            ))}
            {(!graphState?.outputs || graphState.outputs.length === 0) && (
              <div style={styles.emptyHint}>{t.materialGraph.noOutputs}</div>
            )}
          </div>

          {/* Selected node inspector */}
          {selectedNode && (
            <div style={styles.section}>
              <div style={styles.sectionHeader}>
                {t.materialGraph.nodeProperties}
                <button
                  style={{ ...styles.removeBtn, marginLeft: "auto" }}
                  onClick={() => removeNode(selectedNode.id)}
                  title={t.materialGraph.removeNode}
                >
                  🗑
                </button>
              </div>

              <label style={styles.fieldLabel}>ID: {selectedNode.id}</label>
              <label style={styles.fieldLabel}>
                {t.materialGraph.kind}: {selectedNode.kind.replace(/_/g, " ")}
              </label>

              {/* Channel selector */}
              <label style={styles.fieldLabel}>{t.materialGraph.channel}</label>
              <select
                style={styles.select}
                value={selectedNode.channel ?? ""}
                onChange={(e) =>
                  updateNode(selectedNode.id, {
                    channel: e.target.value || undefined,
                  })
                }
              >
                <option value="">({t.materialGraph.none})</option>
                {MATERIAL_CHANNELS.map((ch) => (
                  <option key={ch} value={ch}>
                    {ch}
                  </option>
                ))}
              </select>

              {/* Value editor for scalars */}
              {selectedNode.valueKind === "scalar" && (
                <>
                  <label style={styles.fieldLabel}>{t.materialGraph.value}</label>
                  <input
                    type="number"
                    step="0.01"
                    style={styles.input}
                    defaultValue={selectedNode.scalar}
                    onBlur={(e) =>
                      updateNode(selectedNode.id, {
                        valueKind: "scalar",
                        scalar: parseFloat(e.target.value) || 0,
                      })
                    }
                  />
                </>
              )}

              {/* Set as output */}
              <label style={styles.fieldLabel}>{t.materialGraph.assignOutput}</label>
              <select
                style={styles.select}
                value=""
                onChange={(e) => {
                  if (e.target.value) setOutput(e.target.value, selectedNode.id);
                }}
              >
                <option value="">{t.materialGraph.selectChannel}</option>
                {MATERIAL_CHANNELS.map((ch) => (
                  <option key={ch} value={ch}>
                    {ch}
                  </option>
                ))}
              </select>
            </div>
          )}

          {/* Node list */}
          <div style={styles.section}>
            <div style={styles.sectionHeader}>
              {t.materialGraph.nodeList} ({graphState?.nodes.length ?? 0})
            </div>
            {graphState?.nodes.map((n) => (
              <div
                key={n.id}
                style={{
                  ...styles.nodeListItem,
                  borderLeft: `3px solid ${NODE_KIND_COLORS[n.kind] ?? "#555"}`,
                  background: selectedNode?.id === n.id ? "#313244" : "transparent",
                }}
                onClick={() => setSelectedNode(n)}
              >
                <span>{n.kind.replace(/_/g, " ")}</span>
                <span style={{ color: "#585b70", fontSize: 10 }}>#{n.id}</span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

// ── Styles ──────────────────────────────────────────────────────

const styles: Record<string, React.CSSProperties> = {
  placeholder: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    height: "100%",
    color: "#6c7086",
    fontSize: 13,
  },
  toolbar: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    padding: "6px 10px",
    borderBottom: "1px solid #313244",
    background: "#181825",
  },
  toolbarTitle: {
    fontWeight: 600,
    fontSize: 12,
    color: "#cdd6f4",
    flex: 1,
  },
  toolbarBtn: {
    background: "#313244",
    color: "#cdd6f4",
    border: "1px solid #45475a",
    borderRadius: 4,
    padding: "3px 10px",
    fontSize: 11,
    cursor: "pointer",
  },
  dropdown: {
    position: "absolute",
    right: 0,
    top: "100%",
    background: "#1e1e2e",
    border: "1px solid #45475a",
    borderRadius: 6,
    padding: 4,
    zIndex: 100,
    minWidth: 180,
  },
  dropdownItem: {
    display: "flex",
    alignItems: "center",
    width: "100%",
    background: "none",
    border: "none",
    color: "#cdd6f4",
    padding: "5px 8px",
    fontSize: 11,
    cursor: "pointer",
    borderRadius: 3,
    textAlign: "left",
  },
  sidePanel: {
    width: 220,
    borderLeft: "1px solid #313244",
    background: "#181825",
    overflowY: "auto",
    fontSize: 11,
  },
  section: {
    padding: "8px 10px",
    borderBottom: "1px solid #313244",
  },
  sectionHeader: {
    fontWeight: 600,
    fontSize: 11,
    color: "#a6adc8",
    marginBottom: 6,
    display: "flex",
    alignItems: "center",
    gap: 4,
  },
  outputRow: {
    display: "flex",
    alignItems: "center",
    gap: 4,
    padding: "2px 0",
    fontSize: 10,
  },
  outputChannel: {
    fontWeight: 600,
    color: "#f2cdcd",
    minWidth: 60,
  },
  outputArrow: {
    color: "#585b70",
  },
  outputSource: {
    color: "#94e2d5",
    flex: 1,
  },
  removeBtn: {
    background: "none",
    border: "none",
    color: "#f38ba8",
    cursor: "pointer",
    fontSize: 11,
    padding: "0 2px",
  },
  emptyHint: {
    color: "#585b70",
    fontStyle: "italic",
    fontSize: 10,
    padding: "2px 0",
  },
  fieldLabel: {
    display: "block",
    color: "#a6adc8",
    marginTop: 4,
    fontSize: 10,
  },
  select: {
    width: "100%",
    background: "#1e1e2e",
    color: "#cdd6f4",
    border: "1px solid #45475a",
    borderRadius: 3,
    padding: "3px 4px",
    fontSize: 10,
    marginTop: 2,
  },
  input: {
    width: "100%",
    background: "#1e1e2e",
    color: "#cdd6f4",
    border: "1px solid #45475a",
    borderRadius: 3,
    padding: "3px 4px",
    fontSize: 10,
    marginTop: 2,
  },
  nodeListItem: {
    display: "flex",
    justifyContent: "space-between",
    alignItems: "center",
    padding: "3px 8px",
    cursor: "pointer",
    borderRadius: 3,
    color: "#cdd6f4",
    fontSize: 10,
    marginBottom: 1,
  },
};
