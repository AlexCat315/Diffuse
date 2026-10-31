//! Host adapters bind a typed declaration to a domain catalog.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contribution/Registrar.swift`.
//! Plugin authors neither register globals nor adopt a lifecycle protocol.

use std::collections::BTreeMap;
use std::sync::Arc;

use diffuse_capability::support::disposal::{DisposalScope, Registration};

use crate::PluginError;
use crate::contract::plugin_manifest::PluginManifestValidationError;
use crate::contract::plugin_package::ValidatedPluginPackage;
use crate::contribution::registry::{ContributionPointRegistry, ContributionPointSpec};

type Installer =
    Arc<dyn Fn(&ValidatedPluginPackage) -> Result<Arc<Registration>, PluginError> + Send + Sync>;

#[derive(Clone, Default)]
pub struct ContributionRegistrar {
    installers: BTreeMap<String, Installer>,
}

impl ContributionRegistrar {
    pub fn new() -> Self {
        ContributionRegistrar {
            installers: BTreeMap::new(),
        }
    }

    /// Swift keyed the installer on `Point.id` and installed through
    /// `package.manifest.contributes.decode(point)`, so the closure receives the
    /// decoded descriptors and the package.
    pub fn register<Point: ContributionPointSpec, Install>(
        &mut self,
        install: Install,
    ) -> Result<(), PluginManifestValidationError>
    where
        Install: Fn(
                &[Point::Descriptor],
                &ValidatedPluginPackage,
            ) -> Result<Arc<Registration>, PluginError>
            + Send
            + Sync
            + 'static,
    {
        if self.installers.contains_key(Point::ID) {
            return Err(PluginManifestValidationError::InvalidContribution(
                Point::ID.to_string(),
            ));
        }
        self.installers.insert(
            Point::ID.to_string(),
            Arc::new(move |package| {
                let descriptors = package.manifest.contributes.decode::<Point>()?;
                install(&descriptors, package)
            }),
        );
        Ok(())
    }

    /// Installs `package`'s declarations in the registry's point order (the
    /// manifest's `pointIDs` are sorted). Every registration is owned by the
    /// returned scope, which unwinds if a later point fails.
    pub fn install(&self, package: &ValidatedPluginPackage) -> Result<DisposalScope, PluginError> {
        let scope = DisposalScope::new();
        let result = (|| -> Result<(), PluginError> {
            for id in package.manifest.contributes.point_ids() {
                let Some(install) = self.installers.get(&id) else {
                    return Err(PluginManifestValidationError::InvalidContribution(id).into());
                };
                let registration = install(package)?;
                scope.track_registration(registration);
            }
            Ok(())
        })();
        match result {
            Ok(()) => Ok(scope),
            Err(error) => {
                // Swift: `try? scope.dispose()` then rethrow the original.
                scope.dispose_all();
                Err(error)
            }
        }
    }

    /// Kept so `ContributionPointRegistry` and the manifest share one set of
    /// point ids.
    pub fn point_registry(&self) -> ContributionPointRegistry {
        ContributionPointRegistry::default()
    }
}
