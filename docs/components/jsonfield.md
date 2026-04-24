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
- Invalid JSON stays in the draft and does not overwrite the bound value.
- `Format` pretty-prints with sorted keys for stable diffs.
- `Revert` discards the current draft.
