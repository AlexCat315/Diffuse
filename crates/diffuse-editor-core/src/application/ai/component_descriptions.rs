//! `Editor/Sources/EditorCore/Application/AI/ComponentDescriptions.swift`.

use std::rc::Rc;

use diffuse_ai::session::session::ComponentDescriptionProvider;

use crate::application::editor_application::{EditorApplication, SendableAppHandle};

impl EditorApplication {
    /// `makeComponentDescriptionProvider()` — reads the scene's component
    /// descriptions for the session's context builder.
    pub fn make_component_description_provider(
        self: &Rc<Self>,
    ) -> ComponentDescriptionProvider {
        let app = SendableAppHandle(Rc::downgrade(self));
        std::sync::Arc::new(move |type_id: Option<&str>| {
            app.upgrade()
                .map(|app| app.scene.component_descriptions(type_id))
                .unwrap_or_default()
        })
    }
}
