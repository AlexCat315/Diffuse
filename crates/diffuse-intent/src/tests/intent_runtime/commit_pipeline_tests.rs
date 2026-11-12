//! Ported from `Engine/Tests/IntentRuntimeTests/CommitPipelineTests.swift`.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use diffuse_capability::capability_contract::CapabilityAccess;
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::release::release_phase_gate::ReleasePhaseGate;
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::scene_runtime::SceneRuntime;

use crate::intent_runtime_coordinator::{IntentRuntimeCoordinator, IntentRuntimeCoordinatorError};
use crate::invocation::ambiguity_scorer::AmbiguityScorer;
use crate::invocation::capability_invocation::{
    CapabilityInvocationPlannerError, ConfirmationAnswer, ConfirmationAnswerOutcome,
    ConfirmationQuestion, ConfirmationQuestionKind, ConfirmationResolution, ConfirmationSeverity,
};
use crate::invocation::capability_invocation_planning::{
    CapabilityInvocationContext, CapabilityInvocationPlanner,
};
use crate::pipeline::commit_pipeline::{
    CommitDecision, CommitDenial, CommitDenialCode, CommitEntry, CommitPipeline,
    CommitPipelineError, CommitRequest, Handler,
};
use crate::transactions::transaction_executor::TransactionExecutionContext;
use crate::transactions::transaction_ir::{
    CapabilityInvocationRecord, TransactionApprovalPolicy, TransactionIR, TransactionProvenance,
};

type Trace = Arc<Mutex<Vec<String>>>;

fn record(trace: &Trace, step: &str) {
    trace
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .push(step.to_string());
}

fn trace_values(trace: &Trace) -> Vec<String> {
    trace
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .clone()
}

fn transaction(
    summary: &str,
    approval_policy: TransactionApprovalPolicy,
    with_invocation: bool,
) -> TransactionIR {
    let mut transaction = TransactionIR::new(summary, Vec::new(), TransactionProvenance::Inferred);
    transaction.approval_policy = approval_policy;
    if with_invocation {
        transaction.capability_invocations = vec![CapabilityInvocationRecord::new(
            "scene.set_name",
            1,
            "schema",
            "digest",
            CapabilityAccess::ReversibleWrite,
        )];
    }
    transaction
}

fn default_transaction() -> TransactionIR {
    transaction("Edit", TransactionApprovalPolicy::Automatic, false)
}

fn question(
    id: &str,
    kind: ConfirmationQuestionKind,
    severity: ConfirmationSeverity,
) -> ConfirmationQuestion {
    ConfirmationQuestion::new(id, kind, "Apply?", severity, true, 0.5)
}

fn planner_error(
    error: &crate::pipeline::commit_pipeline::CommitHandlerError,
) -> Option<&CapabilityInvocationPlannerError> {
    error.downcast_ref::<CapabilityInvocationPlannerError>()
}

/// Handlers run in order and the first denial stops the pipeline.
#[test]
fn ordered_short_circuit() {
    let trace: Trace = Arc::new(Mutex::new(Vec::new()));
    let denial = CommitDenial::new(CommitDenialCode::LockedEntities, "locked entity");
    let recorded = trace.clone();
    let first: Handler = Arc::new(move |request| {
        record(&recorded, "first");
        Ok(CommitDecision::Proceed(request))
    });
    let recorded = trace.clone();
    let deny = denial.clone();
    let second: Handler = Arc::new(move |_| {
        record(&recorded, "second");
        Ok(CommitDecision::Deny(deny.clone()))
    });
    let recorded = trace.clone();
    let third: Handler = Arc::new(move |request| {
        record(&recorded, "third");
        Ok(CommitDecision::Proceed(request))
    });
    let pipeline = CommitPipeline::new(vec![first, second, third]);

    let error = pipeline
        .run(CommitRequest::from_transaction(default_transaction()))
        .expect_err("denied");
    let pipeline_error = error
        .downcast_ref::<CommitPipelineError>()
        .expect("pipeline denial");
    assert_eq!(pipeline_error, &CommitPipelineError::Denied(denial));
    assert_eq!(trace_values(&trace), vec!["first", "second"]);
}

/// Handlers can rewrite the request and accumulate confirmation material.
#[test]
fn rewrite_accumulates() {
    let mut sample = question(
        "q1",
        ConfirmationQuestionKind::ApproveDestructive,
        ConfirmationSeverity::Warn,
    );
    sample.source_proposal_ids = vec!["tx".to_string()];
    let expected = sample.clone();

    let first: Handler = {
        let question = sample.clone();
        Arc::new(move |request| {
            let mut next = request;
            next.transaction.summary = "Rewritten".to_string();
            next.transaction.approval_policy = TransactionApprovalPolicy::RequiresApproval;
            next.questions.push(question.clone());
            next.warnings.push("ambiguity".to_string());
            Ok(CommitDecision::Proceed(next))
        })
    };
    let second: Handler = Arc::new(|request| {
        let mut next = request;
        next.warnings.push("policy".to_string());
        Ok(CommitDecision::Proceed(next))
    });
    let pipeline = CommitPipeline::new(vec![first, second]);

    let outcome = pipeline
        .run(CommitRequest::from_transaction(default_transaction()))
        .expect("pipeline outcome");
    assert_eq!(outcome.transaction.summary, "Rewritten");
    assert_eq!(
        outcome.transaction.approval_policy,
        TransactionApprovalPolicy::RequiresApproval
    );
    assert_eq!(outcome.questions, vec![expected]);
    assert_eq!(outcome.warnings, vec!["ambiguity", "policy"]);
}

/// The standard pipeline requires a capability context for invocation-carrying
/// transactions.
#[test]
fn standard_requires_context() {
    let pipeline = CommitPipeline::standard(CapabilityInvocationPlanner::default());
    let error = pipeline
        .run(CommitRequest::from_transaction(transaction(
            "Edit",
            TransactionApprovalPolicy::Automatic,
            true,
        )))
        .expect_err("missing context");
    assert!(error.is::<IntentRuntimeCoordinatorError>());

    let outcome = pipeline
        .run(CommitRequest::from_transaction(default_transaction()))
        .expect("pipeline outcome");
    assert_eq!(
        outcome.transaction.approval_policy,
        TransactionApprovalPolicy::Automatic
    );
    assert!(outcome.questions.is_empty());
    assert!(outcome.warnings.is_empty());
}

/// Registered policies run before the standard gates and revoke cleanly.
#[test]
fn registered_policies_run_first() {
    let coordinator = IntentRuntimeCoordinator::default();
    let mut execution_context = TransactionExecutionContext::default();
    let invocation = transaction("Edit", TransactionApprovalPolicy::Automatic, true);

    let denial = CommitDenial::new(CommitDenialCode::Policy, "blocked by test policy");
    let deny = denial.clone();
    let registration = coordinator
        .register_commit_policy(Arc::new(move |_| Ok(CommitDecision::Deny(deny.clone()))));
    let error = coordinator
        .submit_plan(&invocation, &mut execution_context, None, CommitEntry::Ui)
        .expect_err("policy denial");
    let pipeline_error = error
        .downcast_ref::<CommitPipelineError>()
        .expect("pipeline denial");
    assert_eq!(pipeline_error, &CommitPipelineError::Denied(denial));

    registration.dispose();
    let error = coordinator
        .submit_plan(&invocation, &mut execution_context, None, CommitEntry::Ui)
        .expect_err("standard gate");
    assert!(error.is::<IntentRuntimeCoordinatorError>());
}

/// The standard pipeline rejects a forbidden policy.
#[test]
fn standard_rejects_forbidden() {
    let pipeline = CommitPipeline::standard(CapabilityInvocationPlanner::default());
    let error = pipeline
        .run(CommitRequest::from_transaction(transaction(
            "Edit",
            TransactionApprovalPolicy::Forbidden,
            false,
        )))
        .expect_err("forbidden policy");
    match planner_error(&error) {
        Some(CapabilityInvocationPlannerError::ApprovalForbidden(_)) => {}
        other => panic!("expected approvalForbidden, got {other:?}"),
    }
}

/// Policy questions force approval even without a capability context.
#[test]
fn questions_require_approval() {
    let coordinator = IntentRuntimeCoordinator::default();
    coordinator.register_commit_policy(Arc::new(|request| {
        let mut next = request;
        next.questions = vec![question(
            "policy",
            ConfirmationQuestionKind::ChooseOne,
            ConfirmationSeverity::Info,
        )];
        Ok(CommitDecision::Proceed(next))
    }));
    let mut context = TransactionExecutionContext::new(
        Some(scene()),
        None,
        None,
        None,
        diffuse_observation::event_envelope::EventOrigin::tool(None, None),
        "scene:main",
        "transaction",
        "asset:project",
        "ui:confirmation",
    );
    let result = coordinator
        .submit_plan(&default_transaction(), &mut context, None, CommitEntry::Ui)
        .expect("submitted");
    assert_eq!(
        result.disposition,
        crate::CapabilityInvocationDisposition::ConfirmationRequested
    );
    assert_eq!(
        result.confirmation_request.map(|request| request
            .questions
            .iter()
            .map(|q| q.id.clone())
            .collect::<Vec<_>>()),
        Some(vec!["policy".to_string()])
    );
}

/// Rewritten capability context survives staging and all confirmation questions
/// survive both rounds.
#[test]
fn rewritten_context_and_questions_survive_confirmation() {
    let registry = CapabilityRegistry::default_registry();
    let descriptor = registry
        .descriptor("scene.get_entities")
        .expect("descriptor");
    let contract = descriptor.contract();
    let mut transaction =
        TransactionIR::new("Inspect", Vec::new(), TransactionProvenance::Inferred);
    transaction.capability_invocations = vec![CapabilityInvocationRecord::new(
        descriptor.verb.clone(),
        descriptor.version,
        contract.schema_hash.clone(),
        "digest",
        CapabilityAccess::Read,
    )];
    let coordinator = IntentRuntimeCoordinator::default();
    coordinator.register_commit_policy(Arc::new(|request| {
        let mut next = request;
        next.capability_context = Some(CapabilityInvocationContext::default());
        next.questions = vec![
            question(
                "scope",
                ConfirmationQuestionKind::ChooseOne,
                ConfirmationSeverity::Info,
            ),
            question(
                "risk",
                ConfirmationQuestionKind::ApproveDestructive,
                ConfirmationSeverity::Destructive,
            ),
        ];
        Ok(CommitDecision::Proceed(next))
    }));
    let mut context = TransactionExecutionContext::new(
        Some(scene()),
        None,
        None,
        None,
        diffuse_observation::event_envelope::EventOrigin::tool(None, None),
        "scene:main",
        "transaction",
        "asset:project",
        "ui:confirmation",
    );

    let first = coordinator
        .submit_plan(&transaction, &mut context, None, CommitEntry::Ui)
        .expect("first round");
    let first_request = first.confirmation_request.clone().expect("first request");
    assert_eq!(
        first_request
            .questions
            .iter()
            .map(|question| question.id.clone())
            .collect::<Vec<_>>(),
        vec!["scope".to_string()]
    );

    let accept = |request: &crate::invocation::capability_invocation::ConfirmationRequestBatch| {
        ConfirmationResolution::new(
            request.batch_id.clone(),
            request.correlation_id.clone(),
            request
                .questions
                .iter()
                .map(|question| {
                    ConfirmationAnswer::new(
                        question.id.clone(),
                        ConfirmationAnswerOutcome::Accepted,
                    )
                })
                .collect(),
            false,
        )
    };
    let second = coordinator
        .resolve_plan_confirmation(&accept(&first_request), &mut context)
        .expect("second round");
    let second_request = second.confirmation_request.clone().expect("second request");
    assert_eq!(
        second_request
            .questions
            .iter()
            .map(|question| question.id.clone())
            .collect::<Vec<_>>(),
        vec!["risk".to_string()]
    );

    coordinator.configure_capability_planner(CapabilityInvocationPlanner::new(
        CapabilityRegistry::new(Vec::new()),
        ReleasePhaseGate::default(),
        AmbiguityScorer::default(),
        false,
        BTreeMap::new(),
        Arc::new(|_| true),
    ));
    let error = coordinator
        .resolve_plan_confirmation(&accept(&second_request), &mut context)
        .expect_err("empty registry rejects planning");
    assert!(error.is::<CapabilityInvocationPlannerError>());
    assert!(coordinator.pending_confirmation_request().is_none());
}

fn scene() -> SceneRuntime {
    SceneRuntime::new(ComponentRegistry::built_in())
}
