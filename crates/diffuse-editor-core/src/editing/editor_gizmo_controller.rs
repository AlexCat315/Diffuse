//! Translation of Editor/Sources/EditorCore/Editing/EditorGizmoController.swift.
//!
//! Viewport 3D gizmo drag state and hit testing for translate / rotate / scale.
//!
//! `ViewportPanel` calls `update_snapshot` every frame with the camera, screen
//! frame, selected entity world position and local matrix; pointer and draw
//! callbacks hit-test through `EditorGizmoController::shared()` and receive a
//! new `LocalTransform` matrix.

use std::f32::consts::PI;
use std::sync::{Mutex, MutexGuard, OnceLock};

use diffuse_math::simd::simd_compat::{
    Float3, Float3x3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4, simd_cross, simd_dot,
    simd_inverse, simd_length, simd_normalize,
};
use diffuse_scene::rendering::render_scene::{RenderCamera, RenderCameraProjection};

use crate::editing::viewport::editor_viewport_projection::EditorViewportProjection;
use crate::rendering::viewport::viewport_host::ViewportScreenFrame;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GizmoMode {
    Translate,
    Rotate,
    Scale,
}

/// Gizmo 轴向空间：
/// - `Local`：三轴随物体旋转（Maya/Blender/Unity 默认）。
/// - `World`：三轴始终对齐世界轴。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GizmoSpace {
    Local,
    World,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GizmoAxis {
    X,
    Y,
    Z,
}

impl GizmoAxis {
    pub const ALL: [GizmoAxis; 3] = [GizmoAxis::X, GizmoAxis::Y, GizmoAxis::Z];

    pub fn world_direction(self) -> Float3 {
        match self {
            GizmoAxis::X => Float3::new(1.0, 0.0, 0.0),
            GizmoAxis::Y => Float3::new(0.0, 1.0, 0.0),
            GizmoAxis::Z => Float3::new(0.0, 0.0, 1.0),
        }
    }

    pub fn color(self) -> Float4 {
        match self {
            GizmoAxis::X => Float4::new(0.95, 0.27, 0.34, 1.0),
            GizmoAxis::Y => Float4::new(0.36, 0.86, 0.41, 1.0),
            GizmoAxis::Z => Float4::new(0.34, 0.58, 0.95, 1.0),
        }
    }

    /// 在该轴对应的旋转平面（即垂直于该轴的平面）里的两个正交基向量：
    /// 用来在世界空间画圆 / 计算角度。
    pub fn plane_basis(self) -> (Float3, Float3) {
        match self {
            GizmoAxis::X => (Float3::new(0.0, 1.0, 0.0), Float3::new(0.0, 0.0, 1.0)),
            GizmoAxis::Y => (Float3::new(0.0, 0.0, 1.0), Float3::new(1.0, 0.0, 0.0)),
            GizmoAxis::Z => (Float3::new(1.0, 0.0, 0.0), Float3::new(0.0, 1.0, 0.0)),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GizmoPlane {
    Xy,
    Yz,
    Zx,
}

impl GizmoPlane {
    pub const ALL: [GizmoPlane; 3] = [GizmoPlane::Xy, GizmoPlane::Yz, GizmoPlane::Zx];

    /// 平面里的两个正交世界基向量（U, V）。
    pub fn basis(self) -> (Float3, Float3) {
        match self {
            GizmoPlane::Xy => (Float3::new(1.0, 0.0, 0.0), Float3::new(0.0, 1.0, 0.0)),
            GizmoPlane::Yz => (Float3::new(0.0, 1.0, 0.0), Float3::new(0.0, 0.0, 1.0)),
            GizmoPlane::Zx => (Float3::new(0.0, 0.0, 1.0), Float3::new(1.0, 0.0, 0.0)),
        }
    }

    /// 平面法向量（指向另一根世界轴）。
    pub fn normal(self) -> Float3 {
        match self {
            GizmoPlane::Xy => Float3::new(0.0, 0.0, 1.0),
            GizmoPlane::Yz => Float3::new(1.0, 0.0, 0.0),
            GizmoPlane::Zx => Float3::new(0.0, 1.0, 0.0),
        }
    }

    /// 平面手柄的填充色：取另一根世界轴的颜色，便于和轴线区分。
    pub fn color(self) -> Float4 {
        match self {
            GizmoPlane::Xy => GizmoAxis::Z.color(),
            GizmoPlane::Yz => GizmoAxis::X.color(),
            GizmoPlane::Zx => GizmoAxis::Y.color(),
        }
    }
}

/// 平面手柄的两轴 + 法线。
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GizmoPlaneAxes {
    pub basis_u: Float3,
    pub basis_v: Float3,
    pub normal: Float3,
}

/// All screen-space math runs in the logical `frame` coordinates; the
/// engine's pixel resolution (render scale, HiDPI) never enters here.
#[derive(Clone, Debug)]
pub struct GizmoSnapshot {
    pub mode: GizmoMode,
    pub space: GizmoSpace,
    pub camera: RenderCamera,
    pub frame: ViewportScreenFrame,
    pub entity_id: u64,
    pub entity_world_position: Float3,
    pub entity_world_matrix: Float4x4,
    pub entity_local_matrix: Float4x4,
    pub parent_world_matrix: Float4x4,
    pub axis_length: f32,
}

impl GizmoSnapshot {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        mode: GizmoMode,
        space: GizmoSpace,
        camera: RenderCamera,
        frame: ViewportScreenFrame,
        entity_id: u64,
        entity_world_position: Float3,
        entity_world_matrix: Float4x4,
        entity_local_matrix: Float4x4,
        parent_world_matrix: Float4x4,
        axis_length: f32,
    ) -> Self {
        GizmoSnapshot {
            mode,
            space,
            camera,
            frame,
            entity_id,
            entity_world_position,
            entity_world_matrix,
            entity_local_matrix,
            parent_world_matrix,
            axis_length,
        }
    }

    /// 当前 gizmo 轴在世界空间里的单位向量。`Local` 下从实体世界矩阵取列并归一化，
    /// `World` 下返回原始世界轴。
    pub fn axis_world(&self, axis: GizmoAxis) -> Float3 {
        match self.space {
            GizmoSpace::World => axis.world_direction(),
            GizmoSpace::Local => {
                let column = match axis {
                    GizmoAxis::X => self.entity_world_matrix.columns[0],
                    GizmoAxis::Y => self.entity_world_matrix.columns[1],
                    GizmoAxis::Z => self.entity_world_matrix.columns[2],
                };
                let v = Float3::new(column.x, column.y, column.z);
                let len = simd_length(v);
                if len > 1e-5 {
                    v / len
                } else {
                    axis.world_direction()
                }
            }
        }
    }

    /// 为“以 axis 为法线”的平面（用于旋转环）提供两个世界空间正交基向量。
    pub fn plane_basis_for_rotate_axis(&self, axis: GizmoAxis) -> (Float3, Float3) {
        let n = self.axis_world(axis);
        let other = if axis == GizmoAxis::X {
            GizmoAxis::Y
        } else {
            GizmoAxis::X
        };
        let mut u = self.axis_world(other);
        u = u - n * simd_dot(u, n);
        if simd_length(u) < 1e-5 {
            let fallback = if n.y.abs() < 0.9 {
                Float3::new(0.0, 1.0, 0.0)
            } else {
                Float3::new(1.0, 0.0, 0.0)
            };
            u = fallback - n * simd_dot(fallback, n);
        }
        u = simd_normalize(u);
        let v = simd_normalize(simd_cross(n, u));
        (u, v)
    }

    /// 平面手柄的两轴 + 法线。
    pub fn plane_axes(&self, plane: GizmoPlane) -> GizmoPlaneAxes {
        match plane {
            GizmoPlane::Xy => GizmoPlaneAxes {
                basis_u: self.axis_world(GizmoAxis::X),
                basis_v: self.axis_world(GizmoAxis::Y),
                normal: self.axis_world(GizmoAxis::Z),
            },
            GizmoPlane::Yz => GizmoPlaneAxes {
                basis_u: self.axis_world(GizmoAxis::Y),
                basis_v: self.axis_world(GizmoAxis::Z),
                normal: self.axis_world(GizmoAxis::X),
            },
            GizmoPlane::Zx => GizmoPlaneAxes {
                basis_u: self.axis_world(GizmoAxis::Z),
                basis_v: self.axis_world(GizmoAxis::X),
                normal: self.axis_world(GizmoAxis::Y),
            },
        }
    }

    /// 摄像机 forward 向量（从 eye 指向 target，已归一化）。
    pub fn camera_forward(&self) -> Float3 {
        let raw = self.camera.target - self.camera.eye;
        let len = simd_length(raw);
        if len > 1e-5 {
            raw / len
        } else {
            Float3::new(0.0, 0.0, -1.0)
        }
    }
}

#[derive(Clone, Debug)]
pub struct ActiveGizmoDrag {
    pub entity_id: u64,
    pub mode: GizmoMode,
    pub axis: GizmoAxis,
    pub plane: Option<GizmoPlane>,
    pub start_entity_world_position: Float3,
    pub start_entity_local_matrix: Float4x4,
    pub start_entity_world_matrix: Float4x4,
    pub parent_world_matrix: Float4x4,
    pub parent_inverse_matrix: Float4x4,
    // 拖拽时使用的“有效轴世界向量”（考虑 gizmoSpace）。
    pub axis_world: Float3,
    // 所有拖拽数学都基于“射线/平面相交”：
    // - translate axis: plane = 含 axis 并尽量面向摄像机（axis × (forward × axis)）。
    // - translate plane: plane normal = 平面手柄法线。
    // - rotate: plane normal = handle axis。
    // - scale axis: 同 translate axis。
    pub plane_origin: Float3,
    pub plane_normal: Float3,
    pub start_plane_hit: Float3,
    // rotate: 起始径向向量（在 plane 上，已归一化）
    pub start_radial: Float3,
    // free center handles use the camera-facing plane rather than a single axis.
    pub is_free: bool,
    pub uniform_scale_start_distance: f32,
    // 拖拽时的 gizmo 远近 reference 长度（用于 scale 升压）
    pub reference_length: f32,
}

#[derive(Default)]
struct GizmoState {
    snapshot: Option<GizmoSnapshot>,
    active_drag: Option<ActiveGizmoDrag>,
}

pub struct EditorGizmoController {
    state: Mutex<GizmoState>,
}

impl Default for EditorGizmoController {
    fn default() -> Self {
        Self::new()
    }
}

impl EditorGizmoController {
    pub fn new() -> Self {
        EditorGizmoController {
            state: Mutex::new(GizmoState::default()),
        }
    }

    pub fn shared() -> &'static EditorGizmoController {
        static SHARED: OnceLock<EditorGizmoController> = OnceLock::new();
        SHARED.get_or_init(EditorGizmoController::new)
    }

    fn state(&self) -> MutexGuard<'_, GizmoState> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn snapshot(&self) -> Option<GizmoSnapshot> {
        self.state().snapshot.clone()
    }

    pub fn active_drag(&self) -> Option<ActiveGizmoDrag> {
        self.state().active_drag.clone()
    }

    pub fn update_snapshot(&self, snapshot: Option<GizmoSnapshot>) {
        let mut state = self.state();
        let cleared = match (&state.active_drag, snapshot.as_ref()) {
            (Some(drag), Some(snapshot)) => {
                drag.entity_id != snapshot.entity_id || drag.mode != snapshot.mode
            }
            (Some(_), None) => true,
            (None, _) => false,
        };
        state.snapshot = snapshot;
        if cleared {
            state.active_drag = None;
        }
    }

    pub fn clear_drag(&self) {
        self.state().active_drag = None;
    }

    /// World length corresponding to a fixed logical screen size at the pivot.
    /// Drawing and hit testing consume the same length through the snapshot.
    pub fn axis_length(
        camera: &RenderCamera,
        position: Float3,
        viewport_height: f32,
        screen_length: f32,
    ) -> f32 {
        let visible_height = if camera.projection == RenderCameraProjection::Orthographic {
            RenderCamera::sanitized_orthographic_height(camera.orthographic_height)
        } else {
            let forward = camera.target - camera.eye;
            let length = simd_length(forward);
            let direction = if length > 1e-5 {
                forward / length
            } else {
                Float3::new(0.0, 0.0, -1.0)
            };
            let depth = camera.near.max(simd_dot(position - camera.eye, direction));
            2.0 * depth * (camera.fov_y_radians * 0.5).tan()
        };
        visible_height * screen_length / viewport_height.max(1.0)
    }

    /// `axisLength(camera:position:viewportHeight:)` with Swift's default.
    pub fn axis_length_default(
        camera: &RenderCamera,
        position: Float3,
        viewport_height: f32,
    ) -> f32 {
        Self::axis_length(camera, position, viewport_height, 96.0)
    }

    /// 统一构造 ActiveDrag，把 parent / world 矩阵、起始世界矩阵、平面参数一次性算好，
    /// 便于后续 update 把世界变换换算回本地空间。
    #[allow(clippy::too_many_arguments)]
    fn make_drag(
        &self,
        snap: &GizmoSnapshot,
        axis: GizmoAxis,
        plane: Option<GizmoPlane>,
        axis_world: Float3,
        plane_origin: Float3,
        plane_normal: Float3,
        start_plane_hit: Float3,
        start_radial: Float3,
        is_free: bool,
        uniform_scale_start_distance: f32,
    ) -> ActiveGizmoDrag {
        let parent_world = snap.parent_world_matrix;
        let parent_inverse = simd_inverse(parent_world);
        let start_world_matrix = parent_world * snap.entity_local_matrix;
        ActiveGizmoDrag {
            entity_id: snap.entity_id,
            mode: snap.mode,
            axis,
            plane,
            start_entity_world_position: snap.entity_world_position,
            start_entity_local_matrix: snap.entity_local_matrix,
            start_entity_world_matrix: start_world_matrix,
            parent_world_matrix: parent_world,
            parent_inverse_matrix: parent_inverse,
            axis_world,
            plane_origin,
            plane_normal,
            start_plane_hit,
            start_radial,
            is_free,
            uniform_scale_start_distance: uniform_scale_start_distance.max(0.05),
            reference_length: snap.axis_length.max(0.001),
        }
    }

    /// 命中测试：在屏幕坐标 `(x, y)` 处尝试命中某个轴。命中阈值
    /// `screenTolerance` 单位为像素（rotate 模式下在圆周附近的容差）。
    pub fn begin_drag(
        &self,
        cursor_x: f32,
        cursor_y: f32,
        screen_tolerance: f32,
    ) -> Option<ActiveGizmoDrag> {
        let snap = self.snapshot()?;
        let projector = ScreenProjector::new(&snap)?;

        match snap.mode {
            GizmoMode::Translate => {
                if let Some(drag) =
                    self.begin_center_drag(&snap, &projector, cursor_x, cursor_y, 20.0)
                {
                    return Some(drag);
                }
                self.begin_axis_drag(
                    &snap,
                    &projector,
                    cursor_x,
                    cursor_y,
                    screen_tolerance.max(18.0),
                )
            }
            GizmoMode::Scale => {
                if let Some(drag) =
                    self.begin_center_drag(&snap, &projector, cursor_x, cursor_y, 22.0)
                {
                    return Some(drag);
                }
                self.begin_axis_drag(
                    &snap,
                    &projector,
                    cursor_x,
                    cursor_y,
                    screen_tolerance.max(18.0),
                )
            }
            GizmoMode::Rotate => self.begin_rotate_drag(
                &snap,
                &projector,
                cursor_x,
                cursor_y,
                screen_tolerance.max(18.0),
            ),
        }
    }

    /// `beginDrag(cursorX:cursorY:)` with Swift's default tolerance.
    pub fn begin_drag_default(&self, cursor_x: f32, cursor_y: f32) -> Option<ActiveGizmoDrag> {
        self.begin_drag(cursor_x, cursor_y, 8.0)
    }

    /// 拖动中：根据当前光标位置返回新的 LocalTransform 矩阵。
    /// 返回 `None` 表示当前光标不再可解（例如视线与轴近平行）。
    pub fn update_drag(&self, cursor_x: f32, cursor_y: f32) -> Option<Float4x4> {
        let snap = self.snapshot()?;
        let drag = self.active_drag()?;
        let projector = ScreenProjector::new(&snap)?;
        let ray = projector.cursor_ray(cursor_x, cursor_y);

        match drag.mode {
            GizmoMode::Translate => {
                if drag.plane.is_some() {
                    return update_plane_translate_matrix(&drag, ray);
                }
                update_translate_matrix(&drag, ray)
            }
            GizmoMode::Scale => update_scale_matrix(&drag, ray),
            GizmoMode::Rotate => update_rotate_matrix(&drag, ray),
        }
    }

    fn begin_axis_drag(
        &self,
        snap: &GizmoSnapshot,
        projector: &ScreenProjector,
        cursor_x: f32,
        cursor_y: f32,
        screen_tolerance: f32,
    ) -> Option<ActiveGizmoDrag> {
        let origin_screen = projector.project(snap.entity_world_position)?;

        let mut best_axis: Option<GizmoAxis> = None;
        let mut best_distance = f32::INFINITY;
        for axis in GizmoAxis::ALL {
            let axis_dir = snap.axis_world(axis);
            let tip = snap.entity_world_position + axis_dir * snap.axis_length;
            let Some(tip_screen) = projector.project(tip) else {
                continue;
            };
            let distance = point_to_segment_distance(
                cursor_x,
                cursor_y,
                origin_screen.0,
                origin_screen.1,
                tip_screen.0,
                tip_screen.1,
            );
            if distance < best_distance {
                best_distance = distance;
                best_axis = Some(axis);
            }
        }

        let axis = best_axis?;
        if best_distance > screen_tolerance {
            return None;
        }
        let ray = projector.cursor_ray(cursor_x, cursor_y);

        let axis_world = snap.axis_world(axis);
        let plane_normal =
            axis_drag_plane_normal(axis_world, snap.camera_forward(), projector.camera_up);
        let start_hit =
            ray_plane_intersect(ray.0, ray.1, snap.entity_world_position, plane_normal)?;

        let drag = self.make_drag(
            snap,
            axis,
            None,
            axis_world,
            snap.entity_world_position,
            plane_normal,
            start_hit,
            Float3::ZERO,
            false,
            1.0,
        );
        self.state().active_drag = Some(drag.clone());
        Some(drag)
    }

    fn begin_center_drag(
        &self,
        snap: &GizmoSnapshot,
        projector: &ScreenProjector,
        cursor_x: f32,
        cursor_y: f32,
        screen_tolerance: f32,
    ) -> Option<ActiveGizmoDrag> {
        let origin_screen = projector.project(snap.entity_world_position)?;
        let dx = cursor_x - origin_screen.0;
        let dy = cursor_y - origin_screen.1;
        if (dx * dx + dy * dy).sqrt() > screen_tolerance {
            return None;
        }
        let ray = projector.cursor_ray(cursor_x, cursor_y);
        let hit = ray_plane_intersect(
            ray.0,
            ray.1,
            snap.entity_world_position,
            snap.camera_forward(),
        )?;

        let offset = hit - snap.entity_world_position;
        let offset_length = simd_length(offset);
        let start_radial = if offset_length > 1e-4 {
            offset / offset_length
        } else {
            projector.camera_right
        };
        let drag_axis = simd_normalize(projector.camera_right + projector.camera_up);
        let drag = self.make_drag(
            snap,
            GizmoAxis::X,
            None,
            drag_axis,
            snap.entity_world_position,
            snap.camera_forward(),
            hit,
            start_radial,
            true,
            offset_length.max(snap.axis_length * 0.18),
        );
        self.state().active_drag = Some(drag.clone());
        Some(drag)
    }

    /// 平面手柄在世界空间的几何范围：以原点为起点沿 (basisU, basisV) 方向
    /// 各取 `axisLength * 0.15 .. axisLength * 0.45` 形成一个矩形
    fn plane_quad_corners(&self, snap: &GizmoSnapshot, plane: GizmoPlane) -> [Float3; 4] {
        let axes = snap.plane_axes(plane);
        let lo = snap.axis_length * 0.15;
        let hi = snap.axis_length * 0.45;
        let o = snap.entity_world_position;
        [
            o + axes.basis_u * lo + axes.basis_v * lo,
            o + axes.basis_u * hi + axes.basis_v * lo,
            o + axes.basis_u * hi + axes.basis_v * hi,
            o + axes.basis_u * lo + axes.basis_v * hi,
        ]
    }

    fn begin_plane_translate_drag(
        &self,
        snap: &GizmoSnapshot,
        projector: &ScreenProjector,
        cursor_x: f32,
        cursor_y: f32,
    ) -> Option<ActiveGizmoDrag> {
        for plane in GizmoPlane::ALL {
            let corners = self.plane_quad_corners(snap, plane);
            // 世界空间四点投到屏幕，做凸四边形点在多边形测试。
            let mut screen_corners: Vec<(f32, f32)> = Vec::with_capacity(4);
            for corner in corners {
                match projector.project(corner) {
                    Some(screen) => screen_corners.push(screen),
                    None => {
                        screen_corners.clear();
                        break;
                    }
                }
            }
            if screen_corners.len() != 4 {
                continue;
            }
            if !point_in_quad(cursor_x, cursor_y, &screen_corners) {
                continue;
            }

            // 命中：用 ray-plane 求交得到起始世界点。
            let ray = projector.cursor_ray(cursor_x, cursor_y);
            let axes = snap.plane_axes(plane);
            let hit = ray_plane_intersect(ray.0, ray.1, snap.entity_world_position, axes.normal)?;

            let drag = self.make_drag(
                snap,
                GizmoAxis::X,
                Some(plane),
                Float3::ZERO,
                snap.entity_world_position,
                axes.normal,
                hit,
                Float3::ZERO,
                false,
                1.0,
            );
            self.state().active_drag = Some(drag.clone());
            return Some(drag);
        }
        None
    }

    fn begin_rotate_drag(
        &self,
        snap: &GizmoSnapshot,
        projector: &ScreenProjector,
        cursor_x: f32,
        cursor_y: f32,
        screen_tolerance: f32,
    ) -> Option<ActiveGizmoDrag> {
        // 在三个旋转圆里挑命中的：每个圆采样 N 个点，先在屏幕上找最近点距离。
        let mut best: Option<(GizmoAxis, f32)> = None;

        let radius = snap.axis_length;
        let segments = 64;

        for axis in GizmoAxis::ALL {
            let (basis_u, basis_v) = snap.plane_basis_for_rotate_axis(axis);
            let mut prev_screen: Option<(f32, f32)> = None;
            for i in 0..=segments {
                let t = i as f32 / segments as f32 * 2.0 * PI;
                let world =
                    snap.entity_world_position + (basis_u * t.cos() + basis_v * t.sin()) * radius;
                let Some(screen) = projector.project(world) else {
                    prev_screen = None;
                    continue;
                };
                if let Some(prev) = prev_screen {
                    let d = point_to_segment_distance(
                        cursor_x, cursor_y, prev.0, prev.1, screen.0, screen.1,
                    );
                    let best_distance = best.map_or(f32::INFINITY, |(_, distance)| distance);
                    if d < best_distance {
                        best = Some((axis, d));
                    }
                }
                prev_screen = Some(screen);
            }
        }

        let (axis, screen_distance) = best?;
        if screen_distance > screen_tolerance {
            return None;
        }

        // 用真实 ray-平面求交得到更准的起始径向。
        let ray = projector.cursor_ray(cursor_x, cursor_y);
        let axis_world = snap.axis_world(axis);
        let plane_origin = snap.entity_world_position;
        let hit_world = ray_plane_intersect(ray.0, ray.1, plane_origin, axis_world)?;
        let radial = hit_world - plane_origin;
        if simd_length(radial) <= 1e-4 {
            return None;
        }
        let start_radial = simd_normalize(radial);

        let drag = self.make_drag(
            snap,
            axis,
            None,
            axis_world,
            plane_origin,
            axis_world,
            hit_world,
            start_radial,
            false,
            1.0,
        );
        self.state().active_drag = Some(drag.clone());
        Some(drag)
    }
}

fn update_translate_matrix(drag: &ActiveGizmoDrag, ray: (Float3, Float3)) -> Option<Float4x4> {
    let cur_hit = ray_plane_intersect(ray.0, ray.1, drag.plane_origin, drag.plane_normal)?;
    let mut world_matrix = drag.start_entity_world_matrix;
    if drag.is_free {
        let delta_world = cur_hit - drag.start_plane_hit;
        world_matrix.set_column(
            3,
            Float4::new(
                drag.start_entity_world_position.x + delta_world.x,
                drag.start_entity_world_position.y + delta_world.y,
                drag.start_entity_world_position.z + delta_world.z,
                1.0,
            ),
        );
        return Some(drag.parent_inverse_matrix * world_matrix);
    }
    // 在拖拽平面上的偏移投影到轴向，得到沿轴平移。
    let delta_world = cur_hit - drag.start_plane_hit;
    let along = simd_dot(delta_world, drag.axis_world);
    let new_world_pos = drag.start_entity_world_position + drag.axis_world * along;
    world_matrix.set_column(
        3,
        Float4::new(new_world_pos.x, new_world_pos.y, new_world_pos.z, 1.0),
    );
    Some(drag.parent_inverse_matrix * world_matrix)
}

fn update_scale_matrix(drag: &ActiveGizmoDrag, ray: (Float3, Float3)) -> Option<Float4x4> {
    let cur_hit = ray_plane_intersect(ray.0, ray.1, drag.plane_origin, drag.plane_normal)?;
    let factor = if drag.is_free {
        let current_offset = cur_hit - drag.plane_origin;
        let current_distance = simd_length(current_offset);
        if current_distance <= 1e-4 {
            0.05
        } else {
            let current_direction = simd_normalize(current_offset);
            let same_side = simd_dot(current_direction, drag.start_radial);
            if same_side < -0.1 {
                0.05
            } else {
                (current_distance / drag.uniform_scale_start_distance).clamp(0.05, 20.0)
            }
        }
    } else {
        let along = simd_dot(cur_hit - drag.start_plane_hit, drag.axis_world);
        (1.0 + along / drag.reference_length).max(0.05)
    };
    // 以 startEntityWorldPosition 为中心、沿世界轴做非均匀缩放，
    // 只缩放世界矩阵的三个基底列，保持平移不变，避免以世界原点为中心缩放。
    let m = drag.start_entity_world_matrix;
    let basis = Float3x3::from_float4x4(m);
    let c0 = basis.columns[0];
    let c1 = basis.columns[1];
    let c2 = basis.columns[2];
    let (n0, n1, n2) = if drag.is_free {
        (c0 * factor, c1 * factor, c2 * factor)
    } else {
        let s = scale_along_axis_matrix(factor, drag.axis_world);
        let s3 = Float3x3::from_columns([
            Float3::new(s.columns[0].x, s.columns[0].y, s.columns[0].z),
            Float3::new(s.columns[1].x, s.columns[1].y, s.columns[1].z),
            Float3::new(s.columns[2].x, s.columns[2].y, s.columns[2].z),
        ]);
        (s3 * c0, s3 * c1, s3 * c2)
    };
    let mut world_matrix = m;
    world_matrix.set_column(0, Float4::new(n0.x, n0.y, n0.z, 0.0));
    world_matrix.set_column(1, Float4::new(n1.x, n1.y, n1.z, 0.0));
    world_matrix.set_column(2, Float4::new(n2.x, n2.y, n2.z, 0.0));
    // world_matrix 的平移列保留原始值。
    Some(drag.parent_inverse_matrix * world_matrix)
}

fn update_plane_translate_matrix(
    drag: &ActiveGizmoDrag,
    ray: (Float3, Float3),
) -> Option<Float4x4> {
    drag.plane?;
    let hit = ray_plane_intersect(ray.0, ray.1, drag.plane_origin, drag.plane_normal)?;

    let delta_world = hit - drag.start_plane_hit;
    let new_world_pos = drag.start_entity_world_position + delta_world;
    let mut world_matrix = drag.start_entity_world_matrix;
    world_matrix.set_column(
        3,
        Float4::new(new_world_pos.x, new_world_pos.y, new_world_pos.z, 1.0),
    );
    Some(drag.parent_inverse_matrix * world_matrix)
}

fn update_rotate_matrix(drag: &ActiveGizmoDrag, ray: (Float3, Float3)) -> Option<Float4x4> {
    let hit_world = ray_plane_intersect(ray.0, ray.1, drag.plane_origin, drag.plane_normal)?;

    let cur_raw = hit_world - drag.plane_origin;
    if simd_length(cur_raw) <= 1e-4 {
        return None;
    }
    let cur_radial = simd_normalize(cur_raw);
    let delta_angle = signed_angle_between(drag.start_radial, cur_radial, drag.axis_world);
    // 以实体 startEntityWorldPosition 为轴心，只旋转世界矩阵的三个基底列，
    // 保持平移列不变，避免以世界原点为中心的轨道式旋转。
    let r3 = rotation_matrix(delta_angle, drag.axis_world);
    let m = drag.start_entity_world_matrix;
    let c0 = Float3::new(m.columns[0].x, m.columns[0].y, m.columns[0].z);
    let c1 = Float3::new(m.columns[1].x, m.columns[1].y, m.columns[1].z);
    let c2 = Float3::new(m.columns[2].x, m.columns[2].y, m.columns[2].z);
    let n0 = r3 * c0;
    let n1 = r3 * c1;
    let n2 = r3 * c2;
    let mut world_matrix = m;
    world_matrix.set_column(0, Float4::new(n0.x, n0.y, n0.z, 0.0));
    world_matrix.set_column(1, Float4::new(n1.x, n1.y, n1.z, 0.0));
    world_matrix.set_column(2, Float4::new(n2.x, n2.y, n2.z, 0.0));
    Some(drag.parent_inverse_matrix * world_matrix)
}

// MARK: - Projection helpers

pub struct ScreenProjector {
    projection: EditorViewportProjection,
    pub view_matrix: Float4x4,
    pub proj_matrix: Float4x4,
    pub frame: ViewportScreenFrame,
    pub camera_eye: Float3,
    pub camera_forward: Float3,
    pub camera_right: Float3,
    pub camera_up: Float3,
    pub aspect: f32,
    pub tan_half_fov: f32,
}

impl ScreenProjector {
    pub fn new(snapshot: &GizmoSnapshot) -> Option<Self> {
        let frame = snapshot.frame;
        let camera = &snapshot.camera;
        let projection = EditorViewportProjection::new(*camera, frame)?;
        Some(ScreenProjector {
            view_matrix: projection.view_matrix,
            proj_matrix: projection.projection_matrix,
            frame,
            camera_eye: camera.eye,
            camera_forward: projection.camera_forward,
            camera_right: projection.camera_right,
            camera_up: projection.camera_up,
            aspect: projection.aspect,
            tan_half_fov: projection.tan_half_fov,
            projection,
        })
    }

    pub fn project(&self, world_point: Float3) -> Option<(f32, f32)> {
        self.projection.project(world_point, false)
    }

    pub fn cursor_ray(&self, x: f32, y: f32) -> (Float3, Float3) {
        self.projection.cursor_ray(x, y)
    }
}

fn point_to_segment_distance(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) -> f32 {
    let dx = bx - ax;
    let dy = by - ay;
    let len_sq = dx * dx + dy * dy;
    if len_sq < 1e-4 {
        let ddx = px - ax;
        let ddy = py - ay;
        return (ddx * ddx + ddy * ddy).sqrt();
    }
    let t = (((px - ax) * dx + (py - ay) * dy) / len_sq).clamp(0.0, 1.0);
    let cx = ax + t * dx;
    let cy = ay + t * dy;
    let ex = px - cx;
    let ey = py - cy;
    (ex * ex + ey * ey).sqrt()
}

/// 为一根世界轴选拖拽平面法线：平面含 axis、尽量面向摄像机，避免视线与轴近平行时的数值不稳。
fn axis_drag_plane_normal(axis_world: Float3, camera_forward: Float3, camera_up: Float3) -> Float3 {
    let view_cross_axis = simd_cross(camera_forward, axis_world);
    let mut normal = simd_cross(axis_world, view_cross_axis);
    if simd_length(normal) < 1e-4 {
        normal = simd_cross(axis_world, camera_up);
    }
    if simd_length(normal) < 1e-4 {
        normal = simd_cross(axis_world, Float3::new(1.0, 0.0, 0.0));
    }
    let len = simd_length(normal);
    if len > 1e-5 {
        normal / len
    } else {
        camera_forward
    }
}

/// 以 `from` 到 `to` 绕 `axis` 的有符号夹角，范围 [-π, π]。避免极角 atan2 的 ±π 跳变。
fn signed_angle_between(from: Float3, to: Float3, axis: Float3) -> f32 {
    let n = if simd_length(axis) > 1e-5 {
        simd_normalize(axis)
    } else {
        Float3::new(0.0, 1.0, 0.0)
    };
    let cross = simd_cross(from, to);
    let sin_angle = simd_dot(n, cross);
    let cos_angle = simd_dot(from, to).clamp(-1.0, 1.0);
    sin_angle.atan2(cos_angle)
}

fn ray_plane_intersect(
    ray_origin: Float3,
    ray_dir: Float3,
    plane_origin: Float3,
    plane_normal: Float3,
) -> Option<Float3> {
    let denom = simd_dot(ray_dir, plane_normal);
    if denom.abs() < 1e-5 {
        return None;
    }
    let t = simd_dot(plane_origin - ray_origin, plane_normal) / denom;
    if t < 0.0 {
        return None;
    }
    Some(ray_origin + ray_dir * t)
}

/// 屏幕空间凸四边形点在多边形测试（按顺序遍历四条边的叉积同号即可）。
fn point_in_quad(px: f32, py: f32, quad: &[(f32, f32)]) -> bool {
    if quad.len() != 4 {
        return false;
    }
    let mut last_sign: f32 = 0.0;
    for i in 0..4 {
        let (ax, ay) = quad[i];
        let (bx, by) = quad[(i + 1) % 4];
        let cross = (bx - ax) * (py - ay) - (by - ay) * (px - ax);
        if cross != 0.0 {
            if last_sign == 0.0 {
                last_sign = cross;
            } else if (last_sign > 0.0) != (cross > 0.0) {
                return false;
            }
        }
    }
    true
}

fn rotation_matrix(angle: f32, axis: Float3) -> Float3x3 {
    let c = angle.cos();
    let s = angle.sin();
    let t = 1.0 - c;
    let n = simd_normalize(axis);
    let x = n.x;
    let y = n.y;
    let z = n.z;
    Float3x3::from_columns([
        Float3::new(t * x * x + c, t * x * y + s * z, t * x * z - s * y),
        Float3::new(t * x * y - s * z, t * y * y + c, t * y * z + s * x),
        Float3::new(t * x * z + s * y, t * y * z - s * x, t * z * z + c),
    ])
}

fn rotation4x4(angle: f32, axis: Float3) -> Float4x4 {
    let r = rotation_matrix(angle, axis);
    let mut m = MATRIX_IDENTITY_FLOAT4X4;
    m.set_column(
        0,
        Float4::new(r.columns[0].x, r.columns[0].y, r.columns[0].z, 0.0),
    );
    m.set_column(
        1,
        Float4::new(r.columns[1].x, r.columns[1].y, r.columns[1].z, 0.0),
    );
    m.set_column(
        2,
        Float4::new(r.columns[2].x, r.columns[2].y, r.columns[2].z, 0.0),
    );
    m
}

/// 沿世界轴 a 做非均匀缩放（factor）：S = I + (factor - 1) * a * aᵀ
fn scale_along_axis_matrix(factor: f32, axis: Float3) -> Float4x4 {
    let a = simd_normalize(axis);
    let k = factor - 1.0;
    let mut m = MATRIX_IDENTITY_FLOAT4X4;
    m.set_column(
        0,
        Float4::new(1.0 + k * a.x * a.x, k * a.x * a.y, k * a.x * a.z, 0.0),
    );
    m.set_column(
        1,
        Float4::new(k * a.x * a.y, 1.0 + k * a.y * a.y, k * a.y * a.z, 0.0),
    );
    m.set_column(
        2,
        Float4::new(k * a.x * a.z, k * a.y * a.z, 1.0 + k * a.z * a.z, 0.0),
    );
    m
}
