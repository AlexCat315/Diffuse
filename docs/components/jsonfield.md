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
- Expand opens a centered editor with line numbers. Apply / Primary-Return commits valid JSON atomically; Cancel / Escape discards expanded-window changes.
- Expanded editing requires a `PortalHost` at the window root, normally supplied by `LayerRoot`.
- Text fields support Primary-Z, Primary-Shift-Z and Ctrl-Y. History includes cursor/selection, coalesces continuous typing and treats replacement/paste as one edit.

Use `ResizableTextArea` separately for other multiline inputs. See [interaction primitives](interaction.md) for modal, context menu and transition APIs.
