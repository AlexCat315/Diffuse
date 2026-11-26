//! Owns an exported game's simulation, scene renderer, and HUD.

use std::collections::BTreeSet;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

use cove_graphics::rhi::Device;
use diffuse_editor_core::rendering::hud::in_game_ui_host::InGameUIHost;
use diffuse_editor_core::scene::manifest::node::EditorSceneManifestNode;
use diffuse_game_runtime::game_application::{
    GameApplication, GameApplicationError, ProjectScriptRegistrar,
};
use diffuse_kernel::in_game_canvas::InGameCanvasCommand;
use diffuse_kernel::input_event::{InputEvent, KeyEvent, KeyModifiers};
use diffuse_render::RenderDrawableSize;
use diffuse_render::surface::viewport_surface::ViewportSurfaceState;

use crate::content::game::{GameContentSession, GameContentSnapshot};

#[derive(Debug)]
pub enum GameSessionError {
    InvalidProject,
    Application(GameApplicationError),
}

impl std::fmt::Display for GameSessionError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidProject => formatter.write_str("Invalid packaged game project path."),
            Self::Application(error) => error.fmt(formatter),
        }
    }
}

impl std::error::Error for GameSessionError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::InvalidProject => None,
            Self::Application(error) => Some(error),
        }
    }
}

impl From<GameApplicationError> for GameSessionError {
    fn from(error: GameApplicationError) -> Self {
        Self::Application(error)
    }
}

pub struct GameSession {
    pub application: GameApplication,
    hud: InGameUIHost,
    surface: ViewportSurfaceState,
    held_keys: BTreeSet<u32>,
}

impl GameSession {
    pub fn new(
        device: Arc<Device>,
        project: &str,
        register_project_scripts: ProjectScriptRegistrar,
    ) -> Result<Self, GameSessionError> {
        let root = std::env::var_os("PACKAGE_RESOURCE_BUNDLE_PATH")
            .map(PathBuf::from)
            .ok_or(GameSessionError::InvalidProject)?;
        let directory = packaged_project(&root, project)?;
        let hud = InGameUIHost::new(device.clone()).map_err(GameApplicationError::from)?;
        let application = GameApplication::new(
            Some(&directory),
            Some(device),
            Some(hud.render_provider()),
            Some(register_project_scripts),
        )?;
        application.bootstrap();
        Ok(Self {
            application,
            hud,
            surface: ViewportSurfaceState::default(),
            held_keys: BTreeSet::new(),
        })
    }
}

impl GameContentSession for GameSession {
    fn surface(&self) -> &ViewportSurfaceState {
        &self.surface
    }

    fn prepare(&mut self, pixels: RenderDrawableSize, scale: f32, delta_time: f64) {
        self.application.set_viewport_drawable_size(pixels);
        self.application.tick(delta_time);
        let scale = if scale.is_finite() && scale > 0.0 {
            scale
        } else {
            1.0
        };
        self.hud.tick(
            (pixels.width as f32 / scale) as u32,
            (pixels.height as f32 / scale) as u32,
            scale,
            self.application.scene.current_in_game_canvas(),
        );
        self.surface = self.application.current_viewport_surface_state();
    }

    fn key(&mut self, scancode: u32, down: bool) {
        let changed = if down {
            self.held_keys.insert(scancode)
        } else {
            self.held_keys.remove(&scancode)
        };
        if !changed {
            return;
        }
        let event = KeyEvent {
            scancode,
            keycode: 0,
            modifiers: KeyModifiers::default(),
            is_repeat: false,
        };
        self.application.enqueue_input(if down {
            InputEvent::KeyDown(event)
        } else {
            InputEvent::KeyUp(event)
        });
    }

    fn release_keys(&mut self) {
        while let Some(scancode) = self.held_keys.first().copied() {
            self.key(scancode, false);
        }
    }

    fn snapshot(&self) -> GameContentSnapshot {
        let manifest = self.application.scene.manifest();
        let player = find_player(&manifest.roots)
            .and_then(|node| node.local_transform.as_ref())
            .and_then(|transform| match transform.rows.as_slice() {
                [_, _, _, x, _, _, _, y, _, _, _, z, ..] => Some([*x, *y, *z]),
                _ => None,
            });
        let hud = self
            .application
            .scene
            .current_in_game_canvas()
            .commands
            .into_iter()
            .filter_map(|command| match command {
                InGameCanvasCommand::Label { text, .. } => Some(text),
                _ => None,
            })
            .collect();
        GameContentSnapshot {
            scripts: self.application.compiled_script_count,
            entities: manifest.entity_count,
            rendered: self.surface.is_valid(),
            surface_id: self.surface.surface_id,
            hud,
            player,
        }
    }
}

impl Drop for GameSession {
    fn drop(&mut self) {
        self.application.shutdown();
    }
}

fn packaged_project(root: &Path, project: &str) -> Result<PathBuf, GameSessionError> {
    let mut components = Path::new(project).components();
    if !matches!(components.next(), Some(Component::Normal(name)) if name == project)
        || components.next().is_some()
    {
        return Err(GameSessionError::InvalidProject);
    }
    let root = root
        .canonicalize()
        .map_err(|_| GameSessionError::InvalidProject)?;
    let directory = root
        .join(project)
        .canonicalize()
        .map_err(|_| GameSessionError::InvalidProject)?;
    if !directory.is_dir() || directory.parent() != Some(root.as_path()) {
        return Err(GameSessionError::InvalidProject);
    }
    Ok(directory)
}

fn find_player(nodes: &[EditorSceneManifestNode]) -> Option<&EditorSceneManifestNode> {
    nodes.iter().find_map(|node| {
        if node.name == "Player" {
            Some(node)
        } else {
            find_player(&node.children)
        }
    })
}
