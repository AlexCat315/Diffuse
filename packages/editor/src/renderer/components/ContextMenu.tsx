import React, { useEffect, useRef, useCallback } from "react";

export interface MenuItem {
  label: string;
  shortcut?: string;
  icon?: string;
  disabled?: boolean;
  children?: MenuItem[];
  onClick?: () => void;
}

export interface ContextMenuProps {
  x: number;
  y: number;
  items: MenuItem[];
  onClose: () => void;
}

/**
 * A lightweight context menu component positioned at (x, y) in screen coords.
 * Supports one level of nested submenus.
 */
export function ContextMenu({ x, y, items, onClose }: ContextMenuProps) {
  const menuRef = useRef<HTMLDivElement>(null);
  const [submenuIndex, setSubmenuIndex] = React.useState<number | null>(null);
  const [adjustedPos, setAdjustedPos] = React.useState({ x, y });

  // Adjust position so menu stays within viewport bounds
  useEffect(() => {
    const el = menuRef.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    let ax = x;
    let ay = y;
    if (ax + rect.width > window.innerWidth - 4) ax = window.innerWidth - rect.width - 4;
    if (ay + rect.height > window.innerHeight - 4) ay = window.innerHeight - rect.height - 4;
    if (ax < 4) ax = 4;
    if (ay < 4) ay = 4;
    setAdjustedPos({ x: ax, y: ay });
  }, [x, y]);

  // Close on outside click or Escape
  useEffect(() => {
    const handleKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    const handleClick = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        onClose();
      }
    };
    document.addEventListener("keydown", handleKey);
    document.addEventListener("mousedown", handleClick, true);
    return () => {
      document.removeEventListener("keydown", handleKey);
      document.removeEventListener("mousedown", handleClick, true);
    };
  }, [onClose]);

  const handleItemClick = useCallback(
    (item: MenuItem, e: React.MouseEvent) => {
      e.stopPropagation();
      if (item.disabled) return;
      if (item.children) return; // submenu toggle handled by hover
      item.onClick?.();
      onClose();
    },
    [onClose],
  );

  return (
    <div ref={menuRef} style={{ ...S.menu, left: adjustedPos.x, top: adjustedPos.y }}>
      {items.map((item, i) => {
        if (item.label === "---") {
          return <div key={i} style={S.separator} />;
        }
        const hasChildren = item.children && item.children.length > 0;
        const isOpen = submenuIndex === i;
        return (
          <div
            key={i}
            style={{
              ...S.item,
              ...(item.disabled ? S.itemDisabled : {}),
            }}
            onMouseEnter={() => setSubmenuIndex(hasChildren ? i : null)}
            onMouseLeave={() => { if (!hasChildren) setSubmenuIndex(null); }}
            onClick={(e) => handleItemClick(item, e)}
          >
            <span style={S.itemIcon}>{item.icon ?? ""}</span>
            <span style={S.itemLabel}>{item.label}</span>
            {item.shortcut && <span style={S.itemShortcut}>{item.shortcut}</span>}
            {hasChildren && <span style={S.itemArrow}>▸</span>}
            {hasChildren && isOpen && (
              <Submenu items={item.children!} onClose={onClose} parentRef={menuRef} />
            )}
          </div>
        );
      })}
    </div>
  );
}

function Submenu({
  items,
  onClose,
  parentRef,
}: {
  items: MenuItem[];
  onClose: () => void;
  parentRef: React.RefObject<HTMLDivElement | null>;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [side, setSide] = React.useState<"right" | "left">("right");

  useEffect(() => {
    const el = ref.current;
    const parent = parentRef.current;
    if (!el || !parent) return;
    const pr = parent.getBoundingClientRect();
    const er = el.getBoundingClientRect();
    if (pr.right + er.width > window.innerWidth - 4) {
      setSide("left");
    }
  }, [parentRef]);

  return (
    <div
      ref={ref}
      style={{
        ...S.menu,
        position: "absolute",
        top: -4,
        ...(side === "right" ? { left: "100%", marginLeft: 2 } : { right: "100%", marginRight: 2 }),
      }}
    >
      {items.map((item, i) => {
        if (item.label === "---") {
          return <div key={i} style={S.separator} />;
        }
        return (
          <div
            key={i}
            style={{
              ...S.item,
              ...(item.disabled ? S.itemDisabled : {}),
            }}
            onClick={(e) => {
              e.stopPropagation();
              if (item.disabled) return;
              item.onClick?.();
              onClose();
            }}
          >
            <span style={S.itemIcon}>{item.icon ?? ""}</span>
            <span style={S.itemLabel}>{item.label}</span>
            {item.shortcut && <span style={S.itemShortcut}>{item.shortcut}</span>}
          </div>
        );
      })}
    </div>
  );
}

const S: Record<string, React.CSSProperties> = {
  menu: {
    position: "fixed",
    zIndex: 9999,
    minWidth: 180,
    background: "rgba(24, 24, 37, 0.95)",
    backdropFilter: "blur(12px)",
    WebkitBackdropFilter: "blur(12px)",
    borderRadius: 6,
    border: "1px solid rgba(69, 71, 90, 0.6)",
    boxShadow: "0 4px 16px rgba(0,0,0,0.4), 0 1px 4px rgba(0,0,0,0.2)",
    padding: "4px 0",
    userSelect: "none",
  },
  separator: {
    height: 1,
    margin: "4px 8px",
    background: "rgba(69, 71, 90, 0.5)",
  },
  item: {
    position: "relative" as const,
    display: "flex",
    alignItems: "center",
    padding: "6px 12px",
    cursor: "pointer",
    color: "#cdd6f4",
    fontSize: 13,
    lineHeight: "1.2",
    borderRadius: 0,
    transition: "background 0.08s",
    // Hover is handled via CSS-in-JS workaround below (onMouseEnter)
  },
  itemDisabled: {
    opacity: 0.4,
    cursor: "default",
  },
  itemIcon: {
    width: 20,
    textAlign: "center" as const,
    marginRight: 6,
    fontSize: 14,
    flexShrink: 0,
  },
  itemLabel: {
    flex: 1,
    whiteSpace: "nowrap" as const,
  },
  itemShortcut: {
    marginLeft: 24,
    fontSize: 11,
    color: "#6c7086",
    whiteSpace: "nowrap" as const,
  },
  itemArrow: {
    marginLeft: 8,
    fontSize: 10,
    color: "#6c7086",
  },
};

// Inject a tiny hover stylesheet (avoids inline style limitations)
if (typeof document !== "undefined") {
  const id = "guava-context-menu-style";
  if (!document.getElementById(id)) {
    const style = document.createElement("style");
    style.id = id;
    style.textContent = `
      [data-guava-ctx-menu] > div[style]:hover {
        background: rgba(69, 71, 90, 0.6) !important;
      }
    `;
    document.head.appendChild(style);
  }
}
