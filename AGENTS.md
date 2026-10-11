# AGENTS.md: Code Maintainability Guidelines (General)

## Purpose and Scope

These guidelines govern changes to first-party code, tests, and templates maintained in this repository.

- They apply to first-party code, not to third-party code or generated code, unless explicitly stated otherwise.
- A specific language, framework, or module may have stricter rules; when there is a conflict, the more specific rule wins.
- When the project is in rapid development and has not reached 1.0.0, breaking changes are allowed, but migration must be complete.

## General Principles

- A type, module, or component should own one responsibility.
- Prefer small, clearly bounded, typed groups.
- Keep interfaces explicit; avoid implicit shared state and cross-layer field duplication.
- Preserve unrelated working-tree changes.
- API changes must update all first-party callers, tests, and embedded project/script templates.
- Do not keep compatibility layers; do not add old API aliases, legacy decoders, or migration layers.

## 1. Type and Module Size

Default thresholds are below and may be adjusted by language and project:

- A type or module should have at most about 20 stored fields/members.
- A constructor or initializer should accept at most about 16 parameters.
- A single initialization must not copy or decode more than about 20 distinct fields.
- When a threshold is exceeded, split the responsibility or introduce typed groups instead of continuing to enlarge a single type.

## 2. Configuration and State Modeling

- Split large configuration or state models into typed, domain-oriented groups.
- Each group should own its independent defaults and validation.
- Do not move the same flat field list into one large `Config`, giant builder, or forwarding properties; splitting must change the model, not just the container.
- Ordinary defaults should be declared on the field/property that owns them.
- Required values and invariants should use small, explicit constructors, factories, or initializers.
- For configurable value objects, a synchronous configuration closure or configuration object is acceptable, but it should configure meaningful groups rather than transcribe fields one by one.
- Copy an existing value or group as a whole.
- Avoid parallel field lists across runtime, editor, manifest, or similar layers.
- Serialize typed groups directly.
- During early development, update callers and formats together instead of adding compatibility layers.

## 3. Transient Data and Persistence Boundaries

- Transient runtime/session data must be separate from persisted or authored configuration.
- When changing these boundaries, verify:
  - reset behavior;
  - deterministic seeds;
  - defaults for missing fields;
  - serialization round trips.
- Do not let temporary state accidentally enter persisted formats.

## 4. File and Directory Organization

- Directories express module and domain hierarchy; file names express file responsibility.
- When the path already provides context, do not repeat an enclosing type, module, or directory prefix.
  - Prefer: `Inspector/Physics/RigidBody`
  - Avoid: `Inspector/Physics/EditorSceneAdapter+RigidBody`
- Use `Type+Feature`-style extension filenames only for small, natural extensions of a type.
- When one type accumulates many domain slices, group them in domain directories and use concise responsibility names rather than repeating the type name in every file.
- Keep related codecs, registry code, inspection metadata, and value helpers in responsibility-oriented directories.
- Source file names do not need to match their primary type name.
- Duplicate basenames across independent executables, libraries, or targets are acceptable when module ownership is clear.
- Within one target, avoid duplicate concepts; use domain-specific names or directories to make ownership explicit.
- Do not add a new long-prefix filename merely to match an existing naming pattern.
- To keep information display efficient, the project uses a non-flat directory structure.

## 5. Migration and Compatibility

- Preserve unrelated working-tree changes.
- API migrations must cover all first-party callers, tests, and embedded project/script templates.
- When the project has not reached 1.0.0, backward compatibility is not required, and breaking changes are allowed.
- Do not add old API aliases, legacy decoders, or migration layers just to support old call patterns; update callers and formats directly.
- After migration, remove unused old paths and fields to avoid dual maintenance.

## 6. Review Checklist

When submitting or reviewing code, check the following:

- [ ] Does the type, module, or component own only one responsibility?
- [ ] Are stored fields/members within the default threshold?
- [ ] Are constructor parameters within the default threshold?
- [ ] Does initialization avoid copying or decoding more than the default threshold of fields?
- [ ] Are large configuration/state models split into typed groups with independent defaults and validation?
- [ ] Is the code avoiding a large `Config`, giant builder, or forwarding-property split?
- [ ] Are defaults declared on the field/property that owns them?
- [ ] Are required values and invariants handled by small, explicit construction?
- [ ] Are parallel field lists avoided across layers?
- [ ] Are typed groups serialized directly?
- [ ] Is transient runtime/session data separate from persisted configuration?
- [ ] Are reset behavior, deterministic seeds, defaults for missing fields, and serialization round trips verified?
- [ ] Do file names express responsibility instead of repeating context already provided by the path?
- [ ] Is `Type+Feature`-style naming used only for small, natural extensions?
- [ ] Do API migrations cover all first-party callers, tests, and embedded templates?
- [ ] Are compatibility layers, old aliases, and legacy decoders avoided?
- [ ] Are unrelated working-tree changes preserved?