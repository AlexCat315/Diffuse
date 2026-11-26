pub mod navigation;
pub mod prefab;
#[expect(
    clippy::module_inception,
    reason = "the Swift file and directory share a name"
)]
pub mod scene_graph;
