//! Ported from `Engine/Tests/EngineCoreTests/JobSystemTests.swift`.

use diffuse_kernel::job_system::{JobDispatchReport, JobSystem};

/// `parallelMap` preserves input order and reports parallel dispatch.
#[test]
fn parallel_map_preserves_order_and_reports_dispatch() {
    let job_system = JobSystem::new(4, 1);
    let items: Vec<i32> = (0..8).collect();

    let (values, report) = job_system.parallel_map(&items, Some(1), |value| value * value);

    assert_eq!(values, vec![0, 1, 4, 9, 16, 25, 36, 49]);
    assert_eq!(report.job_count, 4);
    assert_eq!(report.worker_count, 4);
    assert!(report.executed_in_parallel);
}

/// `JobDispatchReport` merges job counts and parallel state.
#[test]
fn job_dispatch_report_merges_counts_and_parallel_state() {
    let report = JobDispatchReport::merged(
        &[
            JobDispatchReport::new(1, 2, false),
            JobDispatchReport::new(3, 2, true),
        ],
        2,
    );

    assert_eq!(report.job_count, 4);
    assert_eq!(report.worker_count, 2);
    assert!(report.executed_in_parallel);
}
