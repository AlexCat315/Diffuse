//! Translation of
//! Editor/Sources/EditorCore/Editing/Viewport/EditorViewportInputController.swift.
//!
//! 视口相机拖拽 / 选择状态的全局持有者。
//! `ViewportPanel.handleViewportInput` 是值类型 view body 里的临时方法，
//! 没法持有状态；这里用单例承接跨事件的轻量上下文。

use std::collections::BTreeSet;
use std::sync::{Mutex, MutexGuard, OnceLock};

use diffuse_kernel::input_event::{KeyModifiers, MouseButton};
use diffuse_math::simd::simd_compat::Float4x4;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CameraDrag {
    Orbit,
    Pan,
    Dolly,
    Freelook,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActiveInteraction {
    PendingClick {
        button: MouseButton,
    },
    Camera {
        drag: CameraDrag,
        button: MouseButton,
    },
    Gizmo {
        button: MouseButton,
    },
    Marquee {
        button: MouseButton,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub struct GizmoGroupTarget {
    pub entity_id: u64,
    pub start_world_matrix: Float4x4,
    pub parent_inverse_matrix: Float4x4,
}

impl GizmoGroupTarget {
    pub fn new(
        entity_id: u64,
        start_world_matrix: Float4x4,
        parent_inverse_matrix: Float4x4,
    ) -> Self {
        GizmoGroupTarget {
            entity_id,
            start_world_matrix,
            parent_inverse_matrix,
        }
    }
}

#[derive(Default)]
struct InputState {
    active_camera_drag: Option<CameraDrag>,
    active_interaction: Option<ActiveInteraction>,
    last_cursor: Option<(f32, f32)>,
    left_down_at: Option<(f32, f32)>,
    marquee_start: Option<(f32, f32)>,
    marquee_current: Option<(f32, f32)>,
    modifiers: KeyModifiers,
    pressed_scancodes: BTreeSet<u32>,
    gizmo_group_targets: Vec<GizmoGroupTarget>,
}

pub struct EditorViewportInputController {
    state: Mutex<InputState>,
}

impl Default for EditorViewportInputController {
    fn default() -> Self {
        Self::new()
    }
}

impl EditorViewportInputController {
    fn new() -> Self {
        EditorViewportInputController {
            state: Mutex::new(InputState::default()),
        }
    }

    pub fn shared() -> &'static EditorViewportInputController {
        static SHARED: OnceLock<EditorViewportInputController> = OnceLock::new();
        SHARED.get_or_init(EditorViewportInputController::new)
    }

    fn state(&self) -> MutexGuard<'_, InputState> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn active_camera_drag(&self) -> Option<CameraDrag> {
        self.state().active_camera_drag
    }

    pub fn set_active_camera_drag(&self, value: Option<CameraDrag>) {
        self.state().active_camera_drag = value;
    }

    pub fn active_interaction(&self) -> Option<ActiveInteraction> {
        self.state().active_interaction
    }

    pub fn set_active_interaction(&self, value: Option<ActiveInteraction>) {
        self.state().active_interaction = value;
    }

    pub fn last_cursor(&self) -> Option<(f32, f32)> {
        self.state().last_cursor
    }

    pub fn set_last_cursor(&self, value: Option<(f32, f32)>) {
        self.state().last_cursor = value;
    }

    /// 鼠标按下时记录起点，以便释放时判断是否算 "click" 触发拾取。
    pub fn left_down_at(&self) -> Option<(f32, f32)> {
        self.state().left_down_at
    }

    pub fn set_left_down_at(&self, value: Option<(f32, f32)>) {
        self.state().left_down_at = value;
    }

    pub fn marquee_start(&self) -> Option<(f32, f32)> {
        self.state().marquee_start
    }

    pub fn set_marquee_start(&self, value: Option<(f32, f32)>) {
        self.state().marquee_start = value;
    }

    pub fn marquee_current(&self) -> Option<(f32, f32)> {
        self.state().marquee_current
    }

    pub fn set_marquee_current(&self, value: Option<(f32, f32)>) {
        self.state().marquee_current = value;
    }

    pub fn modifiers(&self) -> KeyModifiers {
        self.state().modifiers
    }

    pub fn set_modifiers(&self, value: KeyModifiers) {
        self.state().modifiers = value;
    }

    pub fn pressed_scancodes(&self) -> BTreeSet<u32> {
        self.state().pressed_scancodes.clone()
    }

    pub fn set_pressed_scancodes(&self, value: BTreeSet<u32>) {
        self.state().pressed_scancodes = value;
    }

    pub fn gizmo_group_targets(&self) -> Vec<GizmoGroupTarget> {
        self.state().gizmo_group_targets.clone()
    }

    pub fn set_gizmo_group_targets(&self, value: Vec<GizmoGroupTarget>) {
        self.state().gizmo_group_targets = value;
    }

    pub fn has_active_pointer_session(&self) -> bool {
        self.state().active_interaction.is_some()
    }

    /// True while the scene re-renders continuously (camera or gizmo drags) —
    /// the window where interaction downscale pays off. Clicks and marquee
    /// selection leave the camera static, so they stay full-res.
    pub fn is_continuous_scene_interaction_active(&self) -> bool {
        matches!(
            self.state().active_interaction,
            Some(ActiveInteraction::Camera { .. }) | Some(ActiveInteraction::Gizmo { .. })
        )
    }

    pub fn has_freelook_movement_input(&self) -> bool {
        let state = self.state();
        state.active_camera_drag == Some(CameraDrag::Freelook)
            && state
                .pressed_scancodes
                .iter()
                .any(|scancode| Self::FREELOOK_MOVEMENT_SCANCODES.contains(scancode))
    }

    const FREELOOK_MOVEMENT_SCANCODES: [u32; 6] = [
        4,  // A
        7,  // D
        8,  // E
        20, // Q
        22, // S
        26, // W
    ];

    pub fn begin(&self, interaction: ActiveInteraction, at: (f32, f32), modifiers: KeyModifiers) {
        let mut state = self.state();
        state.active_interaction = Some(interaction);
        state.modifiers = modifiers;
        state.last_cursor = Some(at);
        state.left_down_at = Some(at);
        state.marquee_start = None;
        state.marquee_current = None;
        state.active_camera_drag = match interaction {
            ActiveInteraction::Camera { drag, .. } => Some(drag),
            _ => None,
        };
    }

    pub fn end_pointer_session(&self, keeping_keyboard_state: bool) {
        let mut state = self.state();
        state.active_interaction = None;
        state.active_camera_drag = None;
        state.last_cursor = None;
        state.left_down_at = None;
        state.marquee_start = None;
        state.marquee_current = None;
        state.gizmo_group_targets.clear();
        if !keeping_keyboard_state {
            state.modifiers = KeyModifiers::default();
            state.pressed_scancodes.clear();
        }
    }

    /// `endPointerSession(keepingKeyboardState:)` with Swift's default.
    pub fn end_pointer_session_default(&self) {
        self.end_pointer_session(true);
    }

    pub fn reset(&self) {
        self.end_pointer_session(false);
        let mut state = self.state();
        state.active_interaction = None;
        state.modifiers = KeyModifiers::default();
        state.pressed_scancodes.clear();
        state.gizmo_group_targets.clear();
    }
}
