//! `DocumentWorkspace` — project-relative text documents and their lifecycle.

use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use thiserror::Error;

use crate::trash::{WorkspaceTrash, is_symbolic_link, resolve_root};

/// The largest accepted text document: 4 MiB, in UTF-8 bytes.
const MAX_TEXT_BYTES: usize = 4 * 1024 * 1024;

/// Directory names never listed by [`DocumentWorkspace::files`].
const EXCLUDED_DIRECTORIES: [&str; 4] = ["vendor", "build", "node_modules", "third-party"];

/// The most entries [`DocumentWorkspace::files`] reports.
const MAX_LISTED_FILES: usize = 10_000;

/// `TextDocument`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TextDocument {
    pub path: String,
    pub text: String,
    pub(crate) saved_text: Option<String>,
}

impl TextDocument {
    /// The Swift memberwise initialiser; `savedText` is internal to the module.
    pub fn new(
        path: impl Into<String>,
        text: impl Into<String>,
        saved_text: Option<String>,
    ) -> Self {
        TextDocument {
            path: path.into(),
            text: text.into(),
            saved_text,
        }
    }

    /// `existsOnDisk`.
    pub fn exists_on_disk(&self) -> bool {
        self.saved_text.is_some()
    }

    /// `isDirty`.
    pub fn is_dirty(&self) -> bool {
        Some(&self.text) != self.saved_text.as_ref()
    }
}

/// `DocumentError`.
#[derive(Clone, Debug, PartialEq, Eq, Error)]
pub enum DocumentError {
    #[error("Use a project-relative file path inside the workspace")]
    InvalidPath,
    #[error("Text files must be UTF-8 and at most 4 MiB")]
    UnsupportedText,
    #[error("Save or discard the open document before replacing it")]
    UnsavedChanges,
    #[error("The file changed on disk; reopen it before saving")]
    ChangedOnDisk,
    #[error("A file or folder with that name already exists")]
    AlreadyExists,
}

impl DocumentError {
    /// `errorDescription`.
    pub fn error_description(&self) -> String {
        self.to_string()
    }
}

/// General text/code files; opening a file never builds or executes its contents.
///
/// Swift guarded the storage map with an `NSRecursiveLock` because `saveAll`
/// re-entered `save`. The Rust port splits each operation into an unlocked
/// helper and locks once, so a plain `Mutex` is sufficient (MIGRATION.md §5.5).
pub struct DocumentWorkspace {
    root: PathBuf,
    lock: Mutex<()>,
    storage: Mutex<HashMap<String, TextDocument>>,
}

impl DocumentWorkspace {
    /// `init(root:)` — the root is resolved and standardised once.
    pub fn new(root: impl AsRef<Path>) -> Self {
        DocumentWorkspace {
            root: resolve_root(root.as_ref()),
            lock: Mutex::new(()),
            storage: Mutex::new(HashMap::new()),
        }
    }

    /// The workspace root, already resolved and standardised.
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// `documents` — the open documents sorted by path.
    pub fn documents(&self) -> Vec<TextDocument> {
        self.with_lock(|| {
            let storage = self.storage();
            let mut documents: Vec<TextDocument> = storage.values().cloned().collect();
            documents.sort_by(|left, right| left.path.cmp(&right.path));
            documents
        })
    }

    /// `open(_:)` — opens an existing file, or a new empty document when the
    /// path does not exist yet.
    pub fn open(&self, path: &str) -> Result<TextDocument, DocumentError> {
        self.with_lock(|| {
            if let Some(document) = self.storage().get(path) {
                return Ok(document.clone());
            }
            let url = self.resolve(path)?;
            let text = read(&url)?;
            let document = TextDocument::new(path, text.clone().unwrap_or_default(), text);
            self.storage().insert(path.to_string(), document.clone());
            Ok(document)
        })
    }

    /// `edit(_:text:)`.
    pub fn edit(&self, path: &str, text: &str) -> Result<(), DocumentError> {
        self.with_lock(|| {
            if text.len() > MAX_TEXT_BYTES {
                return Err(DocumentError::UnsupportedText);
            }
            let mut storage = self.storage();
            let Some(document) = storage.get_mut(path) else {
                return Err(DocumentError::InvalidPath);
            };
            document.text = text.to_string();
            Ok(())
        })
    }

    /// `save(_:)`.
    pub fn save(&self, path: &str) -> Result<(), DocumentError> {
        self.with_lock(|| self.save_unlocked(path))
    }

    fn save_unlocked(&self, path: &str) -> Result<(), DocumentError> {
        let document = {
            let storage = self.storage();
            storage
                .get(path)
                .cloned()
                .ok_or(DocumentError::InvalidPath)?
        };
        let url = self.resolve(path)?;
        if read(&url)? != document.saved_text {
            return Err(DocumentError::ChangedOnDisk);
        }
        if let Some(parent) = url.parent() {
            fs::create_dir_all(parent).map_err(|_| DocumentError::InvalidPath)?;
        }
        atomic_write(&url, document.text.as_bytes())?;
        self.storage().insert(
            path.to_string(),
            TextDocument::new(path, document.text.clone(), Some(document.text)),
        );
        Ok(())
    }

    /// `saveAll()` — every dirty document, in path order.
    pub fn save_all(&self) -> Result<(), DocumentError> {
        self.with_lock(|| {
            let dirty: Vec<String> = {
                let storage = self.storage();
                let mut documents: Vec<TextDocument> = storage.values().cloned().collect();
                documents.sort_by(|left, right| left.path.cmp(&right.path));
                documents
                    .into_iter()
                    .filter(TextDocument::is_dirty)
                    .map(|document| document.path)
                    .collect()
            };
            for path in dirty {
                self.save_unlocked(&path)?;
            }
            Ok(())
        })
    }

    /// `create(_:text:)` — writes a new file; an existing file is never replaced.
    pub fn create(&self, path: &str, text: &str) -> Result<(), DocumentError> {
        self.with_lock(|| {
            let url = self.resolve(path)?;
            if url.exists() {
                return Err(DocumentError::AlreadyExists);
            }
            if let Some(parent) = url.parent() {
                fs::create_dir_all(parent).map_err(|_| DocumentError::InvalidPath)?;
            }
            atomic_write_new(&url, text.as_bytes())?;
            Ok(())
        })
    }

    /// `move(_:to:)` — renames a file or folder; open documents beneath it follow
    /// the move.
    pub fn move_to(&self, path: &str, destination: &str) -> Result<(), DocumentError> {
        self.with_lock(|| {
            let source = self.resolve(path)?;
            let target = self.resolve(destination)?;
            let prefix = format!("{path}/");
            {
                let storage = self.storage();
                let unsaved = storage.iter().any(|(key, document)| {
                    (key == path || key.starts_with(&prefix)) && document.is_dirty()
                });
                if unsaved {
                    return Err(DocumentError::UnsavedChanges);
                }
            }
            if target.exists() {
                return Err(DocumentError::AlreadyExists);
            }
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent).map_err(|_| DocumentError::InvalidPath)?;
            }
            fs::rename(&source, &target).map_err(|_| DocumentError::InvalidPath)?;

            let mut moved_documents: Vec<(String, TextDocument)> = Vec::new();
            {
                let mut storage = self.storage();
                let moved_keys: Vec<String> = storage
                    .keys()
                    .filter(|key| *key == path || key.starts_with(&prefix))
                    .cloned()
                    .collect();
                for key in moved_keys {
                    let Some(document) = storage.remove(&key) else {
                        continue;
                    };
                    let suffix = key.strip_prefix(path).unwrap_or("");
                    let moved = format!("{destination}{suffix}");
                    moved_documents.push((
                        moved.clone(),
                        TextDocument::new(moved, document.text, document.saved_text),
                    ));
                }
                for (moved, document) in moved_documents {
                    storage.insert(moved, document);
                }
            }
            Ok(())
        })
    }

    /// `remove(_:)` — moves a file or folder to recoverable trash and closes the
    /// documents beneath it.
    pub fn remove(&self, path: &str) -> Result<(), DocumentError> {
        self.with_lock(|| {
            let _ = self.resolve(path)?;
            WorkspaceTrash::remove(path, &self.root)?;
            let prefix = format!("{path}/");
            let mut storage = self.storage();
            storage.retain(|key, _| key != path && !key.starts_with(&prefix));
            Ok(())
        })
    }

    /// `close(_:discard:)`.
    pub fn close(&self, path: &str, discard: bool) -> Result<(), DocumentError> {
        self.with_lock(|| {
            if !discard {
                let storage = self.storage();
                if storage.get(path).is_some_and(TextDocument::is_dirty) {
                    return Err(DocumentError::UnsavedChanges);
                }
            }
            self.storage().remove(path);
            Ok(())
        })
    }

    /// `files()` — project-relative paths of the regular files in the workspace.
    ///
    /// Hidden entries and descend into the excluded directories are skipped, as
    /// Swift's enumerator did, and the walk stops at 10 000 entries.
    pub fn files(&self) -> Vec<String> {
        self.with_lock(|| {
            let mut paths: Vec<String> = Vec::new();
            let root_path = self.root.to_string_lossy().to_string();
            let prefix = format!("{root_path}/");
            let mut pending: Vec<PathBuf> = vec![self.root.clone()];
            // Swift's `while let url = enumerator.nextObject(), paths.count < 10000`
            // stops the whole walk at the cap.
            'walk: while let Some(directory) = pending.pop() {
                let Ok(entries) = fs::read_dir(&directory) else {
                    continue;
                };
                for entry in entries {
                    if paths.len() >= MAX_LISTED_FILES {
                        break 'walk;
                    }
                    let Ok(entry) = entry else {
                        continue;
                    };
                    let name = entry.file_name().to_string_lossy().to_string();
                    if name.starts_with('.') {
                        continue;
                    }
                    let path = entry.path();
                    if is_symbolic_link(&path) || EXCLUDED_DIRECTORIES.contains(&name.as_str()) {
                        continue;
                    }
                    let Ok(file_type) = entry.file_type() else {
                        continue;
                    };
                    if file_type.is_dir() {
                        pending.push(path);
                        continue;
                    }
                    let standardized = path.to_string_lossy().to_string();
                    if let Some(relative) = standardized.strip_prefix(&prefix) {
                        paths.push(relative.to_string());
                    }
                }
            }
            paths.sort();
            paths
        })
    }

    /// `resolve(_:)` — the workspace URL for a relative path, rejecting escapes
    /// and symlinked ancestors.
    fn resolve(&self, path: &str) -> Result<PathBuf, DocumentError> {
        // Swift's `split(separator:)` omits empty components.
        let components: Vec<&str> = path.split('/').filter(|part| !part.is_empty()).collect();
        let invalid = path.is_empty()
            || path.starts_with('/')
            || path.contains('\\')
            || path.contains(':')
            || components
                .iter()
                .any(|component| *component == ".." || component.starts_with('.'));
        if invalid {
            return Err(DocumentError::InvalidPath);
        }
        let mut ancestor = self.root.clone();
        for component in components {
            ancestor.push(component);
            if is_symbolic_link(&ancestor) {
                return Err(DocumentError::InvalidPath);
            }
        }
        // Components are already bounded and checked for symlinks. Re-resolving on
        // Windows would change an existing path to an extended-length path while a
        // root that did not exist at initialization keeps its original spelling.
        Ok(ancestor)
    }

    /// The locked storage map.
    fn storage(&self) -> std::sync::MutexGuard<'_, HashMap<String, TextDocument>> {
        self.storage
            .lock()
            .unwrap_or_else(|error| error.into_inner())
    }

    /// `withLock` — one acquisition per public operation.
    fn with_lock<T>(&self, body: impl FnOnce() -> T) -> T {
        let _guard = self.lock.lock().unwrap_or_else(|error| error.into_inner());
        body()
    }
}

/// `read(_:)` — `None` when the file is absent, an error when it cannot be a
/// text document.
fn read(url: &Path) -> Result<Option<String>, DocumentError> {
    if !url.exists() {
        return Ok(None);
    }
    let metadata = fs::metadata(url).map_err(|_| DocumentError::UnsupportedText)?;
    if !metadata.is_file() || metadata.len() > MAX_TEXT_BYTES as u64 {
        return Err(DocumentError::UnsupportedText);
    }
    let mut bytes = Vec::new();
    fs::File::open(url)
        .and_then(|mut file| file.read_to_end(&mut bytes))
        .map_err(|_| DocumentError::UnsupportedText)?;
    if bytes.len() > MAX_TEXT_BYTES || bytes.contains(&0) {
        return Err(DocumentError::UnsupportedText);
    }
    match String::from_utf8(bytes) {
        Ok(text) => Ok(Some(text)),
        Err(_) => Err(DocumentError::UnsupportedText),
    }
}

/// `Data.write(to:options:.atomic)`.
fn atomic_write(url: &Path, bytes: &[u8]) -> Result<(), DocumentError> {
    cove_system::files::atomic_write(url, bytes, cove_system::files::Access::Inherit)
        .map_err(|_| DocumentError::InvalidPath)
}

/// `Data.write(to:options:.withoutOverwriting)`.
fn atomic_write_new(url: &Path, bytes: &[u8]) -> Result<(), DocumentError> {
    use std::io::Write;

    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(url)
        .map_err(|_| DocumentError::AlreadyExists)?;
    file.write_all(bytes)
        .map_err(|_| DocumentError::InvalidPath)
}
