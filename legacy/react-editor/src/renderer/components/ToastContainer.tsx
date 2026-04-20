import React, { useEffect } from "react";
import ReactDOM from "react-dom";
import { useToastStore, type ToastItem, type ToastLevel } from "../store/toast";

const LEVEL_COLORS: Record<ToastLevel, { bg: string; border: string; text: string }> = {
  info:    { bg: "#1e1e2e", border: "#89b4fa", text: "#cdd6f4" },
  success: { bg: "#1e1e2e", border: "#a6e3a1", text: "#a6e3a1" },
  warning: { bg: "#1e1e2e", border: "#f9e2af", text: "#f9e2af" },
  error:   { bg: "#1e1e2e", border: "#f38ba8", text: "#f38ba8" },
};

const LEVEL_ICONS: Record<ToastLevel, string> = {
  info: "ℹ",
  success: "✓",
  warning: "⚠",
  error: "✗",
};

function ToastEntry({ item }: { item: ToastItem }) {
  const dismiss = useToastStore((s) => s.dismiss);

  useEffect(() => {
    if (item.duration <= 0) return;
    const timer = setTimeout(() => dismiss(item.id), item.duration);
    return () => clearTimeout(timer);
  }, [item.id, item.duration, dismiss]);

  const colors = LEVEL_COLORS[item.level];

  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        gap: 8,
        padding: "8px 14px",
        background: colors.bg,
        border: `1px solid ${colors.border}`,
        borderRadius: 6,
        color: colors.text,
        fontSize: 13,
        lineHeight: "18px",
        boxShadow: "0 4px 12px rgba(0,0,0,0.4)",
        maxWidth: 400,
        wordBreak: "break-word",
        cursor: "pointer",
        animation: "toast-slide-in 0.2s ease-out",
      }}
      onClick={() => dismiss(item.id)}
    >
      <span style={{ fontSize: 15, flexShrink: 0 }}>{LEVEL_ICONS[item.level]}</span>
      <span style={{ flex: 1 }}>{item.message}</span>
    </div>
  );
}

export function ToastContainer() {
  const items = useToastStore((s) => s.items);

  if (items.length === 0) return null;

  return ReactDOM.createPortal(
    <div
      style={{
        position: "fixed",
        bottom: 16,
        right: 16,
        display: "flex",
        flexDirection: "column-reverse",
        gap: 8,
        zIndex: 99999,
        pointerEvents: "auto",
      }}
    >
      {items.map((item) => (
        <ToastEntry key={item.id} item={item} />
      ))}
      <style>{`
        @keyframes toast-slide-in {
          from { opacity: 0; transform: translateY(8px); }
          to   { opacity: 1; transform: translateY(0); }
        }
      `}</style>
    </div>,
    document.body,
  );
}
