//! `LicenseGate.swift` — distribution-mode licensing decisions for perception models.

use std::collections::BTreeSet;

use crate::core::perception_contracts::{PerceptionLicenseMetadata, PerceptionModelManifest};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum PerceptionDistributionMode {
    #[default]
    LocalDev,
    InternalTool,
    CommercialBinary,
    CloudService,
}

impl PerceptionDistributionMode {
    /// Swift `rawValue`.
    pub const fn as_str(self) -> &'static str {
        match self {
            PerceptionDistributionMode::LocalDev => "local_dev",
            PerceptionDistributionMode::InternalTool => "internal_tool",
            PerceptionDistributionMode::CommercialBinary => "commercial_binary",
            PerceptionDistributionMode::CloudService => "cloud_service",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LicenseGateDecision {
    Allowed,
    AllowedWithAttribution,
    DisabledNonCommercial,
    DisabledShareAlike,
    DisabledUnknownWeightsLicense,
    DisabledUnknownDatasetLineage,
    DisabledPolicyViolation(String),
}

impl std::fmt::Display for LicenseGateDecision {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LicenseGateDecision::Allowed => formatter.write_str("allowed"),
            LicenseGateDecision::AllowedWithAttribution => {
                formatter.write_str("allowed_with_attribution")
            }
            LicenseGateDecision::DisabledNonCommercial => {
                formatter.write_str("disabled_non_commercial")
            }
            LicenseGateDecision::DisabledShareAlike => formatter.write_str("disabled_share_alike"),
            LicenseGateDecision::DisabledUnknownWeightsLicense => {
                formatter.write_str("disabled_unknown_weights_license")
            }
            LicenseGateDecision::DisabledUnknownDatasetLineage => {
                formatter.write_str("disabled_unknown_dataset_lineage")
            }
            LicenseGateDecision::DisabledPolicyViolation(reason) => {
                write!(formatter, "disabled_policy_violation: {reason}")
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LicenseGatePolicy {
    pub allowed_code_licenses: BTreeSet<String>,
    pub allowed_weights_licenses: BTreeSet<String>,
    pub allow_unknown_dataset_lineage_in_local_dev: bool,
}

impl LicenseGatePolicy {
    /// Swift `LicenseGatePolicy.commercialDefault`.
    pub fn commercial_default() -> Self {
        LicenseGatePolicy {
            allowed_code_licenses: [
                "Apache-2.0",
                "MIT",
                "BSD-2-Clause",
                "BSD-3-Clause",
                "Apple-System",
            ]
            .into_iter()
            .map(str::to_string)
            .collect(),
            allowed_weights_licenses: [
                "Apache-2.0",
                "MIT",
                "BSD-2-Clause",
                "BSD-3-Clause",
                "Public-Domain",
                "Cove-Owned",
                "Apple-System",
            ]
            .into_iter()
            .map(str::to_string)
            .collect(),
            allow_unknown_dataset_lineage_in_local_dev: true,
        }
    }

    pub fn new(
        allowed_code_licenses: BTreeSet<String>,
        allowed_weights_licenses: BTreeSet<String>,
        allow_unknown_dataset_lineage_in_local_dev: bool,
    ) -> Self {
        LicenseGatePolicy {
            allowed_code_licenses,
            allowed_weights_licenses,
            allow_unknown_dataset_lineage_in_local_dev,
        }
    }
}

impl Default for LicenseGatePolicy {
    fn default() -> Self {
        Self::commercial_default()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LicenseGate {
    pub policy: LicenseGatePolicy,
}

impl LicenseGate {
    pub fn new(policy: LicenseGatePolicy) -> Self {
        LicenseGate { policy }
    }

    pub fn evaluate(
        &self,
        manifest: &PerceptionModelManifest,
        distribution_mode: PerceptionDistributionMode,
    ) -> LicenseGateDecision {
        let license: &PerceptionLicenseMetadata = &manifest.license;
        if license.non_commercial_only || license.commercial_use.to_lowercase().contains("non") {
            return LicenseGateDecision::DisabledNonCommercial;
        }
        if license.requires_share_alike {
            return LicenseGateDecision::DisabledShareAlike;
        }
        if !self
            .policy
            .allowed_code_licenses
            .contains(&license.code_license)
        {
            return LicenseGateDecision::DisabledPolicyViolation(format!(
                "code license '{}' is not allowed",
                license.code_license
            ));
        }
        if !self
            .policy
            .allowed_weights_licenses
            .contains(&license.weights_license)
        {
            if license.weights_license.trim().is_empty()
                || license.weights_license.to_lowercase() == "unknown"
            {
                return LicenseGateDecision::DisabledUnknownWeightsLicense;
            }
            return LicenseGateDecision::DisabledPolicyViolation(format!(
                "weights license '{}' is not allowed",
                license.weights_license
            ));
        }
        if license.dataset_lineage.is_empty()
            && !(distribution_mode == PerceptionDistributionMode::LocalDev
                && self.policy.allow_unknown_dataset_lineage_in_local_dev)
        {
            return LicenseGateDecision::DisabledUnknownDatasetLineage;
        }
        if license.requires_attribution {
            LicenseGateDecision::AllowedWithAttribution
        } else {
            LicenseGateDecision::Allowed
        }
    }
}

impl Default for LicenseGate {
    fn default() -> Self {
        LicenseGate::new(LicenseGatePolicy::commercial_default())
    }
}
