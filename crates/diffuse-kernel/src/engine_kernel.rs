//! `EngineKernel` — the frame-phase contract the engine host drives.

use crate::input_event::InputEvent;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EngineKernelPhase {
    Boot,
    Input,
    Simulation,
    Script,
    RenderPrepare,
    RenderSubmit,
}

impl EngineKernelPhase {
    /// Swift's `CaseIterable` order.
    pub const ALL: [EngineKernelPhase; 6] = [
        EngineKernelPhase::Boot,
        EngineKernelPhase::Input,
        EngineKernelPhase::Simulation,
        EngineKernelPhase::Script,
        EngineKernelPhase::RenderPrepare,
        EngineKernelPhase::RenderSubmit,
    ];
}

#[derive(Clone, Debug, PartialEq)]
pub struct EngineKernelPhaseContext {
    pub frame_index: u64,
    pub delta_time: f64,
    pub input_events: Vec<InputEvent>,
}

impl EngineKernelPhaseContext {
    #[inline]
    pub fn new(frame_index: u64, delta_time: f64, input_events: Vec<InputEvent>) -> Self {
        EngineKernelPhaseContext {
            frame_index,
            delta_time,
            input_events,
        }
    }
}

impl Default for EngineKernelPhaseContext {
    fn default() -> Self {
        EngineKernelPhaseContext {
            frame_index: 0,
            delta_time: 0.0,
            input_events: Vec::new(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct EngineKernelFrameReport {
    pub frame_index: u64,
    pub phase: EngineKernelPhase,
    pub phase_count: usize,
    pub input_event_count: usize,
}

impl EngineKernelFrameReport {
    #[inline]
    pub fn new(
        frame_index: u64,
        phase: EngineKernelPhase,
        phase_count: usize,
        input_event_count: usize,
    ) -> Self {
        EngineKernelFrameReport {
            frame_index,
            phase,
            phase_count,
            input_event_count,
        }
    }

    /// Matches Swift's `inputEventCount` default of 0.
    #[inline]
    pub fn with_counts(frame_index: u64, phase: EngineKernelPhase, phase_count: usize) -> Self {
        Self::new(frame_index, phase, phase_count, 0)
    }
}

pub trait EngineKernel {
    fn boot(&mut self);
    fn tick(
        &mut self,
        phase: EngineKernelPhase,
        context: EngineKernelPhaseContext,
    ) -> EngineKernelFrameReport;
    fn shutdown(&mut self);
}
