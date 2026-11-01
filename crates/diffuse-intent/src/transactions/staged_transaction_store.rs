//! Thread-safe staging of one previewed transaction and its lifecycle events.

use std::collections::BTreeMap;
use std::sync::{Mutex, MutexGuard};

use diffuse_capability::support::swift_date::SwiftDate;
use diffuse_observation::event_envelope::{EventPayloadRef, EventProvenance, EventValue};
use diffuse_observation::event_kind_registry::EventKindId;

use super::transaction_executor::{
    TransactionApplyResult, TransactionExecutionContext, TransactionExecutor,
};
use super::transaction_ir::{
    TransactionApprovalPolicy, TransactionDomain, TransactionIR, TransactionPreviewResult,
};

#[derive(Clone, Debug, PartialEq)]
pub struct StagedTransactionSnapshot {
    pub transaction: TransactionIR,
    pub preview: TransactionPreviewResult,
    pub staged_at: SwiftDate,
}

impl StagedTransactionSnapshot {
    pub fn new(
        transaction: TransactionIR,
        preview: TransactionPreviewResult,
        staged_at: SwiftDate,
    ) -> Self {
        Self {
            transaction,
            preview,
            staged_at,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct StageTransactionResult {
    pub transaction_id: String,
    pub preview: TransactionPreviewResult,
}

impl StageTransactionResult {
    pub fn new(transaction_id: impl Into<String>, preview: TransactionPreviewResult) -> Self {
        Self {
            transaction_id: transaction_id.into(),
            preview,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ApplyStagedTransactionResult {
    pub had_transaction: bool,
    pub transaction_id: Option<String>,
    pub apply_result: Option<TransactionApplyResult>,
}

impl ApplyStagedTransactionResult {
    pub fn new(
        had_transaction: bool,
        transaction_id: Option<String>,
        apply_result: Option<TransactionApplyResult>,
    ) -> Self {
        Self {
            had_transaction,
            transaction_id,
            apply_result,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiscardStagedTransactionResult {
    pub had_transaction: bool,
    pub transaction_id: Option<String>,
}

impl DiscardStagedTransactionResult {
    pub fn new(had_transaction: bool, transaction_id: Option<String>) -> Self {
        Self {
            had_transaction,
            transaction_id,
        }
    }
}

pub type StagedTransactionError = Box<dyn std::error::Error + Send + Sync>;

/// Callers share this store across threads; only the optional staged snapshot is locked.
pub struct StagedTransactionStore {
    executor: TransactionExecutor,
    staged: Mutex<Option<StagedTransactionSnapshot>>,
}

impl StagedTransactionStore {
    pub fn new(executor: TransactionExecutor) -> Self {
        Self {
            executor,
            staged: Mutex::new(None),
        }
    }

    fn state(&self) -> MutexGuard<'_, Option<StagedTransactionSnapshot>> {
        self.staged
            .lock()
            .unwrap_or_else(|error| error.into_inner())
    }

    pub fn staged_transaction(&self) -> Option<StagedTransactionSnapshot> {
        self.state().clone()
    }

    pub fn stage(
        &self,
        transaction: &TransactionIR,
        context: &TransactionExecutionContext,
    ) -> Result<StageTransactionResult, StagedTransactionError> {
        let preview = self.executor.preview(transaction, context)?;
        let snapshot =
            StagedTransactionSnapshot::new(transaction.clone(), preview.clone(), SwiftDate::now());
        *self.state() = Some(snapshot);
        // Publication is outside the lock and follows staging, including on failure.
        self.publish(
            EventKindId::TransactionStaged,
            transaction,
            &preview,
            None,
            context,
        )?;
        Ok(StageTransactionResult::new(&transaction.id, preview))
    }

    pub fn apply_staged_transaction(
        &self,
        context: &mut TransactionExecutionContext,
    ) -> Result<ApplyStagedTransactionResult, StagedTransactionError> {
        let Some(snapshot) = self.staged_transaction() else {
            return Ok(ApplyStagedTransactionResult::new(false, None, None));
        };
        let result = self.executor.apply(&snapshot.transaction, context)?;
        // A failed apply retains the snapshot; successful apply clears it.
        *self.state() = None;
        Ok(ApplyStagedTransactionResult::new(
            true,
            Some(snapshot.transaction.id),
            Some(result),
        ))
    }

    pub fn discard_staged_transaction(
        &self,
        context: Option<&TransactionExecutionContext>,
    ) -> Result<DiscardStagedTransactionResult, StagedTransactionError> {
        let snapshot = self.state().take();
        let Some(snapshot) = snapshot else {
            return Ok(DiscardStagedTransactionResult::new(false, None));
        };
        if let Some(context) = context {
            self.publish(
                EventKindId::TransactionDiscarded,
                &snapshot.transaction,
                &snapshot.preview,
                Some("discarded"),
                context,
            )?;
        }
        Ok(DiscardStagedTransactionResult::new(
            true,
            Some(snapshot.transaction.id),
        ))
    }

    fn publish(
        &self,
        kind: EventKindId,
        transaction: &TransactionIR,
        preview: &TransactionPreviewResult,
        message: Option<&str>,
        context: &TransactionExecutionContext,
    ) -> Result<(), StagedTransactionError> {
        let Some(bus) = &context.observation_bus else {
            return Ok(());
        };
        let approval_policy = match transaction.approval_policy {
            TransactionApprovalPolicy::Automatic => "automatic",
            TransactionApprovalPolicy::RequiresApproval => "requiresApproval",
            TransactionApprovalPolicy::Forbidden => "forbidden",
        };
        let domains = preview
            .changed_domains
            .iter()
            .map(|domain| {
                EventValue::String(
                    match domain {
                        TransactionDomain::Scene => "scene",
                        TransactionDomain::Sequence => "sequence",
                        TransactionDomain::Asset => "asset",
                    }
                    .to_string(),
                )
            })
            .collect();
        let entity_values = |ids: &[u64]| {
            EventValue::Array(
                ids.iter()
                    .map(|&id| {
                        EventValue::Integer(
                            i64::try_from(id).expect("entity ID must fit Swift Int64"),
                        )
                    })
                    .collect(),
            )
        };
        let payload = BTreeMap::from([
            (
                "transaction_id".to_string(),
                EventValue::String(transaction.id.clone()),
            ),
            (
                "summary".to_string(),
                EventValue::String(transaction.summary.clone()),
            ),
            (
                "approval_policy".to_string(),
                EventValue::String(approval_policy.to_string()),
            ),
            ("changed_domains".to_string(), EventValue::Array(domains)),
            (
                "created_entity_ids".to_string(),
                entity_values(&preview.created_entity_ids),
            ),
            (
                "deleted_entity_ids".to_string(),
                entity_values(&preview.deleted_entity_ids),
            ),
            (
                "message".to_string(),
                message
                    .map(|v| EventValue::String(v.to_string()))
                    .unwrap_or(EventValue::Null),
            ),
        ]);
        let _ = bus.publish(
            kind,
            &context.transaction_stream_id,
            EventPayloadRef::Inline { record: payload },
            context.event_origin.clone(),
            None,
            Some(transaction.id.clone()),
            None,
            EventProvenance::Authored,
            1,
        )?;
        Ok(())
    }
}

impl Default for StagedTransactionStore {
    fn default() -> Self {
        Self::new(TransactionExecutor::new())
    }
}
