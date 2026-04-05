import { useLocalState } from "../store/local-state";
import React, { useEffect, useCallback } from "react";
import { useI18n } from "../i18n";
import { IconUndo, IconRedo } from "../components/Icons";
import type { HistoryEntry } from "../../shared/rpc-types";
import { useConnectionStore } from "../store";


export function CommandTimeline() {
  const connected = useConnectionStore((s) => s.connected);
  const { t } = useI18n();
  const [entries, setEntries] = useLocalState<HistoryEntry[]>([]);
  const [cursor, setCursor] = useLocalState<number>(0);
  const [hoveredIdx, setHoveredIdx] = useLocalState<number | null>(null);

  const fetchHistory = useCallback(async () => {
    if (!connected) return;
    try {
      const result = await window.guavaEngine.call("editor.getHistory", {});
      setEntries(result.entries);
      setCursor(result.cursor);
    } catch {
      // RPC not available yet
    }
  }, [connected]);

  useEffect(() => {
    fetchHistory();
  }, [fetchHistory]);

  useEffect(() => {
    if (!connected) return;
    const cleanup = window.guavaEngine.onEvent((event) => {
      if (event === "on:editor.historyChanged") {
        fetchHistory();
      }
    });
    return cleanup;
  }, [connected, fetchHistory]);

  const handleTimeTravel = useCallback(
    async (sequence: number) => {
      try {
        await window.guavaEngine.call("editor.timeTravel", { targetSequence: sequence });
        fetchHistory();
      } catch {
        // ignore
      }
    },
    [fetchHistory],
  );

  const handleUndo = useCallback(() => {
    window.guavaEngine.call("editor.undo", {}).then(fetchHistory).catch(() => {});
  }, [fetchHistory]);

  const handleRedo = useCallback(() => {
    window.guavaEngine.call("editor.redo", {}).then(fetchHistory).catch(() => {});
  }, [fetchHistory]);

  const cursorIndex = entries.findIndex((e) => e.sequence === cursor);

  return (
    <div style={styles.container}>
      <div style={styles.header}>
        <span style={styles.title}>{t.commandTimeline.title}</span>
        <div style={{ flex: 1 }} />
        <button style={styles.actionBtn} onClick={handleUndo} title={t.toolbar.undo}>
          <IconUndo size={12} />
        </button>
        <button style={styles.actionBtn} onClick={handleRedo} title={t.toolbar.redo}>
          <IconRedo size={12} />
        </button>
      </div>

      {entries.length === 0 ? (
        <div style={styles.empty}>{t.commandTimeline.noHistory}</div>
      ) : (
        <div style={styles.timeline}>
          {entries.map((entry, idx) => {
            const isCurrent = idx === cursorIndex;
            const isPast = idx <= cursorIndex;
            const isHovered = idx === hoveredIdx;
            const isAI = entry.source === "ai";

            return (
              <div
                key={entry.sequence}
                style={{
                  ...styles.entry,
                  ...(isPast ? styles.entryPast : styles.entryFuture),
                  ...(isCurrent ? styles.entryCurrent : {}),
                  ...(isHovered ? styles.entryHover : {}),
                }}
                title={`${entry.label}${entry.detail ? ` (${entry.detail})` : ""}`}
                onClick={() => handleTimeTravel(entry.sequence)}
                onMouseEnter={() => setHoveredIdx(idx)}
                onMouseLeave={() => setHoveredIdx(null)}
              >
                <div style={styles.entryDot}>
                  <div
                    style={{
                      ...styles.dot,
                      background: isCurrent
                        ? "#89b4fa"
                        : isAI
                          ? "#cba6f7"
                          : isPast
                            ? "#a6adc8"
                            : "#45475a",
                    }}
                  />
                </div>
                <div style={styles.entryLabel}>
                  {isCurrent && (
                    <span style={styles.currentBadge}>{t.commandTimeline.current}</span>
                  )}
                  <span style={{ opacity: isPast ? 1 : 0.4 }}>{entry.label}</span>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  container: {
    display: "flex",
    flexDirection: "column",
    height: "100%",
    color: "#cdd6f4",
    fontSize: 12,
  },
  header: {
    display: "flex",
    alignItems: "center",
    gap: 6,
    padding: "6px 10px",
    borderBottom: "1px solid #313244",
  },
  title: {
    fontSize: 12,
    fontWeight: 600,
    textTransform: "uppercase" as const,
    letterSpacing: 0.5,
    color: "#a6adc8",
  },
  actionBtn: {
    background: "transparent",
    border: "none",
    color: "#a6adc8",
    cursor: "pointer",
    padding: "2px 4px",
    borderRadius: 3,
    display: "flex",
    alignItems: "center",
  },
  empty: {
    opacity: 0.4,
    textAlign: "center" as const,
    padding: 20,
    fontSize: 12,
  },
  timeline: {
    flex: 1,
    overflow: "auto",
    padding: "4px 0",
  },
  entry: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    padding: "4px 10px",
    cursor: "pointer",
    transition: "background 0.1s",
  },
  entryPast: {},
  entryFuture: { opacity: 0.4 },
  entryCurrent: {
    background: "rgba(137, 180, 250, 0.08)",
  },
  entryHover: {
    background: "rgba(137, 180, 250, 0.12)",
  },
  entryDot: {
    flexShrink: 0,
    width: 16,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
  },
  dot: {
    width: 8,
    height: 8,
    borderRadius: "50%",
  },
  entryLabel: {
    display: "flex",
    alignItems: "center",
    gap: 6,
    minWidth: 0,
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap" as const,
  },
  currentBadge: {
    fontSize: 9,
    fontWeight: 700,
    textTransform: "uppercase" as const,
    color: "#89b4fa",
    letterSpacing: 0.5,
    flexShrink: 0,
  },
};
