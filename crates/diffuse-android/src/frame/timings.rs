//! Translation of Android/CoveAndroidApp/Frame/Timings.swift.

use cove_logging::{Level, LogEvent, LogSystem};
use std::collections::HashMap;
use std::time::Instant;

/// Bounded CPU wall-clock samples. Queue and presentation may include waiting;
/// none of these values claim to measure GPU execution or displayed frames.
pub struct FrameTimings {
    enabled: bool,
    samples: usize,
    start: Instant,
    phases: HashMap<Phase, u64>,
}

impl FrameTimings {
    const SAMPLE_LIMIT: usize = 6000;

    pub fn new(enabled: bool) -> Self {
        Self {
            enabled,
            samples: 0,
            start: Instant::now(),
            phases: HashMap::new(),
        }
    }

    pub fn is_sampling(&self) -> bool {
        self.enabled && self.samples < Self::SAMPLE_LIMIT
    }

    pub fn begin(&mut self) {
        if !self.is_sampling() {
            return;
        }
        self.start = Instant::now();
        self.phases.clear();
    }

    /// Times `operation` and charges the elapsed nanoseconds to `phase`. The
    /// charge is recorded through `Drop`, matching the Swift `defer`.
    pub fn measure<T>(&mut self, phase: Phase, operation: impl FnOnce() -> T) -> T {
        if !self.is_sampling() {
            return operation();
        }
        struct Record<'a> {
            phases: &'a mut HashMap<Phase, u64>,
            phase: Phase,
            before: Instant,
        }
        impl Drop for Record<'_> {
            fn drop(&mut self) {
                *self.phases.entry(self.phase).or_insert(0) +=
                    self.before.elapsed().as_nanos() as u64;
            }
        }
        let record = Record {
            phases: &mut self.phases,
            phase,
            before: Instant::now(),
        };
        let value = operation();
        drop(record);
        value
    }

    pub fn finish(&mut self, timestamp: u64, vertices: usize, indices: usize) {
        if !self.is_sampling() {
            return;
        }
        let total = self.start.elapsed().as_nanos() as u64;
        self.samples += 1;
        let values = Phase::ALL
            .iter()
            .map(|phase| {
                format!(
                    "{}={}ms",
                    phase.raw_value(),
                    Self::milliseconds(*self.phases.get(phase).unwrap_or(&0))
                )
            })
            .collect::<Vec<_>>()
            .join(" ");
        LogSystem::logger("com.cove.android.timing").log(&LogEvent::new(
            Level::Info,
            format!(
                "[timing] android.frame sample={} displayTime={} {} total={}ms vertices={} indices={}",
                self.samples,
                timestamp,
                values,
                Self::milliseconds(total),
                vertices,
                indices
            ),
        ));
    }

    fn milliseconds(duration: u64) -> String {
        format!("{:.3}", duration as f64 / 1_000_000.0)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Phase {
    ScenePrepare,
    FrameSlot,
    DrawableAcquire,
    AtlasUpload,
    CommandRecord,
    QueueSubmit,
    Present,
}

impl Phase {
    pub const ALL: [Self; 7] = [
        Self::ScenePrepare,
        Self::FrameSlot,
        Self::DrawableAcquire,
        Self::AtlasUpload,
        Self::CommandRecord,
        Self::QueueSubmit,
        Self::Present,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::ScenePrepare => "scenePrepare",
            Self::FrameSlot => "frameSlot",
            Self::DrawableAcquire => "drawableAcquire",
            Self::AtlasUpload => "atlasUpload",
            Self::CommandRecord => "commandRecord",
            Self::QueueSubmit => "queueSubmit",
            Self::Present => "present",
        }
    }
}
