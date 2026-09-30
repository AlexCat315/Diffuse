# Editor UI reconstruction

The reference is a compact engine workbench: hierarchy on the left, scene and
script side by side, a property inspector on the right, and immediately visible
performance graphs below. The existing engine scene remains real rendered content;
the illustration's landscape is not a replacement screenshot or a UI backdrop.

## Acceptance evidence

- Visual fidelity includes panel silhouette, proportions, spacing, type hierarchy,
  coherent iconography, subdued strokes, soft elevation, focus/selection feedback,
  and the transition between the light shell and dark code surface. Density alone
  is not acceptance. Compare real screenshots against all three supplied images.
- GuavaUI supplies reusable control sizing, flat document/tool tabs, shrink-safe
  property rows, and reliable resizable panels. Verify layout and input behavior,
  including narrow panes, rather than only API availability.
- Editor uses one density and surface system across toolbar, hierarchy, inspector,
  script editor, output panels and status bar. Verify light and dark rendering.
- A scene/script workbench is accessible without hiding the inspector or scene.
  Preserve saved user layouts; provide an explicit new preset.
- Playback controls remain available while editing scripts. Actions use the
  existing command pipeline and enabled-state policy.
- Inspector prioritizes the selected entity's editable properties. Global scene
  settings and advanced JSON must not displace common entity controls.
- Profiler shows real frame timing graphs and current metrics in the first visible
  region. Detailed frame inspection remains reachable.
- Script editing retains asset identity, cancellation, trust gating, external-file
  conflict handling and last-known-good builds.
- Build the editor and affected tests, then inspect the running UI at normal and
  constrained widths. A successful build alone does not prove visual completion.

## Work sequence

1. Shared GuavaUI density and tab components, Editor design tokens.
2. Workspace presets and global playback toolbar; compact panel chrome.
3. Inspector information architecture and first-screen profiler dashboard.
4. Script workbench adaptation to narrow split panes.
5. Runtime visual and interaction verification; remaining layout fixes.

This checklist tracks the full requested end state and is not a completion report.

## Visual audit scope

The gap is not limited to docking and density. Review these independently:

- **Composition:** panel proportions, the silhouette of the whole window,
  useful content vs. chrome, and where the eye is drawn first.
- **Type:** real monospaced source, Chinese/Latin consistency, heading/body/status
  contrast, clipping, line height, and readable dark-surface foregrounds.
- **Surfaces:** a coherent light/dark palette, restrained borders, small radii,
  elevation only where floating controls need separation from rendered content.
- **Controls:** icon geometry, hit regions, state colors, numeric/vector editors,
  and consistent focus, hover, disabled, dirty, running and error states.
- **Information hierarchy:** common component fields before implementation detail;
  avoid nested property cards and always-expanded advanced JSON dominating a pane.
- **Viewport overlays:** compact grouped tools, reserved space for the view cube,
  and an expandable debug legend instead of an always-visible block of labels.
- **Charts:** visible and resizable first-screen graphs, readable metrics, correct
  measurement semantics, and no invented GPU/memory telemetry.
- **UI foundation:** layout, shaping, input routing, repaint scheduling and
  theme propagation must work together. Similar API spelling to SwiftUI is not
  evidence of equivalent capability or quality.

## Runtime verification, 2026-09-30

- Real engine draw-list mirror inspected at 1280 × 720 and 1440 × 870; no scene
  image or synthetic metrics substituted for the engine's output.
- The workbench now keeps scene and source in independent horizontal dock groups;
  reconciliation respects user docking instead of collapsing them on reload.
- Profiler is a dedicated bottom panel. Its graph and summary have layout tests
  at 640 × 136 and 960 × 176 content sizes.
- Source header/editor/footer share one dark palette. Viewport tool groups use
  a dark floating palette independent of surrounding light inspector chrome.
- Drawable size changes request another display frame in event-driven mode.
- Overview budgets and averages use CPU/present work time, matching the plotted
  series; detailed wall-clock frame analysis still includes pacing/idle time.
- The full Compose suite (354 tests), workbench layout/persistence tests and script
  identity/trust/external-change/build-coordination tests were exercised.

Remaining visual work includes complex component editors, advanced-field disclosure,
complete icon/state consistency, and interaction-level verification of the whole
workbench in both themes. The mirror showed stale/black frames around a native
window resize; first-frame palette inspection is not sufficient evidence that
the resize/live-refresh path is correct. Reproduce this against the native window
and separate mirror readback problems from retained-render/input invalidation.
The supplied concept image remains a direction, not a
claim that the current engine or UI already matches its finished quality.
