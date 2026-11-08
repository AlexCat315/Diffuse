//! `AppleVisionPerceptionWorker.swift` — Vision framework image classification worker.
//!
//! The Vision call stays behind the Objective-C bridge in `native/apple_vision.m`
//! (MIGRATION.md §2.3); non-Apple targets report the worker as unavailable.

use std::path::Path;
use std::time::Instant;

use crate::core::perception_contracts::{
    ClassificationObservation, MODEL_MANIFEST_SCHEMA_VERSION, PerceptionEvidence,
    PerceptionLicenseMetadata, PerceptionModelManifest, PerceptionModelSource,
    PerceptionObservation, PerceptionProvenance, PerceptionResult, PerceptionRuntimeConfig,
    PerceptionSemanticCandidate, PerceptionTask, PerceptionTimingInfo, RESULT_SCHEMA_VERSION,
};
use crate::gates::license_gate::{LicenseGate, LicenseGateDecision, PerceptionDistributionMode};
use crate::worker::perception_worker::{PerceptionRuntimeError, PerceptionWorker};

pub struct AppleVisionPerceptionWorker {
    manifest: PerceptionModelManifest,
    license_gate: LicenseGate,
    distribution_mode: PerceptionDistributionMode,
}

impl AppleVisionPerceptionWorker {
    pub fn new() -> Self {
        Self::with_options(LicenseGate::default(), PerceptionDistributionMode::LocalDev)
    }

    pub fn with_options(
        license_gate: LicenseGate,
        distribution_mode: PerceptionDistributionMode,
    ) -> Self {
        AppleVisionPerceptionWorker {
            manifest: apple_vision_manifest(),
            license_gate,
            distribution_mode,
        }
    }
}

impl Default for AppleVisionPerceptionWorker {
    fn default() -> Self {
        Self::new()
    }
}

fn apple_vision_manifest() -> PerceptionModelManifest {
    PerceptionModelManifest::with_options(
        MODEL_MANIFEST_SCHEMA_VERSION.to_string(),
        "apple_vision_classify_image_v1",
        "Apple Vision Image Classifier",
        PerceptionTask::Classification,
        "apple_vision",
        PerceptionRuntimeConfig::with_options(
            "apple_vision",
            Vec::new(),
            vec!["system".to_string()],
        ),
        "cove.perception.input.rgb_image.v1",
        "cove.perception.output.classifications.v1",
        PerceptionLicenseMetadata::with_defaults(
            "Apple-System",
            "Apple-System",
            vec!["Apple system Vision model".to_string()],
            "allowed",
            "system-provided",
        ),
        PerceptionModelSource::with_options(None, None, Some("system-framework".to_string()), None),
    )
}

impl PerceptionWorker for AppleVisionPerceptionWorker {
    fn manifest(&self) -> PerceptionModelManifest {
        self.manifest.clone()
    }

    fn analyze_image(
        &self,
        url: &Path,
        request_id: &str,
        max_results: i64,
    ) -> Result<PerceptionResult, PerceptionRuntimeError> {
        let decision: LicenseGateDecision = self
            .license_gate
            .evaluate(&self.manifest, self.distribution_mode);
        if decision != LicenseGateDecision::Allowed
            && decision != LicenseGateDecision::AllowedWithAttribution
        {
            return Err(PerceptionRuntimeError::LicenseDenied(decision));
        }
        if !url.exists() {
            return Err(PerceptionRuntimeError::FileNotFound(
                url.display().to_string(),
            ));
        }

        let start = Instant::now();
        let classifications = classify_image(url, max_results)?;
        if classifications.is_empty() {
            return Err(PerceptionRuntimeError::NoObservations);
        }

        let observations = classifications
            .into_iter()
            .enumerate()
            .map(|(index, (label, confidence))| {
                let candidate = PerceptionSemanticCandidate::new(
                    "object_category",
                    normalize_label(&label),
                    confidence,
                );
                let evidence = PerceptionEvidence::new(
                    "system_classifier",
                    self.manifest.model_id.clone(),
                    confidence,
                    Some(label.clone()),
                );
                PerceptionObservation::Classification(ClassificationObservation::new(
                    format!("classification_{index}"),
                    label,
                    "apple_vision_classification",
                    confidence,
                    vec![candidate],
                    vec![evidence],
                ))
            })
            .collect();

        Ok(PerceptionResult::with_options(
            RESULT_SCHEMA_VERSION.to_string(),
            request_id,
            self.manifest.model_id.clone(),
            "system",
            PerceptionTask::Classification,
            "success",
            observations,
            Vec::new(),
            Vec::new(),
            PerceptionTimingInfo::new(start.elapsed().as_secs_f64() * 1_000.0),
            PerceptionProvenance::new("apple_vision", self.manifest.model_id.clone()),
        ))
    }
}

fn normalize_label(label: &str) -> String {
    let lowered = label.to_lowercase().replace([' ', '-'], "_");
    lowered
        .split(',')
        .find(|part| !part.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| label.to_string())
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
fn classify_image(
    path: &Path,
    max_results: i64,
) -> Result<Vec<(String, f64)>, PerceptionRuntimeError> {
    use std::ffi::{CStr, CString};
    use std::os::raw::{c_char, c_int};

    #[repr(C)]
    struct VisionClassification {
        identifier: *mut c_char,
        confidence: f64,
    }

    unsafe extern "C" {
        fn diffuse_vision_classify(
            path: *const c_char,
            max_results: c_int,
            items: *mut *mut VisionClassification,
            count: *mut usize,
            error_message: *mut *mut c_char,
        ) -> bool;
        fn diffuse_vision_free_classifications(items: *mut VisionClassification, count: usize);
        fn diffuse_vision_free_string(text: *mut c_char);
    }

    let path = CString::new(path.to_string_lossy().as_bytes()).map_err(|_| {
        PerceptionRuntimeError::InferenceFailed("input path contains a NUL byte".to_string())
    })?;
    let limit = max_results.max(1);
    let limit = c_int::try_from(limit).unwrap_or(c_int::MAX);

    let mut items: *mut VisionClassification = std::ptr::null_mut();
    let mut count: usize = 0;
    let mut error_message: *mut c_char = std::ptr::null_mut();
    // SAFETY: the path is a valid NUL-terminated string and the out-pointers are
    // valid for the duration of the call. The bridge owns the returned buffers.
    let success = unsafe {
        diffuse_vision_classify(
            path.as_ptr(),
            limit,
            &mut items,
            &mut count,
            &mut error_message,
        )
    };
    if !success {
        let message = if error_message.is_null() {
            "Vision request failed".to_string()
        } else {
            // SAFETY: the bridge returned a NUL-terminated string it allocated.
            let message = unsafe { CStr::from_ptr(error_message) }
                .to_string_lossy()
                .into_owned();
            // SAFETY: the string came from the bridge and is freed exactly once.
            unsafe { diffuse_vision_free_string(error_message) };
            message
        };
        return Err(PerceptionRuntimeError::InferenceFailed(message));
    }

    let mut classifications = Vec::with_capacity(count);
    if !items.is_null() && count > 0 {
        // SAFETY: on success the bridge returns `count` initialized entries.
        let entries = unsafe { std::slice::from_raw_parts(items, count) };
        for entry in entries {
            let identifier = if entry.identifier.is_null() {
                String::new()
            } else {
                // SAFETY: each identifier is a NUL-terminated string owned by the array.
                unsafe { CStr::from_ptr(entry.identifier) }
                    .to_string_lossy()
                    .into_owned()
            };
            classifications.push((identifier, entry.confidence));
        }
    }
    if !items.is_null() {
        // SAFETY: the array and its strings were allocated by the bridge.
        unsafe { diffuse_vision_free_classifications(items, count) };
    }
    Ok(classifications)
}

#[cfg(not(any(target_os = "macos", target_os = "ios")))]
fn classify_image(
    _path: &Path,
    _max_results: i64,
) -> Result<Vec<(String, f64)>, PerceptionRuntimeError> {
    Err(PerceptionRuntimeError::WorkerUnavailable(
        "Apple Vision is not available on this platform".to_string(),
    ))
}
