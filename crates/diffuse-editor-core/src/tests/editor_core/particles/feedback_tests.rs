//! Ported from `Editor/Tests/EditorCoreTests/Particles/FeedbackTests.swift`.

/// Readback counters reach the editor's particle report on the next tick.
#[test]
fn readback_report() {
    use diffuse_scene::components::core::registry::ComponentRegistry;

    use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
    use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

    let adapter = EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::new(),
    );
    adapter.make_particle_simulation_feedback_handler()(&[snapshot()]);
    adapter.tick_scene_default();

    let report = adapter.current_particle_simulation_event_apply_report();
    assert_eq!(report.total_readback_event_count, 9);
    assert_eq!(report.dropped_readback_event_count, 1);
    assert_eq!(report.gpu_alive_particle_count, 8);
    assert_eq!(report.gpu_expired_particle_count, 2);
    assert_eq!(report.gpu_collision_event_count, 3);
    assert_eq!(report.gpu_spawned_particle_count, 4);
    assert_eq!(report.gpu_dropped_spawn_count, 5);
    assert_eq!(report.gpu_compacted_particle_count, 6);
}

/// Scene replacement discards queued and late callbacks, but a handler created
/// afterwards still reports.
#[test]
fn invalidated_feedback() {
    use diffuse_scene::components::core::registry::ComponentRegistry;
    use diffuse_scene::particles::particle_simulation_event_apply_report::ParticleSimulationEventApplyReport;

    use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
    use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

    for operation in ["reset", "load", "undo", "edit"] {
        let adapter = EditorSceneAdapter::new(
            false,
            ComponentRegistry::built_in(),
            EditorInspectorRendererRegistry::new(),
        );
        let entity = adapter.with_scene_mut(|scene| scene.create_entity());
        adapter.reset_edit_history();
        if operation == "undo" {
            assert!(
                adapter.add_component("light", entity.raw_value()),
                "{operation}: add light"
            );
        }

        let handler = adapter.make_particle_simulation_feedback_handler();
        handler(&[snapshot()]);
        adapter.tick_scene_default();
        assert_eq!(
            adapter
                .current_particle_simulation_event_apply_report()
                .total_readback_event_count,
            9,
            "{operation}: first report"
        );

        // Queued feedback from the previous authored scene.
        handler(&[snapshot()]);
        match operation {
            "reset" => adapter.reset_to_preview_scene(),
            "load" => assert!(
                adapter.load(&adapter.manifest()).succeeded(),
                "{operation}: load"
            ),
            "undo" => assert!(adapter.undo_edit(), "{operation}: undo"),
            _ => assert!(
                adapter.add_component("light", entity.raw_value()),
                "{operation}: edit"
            ),
        }
        assert_eq!(
            adapter.current_particle_simulation_event_apply_report(),
            ParticleSimulationEventApplyReport::empty(),
            "{operation}: replacement clears the report"
        );

        // A render-thread callback can arrive after replacement.
        handler(&[snapshot()]);
        adapter.tick_scene_default();
        assert_eq!(
            adapter.current_particle_simulation_event_apply_report(),
            ParticleSimulationEventApplyReport::empty(),
            "{operation}: late callback is discarded"
        );

        adapter.make_particle_simulation_feedback_handler()(&[snapshot()]);
        adapter.tick_scene_default();
        assert_eq!(
            adapter
                .current_particle_simulation_event_apply_report()
                .total_readback_event_count,
            9,
            "{operation}: new handler reports"
        );
    }
}

fn snapshot() -> diffuse_render::core::render_stats::GPUParticleSimulationEventSnapshot {
    use diffuse_render::core::render_stats::GPUParticleSimulationEventSnapshot;

    GPUParticleSimulationEventSnapshot::new(0, None, 8, 9, 1, Vec::new(), 8, 2, 3, 4, 5, 6)
}
