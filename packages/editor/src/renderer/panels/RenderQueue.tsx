import React, { useEffect, useCallback, useRef } from "react";
import { useLocalState } from "../store/local-state";
import { useConnectionStore } from "../store";
import { useSyncedState } from "../store/synced-state";
import { useI18n } from "../i18n";

interface RenderJobInfo {
  index: number;
  sequencePath: string;
  outputDir: string;
  width: number;
  height: number;
  format: string;
  samples: number;
  bounces: number;
  usePathTrace: boolean;
  encodeVideo: boolean;
  videoCodec: string;
  status: string;
  totalFrames: number;
  currentFrame: number;
  statusMessage: string;
}


export function RenderQueue() {
  const connected = useConnectionStore((s) => s.connected);
  const { t } = useI18n();
  const [jobs, setJobs] = useLocalState<RenderJobInfo[]>([]);
  const [isRunning, setIsRunning] = useLocalState(false);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);

  // Form state (synced across windows via useSyncedState)
  const [seqPath, setSeqPath] = useSyncedState("render-queue", "seqPath", "");
  const [outDir, setOutDir] = useSyncedState("render-queue", "outDir", "render_output");
  const [width, setWidth] = useSyncedState("render-queue", "width", 1920);
  const [height, setHeight] = useSyncedState("render-queue", "height", 1080);
  const [format, setFormat] = useSyncedState("render-queue", "format", "png");
  const [samples, setSamples] = useSyncedState("render-queue", "samples", 256);
  const [bounces, setBounces] = useSyncedState("render-queue", "bounces", 8);
  const [usePathTrace, setUsePathTrace] = useSyncedState("render-queue", "usePathTrace", true);
  const [encodeVideo, setEncodeVideo] = useSyncedState("render-queue", "encodeVideo", false);
  const [videoCodec, setVideoCodec] = useSyncedState("render-queue", "videoCodec", "h264");

  const refresh = useCallback(async () => {
    if (!connected) return;
    try {
      const res = await window.guavaEngine.call("renderqueue.listJobs", {});
      setJobs(res.jobs);
      setIsRunning(res.isRunning);
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

  const handleAddJob = async () => {
    if (!seqPath.trim()) return;
    try {
      await window.guavaEngine.call("renderqueue.addJob", {
        sequencePath: seqPath,
        outputDir: outDir,
        width,
        height,
        format,
        samples,
        bounces,
        usePathTrace,
        encodeVideo,
        videoCodec,
      });
      setSeqPath("");
      refresh();
    } catch {
      /* ignore */
    }
  };

  const handleRemoveJob = async (index: number) => {
    try {
      await window.guavaEngine.call("renderqueue.removeJob", { index });
      refresh();
    } catch {
      /* ignore */
    }
  };

  const handleStart = async () => {
    try {
      await window.guavaEngine.call("renderqueue.startQueue", {});
      refresh();
    } catch {
      /* ignore */
    }
  };

  const handleCancel = async () => {
    try {
      await window.guavaEngine.call("renderqueue.cancelQueue", {});
      refresh();
    } catch {
      /* ignore */
    }
  };

  const handleClearCompleted = async () => {
    try {
      await window.guavaEngine.call("renderqueue.clearCompleted", {});
      refresh();
    } catch {
      /* ignore */
    }
  };

  const statusColor = (s: string) => {
    switch (s) {
      case "queued":
        return "#aaa";
      case "rendering":
        return "#ffa726";
      case "complete":
        return "#4caf50";
      case "failed":
        return "#ef5350";
      default:
        return "#888";
    }
  };

  return (
    <div style={styles.container}>
      {/* Add Job Form */}
      <div style={styles.section}>
        <div style={styles.sectionTitle}>{t.renderQueue.addJobTitle}</div>
        <div style={styles.formRow}>
          <label style={styles.formLabel}>{t.renderQueue.sequenceLabel}</label>
          <input
            style={styles.input}
            value={seqPath}
            onChange={(e) => setSeqPath(e.target.value)}
            placeholder="path/to/sequence.guava_sequence"
          />
        </div>
        <div style={styles.formRow}>
          <label style={styles.formLabel}>{t.renderQueue.outputDirLabel}</label>
          <input
            style={styles.input}
            value={outDir}
            onChange={(e) => setOutDir(e.target.value)}
          />
        </div>
        <div style={styles.formRow}>
          <label style={styles.formLabel}>{t.renderQueue.resolutionLabel}</label>
          <input
            type="number"
            style={{ ...styles.input, width: 80 }}
            value={width}
            onChange={(e) => setWidth(Math.max(64, Math.min(7680, parseInt(e.target.value) || 1920)))}
          />
          <span style={{ color: "#666", margin: "0 4px" }}>x</span>
          <input
            type="number"
            style={{ ...styles.input, width: 80 }}
            value={height}
            onChange={(e) => setHeight(Math.max(64, Math.min(4320, parseInt(e.target.value) || 1080)))}
          />
        </div>
        <div style={styles.formRow}>
          <label style={styles.formLabel}>{t.renderQueue.formatLabel}</label>
          <select
            style={styles.select}
            value={format}
            onChange={(e) => setFormat(e.target.value)}
          >
            <option value="png">PNG</option>
            <option value="exr">OpenEXR</option>
          </select>
        </div>
        <div style={styles.formRow}>
          <label style={styles.formLabel}>
            <input
              type="checkbox"
              checked={usePathTrace}
              onChange={(e) => setUsePathTrace(e.target.checked)}
            />{" "}
            {t.renderQueue.pathTraceLabel}
          </label>
        </div>
        {usePathTrace && (
          <>
            <div style={styles.formRow}>
              <label style={styles.formLabel}>{t.renderQueue.samplesLabel}</label>
              <input
                type="number"
                style={{ ...styles.input, width: 80 }}
                value={samples}
                onChange={(e) => setSamples(Math.max(1, Math.min(4096, parseInt(e.target.value) || 256)))}
              />
            </div>
            <div style={styles.formRow}>
              <label style={styles.formLabel}>{t.renderQueue.bouncesLabel}</label>
              <input
                type="number"
                style={{ ...styles.input, width: 80 }}
                value={bounces}
                onChange={(e) => setBounces(Math.max(1, Math.min(12, parseInt(e.target.value) || 8)))}
              />
            </div>
          </>
        )}
        <div style={styles.formRow}>
          <label style={styles.formLabel}>
            <input
              type="checkbox"
              checked={encodeVideo}
              onChange={(e) => setEncodeVideo(e.target.checked)}
            />{" "}
            {t.renderQueue.encodeVideoLabel}
          </label>
        </div>
        {encodeVideo && (
          <div style={styles.formRow}>
            <label style={styles.formLabel}>{t.renderQueue.videoCodecLabel}</label>
            <select
              style={styles.select}
              value={videoCodec}
              onChange={(e) => setVideoCodec(e.target.value)}
            >
              <option value="h264">H.264</option>
              <option value="h265">H.265</option>
              <option value="prores">ProRes</option>
            </select>
          </div>
        )}
        <button style={styles.addBtn} onClick={handleAddJob} disabled={!seqPath.trim()}>
          {t.renderQueue.addButton}
        </button>
      </div>

      {/* Job Queue */}
      <div style={styles.section}>
        <div style={styles.sectionTitle}>
          {t.renderQueue.queueTitle} ({jobs.length} {t.renderQueue.jobsSuffix})
        </div>
        {jobs.length === 0 ? (
          <div style={styles.empty}>
            {t.renderQueue.emptyState}
          </div>
        ) : (
          jobs.map((job) => (
            <div key={job.index} style={styles.jobCard}>
              <div style={styles.jobHeader}>
                <span style={{ color: statusColor(job.status) }}>
                  [{job.status}]
                </span>{" "}
                <span>{job.sequencePath || "(no path)"}</span>
              </div>
              <div style={styles.jobDetail}>
                {job.width}x{job.height} · {job.format.toUpperCase()}
                {job.usePathTrace
                  ? ` · PT ${job.samples}spp/${job.bounces}b`
                  : ""}
              </div>
              {job.totalFrames > 0 && (
                <div style={styles.progressRow}>
                  <div style={styles.progressBar}>
                    <div
                      style={{
                        ...styles.progressFill,
                        width: `${(job.currentFrame / job.totalFrames) * 100}%`,
                      }}
                    />
                  </div>
                  <span style={styles.progressText}>
                    {job.currentFrame}/{job.totalFrames}
                  </span>
                </div>
              )}
              {job.statusMessage && (
                <div style={styles.jobMsg}>{job.statusMessage}</div>
              )}
              {job.status === "queued" && !isRunning && (
                <button
                  style={styles.removeBtn}
                  onClick={() => handleRemoveJob(job.index)}
                >
                  {t.renderQueue.removeButton}
                </button>
              )}
            </div>
          ))
        )}
      </div>

      {/* Queue Controls */}
      <div style={styles.controls}>
        {isRunning ? (
          <button style={styles.cancelBtn} onClick={handleCancel}>
            {t.renderQueue.cancelButton}
          </button>
        ) : (
          <>
            {jobs.some((j) => j.status === "queued") && (
              <button style={styles.startBtn} onClick={handleStart}>
                {t.renderQueue.startButton}
              </button>
            )}
          </>
        )}
        <button style={styles.clearBtn} onClick={handleClearCompleted}>
          {t.renderQueue.clearButton}
        </button>
      </div>
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  container: {
    padding: 8,
    height: "100%",
    overflow: "auto",
    fontFamily: "monospace",
    fontSize: 12,
    color: "#ccc",
    display: "flex",
    flexDirection: "column",
  },
  section: { marginBottom: 12 },
  sectionTitle: {
    color: "#aaa",
    fontSize: 11,
    textTransform: "uppercase" as const,
    marginBottom: 6,
    borderBottom: "1px solid #444",
    paddingBottom: 2,
  },
  formRow: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    marginBottom: 4,
  },
  formLabel: { flex: "0 0 90px", color: "#aaa", fontSize: 11 },
  input: {
    flex: 1,
    padding: "3px 6px",
    background: "#1e1e1e",
    border: "1px solid #444",
    color: "#ccc",
    borderRadius: 3,
    fontSize: 11,
  },
  select: {
    padding: "3px 6px",
    background: "#1e1e1e",
    border: "1px solid #444",
    color: "#ccc",
    borderRadius: 3,
    fontSize: 11,
  },
  addBtn: {
    marginTop: 6,
    padding: "4px 16px",
    background: "#3a5a8a",
    border: "1px solid #4a7abf",
    color: "#fff",
    borderRadius: 3,
    cursor: "pointer",
  },
  jobCard: {
    padding: 8,
    marginBottom: 4,
    background: "#2a2a2a",
    border: "1px solid #444",
    borderRadius: 4,
  },
  jobHeader: { marginBottom: 4 },
  jobDetail: { color: "#888", fontSize: 10, marginBottom: 4 },
  progressRow: { display: "flex", alignItems: "center", gap: 8, marginBottom: 4 },
  progressBar: {
    flex: 1,
    height: 6,
    background: "#1a1a1a",
    borderRadius: 3,
    overflow: "hidden" as const,
  },
  progressFill: { height: "100%", background: "#4caf50", borderRadius: 3 },
  progressText: { fontSize: 10, color: "#888", flex: "0 0 60px", textAlign: "right" as const },
  jobMsg: { color: "#888", fontSize: 10, fontStyle: "italic" as const },
  removeBtn: {
    marginTop: 4,
    padding: "2px 8px",
    background: "#2a2a2a",
    border: "1px solid #555",
    color: "#ccc",
    borderRadius: 3,
    cursor: "pointer",
    fontSize: 10,
  },
  controls: { display: "flex", gap: 8, marginTop: "auto" },
  startBtn: {
    padding: "4px 16px",
    background: "#2e7d32",
    border: "1px solid #43a047",
    color: "#fff",
    borderRadius: 3,
    cursor: "pointer",
  },
  cancelBtn: {
    padding: "4px 16px",
    background: "#c62828",
    border: "1px solid #e53935",
    color: "#fff",
    borderRadius: 3,
    cursor: "pointer",
  },
  clearBtn: {
    padding: "4px 16px",
    background: "#3a3a3a",
    border: "1px solid #555",
    color: "#ccc",
    borderRadius: 3,
    cursor: "pointer",
  },
  empty: { color: "#666", textAlign: "center" as const, padding: 12 },
};
