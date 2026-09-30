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
