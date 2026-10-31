//! Dependent resolution and withdrawal.
//!
//! Ported from `Engine/Sources/PluginRuntime/Lifecycle/Withdrawal.swift`.

use std::collections::BTreeSet;

use crate::PluginError;
use crate::contract::requirements::PluginRequirementResolver;
use crate::lifecycle::manager::PluginManager;

impl PluginManager {
    pub(crate) fn dependents_of(&self, id: &str) -> Vec<String> {
        let capabilities: BTreeSet<String> = {
            let entries = self.lock_entries();
            entries
                .entries
                .get(id)
                .map(|entry| {
                    entry
                        .inspection
                        .contracts
                        .iter()
                        .map(|contract| contract.id.clone())
                        .collect()
                })
                .unwrap_or_default()
        };
        PluginRequirementResolver::dependents(id, &capabilities, &self.enabled_manifests())
    }

    pub(crate) fn dependent_closure(&self, id: &str) -> Vec<String> {
        // Swift was post-order: a plugin is appended only after every plugin that
        // depends on it, so withdrawal releases dependents first. The explicit
        // stack carries the pending exit so the recursion shape is preserved
        // without a recursive call.
        enum Step {
            Enter(String),
            Exit(String),
        }
        let mut seen: BTreeSet<String> = BTreeSet::new();
        let mut ordered: Vec<String> = Vec::new();
        let mut stack: Vec<Step> = vec![Step::Enter(id.to_string())];
        while let Some(step) = stack.pop() {
            match step {
                Step::Enter(current) => {
                    if !seen.insert(current.clone()) {
                        continue;
                    }
                    stack.push(Step::Exit(current.clone()));
                    for dependent in self.dependents_of(&current).into_iter().rev() {
                        stack.push(Step::Enter(dependent));
                    }
                }
                Step::Exit(current) => ordered.push(current),
            }
        }
        ordered
    }

    pub(crate) fn withdraw(
        &self,
        ids: &[String],
        failure: Option<String>,
    ) -> Result<(), PluginError> {
        let mut first_error: Option<PluginError> = None;
        let requested: BTreeSet<&String> = ids.iter().collect();
        let mut seen: BTreeSet<String> = BTreeSet::new();
        let ordered: Vec<String> = ids
            .iter()
            .flat_map(|id| self.dependent_closure(id))
            .filter(|id| requested.contains(id) && seen.insert(id.clone()))
            .collect();
        for id in ordered {
            let removed = {
                let mut entries = self.lock_entries();
                match entries.entries.get_mut(&id) {
                    Some(entry) => {
                        let previous = (entry.scope.take(), entry.binding.take());
                        entry.failure = failure.clone();
                        previous
                    }
                    None => (None, None),
                }
            };
            if let Some(scope) = removed.0 {
                scope.dispose_all();
            }
            if let Some(binding) = removed.1 {
                let driver = self.driver();
                if let Some(driver) = driver
                    && let Err(error) = (driver.deactivate)(&binding)
                    && first_error.is_none()
                {
                    first_error = Some(error);
                }
            }
        }
        match first_error {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }
}
