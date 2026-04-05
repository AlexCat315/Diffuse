import React from "react";

// ── SVG icon imports from assets/ui/icons/svg ───────────────────
import saveUrl from "@icons/save.svg";
import folderFUrl from "@icons/folder-f.svg";
import folderUrl from "@icons/folder.svg";
import undoUrl from "@icons/undo.svg";
import redoUrl from "@icons/redo.svg";
import playUrl from "@icons/play.svg";
import pauseUrl from "@icons/pause.svg";
import stopUrl from "@icons/stop.svg";
import directionArrowsUrl from "@icons/direction-arrows.svg";
import arrowPathUrl from "@icons/arrow-path.svg";
import arrowsPointingOutUrl from "@icons/arrows-pointing-out.svg";
import cursorArrowRaysUrl from "@icons/cursor-arrow-rays.svg";
import xMarkUrl from "@icons/x-mark.svg";
import refreshUrl from "@icons/refresh.svg";
import chevronUpUrl from "@icons/chevron-up.svg";
import chevronDownUrl from "@icons/chevron-down.svg";
import chevronRightUrl from "@icons/chevron-right.svg";
import cubeUrl from "@icons/cube.svg";
import photoUrl from "@icons/photo.svg";
import sparkleUrl from "@icons/sparkle.svg";
import filmUrl from "@icons/film.svg";
import codeBracketUrl from "@icons/code-bracket.svg";
import micUrl from "@icons/mic.svg";
import paintBrushUrl from "@icons/paint-brush.svg";
import documentTextUrl from "@icons/document-text.svg";
import arrowBigUpUrl from "@icons/arrow-big-up.svg";
import clockUrl from "@icons/clock.svg";
import packageUrl from "@icons/package.svg";
import triangleRightUrl from "@icons/triangle-right.svg";
import triangleDownUrl from "@icons/triangle-down.svg";
import gridPatternUrl from "@icons/grid-pattern.svg";
import eyeUrl from "@icons/eye.svg";

// ── Shared icon props ───────────────────────────────────────────
interface IconProps {
  size?: number;
  color?: string;
  className?: string;
  style?: React.CSSProperties;
}

/**
 * Creates a React icon component backed by an SVG file from assets/ui/icons/svg.
 * Uses CSS mask-image so the `color` prop controls the rendered colour.
 */
function createIcon(src: string) {
  return function Icon({ size = 16, color = "currentColor", className, style }: IconProps) {
    return (
      <span
        className={className}
        style={{
          display: "inline-block",
          width: size,
          height: size,
          flexShrink: 0,
          verticalAlign: "middle",
          backgroundColor: color,
          WebkitMaskImage: `url("${src}")`,
          WebkitMaskSize: "contain",
          WebkitMaskRepeat: "no-repeat",
          WebkitMaskPosition: "center",
          maskImage: `url("${src}")`,
          maskSize: "contain",
          maskRepeat: "no-repeat",
          maskPosition: "center",
          ...style,
        }}
      />
    );
  };
}

// ── File & Scene ────────────────────────────────────────────────
export const IconSave = createIcon(saveUrl);
export const IconFolderOpen = createIcon(folderFUrl);
export const IconFolder = createIcon(folderUrl);

// ── Undo / Redo ─────────────────────────────────────────────────
export const IconUndo = createIcon(undoUrl);
export const IconRedo = createIcon(redoUrl);

// ── Playback ────────────────────────────────────────────────────
export const IconPlay = createIcon(playUrl);
export const IconPause = createIcon(pauseUrl);
export const IconStop = createIcon(stopUrl);

// ── Gizmo / Transform ──────────────────────────────────────────
export const IconCursor = createIcon(cursorArrowRaysUrl);
export const IconTranslate = createIcon(directionArrowsUrl);
export const IconRotate = createIcon(arrowPathUrl);
export const IconScale = createIcon(arrowsPointingOutUrl);

// ── UI Actions ──────────────────────────────────────────────────
export const IconClose = createIcon(xMarkUrl);
export const IconRefresh = createIcon(refreshUrl);
export const IconChevronUp = createIcon(chevronUpUrl);
export const IconChevronDown = createIcon(chevronDownUrl);
export const IconChevronRight = createIcon(chevronRightUrl);

// ── Asset types ─────────────────────────────────────────────────
export const IconModel = createIcon(cubeUrl);
export const IconTexture = createIcon(photoUrl);
export const IconShader = createIcon(sparkleUrl);
export const IconScene = createIcon(filmUrl);
export const IconScript = createIcon(codeBracketUrl);
export const IconAudio = createIcon(micUrl);
export const IconMaterial = createIcon(paintBrushUrl);
export const IconFile = createIcon(documentTextUrl);
export const IconArrowUp = createIcon(arrowBigUpUrl);
export const IconAnimation = createIcon(clockUrl);
export const IconPrefab = createIcon(packageUrl);

// ── Arrow indicators ────────────────────────────────────────────
export const IconTriangleRight = createIcon(triangleRightUrl);
export const IconTriangleDown = createIcon(triangleDownUrl);

// ── Viewport shading modes ──────────────────────────────────────
export const IconShadingSolid = createIcon(cubeUrl);
export const IconShadingMaterial = createIcon(paintBrushUrl);
export const IconShadingRendered = createIcon(eyeUrl);
export const IconShadingWireframe = createIcon(gridPatternUrl);

// ── Mesh edit selection modes (inline SVG) ──────────────────────
interface MeshIconProps { size?: number; color?: string; }

/** Vertex mode — single prominent dot with faint corner dots */
export function IconMeshVertex({ size = 14, color = "currentColor" }: MeshIconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg">
      <circle cx="3"  cy="3"  r="1.8" fill={color} opacity="0.45" />
      <circle cx="13" cy="3"  r="1.8" fill={color} opacity="0.45" />
      <circle cx="3"  cy="13" r="1.8" fill={color} opacity="0.45" />
      <circle cx="13" cy="13" r="1.8" fill={color} opacity="0.45" />
      <circle cx="8"  cy="8"  r="3"   fill={color} />
    </svg>
  );
}

/** Edge mode — diagonal line segment with accent dots at each end */
export function IconMeshEdge({ size = 14, color = "currentColor" }: MeshIconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg">
      <line x1="3" y1="13" x2="13" y2="3" stroke={color} strokeWidth="2" strokeLinecap="round" />
      <circle cx="3"  cy="13" r="2" fill={color} />
      <circle cx="13" cy="3"  r="2" fill={color} />
    </svg>
  );
}

/** Face mode — filled quad with corner vertex dots */
export function IconMeshFace({ size = 14, color = "currentColor" }: MeshIconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg">
      <rect x="3" y="3" width="10" height="10" rx="1" fill={color} fillOpacity="0.22" stroke={color} strokeWidth="1.5" />
      <circle cx="3"  cy="3"  r="1.8" fill={color} />
      <circle cx="13" cy="3"  r="1.8" fill={color} />
      <circle cx="3"  cy="13" r="1.8" fill={color} />
      <circle cx="13" cy="13" r="1.8" fill={color} />
    </svg>
  );
}
