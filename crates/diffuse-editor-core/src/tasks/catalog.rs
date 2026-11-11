//! `Editor/Sources/EditorCore/Tasks/Catalog.swift`.

use std::path::Path;

use diffuse_plugin::contract::plugin_package::ValidatedPluginPackage;
use diffuse_plugin::contribution::processes::process_points::TaskContributionPoint;
use diffuse_plugin::contribution::processes::systems::TaskContribution;

use crate::contributions::host::StepProvider;

/// Enabled task declarations with the permission their commands use.
#[derive(Clone, Debug)]
pub struct TaskProvider {
    pub plugin_id: String,
    pub contribution: TaskContribution,
    pub step: StepProvider,
}

impl TaskProvider {
    /// The first enabled provider whose marker is in `root`.
    pub fn provider_for<'a>(
        root: &Path,
        providers: &'a [TaskProvider],
    ) -> Option<&'a TaskProvider> {
        providers
            .iter()
            .find(|provider| root.join(&provider.contribution.marker).exists())
    }

    pub fn registered(packages: &[ValidatedPluginPackage]) -> Vec<TaskProvider> {
        packages
            .iter()
            .flat_map(|package| {
                package
                    .manifest
                    .contributes
                    .decode_lossy::<TaskContributionPoint>()
                    .into_iter()
                    .filter_map(|contribution| {
                        let process =
                            package.manifest.host.processes.iter().find(|permission| {
                                permission
                                    .entry_points
                                    .contains(&TaskContribution::ENTRY_POINT.to_string())
                            })?;
                        Some(TaskProvider {
                            plugin_id: package.manifest.id.clone(),
                            step: StepProvider {
                                plugin_id: package.manifest.id.clone(),
                                title: contribution.title.clone(),
                                package: package.root_url.clone(),
                                entry_point: TaskContribution::ENTRY_POINT.to_string(),
                                activation_event: format!("onCommand:{}", contribution.id),
                                process: process.clone(),
                            },
                            contribution,
                        })
                    })
                    .collect::<Vec<_>>()
            })
            .collect()
    }
}
