//! `BuiltinComponentCodecs` — the v3 component codecs shared by scenes, prefabs,
//! game saves and editor documents.
//!
//! Swift declares `enum BuiltinComponentCodecs {}` here and puts every codec in an
//! `extension` in its own file. MIGRATION.md §5.1 maps one Swift file to one Rust
//! file, so the extensions become `impl BuiltinComponentCodecs` blocks living beside
//! this declaration:
//!
//! * `codecs/rendering.rs` — `Rendering.swift`
//! * `codecs/assets.rs` — `Assets.swift`
//! * `codecs/references.rs` — `References.swift`
//! * `codecs/physics.rs` — `Physics.swift`
//! * `codecs/animation_audio.rs` — `AnimationAudio.swift`
//! * `codecs/particles.rs` — `Particles.swift`
//!
//! The codecs operate on the persisted document, not on a second runtime model:
//! serializers return a [`std::collections::BTreeMap`] keyed exactly as Swift's
//! dictionary keys and valued with [`crate::components::core::value::ComponentValue`]
//! (the JSON shapes MIGRATION.md §5.4 pins down).

/// Swift's empty `enum` used as a namespace. It is never constructed.
pub enum BuiltinComponentCodecs {}
