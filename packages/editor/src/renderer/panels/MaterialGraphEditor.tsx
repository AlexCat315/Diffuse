import React, { useCallback, useEffect, useRef, useState, useMemo } from "react";
import {
  ReactFlow,
  ReactFlowProvider,
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
  useReactFlow,
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

const SOCKET_TYPES = ["scalar", "vec2", "vec3", "vec4", "texture", "surface"] as const;

const VALUE_KINDS = ["none", "scalar", "vec2", "vec3", "vec4", "texture"] as const;

// ── Per-node-kind slot definitions ──────────────────────────────

interface SlotDef {
  label: string;
}
interface NodeSlotConfig {
  inputs: SlotDef[];
  outputs: SlotDef[];
}

const NODE_SLOT_CONFIG: Record<string, NodeSlotConfig> = {
  input_parameter: { inputs: [], outputs: [{ label: "out" }] },
  constant:        { inputs: [], outputs: [{ label: "out" }] },
  texture_sample:  { inputs: [{ label: "UV" }], outputs: [{ label: "color" }] },
  math_add:        { inputs: [{ label: "A" }, { label: "B" }], outputs: [{ label: "out" }] },
  math_multiply:   { inputs: [{ label: "A" }, { label: "B" }], outputs: [{ label: "out" }] },
  split_channels:  { inputs: [{ label: "in" }], outputs: [{ label: "R" }, { label: "G" }, { label: "B" }, { label: "A" }] },
  normal_map:      { inputs: [{ label: "in" }], outputs: [{ label: "out" }] },
  output:          { inputs: [{ label: "surface" }], outputs: [] },
};

// ── Vector value editor component ───────────────────────────────

function VecEditor({
  values,
  count,
  labels,
  onCommit,
}: {
  values: number[];
  count: number;
  labels: string[];
  onCommit: (vals: number[]) => void;
}) {
  const [local, setLocal] = useState<number[]>(values.slice(0, count));

  useEffect(() => {
    setLocal(values.slice(0, count));
  }, [values, count]);

  return (
    <div style={{ display: "flex", gap: 2, marginTop: 2 }}>
      {Array.from({ length: count }).map((_, i) => (
        <div key={i} style={{ flex: 1 }}>
          <div style={{ fontSize: 8, color: "#585b70", textAlign: "center" }}>{labels[i]}</div>
          <input
            type="number"
            step="0.01"
            style={{
              width: "100%",
              background: "#1e1e2e",
              color: "#cdd6f4",
              border: "1px solid #45475a",
              borderRadius: 3,
              padding: "2px 3px",
              fontSize: 9,
              textAlign: "center",
            }}
            value={local[i]?.toFixed(2) ?? "0.00"}
            onChange={(e) => {
              const next = [...local];
              next[i] = parseFloat(e.target.value) || 0;
              setLocal(next);
            }}
            onBlur={() => onCommit(local)}
          />
        </div>
      ))}
    </div>
  );
}

// ── Custom node component ───────────────────────────────────────

function MaterialNode({ data }: NodeProps) {
  const nodeData = data as unknown as MaterialGraphNodeInfo & { label: string };
  const color = NODE_KIND_COLORS[nodeData.kind] ?? "#555";
  const kindLabel = nodeData.kind.replace(/_/g, " ");
  const slotConfig = NODE_SLOT_CONFIG[nodeData.kind] ?? { inputs: [{ label: "in" }], outputs: [{ label: "out" }] };

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
            {nodeData.valueKind === "vec2" && `[${(nodeData.vec2 as number[]).map((v: number) => v.toFixed(2)).join(", ")}]`}
            {nodeData.valueKind === "vec3" && `[${(nodeData.vec3 as number[]).map((v: number) => v.toFixed(2)).join(", ")}]`}
            {nodeData.valueKind === "vec4" && `[${(nodeData.vec4 as number[]).map((v: number) => v.toFixed(2)).join(", ")}]`}
          </div>
        )}
        {nodeData.kind === "texture_sample" && nodeData.textureHandle != null && (
          <div style={{ fontSize: 10, color: "#f9e2af" }}>
            tex #{nodeData.textureHandle}
          </div>
        )}

        {/* Slot labels */}
        <div style={{ display: "flex", justifyContent: "space-between", marginTop: 4 }}>
          <div>
            {slotConfig.inputs.map((s, i) => (
              <div key={i} style={{ fontSize: 9, color: "#a6e3a1", lineHeight: "16px" }}>
                ● {s.label}
              </div>
            ))}
          </div>
          <div style={{ textAlign: "right" }}>
            {slotConfig.outputs.map((s, i) => (
              <div key={i} style={{ fontSize: 9, color: "#f38ba8", lineHeight: "16px" }}>
                {s.label} ●
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* Input handles */}
      {slotConfig.inputs.map((_, i) => (
        <Handle
          key={`in-${i}`}
          id={`in-${i}`}
          type="target"
          position={Position.Left}
          style={{
            background: "#a6e3a1",
            width: 10,
            height: 10,
            borderRadius: "50%",
            top: `${56 + i * 16}px`,
          }}
        />
      ))}
      {/* Output handles */}
      {slotConfig.outputs.map((_, i) => (
        <Handle
          key={`out-${i}`}
          id={`out-${i}`}
          type="source"
          position={Position.Right}
          style={{
            background: "#f38ba8",
            width: 10,
            height: 10,
            borderRadius: "50%",
            top: `${56 + i * 16}px`,
          }}
        />
      ))}
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

const SOCKET_TYPE_COLORS: Record<string, string> = {
  scalar: "#6c7086",
  vec2: "#89b4fa",
  vec3: "#74c7ec",
  vec4: "#cba6f7",
  texture: "#f9e2af",
  surface: "#f38ba8",
};

function toFlowEdges(connections: MaterialGraphConnectionInfo[], nodes?: MaterialGraphNodeInfo[]): Edge[] {
  return connections.map((c, i) => {
    const sourceNode = nodes?.find((n) => n.id === c.fromNodeId);
    const strokeColor = SOCKET_TYPE_COLORS[sourceNode?.outputType ?? ""] ?? "#6c7086";
    return {
      id: `e-${c.fromNodeId}-${c.fromSlot}-${c.toNodeId}-${c.toSlot}`,
      source: String(c.fromNodeId),
      target: String(c.toNodeId),
      sourceHandle: `out-${c.fromSlot}`,
      targetHandle: `in-${c.toSlot}`,
      type: "smoothstep",
      style: { stroke: strokeColor, strokeWidth: 2 },
      animated: true,
    };
  });
}

// ── Main component ──────────────────────────────────────────────

export function MaterialGraphEditor() {
  return (
    <ReactFlowProvider>
      <MaterialGraphEditorInner />
    </ReactFlowProvider>
  );
}

function MaterialGraphEditorInner() {
  const { t } = useI18n();
  const selectedEntity = useSceneStore((s) => s.selectedEntity);
  const connected = useConnectionStore((s) => s.connected);
  const reactFlowInstance = useReactFlow();

  const [graphState, setGraphState] = useState<GraphState | null>(null);
  const [hasGraph, setHasGraph] = useState(false);
  const [flowNodes, setFlowNodes] = useState<Node[]>([]);
  const [flowEdges, setFlowEdges] = useState<Edge[]>([]);
  const [selectedNode, setSelectedNode] = useState<MaterialGraphNodeInfo | null>(null);
  const [addMenuOpen, setAddMenuOpen] = useState(false);
  const [textures, setTextures] = useState<{ handle: number; name: string }[]>([]);
  const [ctxMenu, setCtxMenu] = useState<{ x: number; y: number; nodeId: number } | null>(null);

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
      setFlowEdges(toFlowEdges(gs.connections, gs.nodes));
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

  // ── Fetch texture list (once) ──────────────────────────────

  useEffect(() => {
    if (!connected) return;
    rpc("material.listTextures", {} as never)
      .then((res) => setTextures(res.textures.map((t) => ({ handle: t.handle, name: t.name }))))
      .catch(() => {});
  }, [connected]);

  // ── React Flow handlers ─────────────────────────────────────

  const onNodesChange: OnNodesChange = useCallback(
    (changes) => {
      setFlowNodes((nds) => applyNodeChanges(changes, nds));
      // Sync node removals to engine
      if (selectedEntity == null) return;
      for (const change of changes) {
        if (change.type === "remove") {
          rpc("material.removeGraphNode", {
            entityId: selectedEntity,
            nodeId: Number(change.id),
          })
            .then(() => {
              setSelectedNode(null);
              fetchGraph();
            })
            .catch(() => {});
        }
      }
    },
    [selectedEntity, fetchGraph],
  );

  const onEdgesChange: OnEdgesChange = useCallback(
    (changes) => {
      setFlowEdges((eds) => applyEdgeChanges(changes, eds));
      // Sync edge removals to engine
      if (selectedEntity == null) return;
      for (const change of changes) {
        if (change.type === "remove") {
          const parts = change.id.split("-");
          // edge id format: e-{fromNodeId}-{fromSlot}-{toNodeId}-{toSlot}
          if (parts.length === 5) {
            rpc("material.removeGraphConnection", {
              entityId: selectedEntity,
              fromNodeId: Number(parts[1]),
              fromSlot: Number(parts[2]),
              toNodeId: Number(parts[3]),
              toSlot: Number(parts[4]),
            })
              .then(() => fetchGraph())
              .catch(() => {});
          }
        }
      }
    },
    [selectedEntity, fetchGraph],
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
      const fromSlot = parseInt(connection.sourceHandle?.replace("out-", "") ?? "0", 10);
      const toSlot = parseInt(connection.targetHandle?.replace("in-", "") ?? "0", 10);
      rpc("material.addGraphConnection", {
        entityId: selectedEntity,
        fromNodeId: Number(connection.source),
        fromSlot,
        toNodeId: Number(connection.target),
        toSlot,
      })
        .then(() => fetchGraph())
        .catch(() => {});
    },
    [selectedEntity, fetchGraph],
  );

  const isValidConnection = useCallback(
    (connection: Edge | Connection) => {
      if (connection.source === connection.target) return false;
      // Prevent duplicate connections
      if (
        flowEdges.some(
          (e) => e.source === connection.source && e.target === connection.target &&
            e.sourceHandle === connection.sourceHandle && e.targetHandle === connection.targetHandle,
        )
      )
        return false;

      // Socket type compatibility check
      if (graphState) {
        const sourceNode = graphState.nodes.find((n) => String(n.id) === connection.source);
        const targetNode = graphState.nodes.find((n) => String(n.id) === connection.target);
        if (sourceNode && targetNode) {
          const srcType = sourceNode.outputType;
          const tgtKind = targetNode.kind;
          // output node only accepts surface type
          if (tgtKind === "output" && srcType !== "surface") return false;
          // texture_sample UV input only accepts vec2
          if (tgtKind === "texture_sample" && srcType !== "vec2") return false;
          // normal_map input accepts vec3/vec4
          if (tgtKind === "normal_map" && srcType !== "vec3" && srcType !== "vec4") return false;
          // math nodes accept scalar/vec types, not texture/surface
          if ((tgtKind === "math_add" || tgtKind === "math_multiply") &&
            (srcType === "texture" || srcType === "surface"))
            return false;
          // split_channels accepts vec types
          if (tgtKind === "split_channels" && srcType !== "vec2" && srcType !== "vec3" && srcType !== "vec4")
            return false;
        }
      }
      return true;
    },
    [flowEdges, graphState],
  );

  const onNodeClick = useCallback(
    (_event: React.MouseEvent, node: Node) => {
      if (!graphState) return;
      const info = graphState.nodes.find((n) => n.id === Number(node.id));
      setSelectedNode(info ?? null);
      setCtxMenu(null);
    },
    [graphState],
  );

  const onNodeContextMenu = useCallback(
    (event: React.MouseEvent, node: Node) => {
      event.preventDefault();
      if (!graphState) return;
      const info = graphState.nodes.find((n) => n.id === Number(node.id));
      setSelectedNode(info ?? null);
      setCtxMenu({ x: event.clientX, y: event.clientY, nodeId: Number(node.id) });
    },
    [graphState],
  );

  const onPaneClick = useCallback(() => {
    setCtxMenu(null);
    setAddMenuOpen(false);
  }, []);

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
        sourceSlot: 0,
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

  const duplicateNode = useCallback(
    (nodeId: number) => {
      if (selectedEntity == null || !graphState) return;
      const node = graphState.nodes.find((n) => n.id === nodeId);
      if (!node) return;
      rpc("material.addGraphNode", {
        entityId: selectedEntity,
        kind: node.kind,
        posX: node.posX + 40,
        posY: node.posY + 40,
      })
        .then(() => fetchGraph())
        .catch(() => {});
      setCtxMenu(null);
    },
    [selectedEntity, graphState, fetchGraph],
  );

  const disconnectAll = useCallback(
    (nodeId: number) => {
      if (selectedEntity == null || !graphState) return;
      const conns = graphState.connections.filter(
        (c) => c.fromNodeId === nodeId || c.toNodeId === nodeId,
      );
      Promise.all(
        conns.map((c) =>
          rpc("material.removeGraphConnection", {
            entityId: selectedEntity,
            fromNodeId: c.fromNodeId,
            fromSlot: c.fromSlot,
            toNodeId: c.toNodeId,
            toSlot: c.toSlot,
          }),
        ),
      )
        .then(() => fetchGraph())
        .catch(() => {});
      setCtxMenu(null);
    },
    [selectedEntity, graphState, fetchGraph],
  );

  // ── Early returns ─────────────────────────────────────────

  if (!connected) {
    return <div style={styles.placeholder}>{t.app.connectingToEngine}</div>;
  }

  if (selectedEntity == null) {
    return <div style={styles.placeholder}>{t.materialGraph.noEntity}</div>;
  }

  if (!hasGraph) {
    return (
      <div style={styles.placeholder}>
        <div style={{ textAlign: "center" }}>
          <div>{t.materialGraph.noGraph}</div>
          <button
            style={{ ...styles.toolbarBtn, marginTop: 8 }}
            onClick={() => {
              if (selectedEntity == null) return;
              // Bootstrap: add an output node to force graph creation
              rpc("material.addGraphNode", {
                entityId: selectedEntity,
                kind: "output",
                posX: 400,
                posY: 200,
              })
                .then(() => fetchGraph())
                .catch(() => {});
            }}
          >
            {t.materialGraph.createGraph}
          </button>
        </div>
      </div>
    );
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
            isValidConnection={isValidConnection}
            onNodeClick={onNodeClick}
            onNodeContextMenu={onNodeContextMenu}
            onPaneClick={onPaneClick}
            onNodeDragStop={onNodeDragStop}
            nodeTypes={nodeTypes}
            fitView
            deleteKeyCode="Delete"
            snapToGrid
            snapGrid={[24, 24]}
            defaultEdgeOptions={{ type: "smoothstep", animated: true }}
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

          {/* Context menu */}
          {ctxMenu && (
            <div
              style={{
                position: "fixed",
                left: ctxMenu.x,
                top: ctxMenu.y,
                background: "#1e1e2e",
                border: "1px solid #45475a",
                borderRadius: 6,
                padding: 4,
                zIndex: 200,
                minWidth: 150,
                boxShadow: "0 4px 12px rgba(0,0,0,0.5)",
              }}
            >
              <button
                style={styles.dropdownItem}
                onClick={() => duplicateNode(ctxMenu.nodeId)}
              >
                {t.materialGraph.duplicate}
              </button>
              <button
                style={styles.dropdownItem}
                onClick={() => disconnectAll(ctxMenu.nodeId)}
              >
                {t.materialGraph.disconnectAll}
              </button>
              <button
                style={{ ...styles.dropdownItem, color: "#f38ba8" }}
                onClick={() => {
                  removeNode(ctxMenu.nodeId);
                  setCtxMenu(null);
                }}
              >
                {t.materialGraph.removeNode}
              </button>
            </div>
          )}
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

              {/* Output type selector */}
              <label style={styles.fieldLabel}>{t.materialGraph.outputType}</label>
              <select
                style={styles.select}
                value={selectedNode.outputType}
                onChange={(e) =>
                  updateNode(selectedNode.id, { outputType: e.target.value })
                }
              >
                {SOCKET_TYPES.map((st) => (
                  <option key={st} value={st}>{st}</option>
                ))}
              </select>

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

              {/* Value kind selector (for constant/input_parameter) */}
              {(selectedNode.kind === "constant" || selectedNode.kind === "input_parameter") && (
                <>
                  <label style={styles.fieldLabel}>{t.materialGraph.valueType}</label>
                  <select
                    style={styles.select}
                    value={selectedNode.valueKind}
                    onChange={(e) =>
                      updateNode(selectedNode.id, { valueKind: e.target.value })
                    }
                  >
                    {VALUE_KINDS.map((vk) => (
                      <option key={vk} value={vk}>{vk}</option>
                    ))}
                  </select>
                </>
              )}

              {/* Scalar value editor */}
              {selectedNode.valueKind === "scalar" && (
                <>
                  <label style={styles.fieldLabel}>{t.materialGraph.value}</label>
                  <input
                    type="number"
                    step="0.01"
                    style={styles.input}
                    defaultValue={selectedNode.scalar}
                    key={`s-${selectedNode.id}-${selectedNode.scalar}`}
                    onBlur={(e) =>
                      updateNode(selectedNode.id, {
                        valueKind: "scalar",
                        scalar: parseFloat(e.target.value) || 0,
                      })
                    }
                  />
                </>
              )}

              {/* Vec2 value editor */}
              {selectedNode.valueKind === "vec2" && (
                <>
                  <label style={styles.fieldLabel}>{t.materialGraph.value} (vec2)</label>
                  <VecEditor
                    values={selectedNode.vec2 as unknown as number[]}
                    count={2}
                    labels={["X", "Y"]}
                    onCommit={(vals) =>
                      updateNode(selectedNode.id, { valueKind: "vec2", vec2: vals as [number, number] })
                    }
                  />
                </>
              )}

              {/* Vec3 value editor */}
              {selectedNode.valueKind === "vec3" && (
                <>
                  <label style={styles.fieldLabel}>{t.materialGraph.value} (vec3)</label>
                  <VecEditor
                    values={selectedNode.vec3 as unknown as number[]}
                    count={3}
                    labels={["R", "G", "B"]}
                    onCommit={(vals) =>
                      updateNode(selectedNode.id, { valueKind: "vec3", vec3: vals as [number, number, number] })
                    }
                  />
                </>
              )}

              {/* Vec4 value editor */}
              {selectedNode.valueKind === "vec4" && (
                <>
                  <label style={styles.fieldLabel}>{t.materialGraph.value} (vec4)</label>
                  <VecEditor
                    values={selectedNode.vec4 as unknown as number[]}
                    count={4}
                    labels={["R", "G", "B", "A"]}
                    onCommit={(vals) =>
                      updateNode(selectedNode.id, { valueKind: "vec4", vec4: vals as [number, number, number, number] })
                    }
                  />
                  {/* Color preview swatch */}
                  <div
                    style={{
                      width: "100%",
                      height: 20,
                      borderRadius: 3,
                      marginTop: 4,
                      border: "1px solid #45475a",
                      background: `rgba(${Math.round(((selectedNode.vec4 as unknown as number[])[0] ?? 0) * 255)}, ${Math.round(((selectedNode.vec4 as unknown as number[])[1] ?? 0) * 255)}, ${Math.round(((selectedNode.vec4 as unknown as number[])[2] ?? 0) * 255)}, ${(selectedNode.vec4 as unknown as number[])[3] ?? 1})`,
                    }}
                  />
                </>
              )}

              {/* Texture selector */}
              {selectedNode.kind === "texture_sample" && (
                <>
                  <label style={styles.fieldLabel}>{t.materialGraph.texture}</label>
                  <select
                    style={styles.select}
                    value={selectedNode.textureHandle ?? 0}
                    onChange={(e) => {
                      const h = parseInt(e.target.value, 10);
                      updateNode(selectedNode.id, { textureHandle: h || undefined });
                    }}
                  >
                    <option value={0}>({t.materialGraph.none})</option>
                    {textures.map((tex) => (
                      <option key={tex.handle} value={tex.handle}>
                        {tex.name} (#{tex.handle})
                      </option>
                    ))}
                  </select>
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
                onClick={() => {
                  setSelectedNode(n);
                  const flowNode = flowNodes.find((fn) => fn.id === String(n.id));
                  if (flowNode) {
                    reactFlowInstance.setCenter(
                      flowNode.position.x + 80,
                      flowNode.position.y + 40,
                      { zoom: 1.2, duration: 400 },
                    );
                  }
                }}
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
