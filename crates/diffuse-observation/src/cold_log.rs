//! Cold log: append-only JSONL persistence per stream, plus the bus error type.
//!
//! Swift wrote one JSON object per line with a sorted-key encoder; the newline is
//! appended separately (MIGRATION.md §5.4).

use std::fs::{self, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use thiserror::Error;

use crate::event_envelope::EventEnvelope;

#[derive(Clone, Debug, PartialEq, Eq, Error)]
pub enum ObservationBusError {
    /// `invalidColdLogDirectory(path)`
    #[error("invalid cold log directory: {0}")]
    InvalidColdLogDirectory(String),
    /// `coldLogWriteFailed(message)`
    #[error("cold log write failed: {0}")]
    ColdLogWriteFailed(String),
    /// `coldLogReadFailed(message)`
    #[error("cold log read failed: {0}")]
    ColdLogReadFailed(String),
    /// `noSnapshotProvider(scope:)`
    #[error("no snapshot provider registered for scope '{scope}'")]
    NoSnapshotProvider { scope: String },
    /// `unknownSnapshotID(id)`
    #[error("unknown snapshot ID '{0}'")]
    UnknownSnapshotId(String),
}

/// An append-only per-stream JSONL log.
pub struct ColdLog {
    pub directory_path: String,
    lock: Mutex<()>,
}

impl ColdLog {
    /// Creates the directory when missing; rejects an existing non-directory path.
    pub fn new(directory_path: impl Into<String>) -> Result<Self, ObservationBusError> {
        let directory_path = directory_path.into();
        let path = Path::new(&directory_path);
        match fs::metadata(path) {
            Ok(metadata) => {
                if !metadata.is_dir() {
                    return Err(ObservationBusError::InvalidColdLogDirectory(directory_path));
                }
            }
            Err(_) => {
                fs::create_dir_all(path).map_err(|_| {
                    ObservationBusError::InvalidColdLogDirectory(directory_path.clone())
                })?;
            }
        }
        Ok(ColdLog {
            directory_path,
            lock: Mutex::new(()),
        })
    }

    /// Appends one envelope as a JSON line.
    pub fn append(&self, envelope: &EventEnvelope) -> Result<(), ObservationBusError> {
        let file_path = self.url(&envelope.stream_id);
        let mut data = serde_json::to_vec(envelope)
            .map_err(|error| ObservationBusError::ColdLogWriteFailed(error.to_string()))?;

        let _guard = self.lock.lock().unwrap_or_else(|error| error.into_inner());
        let mut file = OpenOptions::new()
            .create(true)
            .read(true)
            .append(true)
            .open(&file_path)
            .map_err(|_| {
                ObservationBusError::ColdLogWriteFailed(format!(
                    "cannot open {}",
                    file_path.display()
                ))
            })?;
        file.write_all(&data)
            .map_err(|error| ObservationBusError::ColdLogWriteFailed(error.to_string()))?;
        data.clear();
        data.push(b'\n');
        file.write_all(&data)
            .map_err(|error| ObservationBusError::ColdLogWriteFailed(error.to_string()))?;
        Ok(())
    }

    /// Reads envelopes with `seq >= from_seq` and, when given, `seq <= to_seq`.
    pub fn read(
        &self,
        stream_id: &str,
        from_seq: u64,
        to_seq: Option<u64>,
    ) -> Result<Vec<EventEnvelope>, ObservationBusError> {
        let file_path = self.url(stream_id);
        if !file_path.exists() {
            return Ok(Vec::new());
        }

        let mut data = Vec::new();
        {
            let mut file = OpenOptions::new()
                .read(true)
                .open(&file_path)
                .map_err(|error| ObservationBusError::ColdLogReadFailed(error.to_string()))?;
            file.seek(SeekFrom::Start(0))
                .map_err(|error| ObservationBusError::ColdLogReadFailed(error.to_string()))?;
            file.read_to_end(&mut data)
                .map_err(|error| ObservationBusError::ColdLogReadFailed(error.to_string()))?;
        }

        let text = String::from_utf8_lossy(&data);
        let mut envelopes = Vec::new();
        for line in text.split('\n').filter(|line| !line.is_empty()) {
            let envelope: EventEnvelope = serde_json::from_str(line)
                .map_err(|error| ObservationBusError::ColdLogReadFailed(error.to_string()))?;
            if envelope.seq < from_seq {
                continue;
            }
            if let Some(to_seq) = to_seq
                && envelope.seq > to_seq
            {
                continue;
            }
            envelopes.push(envelope);
        }
        Ok(envelopes)
    }

    fn url(&self, stream_id: &str) -> PathBuf {
        Path::new(&self.directory_path).join(Self::sanitized_file_name(stream_id))
    }

    fn sanitized_file_name(stream_id: &str) -> String {
        let mut value = stream_id.to_string();
        for token in ["/", ":", "\\", " "] {
            value = value.replace(token, "_");
        }
        value + ".jsonl"
    }
}
