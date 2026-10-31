//! Version control and task contribution validation.
//!
//! Ported from
//! `Engine/Sources/PluginRuntime/Contribution/Processes/ProcessPoints.swift`.

use crate::contract::host_permissions::PluginHostPermissions;
use crate::contract::plugin_contract::PluginContract;
use crate::contract::plugin_manifest::PluginManifestValidationError;
use crate::contribution::processes::inputs::step_input_type;
use crate::contribution::processes::systems::{TaskContribution, VersionControlContribution};
use crate::contribution::registry::{ContributionPointSpec, ContributionValidation};

pub enum VersionControlContributionPoint {}

impl ContributionPointSpec for VersionControlContributionPoint {
    type Descriptor = VersionControlContribution;

    const ID: &'static str = "cove.vcs/v1";

    fn validate(
        value: &VersionControlContribution,
        host: &PluginHostPermissions,
    ) -> Result<(), PluginManifestValidationError> {
        // Swift compared `host.processes[0].entryPoints == [entryPoint]`, an
        // exact one-element list.
        let single_entry_point = host.processes.len() == 1
            && host.processes[0].entry_points
                == vec![VersionControlContribution::ENTRY_POINT.to_string()];
        if !(ContributionValidation::identifier(&value.id)
            && ContributionValidation::title(&value.title)
            && ContributionValidation::file_name(&value.marker)
            && ContributionValidation::file_name(&value.ignore_file)
            && single_entry_point)
        {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }

    fn validate_runtime(
        _descriptor: &VersionControlContribution,
        contract: Option<&PluginContract>,
    ) -> Result<(), PluginManifestValidationError> {
        let matches = contract
            .and_then(|contract| {
                contract
                    .capability_inputs
                    .iter()
                    .find(|input| input.name == VersionControlContribution::ENTRY_POINT)
            })
            .is_some_and(|input| input.input_type == step_input_type());
        if !matches {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }
}

pub enum TaskContributionPoint {}

impl ContributionPointSpec for TaskContributionPoint {
    type Descriptor = TaskContribution;

    const ID: &'static str = "cove.tasks/v1";

    fn validate(
        value: &TaskContribution,
        host: &PluginHostPermissions,
    ) -> Result<(), PluginManifestValidationError> {
        let matching = host
            .processes
            .iter()
            .filter(|permission| {
                permission
                    .entry_points
                    .contains(&TaskContribution::ENTRY_POINT.to_string())
            })
            .count();
        if !(ContributionValidation::identifier(&value.id)
            && ContributionValidation::title(&value.title)
            && ContributionValidation::file_name(&value.marker)
            && matching == 1)
        {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }

    fn validate_runtime(
        _descriptor: &TaskContribution,
        contract: Option<&PluginContract>,
    ) -> Result<(), PluginManifestValidationError> {
        let matches = contract
            .and_then(|contract| {
                contract
                    .capability_inputs
                    .iter()
                    .find(|input| input.name == TaskContribution::ENTRY_POINT)
            })
            .is_some_and(|input| input.input_type == step_input_type());
        if !matches {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }
}
