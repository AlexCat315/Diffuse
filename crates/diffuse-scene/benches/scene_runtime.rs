//! `SceneRuntimeBenchmarks` — Swift `Engine/Benchmarks/SceneRuntimeBenchmarks/main.swift`.
//!
//! Standalone executable (`harness = false`). Builds a fixed scene of 5,000
//! entities with sphere/box colliders and times raycast, overlap and sweep
//! queries, printing elapsed milliseconds, average traversal counters and
//! p50/p95/p99 latency. Each scenario reuses one `SpatialQueryScratch`, exactly
//! like Swift, so no query allocates its traversal state.
//!
//! The query wrappers (`physics_raycast_with_stats`, …) and `SpatialQueryScratch`
//! live in `SpatialQueries.swift`, which is not translated yet; this bench calls
//! the planned API (`crate::physics::queries::spatial_queries` and the
//! `SceneRuntime` forwarding methods) instead of duplicating those types.

use std::collections::BTreeMap;
use std::time::Instant;

use cove_logging::{LogSystem, LoggingConfiguration};
use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::physics::collider::{Collider, ColliderShape, SpatialAABB};
use diffuse_scene::physics::queries::physics_query_types::{
    PhysicsOverlapAABBQuery, PhysicsQueryFilter, PhysicsRaycastQuery, PhysicsSweepAABBQuery,
};
use diffuse_scene::physics::queries::spatial_queries::SpatialQueryScratch;
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_scene::scene_runtime::SceneRuntime;

/// Swift `BenchmarkConfig`; `SceneRuntime()` maps to `SceneRuntime::new(ComponentRegistry::new())`.
struct BenchmarkConfig {
    entity_count: usize,
    query_count: usize,
}

impl Default for BenchmarkConfig {
    fn default() -> Self {
        BenchmarkConfig {
            entity_count: 5_000,
            query_count: 2_000,
        }
    }
}

fn make_runtime(entity_count: usize) -> SceneRuntime {
    let mut runtime = SceneRuntime::new(ComponentRegistry::new());

    for index in 0..entity_count {
        let entity = runtime.create_entity();
        let x = (index % 100) as f32 * 1.5;
        let y = ((index / 100) % 50) as f32 * 1.1;
        let z = (index / 5_000) as f32 * 3.0;
        runtime.set_local_transform(
            LocalTransform::from_translation(Float3::new(x, y, z)),
            entity,
        );

        if index % 3 == 0 {
            runtime.set_component(
                Collider::with_shape(ColliderShape::Sphere {
                    radius: 0.5,
                    center: Float3::ZERO,
                }),
                entity,
            );
        } else {
            runtime.set_component(
                Collider::with_shape(ColliderShape::Box {
                    half_extents: Float3::new(0.5, 0.5, 0.5),
                    center: Float3::ZERO,
                }),
                entity,
            );
        }
    }

    runtime.tick(0.0, 0, Vec::new());
    runtime
}

/// Returns `(p50, p95, p99)` in nanoseconds from a pre-sorted slice.
fn percentiles(sorted: &[u64]) -> (u64, u64, u64) {
    if sorted.is_empty() {
        return (0, 0, 0);
    }
    let n = sorted.len();
    (
        sorted[n / 2],
        sorted[((n as f64 * 0.95) as usize).min(n - 1)],
        sorted[((n as f64 * 0.99) as usize).min(n - 1)],
    )
}

fn fmt_ms(nanoseconds: f64) -> String {
    format!("{:.2}", nanoseconds / 1_000_000.0)
}

fn fmt_us(nanoseconds: u64) -> String {
    format!("{:.1}", nanoseconds as f64 / 1_000.0)
}

fn fmt_avg(total: i64, count: usize) -> String {
    format!(
        "{:.2}",
        if count > 0 {
            total as f64 / count as f64
        } else {
            0.0
        }
    )
}

fn benchmark_raycast(runtime: &mut SceneRuntime, query_count: usize) {
    let scratch = SpatialQueryScratch::new(); // reused across all queries
    let mut node_visits: i64 = 0;
    let mut leaf_tests: i64 = 0;
    let mut narrow_phase_tests: i64 = 0;
    let mut per_query_ns: Vec<u64> = Vec::with_capacity(query_count);

    for query_index in 0..query_count {
        let origin = Float3::new(
            (query_index % 100) as f32 * 0.8 - 20.0,
            ((query_index / 100) % 50) as f32 * 0.8 - 10.0,
            -50.0,
        );
        let direction = Float3::new(0.1, 0.05, 1.0);
        let started = Instant::now();
        let result = runtime.physics_raycast_with_stats(
            PhysicsRaycastQuery::with_distance(origin, direction, 300.0),
            PhysicsQueryFilter::new(),
            Some(&scratch),
        );
        per_query_ns.push(started.elapsed().as_nanos() as u64);
        node_visits += result.1.node_visits;
        leaf_tests += result.1.leaf_tests;
        narrow_phase_tests += result.1.narrow_phase_tests;
    }

    let total_ns: u64 = per_query_ns.iter().sum();
    let mut sorted = per_query_ns;
    sorted.sort_unstable();
    let (p50, p95, p99) = percentiles(&sorted);
    println!(
        "[Raycast] queries={} elapsed_ms={} avg_node_visits={} avg_leaf_tests={} avg_narrow_phase={} p50={}µs p95={}µs p99={}µs",
        query_count,
        fmt_ms(total_ns as f64),
        fmt_avg(node_visits, query_count),
        fmt_avg(leaf_tests, query_count),
        fmt_avg(narrow_phase_tests, query_count),
        fmt_us(p50),
        fmt_us(p95),
        fmt_us(p99),
    );
}

fn benchmark_overlap(runtime: &mut SceneRuntime, query_count: usize, max_results: usize) {
    let scratch = SpatialQueryScratch::new(); // reused across all queries — no per-query allocation
    let mut node_visits: i64 = 0;
    let mut leaf_tests: i64 = 0;
    let mut narrow_phase_tests: i64 = 0;
    let mut total_hits: i64 = 0;
    let mut per_query_ns: Vec<u64> = Vec::with_capacity(query_count);

    for query_index in 0..query_count {
        let center = Float3::new(
            (query_index % 100) as f32,
            ((query_index / 100) % 50) as f32,
            0.0,
        );
        let started = Instant::now();
        let result = runtime.physics_overlap_aabb_with_stats(
            PhysicsOverlapAABBQuery {
                bounds: SpatialAABB::from_center_half_extents(center, Float3::new(2.0, 2.0, 2.0)),
                max_results,
            },
            PhysicsQueryFilter::new(),
            Some(&scratch),
        );
        per_query_ns.push(started.elapsed().as_nanos() as u64);
        total_hits += result.0.len() as i64;
        node_visits += result.1.node_visits;
        leaf_tests += result.1.leaf_tests;
        narrow_phase_tests += result.1.narrow_phase_tests;
    }

    let total_ns: u64 = per_query_ns.iter().sum();
    let mut sorted = per_query_ns;
    sorted.sort_unstable();
    let (p50, p95, p99) = percentiles(&sorted);
    let label = if max_results == usize::MAX {
        "[Overlap]".to_string()
    } else {
        format!("[Overlap maxResults={max_results}]")
    };
    println!(
        "{} queries={} elapsed_ms={} avg_hits={} avg_node_visits={} avg_leaf_tests={} avg_narrow_phase={} p50={}µs p95={}µs p99={}µs",
        label,
        query_count,
        fmt_ms(total_ns as f64),
        fmt_avg(total_hits, query_count),
        fmt_avg(node_visits, query_count),
        fmt_avg(leaf_tests, query_count),
        fmt_avg(narrow_phase_tests, query_count),
        fmt_us(p50),
        fmt_us(p95),
        fmt_us(p99),
    );
}

fn benchmark_sweep(runtime: &mut SceneRuntime, query_count: usize) {
    let scratch = SpatialQueryScratch::new(); // reused across all queries
    let mut node_visits: i64 = 0;
    let mut leaf_tests: i64 = 0;
    let mut narrow_phase_tests: i64 = 0;
    let mut hit_count: i64 = 0;
    let mut per_query_ns: Vec<u64> = Vec::with_capacity(query_count);

    for query_index in 0..query_count {
        let center = Float3::new(
            (query_index % 100) as f32 * 0.9 - 10.0,
            ((query_index / 100) % 50) as f32 * 0.9 - 5.0,
            -10.0,
        );
        let started = Instant::now();
        let result = runtime.physics_sweep_aabb_with_stats(
            PhysicsSweepAABBQuery::new(
                SpatialAABB::from_center_half_extents(center, Float3::new(0.3, 0.3, 0.3)),
                Float3::new(0.0, 0.0, 60.0),
            ),
            PhysicsQueryFilter::new(),
            Some(&scratch),
        );
        per_query_ns.push(started.elapsed().as_nanos() as u64);
        if result.0.is_some() {
            hit_count += 1;
        }
        node_visits += result.1.node_visits;
        leaf_tests += result.1.leaf_tests;
        narrow_phase_tests += result.1.narrow_phase_tests;
    }

    let total_ns: u64 = per_query_ns.iter().sum();
    let mut sorted = per_query_ns;
    sorted.sort_unstable();
    let (p50, p95, p99) = percentiles(&sorted);
    println!(
        "[Sweep] queries={} elapsed_ms={} hit_count={} avg_node_visits={} avg_leaf_tests={} avg_narrow_phase={} p50={}µs p95={}µs p99={}µs",
        query_count,
        fmt_ms(total_ns as f64),
        hit_count,
        fmt_avg(node_visits, query_count),
        fmt_avg(leaf_tests, query_count),
        fmt_avg(narrow_phase_tests, query_count),
        fmt_us(p50),
        fmt_us(p95),
        fmt_us(p99),
    );
}

fn run() {
    let config = BenchmarkConfig::default();
    let mut runtime = make_runtime(config.entity_count);
    println!(
        "SceneRuntimeBenchmarks entity_count={} query_count={}",
        config.entity_count, config.query_count
    );
    benchmark_raycast(&mut runtime, config.query_count);
    benchmark_overlap(&mut runtime, config.query_count, usize::MAX);
    benchmark_overlap(&mut runtime, config.query_count, 4);
    benchmark_sweep(&mut runtime, config.query_count);
}

fn main() {
    let mut logging_configuration = LoggingConfiguration::default();
    let environment: BTreeMap<String, String> = std::env::vars().collect();
    logging_configuration
        .apply_environment(&environment)
        .expect("logging configuration");
    LogSystem::bootstrap(None, logging_configuration, None).expect("logging bootstrap");

    run();

    LogSystem::flush();
}
