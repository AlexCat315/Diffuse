# JsonField

`JsonField` is a compact multiline editor for structured Inspector values such
as script parameters. It validates JSON before committing and normalizes empty
input to `{}`.

The Swift Editor uses it for `ScriptComponent` parameter editing. Commits flow
through scene transactions, so script parameter edits participate in the same
revision path as other Inspector fields.

```swift
JsonField(text: $parameters) { committed in
    saveParameters(committed)
}
```

## Behavior

- `Cmd-Return` commits valid JSON.
- Invalid JSON stays in the draft across blur/refocus and does not overwrite the bound value.
- Drag the lower grip to resize the inline editor; overflowing text scrolls inside the field.
- The compact toolbar exposes format, revert and expand actions as SVG icons with tooltips. Validation errors appear only when needed.
- `Format` pretty-prints with sorted keys for stable diffs. `Revert` restores the current edit's starting value.
- Expand fills a compact window; at 600pt and wider it opens a centered editor up to 760×560pt with 16pt margins. Both layouts retain the same draft, history, focus and portal during resize, with line numbers and a named dialog/heading.
- The expanded header reserves its icon targets and truncates a long localized title with its full tooltip/name. The editing surface is flat; footer validation and actions remain outside its scrolling content. Compact actions fill the width and stack, with ≥44pt touch targets; longer desktop actions also stack when their natural widths do not fit. Safe-area edges are consumed once.
- Apply / Primary-Return commits valid JSON atomically; Cancel / Escape discards expanded-window changes and returns focus to Expand. Invalid JSON disables Apply and preserves the draft. Error text wraps up to three lines with its complete message in tooltip/accessibility.
- Expanded editing requires a `PortalHost` at the window root, normally supplied by `LayerRoot`.
- Text fields support Primary-Z, Primary-Shift-Z and Ctrl-Y. History includes cursor/selection, coalesces continuous typing and treats replacement/paste as one edit.

Use `ResizableTextArea` separately for other multiline inputs. See [interaction primitives](interaction.md) for modal, context menu and transition APIs.

## Acceptance

`JsonEditorTests` covers 390/720/1280pt, 100%/200% text, touch/mixed/pointer,
light/dark, RTL, nonzero safe areas and long labels. It verifies real pointer
and keyboard input, invalid submission, an atomic commit, cancellation, and draft
and focus retention across open resizes. `JsonFieldTests` and
`EditorInteractionTests` cover normalization, formatting, inline validation,
undo and expanded layout/transactions.

DevTools acceptance on macOS used `--component jsonField`: 390×820 touch at 200%,
720×820 dark mixed input, and 1280×820 RTL pointer at 200%. `query_ui_nodes`
located Expand, `input-ui` opened the editor and replaced its text, and an explicit
`node_id`/`include_value` read confirmed `{"value":42}`. Apply changed the Gallery's
`json-committed` value once; replacing the draft with invalid JSON disabled Apply,
and Escape retained the committed value. `capture-ui --settle-ms 400` mirrors
were inspected after opening, invalid input and cancellation: the narrow editor
fills the window, the header and bottom actions stay reachable, error text wraps,
and wider dialogs retain balanced margins. Native IME still needs device acceptance.
