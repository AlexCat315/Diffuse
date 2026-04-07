import React, { useRef, useEffect, useLayoutEffect, useState, useCallback, useMemo } from "react";
import { useI18n } from "../i18n";
import { IconClose } from "../components/Icons";
import { useConsoleStore } from "../store";
import { setConsoleTrimPaused } from "../store/console";
import { useSyncedState } from "../store/synced-state";

type LogLevel = "debug" | "info" | "warn" | "error";

const LEVELS: LogLevel[] = ["debug", "info", "warn", "error"];

const levelColors: Record<string, string> = {
  debug: "#6c7086",
  info: "#cdd6f4",
  warn: "#f9e2af",
  error: "#f38ba8",
};

const sourceColors: Record<string, string> = {
  renderer: "#89b4fa",
  asset: "#a6e3a1",
  script: "#cba6f7",
  scene: "#fab387",
  editor: "#74c7ec",
  rhi: "#94e2d5",
};

/** Threshold (px) to consider the list "at the bottom". */
const SCROLL_THRESHOLD = 40;

export function Console() {
  const logs = useConsoleStore((s) => s.logs);
  const clearLogs = useConsoleStore((s) => s.clearLogs);
  const { t } = useI18n();

  const listRef = useRef<HTMLDivElement>(null);
  const endRef = useRef<HTMLDivElement>(null);
  // Use a ref for the most up-to-date stick state (avoids race with React batching)
  const stickRef = useRef(true);
  const [stickToBottom, setStickToBottom] = useState(true);
  const [searchText, setSearchText] = useState("");
  const [activeFilters, setActiveFilters] = useSyncedState<Set<LogLevel>>("console", "activeFilters", new Set(LEVELS));

  // Detect if user has scrolled away from bottom
  const handleScroll = useCallback(() => {
    const el = listRef.current;
    if (!el) return;
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < SCROLL_THRESHOLD;
    stickRef.current = atBottom;
    setStickToBottom(atBottom);
    setConsoleTrimPaused(!atBottom);
  }, []);

  // Auto-scroll only when sticking to bottom — uses ref to avoid stale-state race
  useLayoutEffect(() => {
    if (stickRef.current) {
      endRef.current?.scrollIntoView({ behavior: "auto" });
    }
  }, [logs.length]);

  const jumpToBottom = useCallback(() => {
    stickRef.current = true;
    setStickToBottom(true);
    setConsoleTrimPaused(false);
    endRef.current?.scrollIntoView({ behavior: "auto" });
  }, []);

  const toggleFilter = (level: LogLevel) => {
    setActiveFilters((prev) => {
      const next = new Set(prev);
      if (next.has(level)) next.delete(level); else next.add(level);
      return next;
    });
  };

  const searchLower = searchText.toLowerCase();
  const filtered = useMemo(
    () =>
      logs.filter(
        (log) =>
          activeFilters.has(log.level as LogLevel) &&
          (!searchLower ||
            log.message.toLowerCase().includes(searchLower) ||
            (log.source && log.source.toLowerCase().includes(searchLower))),
      ),
    [logs, activeFilters, searchLower],
  );

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
        <input
          type="text"
          value={searchText}
          onChange={(e) => setSearchText(e.target.value)}
          placeholder="Filter..."
          style={styles.searchInput}
        />
        <div style={{ flex: 1 }} />
        <button style={styles.clearBtn} onClick={clearLogs} title={t.console.clearTooltip}>
          <IconClose size={12} />
        </button>
      </div>
      <div style={{ position: "relative", flex: 1, minHeight: 0 }}>
        <div ref={listRef} onScroll={handleScroll} style={styles.logList}>
          {filtered.length === 0 ? (
            <div style={styles.empty}>{t.console.noLogs}</div>
          ) : (
            filtered.map((log) => (
              <div key={log._id} style={styles.logEntry}>
                <span style={{ ...styles.level, color: levelColors[log.level] ?? "#cdd6f4" }}>
                  [{log.level.toUpperCase()}]
                </span>
                {log.source && (
                  <span style={{ ...styles.source, color: sourceColors[log.source] ?? "#585b70" }}>
                    {log.source}
                  </span>
                )}
                <span style={styles.message}>{log.message}</span>
              </div>
            ))
          )}
          <div ref={endRef} />
        </div>
        {!stickToBottom && (
          <button style={styles.jumpBtn} onClick={jumpToBottom}>
            ↓ New logs
          </button>
        )}
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
  logList: { position: "absolute", inset: 0, overflow: "auto", padding: "2px 0", fontFamily: "'SF Mono', 'Fira Code', Menlo, monospace", fontSize: 12 },
  empty: { padding: 24, textAlign: "center", color: "#585b70", fontSize: 12 },
  logEntry: {
    display: "flex",
    gap: 8,
    padding: "3px 10px",
    borderBottom: "1px solid rgba(24,24,37,0.6)",
    transition: "background 0.1s",
  },
  level: { minWidth: 55, fontWeight: 600, fontSize: 10, flexShrink: 0, letterSpacing: 0.3 },
  source: { minWidth: 60, fontSize: 10, opacity: 0.7, flexShrink: 0, fontWeight: 500 },
  message: { color: "#cdd6f4", wordBreak: "break-all", lineHeight: 1.4 },
  searchInput: {
    background: "#1e1e2e",
    border: "1px solid #313244",
    borderRadius: 4,
    color: "#cdd6f4",
    padding: "3px 8px",
    fontSize: 11,
    fontFamily: "'SF Mono', 'Fira Code', Menlo, monospace",
    width: 140,
    outline: "none",
    marginLeft: 8,
  },
  jumpBtn: {
    position: "absolute" as const,
    bottom: 12,
    left: "50%",
    transform: "translateX(-50%)",
    background: "#89b4fa",
    color: "#1e1e2e",
    border: "none",
    borderRadius: 16,
    padding: "5px 16px",
    fontSize: 11,
    fontWeight: 600,
    cursor: "pointer",
    boxShadow: "0 2px 12px rgba(137,180,250,0.3)",
    zIndex: 10,
  },
};
