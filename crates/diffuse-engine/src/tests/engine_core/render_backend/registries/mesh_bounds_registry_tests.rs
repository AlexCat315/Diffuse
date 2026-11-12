//! Ported from
//! `Engine/Tests/EngineCoreTests/RenderBackend/Registries/MeshBoundsRegistryTests.swift`.

use diffuse_math::bounds::bounds_3d::Bounds3D;
use diffuse_math::simd::simd_compat::Float3;
use diffuse_render::registries::mesh_bounds_registry::MeshBoundsRegistry;

/// Stores typed bounds while preserving tuple lookup.
#[test]
fn stores_typed_bounds() {
    MeshBoundsRegistry::clear_all();

    let bounds = Bounds3D::new(Float3::new(-1.0, -2.0, -3.0), Float3::new(1.0, 2.0, 3.0));
    MeshBoundsRegistry::register(3, bounds);

    assert_eq!(MeshBoundsRegistry::bounds_3d(3), Some(bounds));
    let tuple = MeshBoundsRegistry::bounds(3).expect("tuple bounds");
    assert_eq!(tuple.0, bounds.min);
    assert_eq!(tuple.1, bounds.max);

    MeshBoundsRegistry::clear_all();
}
