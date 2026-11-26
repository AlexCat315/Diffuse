use std::f32::consts::PI;
use std::sync::OnceLock;

use diffuse_script_api::authoring::json::{self, JsonObject, JsonValue};
use diffuse_script_api::{
    ScriptAuthoring, ScriptBehavior, ScriptContext, ScriptDefinition, ScriptProperty,
    ScriptPropertyOption, ScriptPropertyValue, Transform3, diffuse_scripts,
};

const GEMS: [[f32; 3]; 8] = [
    [-7.0, 0.65, -4.0],
    [-3.0, 0.65, -4.0],
    [3.0, 0.65, -4.0],
    [7.0, 0.65, -4.0],
    [-7.0, 0.65, 4.0],
    [-3.0, 0.65, 4.0],
    [3.0, 0.65, 4.0],
    [7.0, 0.65, 4.0],
];
const PLAYER_START: [f32; 3] = [0.0, 0.6, 0.0];
const PLAYER_SCALE: [f32; 3] = [0.8, 1.1, 0.8];

#[derive(Clone, Copy, Default, PartialEq, Eq)]
enum Phase {
    #[default]
    Ready,
    Playing,
    Won,
    Lost,
}

impl Phase {
    fn name(self) -> &'static str {
        match self {
            Self::Ready => "ready",
            Self::Playing => "playing",
            Self::Won => "won",
            Self::Lost => "lost",
        }
    }
}

#[derive(Default)]
struct GameScript {
    spawned: Vec<u64>,
    player: Option<u64>,
    gems: Vec<u64>,
    enemies: Vec<u64>,
    collected: [bool; 8],
    phase: Phase,
    duration: f32,
    starting_hearts: i64,
    remaining: f32,
    hearts: i64,
    elapsed: f32,
    invulnerability: f32,
}

impl ScriptAuthoring for GameScript {
    fn definition() -> &'static ScriptDefinition {
        static DEFINITION: OnceLock<ScriptDefinition> = OnceLock::new();
        DEFINITION.get_or_init(|| {
            use ScriptPropertyValue::{Integer, Number, String};
            let property = |key, label: &str, group: &str, value, range: Option<(f64, f64)>| {
                ScriptProperty::with_details(
                    key,
                    Some(label.into()),
                    Some(group.into()),
                    None,
                    value,
                    range.map(|range| range.0),
                    range.map(|range| range.1),
                    None,
                    Vec::new(),
                )
            };
            ScriptDefinition::new(vec![
                property(
                    "title",
                    "Game Title",
                    "Game Rules",
                    String("Crystal Rush".into()),
                    None,
                ),
                property(
                    "duration",
                    "Round Duration",
                    "Game Rules",
                    Number(50.0),
                    Some((1.0, 3600.0)),
                ),
                property(
                    "startingHearts",
                    "Starting Hearts",
                    "Game Rules",
                    Integer(3),
                    Some((1.0, 20.0)),
                ),
                property(
                    "startMode",
                    "Start Mode",
                    "Game Rules",
                    String("ready".into()),
                    None,
                )
                .with_options(vec![
                    ScriptPropertyOption::new("ready", Some("Wait for Input".into())),
                    ScriptPropertyOption::new("playing", Some("Start Immediately".into())),
                ]),
                property(
                    "moveSpeed",
                    "Move Speed",
                    "Movement",
                    Number(4.5),
                    Some((0.0, 50.0)),
                ),
                property(
                    "sprintSpeed",
                    "Sprint Speed",
                    "Movement",
                    Number(7.0),
                    Some((0.0, 50.0)),
                ),
            ])
        })
    }
}

impl ScriptBehavior for GameScript {
    fn on_start(&mut self, context: &ScriptContext) {
        self.duration = context.float_parameter("duration").unwrap_or(50.0);
        self.starting_hearts = context.double_parameter("startingHearts").unwrap_or(3.0) as i64;
        self.remaining = self.duration;
        self.hearts = self.starting_hearts;
        assert!(context.set_resource_json("InputActionMap", INPUT_ACTIONS));

        let camera = self.spawn(context, "Camera", transform([0.0, 19.0, 18.0], [1.0; 3]));
        set_component(
            context,
            camera,
            "camera",
            &format!(
                r#"{{"target":[0,0,0],"fovYRadians":{},"near":0.1,"far":100,"isActive":true}}"#,
                PI / 3.5
            ),
        );
        let sun = self.spawn(
            context,
            "Sun",
            rotating([0.0; 3], [1.0; 3], -PI / 3.0, [1.0, 0.0, 0.0]),
        );
        set_component(
            context,
            sun,
            "light",
            r#"{"type":"directional","intensity":3,"castShadows":true}"#,
        );
        let fill = self.spawn(context, "Fill", transform([0.0, 7.0, 0.0], [1.0; 3]));
        set_component(
            context,
            fill,
            "light",
            &format!(
                r#"{{"type":"point","color":{:?},"intensity":55,"range":28}}"#,
                [0.25_f32, 0.55, 1.0].map(f64::from),
            ),
        );

        self.cube(
            context,
            "Arena",
            [0.0, -0.2, 0.0],
            [18.0, 0.3, 14.0],
            [0.035, 0.055, 0.1],
            [0.0; 3],
        );
        for x in -4..=4 {
            for z in -3..=3 {
                if (x + z) % 2 == 0 {
                    self.cube(
                        context,
                        "Tile",
                        [x as f32 * 2.0, -0.02, z as f32 * 2.0],
                        [1.92, 0.02, 1.92],
                        [0.06, 0.10, 0.16],
                        [0.0; 3],
                    );
                }
            }
        }
        for z in [-7.0, 7.0] {
            self.cube(
                context,
                "Boundary",
                [0.0, 0.05, z],
                [18.0, 0.2, 0.18],
                [0.1, 0.8, 0.9],
                [0.04, 0.35, 0.5],
            );
        }
        for x in [-9.0, 9.0] {
            self.cube(
                context,
                "Boundary",
                [x, 0.05, 0.0],
                [0.18, 0.2, 14.0],
                [0.1, 0.8, 0.9],
                [0.04, 0.35, 0.5],
            );
        }
        let player = self.cube(
            context,
            "Player",
            PLAYER_START,
            PLAYER_SCALE,
            [0.3, 0.85, 1.0],
            [0.03, 0.2, 0.3],
        );
        self.player = Some(player);
        set_component(
            context,
            player,
            "collider",
            r#"{"shape":"sphere","radius":0.45}"#,
        );
        for (index, [x, y, z]) in GEMS.into_iter().enumerate() {
            let gem = self.cube(
                context,
                &format!("Crystal {}", index + 1),
                [x, y, z],
                [0.55; 3],
                [0.8, 1.0, 0.25],
                [0.2, 0.45, 0.015],
            );
            set_component(
                context,
                gem,
                "collider",
                r#"{"shape":"sphere","radius":0.5,"isTrigger":true}"#,
            );
            self.gems.push(gem);
            self.cube(
                context,
                "Crystal Pad",
                [x, 0.04, z],
                [1.1, 0.07, 1.1],
                [0.08, 0.23, 0.18],
                [0.0; 3],
            );
        }
        for index in 0..3 {
            let enemy = self.cube(
                context,
                &format!("Sentinel {}", index + 1),
                [0.0, 0.7, 0.0],
                [1.1, 1.3, 1.1],
                [1.0, 0.18, 0.3],
                [0.3, 0.015, 0.03],
            );
            self.enemies.push(enemy);
        }
        if context.string_parameter("startMode").as_deref() == Some("playing") {
            self.phase = Phase::Playing;
        }
        self.update_world(context);
        self.draw_hud(context);
    }

    fn on_update(&mut self, context: &ScriptContext) {
        let dt = (context.delta_time() as f32).clamp(0.0, 0.05);
        if context.input_just_pressed("restart") {
            self.restart(context);
        }
        if self.phase == Phase::Ready && context.input_just_pressed("start") {
            self.phase = Phase::Playing;
        }
        if self.phase == Phase::Playing
            && let Some(player) = self.player
            && let Some(mut transform) = context.local_transform_of(player)
        {
            self.elapsed += dt;
            self.remaining = (self.remaining - dt).max(0.0);
            self.invulnerability = (self.invulnerability - dt).max(0.0);
            let (mut x, mut z) = (context.input_axis("move_x"), -context.input_axis("move_y"));
            let magnitude = (x * x + z * z).sqrt();
            if magnitude > 1.0 {
                x /= magnitude;
                z /= magnitude;
            }
            let speed = if context.input_held("sprint") {
                context.float_parameter("sprintSpeed").unwrap_or(7.0)
            } else {
                context.float_parameter("moveSpeed").unwrap_or(4.5)
            };
            let position = &mut transform.columns[3];
            position[0] = (position[0] + x * speed * dt).clamp(-8.25, 8.25);
            position[2] = (position[2] + z * speed * dt).clamp(-6.25, 6.25);
            let position = [position[0], position[1], position[2]];
            context.set_local_transform_for(transform, player);
            for (index, gem) in GEMS.into_iter().enumerate() {
                if !self.collected[index] && planar_distance(position, gem) < 0.85 {
                    self.collected[index] = true;
                    set_visible(context, self.gems[index], false);
                }
            }
            for index in 0..self.enemies.len() {
                if self.invulnerability <= 0.0
                    && planar_distance(position, self.enemy_position(index)) < 0.95
                {
                    self.hearts -= 1;
                    self.invulnerability = 1.4;
                }
            }
            if self.score() == self.gems.len() {
                self.phase = Phase::Won;
            } else if self.hearts <= 0 || self.remaining <= 0.0 {
                self.phase = Phase::Lost;
            }
        }
        self.update_world(context);
        self.draw_hud(context);
        let position = self
            .player
            .and_then(|entity| context.local_transform_of(entity))
            .map_or([0.0; 4], |transform| transform.columns[3]);
        let state: JsonObject = [
            ("game", title(context)),
            ("phase", self.phase.name().into()),
            ("score", self.score().to_string()),
            ("target", "8".into()),
            ("hearts", self.hearts.to_string()),
            ("remaining_seconds", format!("{:.2}", self.remaining)),
            ("player_x", position[0].to_string()),
            ("player_z", position[2].to_string()),
        ]
        .into_iter()
        .map(|(key, value)| (key.into(), JsonValue::String(value)))
        .collect();
        context.report_state(&JsonValue::Object(state).to_json());
    }

    fn on_destroy(&mut self, context: &ScriptContext) {
        for entity in self.spawned.drain(..) {
            context.destroy_entity(entity);
        }
    }
}

impl GameScript {
    fn spawn(&mut self, context: &ScriptContext, name: &str, transform: Transform3) -> u64 {
        let entity = context
            .create_entity(Some(name), transform)
            .expect("create Crystal Rush entity");
        self.spawned.push(entity);
        context.set_parent(entity, Some(context.entity()));
        entity
    }

    fn cube(
        &mut self,
        context: &ScriptContext,
        name: &str,
        position: [f32; 3],
        scale: [f32; 3],
        color: [f32; 3],
        glow: [f32; 3],
    ) -> u64 {
        let entity = self.spawn(context, name, transform(position, scale));
        set_component(
            context,
            entity,
            "renderMesh",
            &format!(
                r#"{{"meshIndex":0,"colorTint":{:?}}}"#,
                color.map(f64::from)
            ),
        );
        set_component(
            context,
            entity,
            "renderMaterial",
            &format!(
                r#"{{"roughnessFactor":0.72,"emissiveFactor":{:?}}}"#,
                glow.map(f64::from)
            ),
        );
        entity
    }

    fn restart(&mut self, context: &ScriptContext) {
        self.phase = Phase::Playing;
        self.collected.fill(false);
        self.hearts = self.starting_hearts;
        self.remaining = self.duration;
        self.elapsed = 0.0;
        self.invulnerability = 0.0;
        if let Some(player) = self.player {
            context.set_local_transform_for(transform(PLAYER_START, PLAYER_SCALE), player);
        }
        for &gem in &self.gems {
            set_visible(context, gem, true);
        }
    }

    fn enemy_position(&self, index: usize) -> [f32; 3] {
        let index = index as f32;
        let angle = self.elapsed * (0.65 + index * 0.1) + index * 2.1;
        [angle.sin() * (4.0 + index), 0.7, (angle * 0.85).cos() * 3.0]
    }

    fn update_world(&self, context: &ScriptContext) {
        for (index, &enemy) in self.enemies.iter().enumerate() {
            context.set_local_transform_for(
                rotating(
                    self.enemy_position(index),
                    [1.1, 1.3, 1.1],
                    self.elapsed + index as f32,
                    [0.0, 1.0, 0.0],
                ),
                enemy,
            );
        }
        let axis_length = (0.4_f32 * 0.4 + 1.0 + 0.2 * 0.2).sqrt();
        let axis = [0.4 / axis_length, 1.0 / axis_length, 0.2 / axis_length];
        for (index, &gem) in self.gems.iter().enumerate() {
            if !self.collected[index] {
                let mut position = GEMS[index];
                position[1] += (self.elapsed * 3.0 + index as f32).sin() * 0.13;
                context.set_local_transform_for(
                    rotating(
                        position,
                        [0.55; 3],
                        self.elapsed * 1.5 + index as f32 * 0.3,
                        axis,
                    ),
                    gem,
                );
            }
        }
        if let Some(player) = self.player {
            set_visible(
                context,
                player,
                self.invulnerability <= 0.0 || (self.invulnerability * 10.0) as i64 % 2 == 0,
            );
        }
    }

    fn score(&self) -> usize {
        self.collected
            .iter()
            .filter(|&&collected| collected)
            .count()
    }

    fn draw_hud(&self, context: &ScriptContext) {
        context.draw_ui(|canvas| {
            let muted = [0.6, 0.72, 0.85, 1.0];
            let cyan = [0.35, 0.88, 1.0, 1.0];
            let white = [1.0; 4];
            canvas.draw_rect(24.0, 24.0, 346.0, 136.0, 14.0, [0.015, 0.025, 0.06, 0.94]);
            canvas.draw_label(&title(context), 42.0, 38.0, 24.0, cyan);
            let hearts = "♥".repeat(self.hearts.max(0) as usize);
            canvas.draw_label(
                &format!("晶体 {} / 8    生命 {hearts}", self.score()),
                42.0,
                76.0,
                20.0,
                white,
            );
            canvas.draw_label(
                &format!("剩余时间  {} 秒", self.remaining.ceil() as i64),
                42.0,
                108.0,
                15.0,
                muted,
            );
            canvas.draw_progress_bar(
                42.0,
                140.0,
                308.0,
                5.0,
                self.remaining,
                self.duration,
                3.0,
                cyan,
                [0.15, 0.15, 0.15, 0.85],
            );
            canvas.draw_rect(24.0, 172.0, 346.0, 66.0, 10.0, [0.015, 0.025, 0.06, 0.85]);
            canvas.draw_label("WASD 移动  ·  Shift 加速", 42.0, 185.0, 16.0, muted);
            canvas.draw_label(
                "收集绿色晶体，避开红色守卫  ·  R 重开",
                42.0,
                208.0,
                14.0,
                muted,
            );
            let (heading, detail, instruction, color) = match self.phase {
                Phase::Playing => return,
                Phase::Ready => (
                    "准备好了吗？",
                    format!("{} 秒内收集 8 块晶体。", self.duration as i64),
                    "按空格开始",
                    cyan,
                ),
                Phase::Won => (
                    "全部收集！你赢了",
                    format!("最终成绩：{} / 8 块晶体", self.score()),
                    "按 R 再玩一次",
                    cyan,
                ),
                Phase::Lost => (
                    "挑战结束",
                    format!("最终成绩：{} / 8 块晶体", self.score()),
                    "按 R 再玩一次",
                    [1.0, 0.0, 0.0, 1.0],
                ),
            };
            canvas.draw_rect(24.0, 254.0, 346.0, 152.0, 14.0, [0.015, 0.035, 0.08, 0.96]);
            canvas.draw_label(heading, 42.0, 278.0, 28.0, color);
            canvas.draw_label(&detail, 42.0, 322.0, 18.0, white);
            canvas.draw_label(instruction, 42.0, 363.0, 20.0, cyan);
        });
    }
}

fn title(context: &ScriptContext) -> String {
    context
        .string_parameter("title")
        .unwrap_or_else(|| "Crystal Rush".into())
}

fn set_component(context: &ScriptContext, entity: u64, name: &str, document: &str) {
    assert!(
        context.set_component_json(entity, name, document),
        "set {name}"
    );
}

fn set_visible(context: &ScriptContext, entity: u64, visible: bool) {
    if let Some(mut mesh) = context
        .component_json(entity, "renderMesh")
        .as_deref()
        .and_then(json::parse)
        && let JsonValue::Object(fields) = &mut mesh
    {
        fields.insert("isVisible".into(), JsonValue::Bool(visible));
        set_component(context, entity, "renderMesh", &mesh.to_json());
    }
}

fn planar_distance(a: [f32; 3], b: [f32; 3]) -> f32 {
    let (x, z) = (a[0] - b[0], a[2] - b[2]);
    (x * x + z * z).sqrt()
}

fn transform([x, y, z]: [f32; 3], [sx, sy, sz]: [f32; 3]) -> Transform3 {
    Transform3::new([x, y, z, 0.0], [0.0, 0.0, 0.0, 1.0], [sx, sy, sz, 0.0])
}

fn rotating([x, y, z]: [f32; 3], [sx, sy, sz]: [f32; 3], angle: f32, axis: [f32; 3]) -> Transform3 {
    let (sin, cos) = (angle * 0.5).sin_cos();
    Transform3::new(
        [x, y, z, 0.0],
        [axis[0] * sin, axis[1] * sin, axis[2] * sin, cos],
        [sx, sy, sz, 0.0],
    )
}

// Cove's default bindings followed by the game's three actions. Scancodes are SDL3.
const INPUT_ACTIONS: &str = r#"{"bindings":{
    "move_forward":[{"type":"key","scancode":26},{"type":"key","scancode":82},{"type":"gamepadButton","button":"DpadUp"}],
    "move_back":[{"type":"key","scancode":22},{"type":"key","scancode":81},{"type":"gamepadButton","button":"DpadDown"}],
    "move_left":[{"type":"key","scancode":4},{"type":"key","scancode":80},{"type":"gamepadButton","button":"DpadLeft"}],
    "move_right":[{"type":"key","scancode":7},{"type":"key","scancode":79},{"type":"gamepadButton","button":"DpadRight"}],
    "move_up":[{"type":"key","scancode":8}],"move_down":[{"type":"key","scancode":20}],
    "move_x":[{"type":"keyAxis","negative":4,"positive":7}],
    "move_y":[{"type":"keyAxis","negative":22,"positive":26}],
    "jump":[{"type":"key","scancode":44},{"type":"gamepadButton","button":"South"}],
    "crouch":[{"type":"key","scancode":224},{"type":"gamepadButton","button":"East"}],
    "look_x":[{"type":"mouseMotion","axis":"x","requiredButton":"Right"},{"type":"gamepadAxis","axis":"RightX"}],
    "look_y":[{"type":"mouseMotion","axis":"y","requiredButton":"Right"},{"type":"gamepadAxis","axis":"RightY"}],
    "orbit_x":[{"type":"mouseMotion","axis":"x","requiredButton":"Right"},{"type":"gamepadAxis","axis":"RightX"}],
    "orbit_y":[{"type":"mouseMotion","axis":"y","requiredButton":"Right"},{"type":"gamepadAxis","axis":"RightY"}],
    "camera_zoom":[{"type":"mouseWheel","axis":"y"}],
    "start":[{"type":"key","scancode":44}],"restart":[{"type":"key","scancode":21}],
    "sprint":[{"type":"key","scancode":225}]
}}"#;

diffuse_scripts!(GameScript);
