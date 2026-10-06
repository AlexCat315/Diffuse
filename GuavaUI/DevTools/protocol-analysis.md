# Source locations and component recomposition

Additive fields in `guava-devtools/0.1`; hosts advertise `source` and
`recomposition`. Older snapshots/clients continue to work.

Each `NodeSummary` may include:

```json
{
  "source": {
    "fileID": "MyApp/Counter.swift",
    "filePath": "/build/project/Counter.swift",
    "line": 42,
    "column": 9
  },
  "ownerScopeID": "17",
  "recomposition": {
    "count": 3,
    "initialMs": 0.62,
    "lastMs": 0.18,
    "totalMs": 0.59,
    "maxMs": 0.23,
    "reasons": [{"kind": "state", "detail": "count"}]
  }
}
```

`source` records the component/view expression call site, not necessarily the
type declaration. `ownerScopeID` is the nearest user-view anchor's decimal
ElementID. Only that anchor carries `recomposition`; primitive nodes refer to
their owner rather than duplicating statistics. Fields may be absent for manual
nodes or disabled profiling. A source-less node may use a clearly labelled
ancestor location in the client.

`count` excludes initial materialisation and counts real body evaluation plus
reconciliation, including parent-driven updates. Durations use a monotonic clock
in milliseconds and exclude Yoga layout and rendering. They are inclusive of
child work, so summed rows do not represent frame time. Last reasons contain up
to 16 distinct entries, each with a bounded `kind` (64 characters), optional
`detail` (160 characters) and optional decimal `originScopeID`. Current kinds:

| Kind | Detail / origin |
| --- | --- |
| `state` | The owning `@State` property name |
| `observable` | Observable registrar key, or the `@Observed` property name |
| `dynamicProperty` | Other erased dynamic property names |
| `parent` | Originating parent scope, when available |
| `environment` | Changed CompositionLocal provider and parent scope |
| `manual` | Explicit/unattributed scope invalidation |

No state values, source contents or previous cause history are transmitted.
Queued invalidations deduplicate evaluations while preserving distinct reasons;
a scope that invalidates itself during evaluation keeps its reasons for the next
frame. Removed scopes ignore pending work.

`inspect.recomposition.reset` takes no payload (or null/empty object), uses normal
inspection ownership/validation, and resets all live components' update counters,
durations and last causes. Initial-mount times, app state, selection and temporary
style history are retained. Reply is `inspect.recomposition.reset.ok` with normal
inspection state; hosts then publish the refreshed tree. Malformed payloads use
the existing `.err` response.

Editor links are client preferences, not protocol commands. Clients accept only
VS Code/Cursor schemes, positive line/column integers and absolute POSIX/Windows
paths, and encode path segments. Optional build/local prefix remapping requires
a complete directory-boundary match. No runtime file read, shell command or URL
template is exposed.
