import React, { useEffect, useState, useCallback } from "react";

interface Bookmark {
  index: number;
  name: string;
  position: { x: number; y: number; z: number };
  rotation: { x: number; y: number; z: number; w: number };
  fov: number;
}

interface CameraBookmarksProps {
  connected: boolean;
}

export function CameraBookmarks({ connected }: CameraBookmarksProps) {
  const [bookmarks, setBookmarks] = useState<Bookmark[]>([]);
  const [editingIdx, setEditingIdx] = useState<number | null>(null);
  const [editName, setEditName] = useState("");

  const refresh = useCallback(async () => {
    if (!connected) return;
    try {
      const res = await window.guavaEngine.call("camera.listBookmarks", {});
      setBookmarks(res.bookmarks);
    } catch {
      /* ignore */
    }
  }, [connected]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  const handleAdd = async () => {
    const name = `Bookmark ${bookmarks.length + 1}`;
    await window.guavaEngine.call("camera.addBookmark", { name });
    refresh();
  };

  const handleApply = async (index: number) => {
    await window.guavaEngine.call("camera.applyBookmark", { index });
  };

  const handleRemove = async (index: number) => {
    await window.guavaEngine.call("camera.removeBookmark", { index });
    refresh();
  };

  const handleRenameStart = (b: Bookmark) => {
    setEditingIdx(b.index);
    setEditName(b.name);
  };

  const handleRenameCommit = async () => {
    if (editingIdx == null) return;
    await window.guavaEngine.call("camera.renameBookmark", { index: editingIdx, name: editName });
    setEditingIdx(null);
    refresh();
  };

  const fmtPos = (p: { x: number; y: number; z: number }) =>
    `${p.x.toFixed(1)}, ${p.y.toFixed(1)}, ${p.z.toFixed(1)}`;

  return (
    <div style={styles.container}>
      <div style={styles.header}>
        <span style={styles.title}>Camera Bookmarks</span>
        <span style={styles.count}>{bookmarks.length}</span>
        <div style={{ flex: 1 }} />
        <button style={styles.addBtn} onClick={handleAdd} title="Save current camera position">
          + Add
        </button>
      </div>
      <div style={styles.list}>
        {bookmarks.length === 0 ? (
          <div style={styles.empty}>No bookmarks yet. Click "+ Add" to save the current camera.</div>
        ) : (
          bookmarks.map((b) => (
            <div key={b.index} style={styles.item}>
              <div style={styles.itemHeader}>
                {editingIdx === b.index ? (
                  <input
                    style={styles.nameInput}
                    value={editName}
                    onChange={(e) => setEditName(e.target.value)}
                    onBlur={handleRenameCommit}
                    onKeyDown={(e) => e.key === "Enter" && handleRenameCommit()}
                    autoFocus
                  />
                ) : (
                  <span style={styles.name} onDoubleClick={() => handleRenameStart(b)}>
                    {b.name}
                  </span>
                )}
                <div style={styles.actions}>
                  <button style={styles.actionBtn} onClick={() => handleApply(b.index)} title="Go to bookmark">
                    ▶
                  </button>
                  <button style={styles.actionBtn} onClick={() => handleRemove(b.index)} title="Delete">
                    ✕
                  </button>
                </div>
              </div>
              <div style={styles.meta}>pos: ({fmtPos(b.position)})</div>
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
  addBtn: {
    background: "#313244",
    border: "1px solid #45475a",
    borderRadius: 4,
    color: "#89b4fa",
    cursor: "pointer",
    padding: "2px 8px",
    fontSize: 11,
    fontWeight: 600,
  },
  list: { flex: 1, overflow: "auto", padding: 4 },
  empty: { padding: 16, textAlign: "center", opacity: 0.4, fontSize: 12, color: "#a6adc8" },
  item: {
    padding: "6px 8px",
    borderBottom: "1px solid #181825",
    fontSize: 12,
  },
  itemHeader: {
    display: "flex",
    justifyContent: "space-between",
    alignItems: "center",
  },
  name: { color: "#cdd6f4", cursor: "default", fontWeight: 500 },
  nameInput: {
    background: "#313244",
    border: "1px solid #89b4fa",
    borderRadius: 3,
    color: "#cdd6f4",
    fontSize: 12,
    padding: "1px 4px",
    outline: "none",
    width: 140,
  },
  actions: { display: "flex", gap: 4 },
  actionBtn: {
    background: "transparent",
    border: "none",
    color: "#6c7086",
    cursor: "pointer",
    fontSize: 11,
    padding: "1px 4px",
    borderRadius: 3,
  },
  meta: { color: "#6c7086", fontSize: 10, marginTop: 2, fontFamily: "monospace" },
};
