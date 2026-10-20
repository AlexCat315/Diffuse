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

## 6. API Surface and Non-Invasiveness

- Keep the public API surface minimal and intentional. Default to the narrowest visibility; make something public only when a first-party caller must use it.
- Do not leak internal types, storage, helpers, lifecycle details, or mutable state through the public API.
- Design non-invasive APIs. An API must not require callers to:
  - inherit from a framework/base type;
  - conform to unrelated protocols;
  - wrap, subclass, or restructure their own domain types;
  - pass internal context, tokens, handles, or implementation details;
  - register globals or mutate shared state;
  - adopt framework-specific control flow, lifecycle, threading, or ordering just to use the API.
- Prefer composition, plain values, functions, and narrow protocols over inheritance, global registration, and deep callback chains.
- Let callers pass data in and receive results out. If a high-level operation needs multiple internal steps, expose a facade or entry point instead of forcing callers to orchestrate them.
- Put any required adaptation in an adapter/facade at the boundary. Do not push framework details into caller code.
- Keep dependencies directional. Public APIs must not force higher-level concepts into lower-level modules or leak domain-internal types across boundaries.
- Adding or changing an API should not require invasive edits across many unrelated call sites. If it does, reconsider the boundary.
- When in doubt, start with the smallest non-invasive API and expand only for proven caller needs.

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
- [ ] Is the public API surface minimal and intentional?
- [ ] Are internal types, state, helpers, and lifecycle details hidden?
- [ ] Can callers use the API without inheritance, wrapping, global registration, or restructuring?
- [ ] Are multi-step internal workflows exposed as a facade/entry point rather than caller orchestration?
- [ ] Is adaptation kept at the boundary?
- [ ] Are dependencies directional and free of leaked internal types?
- [ ] Does the API avoid exposing mutable internal state?
- [ ] Could a smaller value/function/protocol-based API work instead?


Keep public APIs minimal and non-invasive: expose only what callers need, and never require callers to inherit, conform, wrap, register, or restructure their code just to use the API.
Make effective use of new Swift 6 features. For instance, Swift 6 introduces changes via the SE-0409 proposal, allowing access level modifiers—such as `private import` and `internal import`—to be applied to `import` declarations.
This implies the following:
Default behavior: If no modifier is specified, the implicit access level for an import remains `public`, meaning the imported module can be referenced throughout the entire module (target). 
Restricting import scope: You can use `private import SomeModule`, which limits the use of symbols imported from `SomeModule` to that specific source file, preventing them from being referenced by other files within the same target. This achieves the "file-level import scoping" you mentioned.

I will not allow Python to pollute my project!

Please use the `guava cli` command to run the program; do not use the `swift` command.