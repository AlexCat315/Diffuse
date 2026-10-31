//! `AOVSpec` and `AOVRegistry` — the render-pass channel table.

use std::sync::Mutex;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AovSpec {
    pub id: String,
    pub name: String,
    pub channel_count: i64,
    pub description: String,
}

impl AovSpec {
    /// Swift default: `channelCount: 3`, `description: ""`.
    #[inline]
    pub fn new(id: impl Into<String>, name: impl Into<String>) -> Self {
        AovSpec {
            id: id.into(),
            name: name.into(),
            channel_count: 3,
            description: String::new(),
        }
    }

    pub fn with_channels(mut self, channel_count: i64) -> Self {
        self.channel_count = channel_count;
        self
    }

    pub fn with_description(mut self, description: impl Into<String>) -> Self {
        self.description = description.into();
        self
    }
}

/// Swift used an `@unchecked Sendable` class with a mutable array; the Rust
/// equivalent is a mutex so registration stays usable across threads.
pub struct AovRegistry {
    specs: Mutex<Vec<AovSpec>>,
}

impl AovRegistry {
    /// Builds the registry with the built-in AOVs registered.
    pub fn new() -> Self {
        let registry = AovRegistry {
            specs: Mutex::new(Vec::new()),
        };
        registry.register_builtins();
        registry
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<AovSpec>> {
        self.specs.lock().unwrap_or_else(|error| error.into_inner())
    }

    pub fn all_specs(&self) -> Vec<AovSpec> {
        self.lock().clone()
    }

    /// Registers a spec, replacing any existing entry with the same id and
    /// appending it at the end — Swift's `removeAll { $0.id == spec.id }` then
    /// `append`.
    pub fn register(&self, spec: AovSpec) {
        let mut specs = self.lock();
        specs.retain(|existing| existing.id != spec.id);
        specs.push(spec);
    }

    pub fn spec(&self, id: &str) -> Option<AovSpec> {
        self.lock().iter().find(|spec| spec.id == id).cloned()
    }

    pub fn total_channel_count(&self) -> i64 {
        self.lock().iter().map(|spec| spec.channel_count).sum()
    }

    fn register_builtins(&self) {
        for spec in [
            AovSpec::new("beauty", "Beauty")
                .with_channels(4)
                .with_description("Final shaded RGBA"),
            AovSpec::new("diffuse", "Diffuse").with_description("Diffuse albedo"),
            AovSpec::new("specular", "Specular").with_description("Specular reflection"),
            AovSpec::new("depth", "Depth")
                .with_channels(1)
                .with_description("World-space depth"),
            AovSpec::new("normal", "Normal").with_description("World-space normals"),
            AovSpec::new("cryptomatte", "Cryptomatte")
                .with_channels(4)
                .with_description("Per-object matte IDs"),
            AovSpec::new("albedo", "Albedo").with_description("Base color without lighting"),
            AovSpec::new("emission", "Emission").with_description("Emissive contribution"),
            AovSpec::new("ambient_occlusion", "Ambient Occlusion")
                .with_channels(1)
                .with_description("AO factor"),
            AovSpec::new("motion_vector", "Motion Vector")
                .with_channels(2)
                .with_description("Screen-space motion"),
        ] {
            self.register(spec);
        }
    }
}

impl Default for AovRegistry {
    fn default() -> Self {
        Self::new()
    }
}
