# Swift maintainability

For first-party Swift code in Engine, Editor, and GuavaUI:

- A class or struct should own one responsibility. Keep at most 20 stored instance properties and at most 16 initializer parameters. An initializer must not copy or decode more than 20 distinct stored properties.
- Split large configuration/state models into typed groups with independent defaults and validation. Do not move the same flat field list into one large `Config`, a giant builder, or forwarding properties.
- Declare ordinary defaults on the owning properties. Use small explicit initializers for required values and invariants. For configurable value types, a synchronous `inout` configuration closure is acceptable; it should configure meaningful groups.
- Copy an existing value/group as a whole. Avoid parallel runtime/editor/manifest field lists. Serialize the typed groups directly. This project is in early development: update callers and formats together instead of adding old API aliases, legacy decoders, or migration layers.
- Keep transient simulation/session data separate from authored or persisted settings. Verify reset behavior, deterministic seeds, defaults for missing fields, and serialization round trips when changing these boundaries.
- Exceptions for required binary/GPU layouts need a concrete reason. Existing debt is recorded in `scripts/swift-maintainability-baseline.json`; it may shrink, never grow merely to satisfy the check. New oversized declarations need structural changes.
- Run `python3 scripts/check-swift-maintainability.py` and the affected Swift package tests. Use `--report` to inspect remaining existing debt. The structural check is a guard; review responsibility boundaries as well.

## File and directory naming

- Let directories express module and domain hierarchy; let file names express the file's responsibility. Do not repeat an enclosing type, module, or directory prefix when the path already provides that context. For example, prefer `Inspector/Physics/RigidBody.swift` over `Inspector/Physics/EditorSceneAdapter+RigidBody.swift`.
- Use `Type+Feature.swift` only for a small, natural extension of a type. When one type accumulates many domain slices, group them in domain directories and use concise responsibility names rather than repeating the type name in every file.
- Keep related codecs, registry code, inspection metadata, and value helpers in responsibility-oriented directories. A Swift file name does not need to match its primary type name.
- Duplicate basenames across independent executable or library targets are acceptable when their module ownership is clear. Avoid duplicate concepts within one target when a domain-specific name or directory can make ownership explicit.
- Do not add a new long-prefix filename merely to match an existing naming pattern.
To address this issue and maintain efficient information display, this project adopts a non-flat directory structure.

Preserve unrelated working-tree changes. Make API migrations in all first-party callers, tests, and embedded project/script templates.

The project is currently in a phase of rapid development and has not yet reached the official 1.0.0 release; there is no need to maintain backward compatibility, so breaking changes are permissible.
