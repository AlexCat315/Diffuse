import React, { useEffect, useState, useCallback, useRef } from "react";
import { useConnectionStore } from "../store";

interface BindingCacheStats {
  hits: number;
  misses: number;
  evictions: number;
  entries: number;
  maxEntries: number;
  hitRate: number;
  frameHits: number;
  frameMisses: number;
  frameEvictions: number;
}

interface PassInfo {
  name: string;
  status: string;
}

interface RhiStatsData {
  bindingCache: BindingCacheStats;
  passes: PassInfo[];
}


export function RhiStats() {
  const connected = useConnectionStore((s) => s.connected);
  const [data, setData] = useState<RhiStatsData | null>(null);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const refresh = useCallback(async () => {
    if (!connected) return;
    try {
      const res = await window.guavaEngine.call("debug.getRhiStats", {});
      setData(res);
    } catch {
      /* ignore */
    }
  }, [connected]);

  useEffect(() => {
    refresh();
    timerRef.current = setInterval(refresh, 1000);
    return () => {
      if (timerRef.current) clearInterval(timerRef.current);
    };
  }, [refresh]);

  const handleReset = async () => {
    await window.guavaEngine.call("debug.resetRhiStats", {});
    refresh();
  };

  const c = data?.bindingCache;

  return (
    <div style={styles.container}>
      <div style={styles.header}>
        <span style={styles.title}>RHI Stats</span>
        <div style={{ flex: 1 }} />
        <button style={styles.resetBtn} onClick={handleReset}>
          Reset
        </button>
      </div>
      <div style={styles.content}>
        {/* Binding Cache Section */}
        <div style={styles.section}>
          <div style={styles.sectionTitle}>Binding Set Cache</div>
          {c ? (
            <>
              <div style={styles.barContainer}>
                <div style={styles.barLabel}>
                  Hit Rate: {c.hitRate.toFixed(1)}%
                </div>
                <div style={styles.barBg}>
                  <div
                    style={{
                      ...styles.barFill,
                      width: `${Math.min(c.hitRate, 100)}%`,
                      background: c.hitRate >= 90 ? "#a6e3a1" : c.hitRate >= 70 ? "#f9e2af" : "#f38ba8",
                    }}
                  />
                </div>
              </div>
              <div style={styles.barContainer}>
                <div style={styles.barLabel}>
                  Entries: {c.entries} / {c.maxEntries}
                </div>
                <div style={styles.barBg}>
                  <div
                    style={{
                      ...styles.barFill,
                      width: `${(c.entries / c.maxEntries) * 100}%`,
                      background: "#89b4fa",
                    }}
                  />
                </div>
              </div>
              <div style={styles.statsGrid}>
                <StatCell label="Hits" value={c.hits} />
                <StatCell label="Misses" value={c.misses} />
                <StatCell label="Evictions" value={c.evictions} />
                <StatCell label="Frame Hits" value={c.frameHits} color="#a6e3a1" />
                <StatCell label="Frame Miss" value={c.frameMisses} color="#f9e2af" />
                <StatCell label="Frame Evict" value={c.frameEvictions} color="#f38ba8" />
              </div>
            </>
          ) : (
            <div style={styles.empty}>No data</div>
          )}
        </div>

        {/* Render Passes Section */}
        <div style={styles.section}>
          <div style={styles.sectionTitle}>Render Passes ({data?.passes.length ?? 0})</div>
          <div style={styles.passList}>
            {data?.passes.map((p) => (
              <div key={p.name} style={styles.passRow}>
                <span style={styles.passName}>{p.name}</span>
                <span style={styles.passStatus}>{p.status}</span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

function StatCell({ label, value, color }: { label: string; value: number; color?: string }) {
  return (
    <div style={styles.statCell}>
      <div style={{ ...styles.statValue, color: color ?? "#cdd6f4" }}>{value.toLocaleString()}</div>
      <div style={styles.statLabel}>{label}</div>
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
  resetBtn: {
    background: "#313244",
    border: "1px solid #45475a",
    borderRadius: 4,
    color: "#f9e2af",
    cursor: "pointer",
    padding: "2px 8px",
    fontSize: 11,
    fontWeight: 600,
  },
  content: { flex: 1, overflow: "auto", padding: 8 },
  section: { marginBottom: 12 },
  sectionTitle: {
    fontSize: 11,
    fontWeight: 600,
    color: "#89b4fa",
    textTransform: "uppercase",
    letterSpacing: 0.5,
    marginBottom: 6,
  },
  barContainer: { marginBottom: 6 },
  barLabel: { fontSize: 11, color: "#a6adc8", marginBottom: 2 },
  barBg: {
    height: 6,
    background: "#313244",
    borderRadius: 3,
    overflow: "hidden",
  },
  barFill: {
    height: "100%",
    borderRadius: 3,
    transition: "width 0.3s",
  },
  statsGrid: {
    display: "grid",
    gridTemplateColumns: "1fr 1fr 1fr",
    gap: 4,
    marginTop: 6,
  },
  statCell: {
    background: "#181825",
    borderRadius: 4,
    padding: "4px 6px",
    textAlign: "center",
  },
  statValue: { fontSize: 13, fontWeight: 700, fontFamily: "monospace" },
  statLabel: { fontSize: 9, color: "#6c7086", marginTop: 1 },
  passList: { fontSize: 11 },
  passRow: {
    display: "flex",
    justifyContent: "space-between",
    padding: "2px 4px",
    borderBottom: "1px solid #181825",
  },
  passName: { color: "#cdd6f4" },
  passStatus: { color: "#6c7086", fontSize: 10, fontFamily: "monospace" },
  empty: { padding: 16, textAlign: "center", opacity: 0.4, fontSize: 12, color: "#a6adc8" },
};
