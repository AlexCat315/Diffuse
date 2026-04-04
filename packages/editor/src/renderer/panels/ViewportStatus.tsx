import React, { useEffect, useState } from "react";
import { useI18n } from "../i18n";
import { useConnectionStore } from "../store";

interface ViewportMetrics {
  fps: number;
  drawCalls: number;
  triangles: number;
}


export function ViewportStatus() {
  const connected = useConnectionStore((s) => s.connected);
  const { t } = useI18n();
  const [metrics, setMetrics] = useState<ViewportMetrics | null>(null);

  useEffect(() => {
    if (!connected) {
      setMetrics(null);
      return;
    }

    const cleanup = window.guavaEngine.onEvent((event, data) => {
      if (event === "on:viewport.metrics") {
        setMetrics(data as ViewportMetrics);
      }
    });

    return cleanup;
  }, [connected]);

  if (!connected || !metrics) return null;

  const fpsColor = metrics.fps >= 55 ? "#a6e3a1" : metrics.fps >= 30 ? "#f9e2af" : "#f38ba8";

  return (
    <div style={styles.bar}>
      <span style={{ ...styles.item, color: fpsColor }}>
        {Math.round(metrics.fps)} {t.viewportStatus.fps}
      </span>
      <span style={styles.separator} />
      <span style={styles.item}>
        {formatNumber(metrics.drawCalls)} {t.viewportStatus.drawCalls}
      </span>
      <span style={styles.separator} />
      <span style={styles.item}>
        {formatNumber(metrics.triangles)} {t.viewportStatus.triangles}
      </span>
    </div>
  );
}

function formatNumber(n: number): string {
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(1) + "M";
  if (n >= 1_000) return (n / 1_000).toFixed(1) + "K";
  return String(n);
}

const styles: Record<string, React.CSSProperties> = {
  bar: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    padding: "2px 12px",
    background: "#11111b",
    borderTop: "1px solid #313244",
    fontSize: 11,
    color: "#6c7086",
    minHeight: 22,
    flexShrink: 0,
  },
  item: {
    fontFamily: "monospace",
    letterSpacing: 0.3,
  },
  separator: {
    width: 1,
    height: 12,
    background: "#313244",
  },
};
