import React, { useEffect, useState, useCallback, useRef } from "react";
import { useI18n } from "../i18n";
import { useConnectionStore } from "../store";

interface BusInfo {
  id: string;
  label: string;
  volume: number;
  playing: number;
}


export function AudioMixer() {
  const connected = useConnectionStore((s) => s.connected);
  const { t } = useI18n();
  const [available, setAvailable] = useState(false);
  const [activeVoices, setActiveVoices] = useState(0);
  const [buses, setBuses] = useState<BusInfo[]>([]);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const refresh = useCallback(async () => {
    if (!connected) return;
    try {
      const res = await window.guavaEngine.call("audio.getMixerStatus", {});
      setAvailable(res.available);
      setActiveVoices(res.activeVoices);
      setBuses(res.buses);
    } catch {
      /* ignore */
    }
  }, [connected]);

  useEffect(() => {
    refresh();
    timerRef.current = setInterval(refresh, 500);
    return () => {
      if (timerRef.current) clearInterval(timerRef.current);
    };
  }, [refresh]);

  const handleVolumeChange = async (busId: string, volume: number) => {
    try {
      await window.guavaEngine.call("audio.setBusVolume", { busId, volume });
      setBuses((prev) => prev.map((b) => (b.id === busId ? { ...b, volume } : b)));
    } catch {
      /* ignore */
    }
  };

  return (
    <div style={styles.container}>
      <div style={styles.header}>
        <span style={styles.title}>{t.audio.title}</span>
        <span style={styles.count}>{activeVoices} {t.audio.voices}</span>
        {!available && <span style={styles.badge}>{t.audio.offline}</span>}
      </div>
      <div style={styles.content}>
        {buses.length === 0 ? (
          <div style={styles.empty}>{available ? t.audio.noBuses : t.audio.runtimeUnavailable}</div>
        ) : (
          buses.map((bus) => (
            <div key={bus.id} style={styles.busRow}>
              <div style={styles.busHeader}>
                <span style={styles.busLabel}>{bus.label}</span>
                <span style={styles.busPlaying}>{bus.playing} {t.audio.playing}</span>
              </div>
              <div style={styles.sliderRow}>
                <input
                  type="range"
                  min={0}
                  max={1}
                  step={0.01}
                  value={bus.volume}
                  onChange={(e) => handleVolumeChange(bus.id, parseFloat(e.target.value))}
                  style={styles.slider}
                />
                <span style={styles.volumeLabel}>{Math.round(bus.volume * 100)}%</span>
              </div>
            </div>
          ))
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
  badge: {
    background: "#f38ba8",
    borderRadius: 8,
    padding: "0 6px",
    fontSize: 10,
    color: "#1e1e2e",
    fontWeight: 700,
  },
  content: { flex: 1, overflow: "auto", padding: 8 },
  empty: { padding: 16, textAlign: "center", opacity: 0.4, fontSize: 12, color: "#a6adc8" },
  busRow: {
    padding: "8px",
    borderBottom: "1px solid #181825",
  },
  busHeader: {
    display: "flex",
    justifyContent: "space-between",
    alignItems: "center",
    marginBottom: 4,
  },
  busLabel: { color: "#cdd6f4", fontWeight: 600, fontSize: 12 },
  busPlaying: { color: "#6c7086", fontSize: 10, fontFamily: "monospace" },
  sliderRow: {
    display: "flex",
    alignItems: "center",
    gap: 8,
  },
  slider: {
    flex: 1,
    height: 4,
    appearance: "auto" as React.CSSProperties["appearance"],
    cursor: "pointer",
    accentColor: "#89b4fa",
  },
  volumeLabel: {
    minWidth: 36,
    textAlign: "right",
    fontSize: 11,
    fontFamily: "monospace",
    color: "#a6adc8",
  },
};
