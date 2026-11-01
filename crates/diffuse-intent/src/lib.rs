//! Crate root. See MIGRATION.md §5.
pub mod capabilities;
pub mod intent_runtime_coordinator;
pub mod invocation;
pub mod pipeline;
pub mod planning;
#[cfg(test)]
pub mod tests;
pub mod transactions;

pub use capabilities::built_in_typed_capabilities::BuiltInTypedCapabilityCatalog;
pub use capabilities::cove_capability::{
    AnyCapabilityRegistration, CapabilityPreparationContext, CapabilityPreparationEntity,
    CapabilityPreparationError, CapabilityPreparationMaterial, CapabilityPreparationTransform,
    CapabilityPreview, CapabilityRegistrationError, CoveCapability, CoveCapabilityInput,
    PreparedCapability,
};
pub use intent_runtime_coordinator::{
    CapabilityInvocationDisposition, CapabilityInvocationResult, IntentRuntimeCoordinator,
    IntentRuntimeCoordinatorError, validate_confirmation_resolution,
};
pub use invocation::capability_invocation_planning::{
    CapabilityInvocationContext, CapabilityInvocationPlan, CapabilityInvocationPlanner,
    CapabilityValidationFailure,
};
pub use pipeline::commit_pipeline::{
    CommitDecision, CommitDenial, CommitDenialCode, CommitEntry, CommitHandlerError,
    CommitPipeline, CommitPipelineError, CommitRequest, Handler,
};
pub use transactions::transaction_executor::{
    TransactionApplyResult, TransactionExecutionContext, TransactionExecutionError,
    TransactionExecutor, TransactionExecutorError,
};
