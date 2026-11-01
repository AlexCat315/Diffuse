//! Ordered commit policies and the standard capability planning gates.

use std::sync::Arc;

use crate::intent_runtime_coordinator::IntentRuntimeCoordinatorError;
use crate::invocation::capability_invocation::{
    CapabilityInvocationPlannerError, ConfirmationQuestion,
};
use crate::invocation::capability_invocation_planning::{
    CapabilityInvocationContext, CapabilityInvocationPlanner,
};
use crate::transactions::transaction_ir::{TransactionApprovalPolicy, TransactionIR};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum CommitEntry {
    #[default]
    Ui,
    Mcp {
        session_id: String,
    },
    Headless,
    Human,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CommitRequest {
    pub transaction: TransactionIR,
    pub capability_context: Option<CapabilityInvocationContext>,
    pub entry: CommitEntry,
    pub questions: Vec<ConfirmationQuestion>,
    pub warnings: Vec<String>,
}

impl CommitRequest {
    pub fn new(
        transaction: TransactionIR,
        capability_context: Option<CapabilityInvocationContext>,
        entry: CommitEntry,
        questions: Vec<ConfirmationQuestion>,
        warnings: Vec<String>,
    ) -> Self {
        Self {
            transaction,
            capability_context,
            entry,
            questions,
            warnings,
        }
    }

    pub fn from_transaction(transaction: TransactionIR) -> Self {
        Self::new(transaction, None, CommitEntry::Ui, Vec::new(), Vec::new())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CommitDenialCode {
    ReleasePhase,
    Precondition,
    PluginAuthority,
    LockedEntities,
    SceneNotEditable,
    Busy,
    PendingConfirmation,
    Policy,
}

impl CommitDenialCode {
    pub const fn raw_value(self) -> &'static str {
        match self {
            Self::ReleasePhase => "releasePhase",
            Self::Precondition => "precondition",
            Self::PluginAuthority => "pluginAuthority",
            Self::LockedEntities => "lockedEntities",
            Self::SceneNotEditable => "sceneNotEditable",
            Self::Busy => "busy",
            Self::PendingConfirmation => "pendingConfirmation",
            Self::Policy => "policy",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CommitDenial {
    pub code: CommitDenialCode,
    pub reason: String,
}

impl CommitDenial {
    pub fn new(code: CommitDenialCode, reason: impl Into<String>) -> Self {
        Self {
            code,
            reason: reason.into(),
        }
    }
}

impl std::fmt::Display for CommitDenial {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.reason)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum CommitDecision {
    Proceed(CommitRequest),
    Deny(CommitDenial),
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum CommitPipelineError {
    #[error("{0}")]
    Denied(CommitDenial),
}

/// Preserve handler-specific errors, including their concrete type for downcasts.
pub type CommitHandlerError = Box<dyn std::error::Error + Send + Sync>;
pub type Handler =
    Arc<dyn Fn(CommitRequest) -> Result<CommitDecision, CommitHandlerError> + Send + Sync>;

#[derive(Clone, Default)]
pub struct CommitPipeline {
    pub(crate) handlers: Vec<Handler>,
}

impl CommitPipeline {
    pub fn new(handlers: Vec<Handler>) -> Self {
        Self { handlers }
    }

    pub fn appending(&self, handler: Handler) -> Self {
        let mut handlers = self.handlers.clone();
        handlers.push(handler);
        Self::new(handlers)
    }

    pub fn run(&self, request: CommitRequest) -> Result<CommitRequest, CommitHandlerError> {
        let mut current = request;
        for handler in &self.handlers {
            current = match handler(current)? {
                CommitDecision::Proceed(next) => next,
                CommitDecision::Deny(denial) => {
                    return Err(Box::new(CommitPipelineError::Denied(denial)));
                }
            };
        }
        Ok(current)
    }

    pub fn standard(planner: CapabilityInvocationPlanner) -> Self {
        Self::new(vec![
            Arc::new(Self::require_capability_context),
            Self::plan_capabilities(planner),
            Arc::new(Self::reject_forbidden_policy),
        ])
    }

    fn require_capability_context(
        request: CommitRequest,
    ) -> Result<CommitDecision, CommitHandlerError> {
        if !request.transaction.capability_invocations.is_empty()
            && request.capability_context.is_none()
        {
            return Err(Box::new(
                IntentRuntimeCoordinatorError::MissingCapabilityContext,
            ));
        }
        Ok(CommitDecision::Proceed(request))
    }

    fn plan_capabilities(planner: CapabilityInvocationPlanner) -> Handler {
        Arc::new(move |mut request| {
            let Some(context) = &request.capability_context else {
                return Ok(CommitDecision::Proceed(request));
            };
            let plan = planner.plan(&request.transaction, context)?;
            request.transaction.approval_policy = plan.approval_policy;
            request.questions.extend(plan.questions);
            request.warnings.extend(plan.warnings);
            Ok(CommitDecision::Proceed(request))
        })
    }

    fn reject_forbidden_policy(
        mut request: CommitRequest,
    ) -> Result<CommitDecision, CommitHandlerError> {
        if request.transaction.approval_policy == TransactionApprovalPolicy::Forbidden {
            return Err(Box::new(
                CapabilityInvocationPlannerError::ApprovalForbidden(request.transaction.id),
            ));
        }
        if !request.questions.is_empty() {
            request.transaction.approval_policy = TransactionApprovalPolicy::RequiresApproval;
        }
        Ok(CommitDecision::Proceed(request))
    }
}
