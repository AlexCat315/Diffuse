//! Ported from `Engine/Tests/PluginRuntimeTests/Processes.swift`.
//!
//! Environment-dependent: needs `/usr/bin/printf` and a POSIX process model, the
//! same `#if os(macOS) || os(Linux)` guard as Swift. Swift set a one-minute time
//! limit on the suite; each loop here is bounded the same way.

#[cfg(any(target_os = "macos", target_os = "linux"))]
mod enabled {
    use diffuse_capability::capability_contract::CapabilityAccess;
    use diffuse_capability::capability_registry::CapabilityRegistry;
    use diffuse_capability::support::swift_date::SwiftDate;

    use crate::contract::bun_plugin_contract::BunPluginContract;
    use crate::contract::host_permissions::{PluginHostPermissions, PluginProcessPermission};
    use crate::contract::plugin_manifest::{CovePluginManifest, PluginImportPermission};
    use crate::contract::plugin_package::{ValidatedPluginPackage, ValidatedPluginRuntime};
    use crate::plugin_authorization::{
        PluginAuthorizationRecord, PluginCapabilityRegistryBuilder, PluginContractDeriver,
        PluginExecutionBinding, PluginInspection,
    };
    use crate::processes::contract::{
        Operation, PluginProcessContext, PluginProcessError, PluginProcessRequest,
    };
    use crate::processes::service::PluginProcessService;

    fn inspection(id: &str) -> PluginInspection {
        let mut rule = PluginProcessPermission::new("echo", "printf");
        rule.argument_prefix = vec!["hello".to_string()];
        rule.entry_points = vec!["launch".to_string()];
        let mut permissions = PluginHostPermissions::new();
        permissions.processes = vec![rule];
        let manifest = CovePluginManifest::new(
            id,
            1,
            "Process test",
            "fixture",
            CapabilityAccess::Read,
            vec![PluginImportPermission::Process],
            Vec::new(),
            Vec::new(),
            permissions,
            Default::default(),
        );
        let wit = BunPluginContract::decode(
            br#"{"version":1,"entries":[{"name":"launch","title":"Launch","description":"","input":{"record":{"enabled":"bool"}}}]}"#,
            &[PluginImportPermission::Process],
        )
        .expect("contract decodes");
        let package = ValidatedPluginPackage::new(
            std::path::PathBuf::from("/tmp/test.coveplugin"),
            manifest,
            Some(ValidatedPluginRuntime {
                entry_url: std::path::PathBuf::from("/tmp/component.wasm"),
                contract_url: std::path::PathBuf::from("/tmp/capabilities.wit"),
                contract: wit,
                code_hash: "code".to_string(),
                contract_hash: "contract".to_string(),
            }),
        );
        PluginInspection::from_package(&package, PluginContractDeriver::contracts(&package))
    }

    fn mount(service: &PluginProcessService, inspection: &PluginInspection) {
        let mut context = PluginProcessContext::new(std::env::temp_dir());
        context.executables.insert(
            "printf".to_string(),
            std::path::PathBuf::from("/usr/bin/printf"),
        );
        let authorization = PluginAuthorizationRecord::from_inspection(inspection, SwiftDate(0.0))
            .expect("authorizes");
        service
            .mount(inspection, &authorization, context)
            .expect("mounts");
    }

    // @Test("exact arguments, environment and host entry points are enforced")
    #[test]
    fn permissions() {
        let service = PluginProcessService::new();
        let inspection = inspection("test.process");
        mount(&service, &inspection);
        let id = inspection.manifest.id.clone();

        let mut request = PluginProcessRequest::new(Operation::Start);
        request.permission = Some("echo".to_string());
        request.arguments = vec!["hello".to_string(), "extra".to_string()];
        assert_eq!(
            service
                .perform(&id, "launch", &request)
                .map_err(|error| error.to_string()),
            Err(crate::PluginError::Process(PluginProcessError::ArgumentsDenied).to_string())
        );

        request.arguments = vec!["hello".to_string()];
        request
            .environment
            .insert("LD_PRELOAD".to_string(), "untrusted".to_string());
        assert_eq!(
            service
                .perform(&id, "launch", &request)
                .map_err(|error| error.to_string()),
            Err(crate::PluginError::Process(PluginProcessError::EnvironmentDenied).to_string())
        );

        request.environment.clear();
        assert_eq!(
            service
                .perform(&id, "read-scene", &request)
                .map_err(|error| error.to_string()),
            Err(crate::PluginError::Process(PluginProcessError::NotAuthorized).to_string())
        );
        service.unmount(&id);
    }

    // @Test("a running process survives individual calls and returns drained output")
    #[test]
    fn lifecycle() {
        let service = PluginProcessService::new();
        let inspection = inspection("test.process");
        mount(&service, &inspection);
        let id = inspection.manifest.id.clone();

        let mut start = PluginProcessRequest::new(Operation::Start);
        start.permission = Some("echo".to_string());
        start.arguments = vec!["hello".to_string()];
        let handle = service
            .perform(&id, "launch", &start)
            .expect("starts process")
            .handle;

        let mut poll = PluginProcessRequest::new(Operation::Poll);
        poll.handle = Some(handle);
        let mut output: Vec<u8> = Vec::new();
        let mut status: Option<i32> = None;
        for _ in 0..100 {
            let update = service.perform(&id, "launch", &poll).expect("polls");
            output.extend_from_slice(update.stdout.as_slice());
            status = update.exit_status;
            if status.is_some() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert_eq!(String::from_utf8_lossy(&output), "hello");
        assert_eq!(status, Some(0));
        service.unmount(&id);
    }

    // @Test("another plugin and a later mount cannot reuse handles")
    #[test]
    fn revocation() {
        let service = PluginProcessService::new();
        let first = inspection("test.process");
        let second = inspection("test.second");
        mount(&service, &first);
        mount(&service, &second);

        let mut start = PluginProcessRequest::new(Operation::Start);
        start.permission = Some("echo".to_string());
        start.arguments = vec!["hello".to_string()];
        let handle = service
            .perform(&first.manifest.id, "launch", &start)
            .expect("starts process")
            .handle;

        let mut poll = PluginProcessRequest::new(Operation::Poll);
        poll.handle = Some(handle);
        assert_eq!(
            service
                .perform(&second.manifest.id, "launch", &poll)
                .map_err(|error| error.to_string()),
            Err(crate::PluginError::Process(PluginProcessError::InvalidHandle).to_string())
        );
        mount(&service, &first);
        assert_eq!(
            service
                .perform(&first.manifest.id, "launch", &poll)
                .map_err(|error| error.to_string()),
            Err(crate::PluginError::Process(PluginProcessError::InvalidHandle).to_string())
        );
        service.unmount(&first.manifest.id);
        service.unmount(&second.manifest.id);
    }

    // @Test("command authority changes invalidate authorization and host functions are not AI exposed")
    #[test]
    fn authorization() {
        let inspection = inspection("test.process");
        let authorization = PluginAuthorizationRecord::from_inspection(&inspection, SwiftDate(0.0))
            .expect("authorizes");
        let binding = PluginExecutionBinding::new(
            "/tmp/test.coveplugin",
            inspection.clone(),
            authorization.clone(),
            1,
        )
        .expect("binds");
        let registry = PluginCapabilityRegistryBuilder::build(
            &CapabilityRegistry::default_registry(),
            std::slice::from_ref(&binding),
            &[],
        )
        .expect("builds registry");
        assert_eq!(
            registry
                .descriptor("test.process.launch")
                .map(|descriptor| descriptor.is_ai_exposed),
            Some(false)
        );

        let mut changed = inspection;
        changed.manifest.host.processes[0].allows_additional_arguments = true;
        assert!(!authorization.is_still_valid(&changed));
        assert_ne!(
            PluginAuthorizationRecord::from_inspection(&changed, SwiftDate(0.0))
                .expect("authorizes")
                .authority_digest(),
            authorization.authority_digest()
        );
    }
}
