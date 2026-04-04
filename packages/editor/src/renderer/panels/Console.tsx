import React, { useRef, useEffect, useState } from "react";
import type { LogEntry } from "../../shared/rpc-types";
import { useI18n } from "../i18n";
import { IconClose } from "../components/Icons";
import { useConsoleStore } from "../store";

type LogLevel = "debug" | "info" | "warn" | "error";

const LEVELS: LogLevel[] = ["debug", "info", "warn", "error"];

const levelColors: Record<string, string> = {
  debug: "#6c7086",
  info: "#cdd6f4",
  warn: "#f9e2af",
  error: "#f38ba8",
};

export function Console() {
  const logs = useConsoleStore((s) => s.logs);
  const clearLogs = useConsoleStore((s) => s.clearLogs);
  const { t } = useI18n();
  const endRef = useRef<HTMLDivElement>(null);
  const [activeFilters, setActiveFilters] = useState<Set<LogLevel>>(new Set(LEVELS));

  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [logs.length]);

  const toggleFilter = (level: LogLevel) => {
    setActiveFilters((prev) => {
      const next = new Set(prev);
      next.has(level) ? next.delete(level) : next.add(level);
      return next;
    });
  };

  const filtered = logs.filter((log) => activeFilters.has(log.level as LogLevel));

  return (
    <div style={styles.container}>
      <div style={styles.header}>
        <span style={styles.title}>{t.console.title}</span>
        <span style={styles.count}>{filtered.length}</span>
        <div style={styles.filters}>
          {LEVELS.map((level) => (
            <button
              key={level}
              style={{
                ...styles.filterBtn,
                color: levelColors[level],
                opacity: activeFilters.has(level) ? 1 : 0.3,
                border: activeFilters.has(level) ? `1px solid ${levelColors[level]}` : "1px solid transparent",
              }}
              onClick={() => toggleFilter(level)}
              title={`Toggle ${level}`}
            >
              {level[0].toUpperCase()}
            </button>
          ))}
        </div>
        <div style={{ flex: 1 }} />
        <button style={styles.clearBtn} onClick={clearLogs} title={t.console.clearTooltip}>
          <IconClose size={12} />
        </button>
      </div>
      <div style={styles.logList}>
        {filtered.length === 0 ? (
          <div style={styles.empty}>{t.console.noLogs}</div>
        ) : (
          filtered.map((log, i) => (
            <div key={i} style={styles.logEntry}>
              <span style={{ ...styles.level, color: levelColors[log.level] ?? "#cdd6f4" }}>
                [{log.level.toUpperCase()}]
              </span>
              <span style={styles.message}>{log.message}</span>
            </div>
          ))
        )}
        <div ref={endRef} />
      </div>
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  container: { display: "flex", flexDirection: "column", height: "100%" },
  header: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    padding: "6px 12px",
    borderBottom: "1px solid #313244",
    fontSize: 12,
    fontWeight: 600,
    textTransform: "uppercase",
    letterSpacing: 0.5,
    color: "#a6adc8",
  },
  title: {},
  count: {
    background: "#45475a",
    borderRadius: 8,
    padding: "0 6px",
    fontSize: 10,
    color: "#a6adc8",
  },
  filters: {
    display: "flex",
    gap: 2,
    marginLeft: 8,
  },
  filterBtn: {
    background: "transparent",
    border: "1px solid transparent",
    borderRadius: 3,
    cursor: "pointer",
    padding: "1px 5px",
    fontSize: 10,
    fontWeight: 700,
    fontFamily: "monospace",
    transition: "opacity 0.1s",
  },
  clearBtn: {
    background: "transparent",
    border: "1px solid transparent",
    borderRadius: 3,
    color: "#6c7086",
    cursor: "pointer",
    padding: "1px 5px",
    fontSize: 12,
  },
  logList: { flex: 1, overflow: "auto", padding: 4, fontFamily: "monospace", fontSize: 12 },
  empty: { padding: 16, textAlign: "center", opacity: 0.4 },
  logEntry: {
    display: "flex",
    gap: 8,
    padding: "1px 8px",
    borderBottom: "1px solid #181825",
  },
  level: { minWidth: 55, fontWeight: 600, fontSize: 11 },
  message: { color: "#cdd6f4", wordBreak: "break-all" },
};
