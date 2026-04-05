import React, { useState, useRef } from "react";
import ReactDOM from "react-dom";

interface TooltipProps {
  label: string;
  shortcut?: string;
  children: React.ReactNode;
  /** Where the tooltip appears relative to the trigger. Default: "bottom" */
  placement?: "top" | "bottom";
}

/**
 * Hover tooltip that renders into document.body via a portal so it is never
 * clipped by ancestor overflow:hidden containers (e.g. flexlayout tab headers).
 */
export function Tooltip({ label, shortcut, children, placement = "bottom" }: TooltipProps) {
  const [pos, setPos] = useState<{ x: number; y: number } | null>(null);
  const ref = useRef<HTMLDivElement>(null);

  const handleMouseEnter = () => {
    if (!ref.current) return;
    const r = ref.current.getBoundingClientRect();
    setPos({
      x: r.left + r.width / 2,
      y: placement === "bottom" ? r.bottom + 7 : r.top - 7,
    });
  };

  const handleMouseLeave = () => setPos(null);

  const transformStyle =
    placement === "bottom"
      ? "translateX(-50%)"
      : "translate(-50%, -100%)";

  return (
    <div
      ref={ref}
      style={styles.wrapper}
      onMouseEnter={handleMouseEnter}
      onMouseLeave={handleMouseLeave}
    >
      {children}
      {pos &&
        ReactDOM.createPortal(
          <div
            style={{
              ...styles.bubble,
              position: "fixed",
              left: pos.x,
              top: pos.y,
              transform: transformStyle,
            }}
          >
            <span>{label}</span>
            {shortcut && <kbd style={styles.kbd}>{shortcut}</kbd>}
          </div>,
          document.body,
        )}
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  wrapper: {
    position: "relative",
    display: "inline-flex",
  },
  bubble: {
    background: "#1e1e2e",
    border: "1px solid #45475a",
    borderRadius: 5,
    padding: "5px 9px",
    fontSize: 11,
    color: "#cdd6f4",
    whiteSpace: "nowrap",
    zIndex: 99999,
    pointerEvents: "none",
    boxShadow: "0 3px 10px rgba(0,0,0,0.5)",
    display: "flex",
    alignItems: "center",
    gap: 7,
  },
  kbd: {
    background: "#313244",
    border: "1px solid #585b70",
    borderRadius: 3,
    padding: "1px 5px",
    fontSize: 10,
    color: "#a6adc8",
    fontFamily: "monospace",
    fontStyle: "normal",
    lineHeight: "1.4",
  },
};

