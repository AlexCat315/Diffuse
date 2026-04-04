import React, { useEffect, useState, useCallback, useRef, useMemo } from "react";
import { rpc } from "../rpc";

// ── Types ───────────────────────────────────────────────────────

interface CameraKeyframe {
  index: number;
  time: number;
  position: number[];
  rotation: number[];
  fov: number;
  easing: string;
}

interface EventEntry {
  index: number;
  time: number;
  name: string;
}

interface ScalarKeyframe {
  index: number;
  time: number;
  value: number;
  easing: string;
}

interface SeqTrack {
  index: number;
  kind: string;
  target: string;
  // camera_path
  keyframes?: CameraKeyframe[];
  // animation / audio
  clipPath?: string;
  startTime?: number;
  endTime?: number;
  blendIn?: number;
  blendOut?: number;
  speed?: number;
  volume?: number;
  fadeIn?: number;
  fadeOut?: number;
  // event
  events?: EventEntry[];
  // property
  property?: string;
}

interface SeqState {
  loaded: boolean;
  name?: string;
  fps?: number;
  duration?: number;
  currentTime: number;
  isPlaying: boolean;
  speed: number;
  filePath?: string;
  tracks?: SeqTrack[];
}

const TRACK_COLORS: Record<string, string> = {
  camera_path: "#89b4fa",
  animation: "#a6e3a1",
  audio: "#f9e2af",
  event: "#f38ba8",
  property: "#cba6f7",
};

const TRACK_BADGES: Record<string, string> = {
  camera_path: "CAM",
  animation: "ANIM",
  audio: "SFX",
  event: "EVT",
  property: "PROP",
};

const EASING_OPTIONS = ["linear", "step", "ease_in", "ease_out", "ease_in_out"];
const TRACK_KINDS = ["camera_path", "animation", "audio", "event", "property"];
const RULER_HEIGHT = 24;
const TRACK_HEIGHT = 28;

// ── Main component ──────────────────────────────────────────────

export function SequencerPanel({ connected }: { connected: boolean }) {
  const [state, setState] = useState<SeqState | null>(null);
  const [selectedTrack, setSelectedTrack] = useState<number | null>(null);
  const [selectedKf, setSelectedKf] = useState<number | null>(null);
  const [timelineScale, setTimelineScale] = useState(80); // px per second
  const [timelineScroll, setTimelineScroll] = useState(0);
  const [newTrackKind, setNewTrackKind] = useState("camera_path");
  const [newTrackTarget, setNewTrackTarget] = useState("");
  const [nameBuf, setNameBuf] = useState("");
  const [fpsBuf, setFpsBuf] = useState("");
  const [durationBuf, setDurationBuf] = useState("");
  const [filePathBuf, setFilePathBuf] = useState("");
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const timelineContainerRef = useRef<HTMLDivElement>(null);
  const commitTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  // ── Polling ────────────────────────────────────────────────

  const fetchState = useCallback(async () => {
    if (!connected) return;
    try {
      const s = (await rpc("sequencer.getState", {})) as SeqState;
      setState(s);
      if (s.loaded) {
        setNameBuf(s.name ?? "");
        setFpsBuf(String(s.fps ?? 30));
        setDurationBuf(String((s.duration ?? 0).toFixed(2)));
        setFilePathBuf(s.filePath ?? "");
      }
    } catch {
      /* ignore */
    }
  }, [connected]);

  useEffect(() => {
    fetchState();
    const id = setInterval(fetchState, 500);
    return () => clearInterval(id);
  }, [fetchState]);

  // ── Actions ────────────────────────────────────────────────

  const create = async () => {
    await rpc("sequencer.create", { name: "New Sequence", fps: 30 });
    fetchState();
  };

  const handleLoad = async () => {
    if (!filePathBuf) return;
    await rpc("sequencer.load", { path: filePathBuf });
    fetchState();
  };

  const handleSave = async () => {
    await rpc("sequencer.save", filePathBuf ? { path: filePathBuf } : {});
  };

  const commitProps = useCallback(() => {
    if (commitTimer.current) clearTimeout(commitTimer.current);
    commitTimer.current = setTimeout(async () => {
      const params: Record<string, unknown> = {};
      if (nameBuf !== (state?.name ?? "")) params.name = nameBuf;
      const fps = parseFloat(fpsBuf);
      if (!isNaN(fps) && fps !== (state?.fps ?? 30)) params.fps = fps;
      const dur = parseFloat(durationBuf);
      if (!isNaN(dur) && dur !== (state?.duration ?? 0)) params.duration = dur;
      if (Object.keys(params).length > 0) {
        await rpc("sequencer.setProperties", params);
      }
    }, 200);
  }, [state?.name, state?.fps, state?.duration, nameBuf, fpsBuf, durationBuf]);

  const handlePlay = () => rpc("sequencer.play", {});
  const handlePause = () => rpc("sequencer.pause", {});
  const handleStop = () => rpc("sequencer.stop", {});
  const handleSeek = (time: number) => rpc("sequencer.seek", { time });

  const handleAddTrack = async () => {
    if (!newTrackTarget.trim()) return;
    await rpc("sequencer.addTrack", { kind: newTrackKind, target: newTrackTarget.trim() });
    setNewTrackTarget("");
    fetchState();
  };

  const handleRemoveTrack = async (index: number) => {
    await rpc("sequencer.removeTrack", { index });
    if (selectedTrack === index) {
      setSelectedTrack(null);
      setSelectedKf(null);
    }
    fetchState();
  };

  const handleAddKeyframe = async () => {
    if (selectedTrack === null || !state?.loaded) return;
    const track = state.tracks?.[selectedTrack];
    if (!track) return;
    const time = state.currentTime;
    if (track.kind === "camera_path") {
      await rpc("sequencer.addKeyframe", { trackIndex: selectedTrack, time, position: [0, 0, 0] as unknown, rotation: [0, 0, 0, 1] as unknown, fov: 60 });
    } else if (track.kind === "event") {
      await rpc("sequencer.addKeyframe", { trackIndex: selectedTrack, time, name: "event" });
    } else if (track.kind === "property") {
      await rpc("sequencer.addKeyframe", { trackIndex: selectedTrack, time, value: 0 });
    } else {
      await rpc("sequencer.addKeyframe", { trackIndex: selectedTrack, time });
    }
    fetchState();
  };

  const handleRemoveKeyframe = async () => {
    if (selectedTrack === null || selectedKf === null) return;
    await rpc("sequencer.removeKeyframe", { trackIndex: selectedTrack, keyframeIndex: selectedKf });
    setSelectedKf(null);
    fetchState();
  };

  // ── Timeline canvas drawing ────────────────────────────────

  const tracks = state?.tracks ?? [];
  const duration = state?.duration ?? 10;
  const canvasWidth = Math.max(600, duration * timelineScale + 100);
  const canvasHeight = RULER_HEIGHT + tracks.length * TRACK_HEIGHT + 4;

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    const dpr = window.devicePixelRatio || 1;
    canvas.width = canvasWidth * dpr;
    canvas.height = canvasHeight * dpr;
    ctx.scale(dpr, dpr);
    ctx.clearRect(0, 0, canvasWidth, canvasHeight);

    // Ruler background
    ctx.fillStyle = "#181825";
    ctx.fillRect(0, 0, canvasWidth, RULER_HEIGHT);

    // Ruler ticks
    const tickInterval = timelineScale >= 60 ? 1 : timelineScale >= 30 ? 2 : 5;
    const subTicks = timelineScale >= 60 ? 5 : timelineScale >= 30 ? 2 : 1;
    for (let t = 0; t <= duration + tickInterval; t += tickInterval) {
      const x = t * timelineScale;
      ctx.strokeStyle = "#585b70";
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(x, 0);
      ctx.lineTo(x, RULER_HEIGHT);
      ctx.stroke();
      ctx.fillStyle = "#a6adc8";
      ctx.font = "10px monospace";
      ctx.fillText(formatTime(t), x + 2, 12);

      // Sub-ticks
      if (subTicks > 1) {
        for (let s = 1; s < subTicks; s++) {
          const sx = x + (s * tickInterval * timelineScale) / subTicks;
          ctx.strokeStyle = "#313244";
          ctx.beginPath();
          ctx.moveTo(sx, RULER_HEIGHT - 6);
          ctx.lineTo(sx, RULER_HEIGHT);
          ctx.stroke();
        }
      }
    }

    // Track rows
    for (let i = 0; i < tracks.length; i++) {
      const track = tracks[i];
      const y = RULER_HEIGHT + i * TRACK_HEIGHT;
      const color = TRACK_COLORS[track.kind] ?? "#cdd6f4";

      // Row background
      ctx.fillStyle = i === selectedTrack ? "#313244" : i % 2 === 0 ? "#1e1e2e" : "#11111b";
      ctx.fillRect(0, y, canvasWidth, TRACK_HEIGHT);

      // Track bar / keyframe markers
      if (track.kind === "camera_path" && track.keyframes) {
        for (const kf of track.keyframes) {
          const kx = kf.time * timelineScale;
          drawDiamond(ctx, kx, y + TRACK_HEIGHT / 2, 5, kf.index === selectedKf && i === selectedTrack ? "#f5e0dc" : color);
        }
      } else if ((track.kind === "animation" || track.kind === "audio") && track.startTime != null && track.endTime != null) {
        const sx = track.startTime * timelineScale;
        const ex = track.endTime * timelineScale;
        ctx.fillStyle = color + "55";
        ctx.fillRect(sx, y + 4, ex - sx, TRACK_HEIGHT - 8);
        ctx.strokeStyle = color;
        ctx.lineWidth = 1;
        ctx.strokeRect(sx, y + 4, ex - sx, TRACK_HEIGHT - 8);
      } else if (track.kind === "event" && track.events) {
        for (const ev of track.events) {
          const ex = ev.time * timelineScale;
          drawDiamond(ctx, ex, y + TRACK_HEIGHT / 2, 5, ev.index === selectedKf && i === selectedTrack ? "#f5e0dc" : color);
        }
      } else if (track.kind === "property" && track.keyframes) {
        for (const kf of (track as SeqTrack & { keyframes: ScalarKeyframe[] }).keyframes) {
          const kx = kf.time * timelineScale;
          drawDiamond(ctx, kx, y + TRACK_HEIGHT / 2, 5, kf.index === selectedKf && i === selectedTrack ? "#f5e0dc" : color);
        }
      }

      // Row separator
      ctx.strokeStyle = "#313244";
      ctx.lineWidth = 0.5;
      ctx.beginPath();
      ctx.moveTo(0, y + TRACK_HEIGHT);
      ctx.lineTo(canvasWidth, y + TRACK_HEIGHT);
      ctx.stroke();
    }

    // Playhead
    const px = (state?.currentTime ?? 0) * timelineScale;
    ctx.strokeStyle = "#f38ba8";
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(px, 0);
    ctx.lineTo(px, canvasHeight);
    ctx.stroke();
    // Playhead triangle
    ctx.fillStyle = "#f38ba8";
    ctx.beginPath();
    ctx.moveTo(px - 5, 0);
    ctx.lineTo(px + 5, 0);
    ctx.lineTo(px, 8);
    ctx.closePath();
    ctx.fill();
  }, [state, selectedTrack, selectedKf, timelineScale, canvasWidth, canvasHeight, tracks, duration]);

  // ── Canvas click handler ───────────────────────────────────

  const handleCanvasClick = useCallback(
    (e: React.MouseEvent<HTMLCanvasElement>) => {
      const canvas = canvasRef.current;
      if (!canvas) return;
      const rect = canvas.getBoundingClientRect();
      const x = e.clientX - rect.left;
      const y = e.clientY - rect.top;

      if (y < RULER_HEIGHT) {
        // Click on ruler → seek
        const time = Math.max(0, x / timelineScale);
        handleSeek(time);
        return;
      }

      // Determine track row
      const trackIdx = Math.floor((y - RULER_HEIGHT) / TRACK_HEIGHT);
      if (trackIdx < 0 || trackIdx >= tracks.length) return;
      setSelectedTrack(trackIdx);

      // Check for keyframe hit
      const track = tracks[trackIdx];
      const clickTime = x / timelineScale;
      const hitRadius = 8 / timelineScale;

      if (track.kind === "camera_path" && track.keyframes) {
        const hit = track.keyframes.find((kf) => Math.abs(kf.time - clickTime) < hitRadius);
        setSelectedKf(hit ? hit.index : null);
      } else if (track.kind === "event" && track.events) {
        const hit = track.events.find((ev) => Math.abs(ev.time - clickTime) < hitRadius);
        setSelectedKf(hit ? hit.index : null);
      } else if (track.kind === "property" && track.keyframes) {
        const hit = (track as SeqTrack & { keyframes: ScalarKeyframe[] }).keyframes.find(
          (kf) => Math.abs(kf.time - clickTime) < hitRadius
        );
        setSelectedKf(hit ? hit.index : null);
      } else {
        setSelectedKf(null);
      }
    },
    [tracks, timelineScale]
  );

  // ── Wheel zoom ─────────────────────────────────────────────

  const handleWheel = useCallback(
    (e: React.WheelEvent) => {
      if (e.ctrlKey || e.metaKey) {
        e.preventDefault();
        setTimelineScale((s) => Math.max(10, Math.min(400, s - e.deltaY * 0.5)));
      }
    },
    []
  );

  // ── Selected object info ───────────────────────────────────

  const selTrack = selectedTrack !== null ? tracks[selectedTrack] : null;

  // ── Render ─────────────────────────────────────────────────

  if (!connected) {
    return <div style={S.empty}>Not connected</div>;
  }

  if (!state?.loaded) {
    return (
      <div style={S.empty}>
        <div style={{ display: "flex", flexDirection: "column", gap: 8, alignItems: "center" }}>
          <span style={{ color: "#a6adc8" }}>No Sequence Loaded</span>
          <div style={{ display: "flex", gap: 8 }}>
            <button style={S.btn} onClick={create}>New Sequence</button>
            <input
              style={S.input}
              value={filePathBuf}
              onChange={(e) => setFilePathBuf(e.target.value)}
              placeholder="path/to/sequence.guava_sequence"
            />
            <button style={S.btn} onClick={handleLoad}>Load</button>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div style={S.root}>
      {/* Toolbar */}
      <div style={S.toolbar}>
        <button style={S.btn} onClick={create} title="New">New</button>
        <input
          style={{ ...S.input, width: 200 }}
          value={filePathBuf}
          onChange={(e) => setFilePathBuf(e.target.value)}
          placeholder="File path"
        />
        <button style={S.btn} onClick={handleLoad}>Load</button>
        <button style={S.btn} onClick={handleSave}>Save</button>
        <span style={S.sep} />
        <button style={S.btn} onClick={handleStop} title="Stop">⏹</button>
        <button
          style={{ ...S.btn, ...(state.isPlaying ? { background: "#f38ba8", color: "#1e1e2e" } : {}) }}
          onClick={state.isPlaying ? handlePause : handlePlay}
        >
          {state.isPlaying ? "⏸" : "▶"}
        </button>
        <span style={{ color: "#cdd6f4", fontFamily: "monospace", fontSize: 12, marginLeft: 4 }}>
          {formatTime(state.currentTime)} / {formatTime(state.duration ?? 0)}
        </span>
        <span style={S.sep} />
        <label style={S.label}>Name</label>
        <input
          style={{ ...S.input, width: 120 }}
          value={nameBuf}
          onChange={(e) => { setNameBuf(e.target.value); commitProps(); }}
        />
        <label style={S.label}>FPS</label>
        <input
          style={{ ...S.input, width: 40 }}
          value={fpsBuf}
          onChange={(e) => { setFpsBuf(e.target.value); commitProps(); }}
        />
        <label style={S.label}>Dur</label>
        <input
          style={{ ...S.input, width: 60 }}
          value={durationBuf}
          onChange={(e) => { setDurationBuf(e.target.value); commitProps(); }}
        />
      </div>

      {/* Main body: tracks + timeline + properties */}
      <div style={S.body}>
        {/* Track list */}
        <div style={S.trackList}>
          <div style={S.trackListHeader}>Tracks</div>
          {tracks.map((track, i) => (
            <div
              key={i}
              style={{
                ...S.trackItem,
                background: i === selectedTrack ? "#313244" : "transparent",
              }}
              onClick={() => { setSelectedTrack(i); setSelectedKf(null); }}
            >
              <span style={{ ...S.badge, background: TRACK_COLORS[track.kind] + "33", color: TRACK_COLORS[track.kind] }}>
                {TRACK_BADGES[track.kind] ?? "?"}
              </span>
              <span style={S.trackName}>{track.target || `Track ${i}`}</span>
              <button style={S.btnSmall} onClick={(e) => { e.stopPropagation(); handleRemoveTrack(i); }} title="Remove">×</button>
            </div>
          ))}
          {/* Add track */}
          <div style={{ padding: "4px 6px", borderTop: "1px solid #313244" }}>
            <select style={S.select} value={newTrackKind} onChange={(e) => setNewTrackKind(e.target.value)}>
              {TRACK_KINDS.map((k) => <option key={k} value={k}>{TRACK_BADGES[k]}</option>)}
            </select>
            <input
              style={{ ...S.input, width: "100%", marginTop: 2 }}
              value={newTrackTarget}
              onChange={(e) => setNewTrackTarget(e.target.value)}
              placeholder="Target entity"
              onKeyDown={(e) => e.key === "Enter" && handleAddTrack()}
            />
            <button style={{ ...S.btn, width: "100%", marginTop: 2 }} onClick={handleAddTrack}>+ Add Track</button>
          </div>
        </div>

        {/* Timeline canvas */}
        <div
          ref={timelineContainerRef}
          style={S.timelineContainer}
          onWheel={handleWheel}
        >
          <canvas
            ref={canvasRef}
            style={{ width: canvasWidth, height: canvasHeight, display: "block", cursor: "crosshair" }}
            onClick={handleCanvasClick}
          />
        </div>

        {/* Properties */}
        <div style={S.propsPanel}>
          <div style={S.trackListHeader}>Properties</div>
          {selTrack ? (
            <div style={{ padding: "4px 6px" }}>
              <PropLabel>Kind</PropLabel>
              <span style={S.propValue}>{selTrack.kind}</span>
              <PropLabel>Target</PropLabel>
              <span style={S.propValue}>{selTrack.target}</span>

              {/* Track-type specific props */}
              {(selTrack.kind === "animation" || selTrack.kind === "audio") && (
                <TrackClipProps track={selTrack} onUpdate={fetchState} />
              )}
              {selTrack.kind === "property" && (
                <>
                  <PropLabel>Property</PropLabel>
                  <span style={S.propValue}>{selTrack.property ?? ""}</span>
                </>
              )}

              {/* Keyframe section */}
              <div style={{ marginTop: 8, borderTop: "1px solid #313244", paddingTop: 6 }}>
                <div style={{ display: "flex", gap: 4, marginBottom: 4 }}>
                  <button style={S.btn} onClick={handleAddKeyframe}>+ Keyframe</button>
                  {selectedKf !== null && (
                    <button style={{ ...S.btn, background: "#f38ba833", color: "#f38ba8" }} onClick={handleRemoveKeyframe}>
                      − Delete KF
                    </button>
                  )}
                </div>
                {selectedKf !== null && selTrack.kind === "camera_path" && selTrack.keyframes && (
                  <CameraKfEditor trackIndex={selectedTrack!} kf={selTrack.keyframes[selectedKf]} onUpdate={fetchState} />
                )}
                {selectedKf !== null && selTrack.kind === "event" && selTrack.events && (
                  <EventKfEditor trackIndex={selectedTrack!} entry={selTrack.events[selectedKf]} onUpdate={fetchState} />
                )}
                {selectedKf !== null && selTrack.kind === "property" && selTrack.keyframes && (
                  <ScalarKfEditor
                    trackIndex={selectedTrack!}
                    kf={(selTrack as SeqTrack & { keyframes: ScalarKeyframe[] }).keyframes[selectedKf]}
                    onUpdate={fetchState}
                  />
                )}
              </div>
            </div>
          ) : (
            <div style={{ padding: 8, color: "#585b70", fontSize: 12, textAlign: "center" }}>
              Select a track
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

// ── Sub-components ───────────────────────────────────────────────

function PropLabel({ children }: { children: React.ReactNode }) {
  return <div style={{ color: "#a6adc8", fontSize: 10, marginTop: 4 }}>{children}</div>;
}

function TrackClipProps({ track, onUpdate }: { track: SeqTrack; onUpdate: () => void }) {
  const update = async (fields: Record<string, unknown>) => {
    await rpc("sequencer.updateTrack", { index: track.index, ...fields });
    onUpdate();
  };
  return (
    <>
      <PropLabel>Clip Path</PropLabel>
      <input
        style={{ ...S.input, width: "100%" }}
        defaultValue={track.clipPath ?? ""}
        onBlur={(e) => update({ clipPath: e.target.value })}
      />
      <PropLabel>Start / End</PropLabel>
      <div style={{ display: "flex", gap: 4 }}>
        <NumberInput value={track.startTime ?? 0} onChange={(v) => update({ startTime: v })} />
        <NumberInput value={track.endTime ?? 0} onChange={(v) => update({ endTime: v })} />
      </div>
      {track.kind === "animation" && (
        <>
          <PropLabel>Blend In / Out</PropLabel>
          <div style={{ display: "flex", gap: 4 }}>
            <NumberInput value={track.blendIn ?? 0} onChange={(v) => update({ blendIn: v })} />
            <NumberInput value={track.blendOut ?? 0} onChange={(v) => update({ blendOut: v })} />
          </div>
          <PropLabel>Speed</PropLabel>
          <NumberInput value={track.speed ?? 1} onChange={(v) => update({ speed: v })} />
        </>
      )}
      {track.kind === "audio" && (
        <>
          <PropLabel>Volume</PropLabel>
          <NumberInput value={track.volume ?? 1} onChange={(v) => update({ volume: v })} />
          <PropLabel>Fade In / Out</PropLabel>
          <div style={{ display: "flex", gap: 4 }}>
            <NumberInput value={track.fadeIn ?? 0} onChange={(v) => update({ fadeIn: v })} />
            <NumberInput value={track.fadeOut ?? 0} onChange={(v) => update({ fadeOut: v })} />
          </div>
        </>
      )}
    </>
  );
}

function CameraKfEditor({ trackIndex, kf, onUpdate }: { trackIndex: number; kf: CameraKeyframe; onUpdate: () => void }) {
  const update = async (fields: Record<string, unknown>) => {
    await rpc("sequencer.updateKeyframe", { trackIndex, keyframeIndex: kf.index, ...fields });
    onUpdate();
  };
  return (
    <div style={{ fontSize: 11 }}>
      <PropLabel>Time</PropLabel>
      <NumberInput value={kf.time} onChange={(v) => update({ time: v })} />
      <PropLabel>Position (x,y,z)</PropLabel>
      <div style={{ display: "flex", gap: 2 }}>
        {kf.position.map((v, i) => (
          <NumberInput
            key={i}
            value={v}
            onChange={(nv) => { const p = [...kf.position]; p[i] = nv; update({ position: p }); }}
          />
        ))}
      </div>
      <PropLabel>Rotation (x,y,z,w)</PropLabel>
      <div style={{ display: "flex", gap: 2 }}>
        {kf.rotation.map((v, i) => (
          <NumberInput
            key={i}
            value={v}
            onChange={(nv) => { const r = [...kf.rotation]; r[i] = nv; update({ rotation: r }); }}
          />
        ))}
      </div>
      <PropLabel>FOV</PropLabel>
      <NumberInput value={kf.fov} onChange={(v) => update({ fov: v })} />
      <PropLabel>Easing</PropLabel>
      <select style={S.select} value={kf.easing} onChange={(e) => update({ easing: e.target.value })}>
        {EASING_OPTIONS.map((o) => <option key={o} value={o}>{o}</option>)}
      </select>
    </div>
  );
}

function EventKfEditor({ trackIndex, entry, onUpdate }: { trackIndex: number; entry: EventEntry; onUpdate: () => void }) {
  const update = async (fields: Record<string, unknown>) => {
    await rpc("sequencer.updateKeyframe", { trackIndex, keyframeIndex: entry.index, ...fields });
    onUpdate();
  };
  return (
    <div style={{ fontSize: 11 }}>
      <PropLabel>Time</PropLabel>
      <NumberInput value={entry.time} onChange={(v) => update({ time: v })} />
      <PropLabel>Event Name</PropLabel>
      <input
        style={{ ...S.input, width: "100%" }}
        defaultValue={entry.name}
        onBlur={(e) => update({ name: e.target.value })}
      />
    </div>
  );
}

function ScalarKfEditor({ trackIndex, kf, onUpdate }: { trackIndex: number; kf: ScalarKeyframe; onUpdate: () => void }) {
  const update = async (fields: Record<string, unknown>) => {
    await rpc("sequencer.updateKeyframe", { trackIndex, keyframeIndex: kf.index, ...fields });
    onUpdate();
  };
  return (
    <div style={{ fontSize: 11 }}>
      <PropLabel>Time</PropLabel>
      <NumberInput value={kf.time} onChange={(v) => update({ time: v })} />
      <PropLabel>Value</PropLabel>
      <NumberInput value={kf.value} onChange={(v) => update({ value: v })} />
      <PropLabel>Easing</PropLabel>
      <select style={S.select} value={kf.easing} onChange={(e) => update({ easing: e.target.value })}>
        {EASING_OPTIONS.map((o) => <option key={o} value={o}>{o}</option>)}
      </select>
    </div>
  );
}

function NumberInput({ value, onChange }: { value: number; onChange: (v: number) => void }) {
  const [buf, setBuf] = useState(String(value));
  useEffect(() => setBuf(String(parseFloat(value.toFixed(4)))), [value]);
  return (
    <input
      style={{ ...S.input, width: 60 }}
      value={buf}
      onChange={(e) => setBuf(e.target.value)}
      onBlur={() => {
        const v = parseFloat(buf);
        if (!isNaN(v)) onChange(v);
        else setBuf(String(value));
      }}
      onKeyDown={(e) => {
        if (e.key === "Enter") {
          const v = parseFloat(buf);
          if (!isNaN(v)) onChange(v);
        }
      }}
    />
  );
}

// ── Drawing helpers ──────────────────────────────────────────────

function drawDiamond(ctx: CanvasRenderingContext2D, x: number, y: number, size: number, color: string) {
  ctx.fillStyle = color;
  ctx.beginPath();
  ctx.moveTo(x, y - size);
  ctx.lineTo(x + size, y);
  ctx.lineTo(x, y + size);
  ctx.lineTo(x - size, y);
  ctx.closePath();
  ctx.fill();
}

function formatTime(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m}:${s.toFixed(1).padStart(4, "0")}`;
}

// ── Styles ───────────────────────────────────────────────────────

const S: Record<string, React.CSSProperties> = {
  root: {
    display: "flex",
    flexDirection: "column",
    height: "100%",
    background: "#1e1e2e",
    color: "#cdd6f4",
    fontSize: 12,
  },
  empty: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    height: "100%",
    color: "#585b70",
    fontSize: 13,
  },
  toolbar: {
    display: "flex",
    alignItems: "center",
    gap: 4,
    padding: "4px 6px",
    borderBottom: "1px solid #313244",
    background: "#181825",
    flexShrink: 0,
  },
  body: {
    display: "flex",
    flex: 1,
    overflow: "hidden",
  },
  trackList: {
    width: 180,
    borderRight: "1px solid #313244",
    overflowY: "auto",
    flexShrink: 0,
  },
  trackListHeader: {
    padding: "4px 6px",
    fontWeight: 600,
    fontSize: 11,
    color: "#a6adc8",
    borderBottom: "1px solid #313244",
    background: "#181825",
  },
  trackItem: {
    display: "flex",
    alignItems: "center",
    gap: 4,
    padding: "3px 6px",
    cursor: "pointer",
    height: TRACK_HEIGHT,
    borderBottom: "1px solid #11111b",
  },
  trackName: {
    flex: 1,
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    fontSize: 11,
  },
  badge: {
    fontSize: 9,
    fontWeight: 700,
    padding: "1px 4px",
    borderRadius: 3,
  },
  timelineContainer: {
    flex: 1,
    overflow: "auto",
    position: "relative",
  },
  propsPanel: {
    width: 220,
    borderLeft: "1px solid #313244",
    overflowY: "auto",
    flexShrink: 0,
  },
  btn: {
    background: "#313244",
    color: "#cdd6f4",
    border: "none",
    borderRadius: 4,
    padding: "3px 8px",
    cursor: "pointer",
    fontSize: 11,
  },
  btnSmall: {
    background: "transparent",
    color: "#585b70",
    border: "none",
    cursor: "pointer",
    fontSize: 14,
    lineHeight: 1,
    padding: 0,
  },
  input: {
    background: "#11111b",
    color: "#cdd6f4",
    border: "1px solid #313244",
    borderRadius: 3,
    padding: "2px 4px",
    fontSize: 11,
    outline: "none",
  },
  select: {
    background: "#11111b",
    color: "#cdd6f4",
    border: "1px solid #313244",
    borderRadius: 3,
    padding: "2px 4px",
    fontSize: 11,
    outline: "none",
  },
  label: {
    color: "#a6adc8",
    fontSize: 10,
    marginLeft: 4,
  },
  sep: {
    width: 1,
    height: 18,
    background: "#313244",
    margin: "0 4px",
    display: "inline-block",
  },
  propValue: {
    color: "#cdd6f4",
    fontSize: 11,
    display: "block",
    padding: "1px 0",
  },
};
