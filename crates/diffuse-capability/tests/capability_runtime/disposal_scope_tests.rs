//! `DisposalScopeTests` — Swift suite `Disposal scope`.
//!
//! Swift used actors, `Task` and `CheckedContinuation`; MIGRATION.md §5.5 maps
//! those to threads and mutexes, so this suite exercises the same guarantees
//! with plain concurrent threads.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use diffuse_capability::support::disposal::{DisposalScope, Registration};

#[derive(Clone, Default)]
struct OrderLog(Arc<Mutex<Vec<i32>>>);

impl OrderLog {
    fn record(&self, value: i32) {
        self.0.lock().expect("order log").push(value);
    }

    fn values(&self) -> Vec<i32> {
        self.0.lock().expect("order log").clone()
    }
}

// "disposeAll unwinds registrations in reverse order"
#[test]
fn reverse_order() {
    let log = OrderLog::default();
    let scope = DisposalScope::new();
    for index in 1..=3 {
        let log = log.clone();
        scope.track(move || log.record(index));
    }
    scope.dispose_all();
    assert_eq!(log.values(), vec![3, 2, 1]);
}

// "a registration disposes exactly once across early disposal and scope unwind"
#[test]
fn disposes_exactly_once() {
    let log = OrderLog::default();
    let scope = DisposalScope::new();
    let first = {
        let log = log.clone();
        scope.track(move || log.record(1))
    };
    {
        let log = log.clone();
        scope.track(move || log.record(2));
    }

    first.dispose();
    first.dispose();
    scope.dispose_all();
    scope.dispose_all();

    assert_eq!(log.values(), vec![1, 2]);
}

// "scope stays usable after unwinding and accepts transferred handles"
#[test]
fn reusable_and_transfers_handles() {
    let log = OrderLog::default();
    let scope = DisposalScope::new();
    scope.dispose_all();

    let borrowed = {
        let log = log.clone();
        Arc::new(Registration::new(move || log.record(7)))
    };
    scope.track_registration(borrowed);
    scope.dispose_all();

    assert_eq!(log.values(), vec![7]);
}

// "concurrent tracking never loses a registration"
#[test]
fn concurrent_tracking() {
    let log = OrderLog::default();
    let scope = Arc::new(DisposalScope::new());
    std::thread::scope(|threads| {
        for index in 0..64 {
            let scope = scope.clone();
            let log = log.clone();
            threads.spawn(move || {
                scope.track(move || log.record(index));
            });
        }
    });
    scope.dispose_all();
    let values = log.values();
    assert_eq!(values.len(), 64);
    let unique: std::collections::BTreeSet<i32> = values.into_iter().collect();
    assert_eq!(unique, (0..64).collect());
}

// "tracking after an unwind belongs to the next generation"
#[test]
fn tracking_after_unwind_is_not_disposed_by_earlier_call() {
    let log = OrderLog::default();
    let scope = DisposalScope::new();
    {
        let log = log.clone();
        scope.track(move || log.record(1));
    }
    scope.dispose_all();

    {
        let log = log.clone();
        scope.track(move || log.record(2));
    }
    assert_eq!(log.values(), vec![1]);

    scope.dispose_all();
    assert_eq!(log.values(), vec![1, 2]);
}

// "concurrent disposal waits for teardown and serializes generations"
#[test]
fn concurrent_disposal_waits_for_completion() {
    let log = OrderLog::default();
    let scope = Arc::new(DisposalScope::new());
    let started = Arc::new(AtomicUsize::new(0));
    let release = Arc::new(std::sync::Barrier::new(2));

    let registration = {
        let log = log.clone();
        let started = started.clone();
        let release = release.clone();
        scope.track(move || {
            started.fetch_add(1, Ordering::SeqCst);
            // Swift's Barrier.hold() waited for the test to observe the start.
            release.wait();
            log.record(1);
        })
    };

    let first = {
        let scope = scope.clone();
        std::thread::spawn(move || scope.dispose_all())
    };
    while started.load(Ordering::SeqCst) == 0 {
        std::thread::yield_now();
    }
    let second = {
        let log = log.clone();
        std::thread::spawn(move || {
            registration.dispose();
            log.record(2);
        })
    };
    {
        let log = log.clone();
        scope.track(move || log.record(3));
    }
    let next_generation = {
        let scope = scope.clone();
        std::thread::spawn(move || scope.dispose_all())
    };

    release.wait();
    first.join().expect("first disposal");
    second.join().expect("second disposal");
    next_generation.join().expect("next generation disposal");

    let values = log.values();
    // The property under test is that `dispose()` waits for the teardown it did not
    // start: entry 1 must be recorded before entry 2. Entry 3 belongs to the next
    // generation and may interleave with either, exactly as Swift's concurrent
    // `Task` scheduling allowed.
    let position_of_one = values
        .iter()
        .position(|value| *value == 1)
        .expect("teardown ran");
    let position_of_two = values
        .iter()
        .position(|value| *value == 2)
        .expect("second dispose ran");
    assert!(
        position_of_one < position_of_two,
        "dispose must wait for the running teardown"
    );
    let unique: std::collections::BTreeSet<i32> = values.into_iter().collect();
    assert_eq!(unique, [1, 2, 3].into_iter().collect());
}
