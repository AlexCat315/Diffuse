# Swift maintainability

For first-party Swift code in Engine, Editor, and GuavaUI:

- A class or struct should own one responsibility. Keep at most 20 stored instance properties and at most 16 initializer parameters. An initializer must not copy or decode more than 20 distinct stored properties.
- Split large configuration/state models into typed groups with independent defaults and validation. Do not move the same flat field list into one large `Config`, a giant builder, or forwarding properties.
- Declare ordinary defaults on the owning properties. Use small explicit initializers for required values and invariants. For configurable value types, a synchronous `inout` configuration closure is acceptable; it should configure meaningful groups.
- Copy an existing value/group as a whole. Avoid parallel runtime/editor/manifest field lists. Serialize the typed groups directly. This project is in early development: update callers and formats together instead of adding old API aliases, legacy decoders, or migration layers.
- Keep transient simulation/session data separate from authored or persisted settings. Verify reset behavior, deterministic seeds, defaults for missing fields, and serialization round trips when changing these boundaries.
- Exceptions for required binary/GPU layouts need a concrete reason. Existing debt is recorded in `scripts/swift-maintainability-baseline.json`; it may shrink, never grow merely to satisfy the check. New oversized declarations need structural changes.
- Run `python3 scripts/check-swift-maintainability.py` and the affected Swift package tests. Use `--report` to inspect remaining existing debt. The structural check is a guard; review responsibility boundaries as well.

Preserve unrelated working-tree changes. Make API migrations in all first-party callers, tests, and embedded project/script templates.
