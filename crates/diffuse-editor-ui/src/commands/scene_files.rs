//! `Editor/Sources/EditorUI/Commands/SceneFiles.swift`.

use std::path::Path;
use std::rc::Rc;

use diffuse_editor_core::application::editor_application::EditorApplication;
use diffuse_editor_core::state::editor_state::EditorConsoleSeverity;

use crate::commands::policy::EditorSceneAuthoringPolicy;
use crate::localization::localized;

pub struct EditorSceneFileCoordinator;

impl EditorSceneFileCoordinator {
    pub fn request_open(app: &Rc<EditorApplication>) {
        if !EditorSceneAuthoringPolicy::can_edit_scene(app.store.playback_state()) {
            app.log_console(
                "Stop simulation before opening another scene",
                EditorConsoleSeverity::Warning,
                None,
                None,
                None,
            );
            return;
        }
        if !Self::present_picker(app) {
            app.log_console(
                "Scene picker is unavailable",
                EditorConsoleSeverity::Error,
                Some("No active display".to_owned()),
                None,
                None,
            );
        }
    }

    #[cfg(not(target_arch = "wasm32"))]
    fn present_picker(app: &Rc<EditorApplication>) -> bool {
        use cove_shell::FileDialogFilter;
        use cove_ui::hosts::desktop::application::composition::AppDisplayHandleHolder;

        let Some(display) = AppDisplayHandleHolder::current() else {
            return false;
        };
        let directory = Path::new(&app.project_directory).join(".cove");
        let filter = FileDialogFilter {
            name: localized("Cove Scene"),
            extensions: vec!["json".to_owned()],
        };
        display.request_open_file(
            &[filter],
            false,
            directory.to_str(),
            Self::open_selection(app),
        );
        true
    }

    #[cfg(target_arch = "wasm32")]
    fn present_picker(app: &Rc<EditorApplication>) -> bool {
        use cove_ui::core::scene::{FilePicker, FilePickerFilter};

        if !FilePicker::is_installed() {
            return false;
        }
        let filter = FilePickerFilter::new(localized("Cove Scene"), ["json".to_owned()]);
        FilePicker::request(&[filter], false, Self::open_selection(app));
        true
    }

    fn open_selection(app: &Rc<EditorApplication>) -> Box<dyn FnOnce(Vec<String>)> {
        let app = Rc::downgrade(app);
        Box::new(move |paths| {
            if let Some(path) = paths.first()
                && let Some(app) = app.upgrade().filter(|app| app.is_active())
            {
                app.request_open_scene_manifest_at(Path::new(path));
            }
        })
    }
}

#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests {
    use std::cell::Cell;
    use std::fs;

    use cove_ui::hosts::desktop::application::composition::AppDisplayHandleHolder;
    use cove_ui::hosts::desktop::display::{AppDisplayHandle, DisplayBindings};
    use diffuse_editor_core::state::editor_reducer::EditorAction;
    use diffuse_editor_core::state::editor_state::{EditorPendingDocumentAction, PlaybackState};

    use super::*;

    #[test]
    fn scene_picker_obeys_playback_and_routes_the_selected_file_through_document_review() {
        let root = std::env::temp_dir().join(diffuse_kernel::codable::new_uuid());
        fs::create_dir_all(&root).expect("project directory");
        let root = root.canonicalize().unwrap();
        let application = EditorApplication::new(root.to_string_lossy().into_owned()).unwrap();
        application.create_empty_scene();
        let chosen = root.join("alternate.json");
        let count = Rc::new(Cell::new(0));
        let display = AppDisplayHandle::default();
        display.install(DisplayBindings {
            open_file_dialog: Some(Rc::new({
                let count = count.clone();
                let expected_directory = root.join(".cove");
                let chosen = chosen.clone();
                move |directory, filters, multiple, accept| {
                    count.set(count.get() + 1);
                    assert_eq!(directory, expected_directory.to_str());
                    assert_eq!(filters.len(), 1);
                    assert_eq!(filters[0].extensions, ["json"]);
                    assert!(!multiple);
                    accept(vec![chosen.to_string_lossy().into_owned()]);
                }
            })),
            ..DisplayBindings::default()
        });
        let previous = AppDisplayHandleHolder::current();
        AppDisplayHandleHolder::set_current(Some(display));
        application
            .store
            .dispatch(EditorAction::SetPlaybackState(PlaybackState::Playing));
        EditorSceneFileCoordinator::request_open(&application);
        assert_eq!(count.get(), 0);
        application
            .store
            .dispatch(EditorAction::SetPlaybackState(PlaybackState::Stopped));
        EditorSceneFileCoordinator::request_open(&application);
        AppDisplayHandleHolder::set_current(previous);
        assert_eq!(count.get(), 1);
        let pending = application
            .store
            .pending_close_request()
            .expect("open needs document review");
        assert_eq!(pending.action, EditorPendingDocumentAction::OpenScene);
        assert_eq!(pending.document_path.as_deref(), chosen.to_str());
        application.shutdown();
        fs::remove_dir_all(root).unwrap();
    }
}
