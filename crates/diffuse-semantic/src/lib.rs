//! Crate root. See MIGRATION.md §5.
pub mod asset_semantic_pipeline;
pub mod backends;
pub mod memory;
pub mod semantic_contracts;
pub mod semantic_world_event_mapper;

pub use asset_semantic_pipeline::{AssetSemanticPipeline, SemanticPipelineConfig};
pub use backends::geometry_backend::GeometryBackend;
pub use backends::semantic_analyzer_backend::{
    MetadataBackend, NameHeuristicBackend, RigBackend, SemanticAnalyzerBackend,
};
pub use backends::vision_backend::VisionBackend;
pub use memory::file_backed_semantic_memory_store::FileBackedSemanticMemoryStore;
pub use memory::semantic_memory_store::{
    EphemeralSemanticMemoryStore, MemoryScope, MemorySource, SemanticMemoryEntry,
    SemanticMemoryError, SemanticMemoryStore,
};
pub use semantic_contracts::*;
pub use semantic_world_event_mapper::SemanticWorldEventMapper;
