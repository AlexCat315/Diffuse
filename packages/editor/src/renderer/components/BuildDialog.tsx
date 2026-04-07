import React, { useState, useEffect, useCallback, useRef } from "react";
import { IconClose } from "./Icons";

interface BuildProgress {
  stage: string;
  percent: number;
  detail?: string;
  log?: string;
}

interface BuildDialogProps {
  open: boolean;
  onClose: () => void;
}

export function BuildDialog({ open, onClose }: BuildDialogProps) {
  const [building, setBuilding] = useState(false);
  const [progress, setProgress] = useState<BuildProgress | null>(null);
  const [result, setResult] = useState<{ ok: boolean; path?: string; error?: string } | null>(null);
  const [optimize, setOptimize] = useState<"Debug" | "ReleaseSafe" | "ReleaseFast">("ReleaseSafe");
  const [logs, setLogs] = useState<string[]>([]);
  const logEndRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const unsub = window.guavaEngine.onBuildProgress((p) => {
      setProgress(p);
      if (p.log) {
        setLogs((prev) => {
          const next = [...prev, p.log!];
          return next.length > 500 ? next.slice(-500) : next;
        });
      }
    });
    return unsub;
  }, [open]);

  useEffect(() => {
    logEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [logs]);

  const handleBuild = useCallback(async (choosePath = false, runAfter = false) => {
    setBuilding(true);
    setResult(null);
    setLogs([]);
    setProgress({ stage: "init", percent: 0, detail: "Starting..." });
    try {
      const res = await window.guavaEngine.buildPackage({ optimize, choosePath }) as { ok: boolean; path?: string; error?: string };
      if (res.error === "Cancelled" || res.error === "Error: Build cancelled") {
        setBuilding(false);
        setProgress(null);
        return;
      }
      setResult(res);
      if (runAfter && res.ok && res.path) {
        await window.guavaEngine.runBuiltGame(res.path);
      }
    } catch (err) {
      setResult({ ok: false, error: String(err) });
    } finally {
      setBuilding(false);
    }
  }, [optimize]);

  const handleCancel = useCallback(async () => {
    await window.guavaEngine.cancelBuild();
  }, []);

  const handleRunGame = useCallback(async () => {
    if (!result?.path) return;
    await window.guavaEngine.runBuiltGame(result.path);
  }, [result]);

  if (!open) return null;

  return (
    <div style={styles.overlay} onClick={building ? undefined : onClose}>
      <div style={styles.dialog} onClick={(e) => e.stopPropagation()}>
        <div style={styles.header}>
          <span style={styles.title}>Build Standalone Game</span>
          {!building && (
            <button style={styles.closeBtn} onClick={onClose}><IconClose size={10} /></button>
          )}
        </div>

        {!building && !result && (
          <div style={styles.body}>
            <div style={styles.field}>
              <label style={styles.label}>Optimization</label>
              <select
                style={styles.select}
                value={optimize}
                onChange={(e) => setOptimize(e.target.value as typeof optimize)}
              >
                <option value="Debug">Debug (fast compile, slow runtime)</option>
                <option value="ReleaseSafe">ReleaseSafe (recommended)</option>
                <option value="ReleaseFast">ReleaseFast (max performance)</option>
              </select>
            </div>
            <div style={styles.info}>
              Output: <strong style={{ color: "#cdd6f4" }}>{"{project}/Build/"}</strong>
            </div>
            <div style={styles.actions}>
              <button style={styles.cancelBtn} onClick={onClose}>Cancel</button>
              <button style={styles.cancelBtn} onClick={() => handleBuild(true)}>Choose Folder...</button>
              <button style={styles.cancelBtn} onClick={() => handleBuild(false)}>Build</button>
              <button style={styles.buildBtn} onClick={() => handleBuild(false, true)}>Build & Run</button>
            </div>
          </div>
        )}

        {building && progress && (
          <div style={styles.body}>
            <div style={styles.progressLabel}>{progress.detail || progress.stage}</div>
            <div style={styles.progressBar}>
              <div style={{ ...styles.progressFill, width: `${progress.percent}%` }} />
            </div>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 8 }}>
              <div style={styles.progressPercent}>{Math.round(progress.percent)}%</div>
              <button style={styles.cancelBtn} onClick={handleCancel}>Cancel</button>
            </div>
            {logs.length > 0 && (
              <div style={styles.logContainer}>
                {logs.map((line, i) => (
                  <div key={i} style={styles.logLine}>{line}</div>
                ))}
                <div ref={logEndRef} />
              </div>
            )}
          </div>
        )}

        {!building && result && (
          <div style={styles.body}>
            {result.ok ? (
              <>
                <div style={styles.successText}>Build complete!</div>
                <div style={styles.pathText}>{result.path}</div>
                <div style={styles.actions}>
                  <button style={styles.cancelBtn} onClick={() => { setResult(null); }}>Build Again</button>
                  <button style={styles.buildBtn} onClick={handleRunGame}>Run Game</button>
                  <button style={styles.cancelBtn} onClick={onClose}>Close</button>
                </div>
              </>
            ) : (
              <>
                <div style={styles.errorText}>Build failed</div>
                <div style={styles.errorDetail}>{result.error}</div>
                <div style={styles.actions}>
                  <button style={styles.cancelBtn} onClick={() => setResult(null)}>Try Again</button>
                  <button style={styles.cancelBtn} onClick={onClose}>Close</button>
                </div>
              </>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

const styles = {
  overlay: {
    position: "fixed" as const,
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    background: "rgba(0,0,0,0.5)",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    zIndex: 9999,
  },
  dialog: {
    background: "#1e1e2e",
    border: "1px solid #45475a",
    borderRadius: 8,
    width: 480,
    maxWidth: "90vw",
    overflow: "hidden",
  },
  header: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    padding: "12px 16px",
    borderBottom: "1px solid #313244",
  },
  title: {
    color: "#cdd6f4",
    fontWeight: 600,
    fontSize: 14,
  },
  closeBtn: {
    background: "none",
    border: "none",
    color: "#6c7086",
    cursor: "pointer",
    fontSize: 16,
    padding: 4,
  },
  body: {
    padding: "16px",
  },
  field: {
    marginBottom: 12,
  },
  label: {
    display: "block",
    color: "#a6adc8",
    fontSize: 12,
    marginBottom: 4,
  },
  select: {
    width: "100%",
    background: "#313244",
    color: "#cdd6f4",
    border: "1px solid #45475a",
    borderRadius: 4,
    padding: "6px 8px",
    fontSize: 13,
  },
  info: {
    color: "#6c7086",
    fontSize: 12,
    lineHeight: "1.5",
    marginBottom: 16,
  },
  actions: {
    display: "flex",
    gap: 8,
    justifyContent: "flex-end",
  },
  cancelBtn: {
    background: "#313244",
    color: "#cdd6f4",
    border: "1px solid #45475a",
    borderRadius: 4,
    padding: "6px 16px",
    cursor: "pointer",
    fontSize: 13,
  },
  buildBtn: {
    background: "#89b4fa",
    color: "#1e1e2e",
    border: "none",
    borderRadius: 4,
    padding: "6px 16px",
    cursor: "pointer",
    fontWeight: 600,
    fontSize: 13,
  },
  progressLabel: {
    color: "#cdd6f4",
    fontSize: 13,
    marginBottom: 8,
  },
  progressBar: {
    height: 6,
    background: "#313244",
    borderRadius: 3,
    overflow: "hidden",
    marginBottom: 4,
  },
  progressFill: {
    height: "100%",
    background: "#89b4fa",
    borderRadius: 3,
    transition: "width 0.3s ease",
  },
  progressPercent: {
    color: "#6c7086",
    fontSize: 12,
    textAlign: "right" as const,
  },
  successText: {
    color: "#a6e3a1",
    fontSize: 14,
    fontWeight: 600,
    marginBottom: 8,
  },
  pathText: {
    color: "#6c7086",
    fontSize: 12,
    marginBottom: 16,
    wordBreak: "break-all" as const,
  },
  errorText: {
    color: "#f38ba8",
    fontSize: 14,
    fontWeight: 600,
    marginBottom: 8,
  },
  errorDetail: {
    color: "#f38ba8",
    fontSize: 12,
    marginBottom: 16,
    whiteSpace: "pre-wrap" as const,
    maxHeight: 200,
    overflow: "auto",
  },
  logContainer: {
    background: "#11111b",
    border: "1px solid #313244",
    borderRadius: 4,
    padding: 8,
    maxHeight: 200,
    overflow: "auto",
    fontFamily: "monospace",
    fontSize: 11,
  },
  logLine: {
    color: "#a6adc8",
    lineHeight: "1.4",
    whiteSpace: "pre-wrap" as const,
    wordBreak: "break-all" as const,
  },
};
