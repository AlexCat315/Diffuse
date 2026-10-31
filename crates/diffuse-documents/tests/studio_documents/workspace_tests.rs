//! `WorkspaceTests` — Swift suite `StudioDocumentsTests`.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use diffuse_documents::trash::WorkspaceTrash;
use diffuse_documents::workspace::{DocumentError, DocumentWorkspace};

/// A fresh directory under the system temporary directory, removed on drop.
struct TempDirectory(PathBuf);

impl TempDirectory {
    fn new(create: bool) -> Self {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!("diffuse-documents-{nanos:x}-{counter:x}"));
        if create {
            fs::create_dir_all(&path).expect("creating the temporary directory");
        }
        TempDirectory(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

// Swift's `#if !os(macOS)`: macOS uses the native Trash, so only the other hosts
// keep the item under `.cove/trash`.
#[cfg(not(target_os = "macos"))]
#[test]
fn removed_documents_remain_recoverable_outside_the_file_listing() {
    let root = TempDirectory::new(false);
    let workspace = DocumentWorkspace::new(root.path());
    workspace
        .create("notes/设计.md", "Keep this content")
        .expect("creating the document");
    fs::write(root.path().join(".gitignore"), "Hidden content").expect("writing the hidden file");
    let _ = workspace
        .open("notes/设计.md")
        .expect("opening the document");
    workspace
        .remove("notes/设计.md")
        .expect("removing the document");
    WorkspaceTrash::remove(".gitignore", root.path()).expect("trashing the hidden file");
    assert!(workspace.documents().is_empty());
    assert!(workspace.files().is_empty());

    let trash = root.path().join(".cove/trash");
    let entries: Vec<PathBuf> = fs::read_dir(&trash)
        .expect("reading the trash directory")
        .map(|entry| entry.expect("a trash entry").path())
        .collect();
    let stored = entries
        .iter()
        .map(|entry| entry.join("notes/设计.md"))
        .find(|candidate| candidate.exists())
        .expect("the trashed document");
    assert_eq!(
        fs::read_to_string(&stored).expect("reading the trashed document"),
        "Keep this content"
    );
    let hidden = entries
        .iter()
        .map(|entry| entry.join(".gitignore"))
        .find(|candidate| candidate.exists())
        .expect("the trashed hidden file");
    assert_eq!(
        fs::read_to_string(&hidden).expect("reading the trashed hidden file"),
        "Hidden content"
    );
}

// "fileListingUsesCanonicalProjectRelativePaths"
#[test]
fn file_listing_uses_canonical_project_relative_paths() {
    let directory = TempDirectory::new(true);
    fs::create_dir_all(directory.path().join("Notes")).expect("creating Notes");
    fs::write(directory.path().join("README.md"), "Read me").expect("writing README.md");
    fs::write(directory.path().join("Notes/设计.md"), "中文").expect("writing the note");
    let workspace = DocumentWorkspace::new(directory.path());
    assert_eq!(workspace.files(), vec!["Notes/设计.md", "README.md"]);
    for path in workspace.files() {
        assert_eq!(
            workspace.open(&path).expect("opening a listed file").path,
            path
        );
    }
}

// "plainDocumentsSaveUnicodeAndProtectExternalChanges"
#[test]
fn plain_documents_save_unicode_and_protect_external_changes() {
    let root = TempDirectory::new(false);
    let workspace = DocumentWorkspace::new(root.path());
    assert!(
        workspace
            .open("notes/设计.md")
            .expect("opening a missing document")
            .is_dirty()
    );
    workspace
        .edit("notes/设计.md", "# 工作站 🥭\n")
        .expect("editing the document");
    workspace.save_all().expect("saving every document");
    assert!(
        !workspace
            .documents()
            .first()
            .expect("the open document")
            .is_dirty()
    );
    assert_eq!(workspace.files(), vec!["notes/设计.md"]);
    workspace
        .edit("notes/设计.md", "New text")
        .expect("editing the document");
    assert_eq!(
        workspace.close("notes/设计.md", false),
        Err(DocumentError::UnsavedChanges)
    );
    fs::write(root.path().join("notes/设计.md"), "External edit")
        .expect("writing the external edit");
    assert_eq!(workspace.save_all(), Err(DocumentError::ChangedOnDisk));
    assert_eq!(
        workspace
            .documents()
            .first()
            .expect("the open document")
            .text,
        "New text"
    );
    workspace
        .close("notes/设计.md", true)
        .expect("discarding the document");
    assert_eq!(
        workspace
            .open("notes/设计.md")
            .expect("reopening the document")
            .text,
        "External edit"
    );
}

// "documentPathsAndBinaryFilesAreRejected"
#[test]
fn document_paths_and_binary_files_are_rejected() {
    let root = TempDirectory::new(true);
    let workspace = DocumentWorkspace::new(root.path());
    for path in [
        "../outside",
        "/tmp/file",
        ".git/config",
        "a/../../file",
        "C:\\file",
    ] {
        assert_eq!(
            workspace.open(path),
            Err(DocumentError::InvalidPath),
            "open must reject {path}"
        );
    }
    for path in [
        "../outside",
        "/tmp/file",
        "a/../../file",
        "C:\\file",
        ".cove/trash",
    ] {
        assert_eq!(
            WorkspaceTrash::remove(path, root.path()),
            Err(DocumentError::InvalidPath),
            "trash must reject {path}"
        );
    }

    #[cfg(unix)]
    std::os::unix::fs::symlink(
        root.path()
            .parent()
            .expect("the temporary directory parent"),
        root.path().join("outside"),
    )
    .expect("creating the symlink");
    assert_eq!(
        workspace.open("outside/file"),
        Err(DocumentError::InvalidPath)
    );
    assert_eq!(
        WorkspaceTrash::remove("outside/file", root.path()),
        Err(DocumentError::InvalidPath)
    );

    fs::write(root.path().join("binary"), [0u8, 1, 255]).expect("writing the binary file");
    assert_eq!(
        workspace.open("binary"),
        Err(DocumentError::UnsupportedText)
    );
}

// `DocumentWorkspace` writes user text verbatim: content is stored as raw UTF-8
// bytes with no normalisation, so the bytes on disk are exactly the bytes the
// caller supplied. This is the byte-compatibility requirement for this crate
// (it persists no `Codable` structures of its own).
#[test]
fn saved_document_bytes_are_verbatim_utf8() {
    let root = TempDirectory::new(false);
    let workspace = DocumentWorkspace::new(root.path());
    let contents = "# 工作站 🥭\r\n\ttabbed \"quoted\" \\ backslash\n";
    workspace
        .create("notes/设计.md", contents)
        .expect("creating the document");
    assert_eq!(
        fs::read(root.path().join("notes/设计.md")).expect("reading the created file"),
        contents.as_bytes()
    );

    workspace
        .open("notes/设计.md")
        .expect("opening the document");
    workspace
        .edit("notes/设计.md", contents)
        .expect("editing the document");
    workspace
        .save("notes/设计.md")
        .expect("saving the document");
    assert_eq!(
        fs::read(root.path().join("notes/设计.md")).expect("reading the saved file"),
        contents.as_bytes()
    );

    // Reopening yields the same string, and the document is clean afterwards.
    let reopened = workspace
        .open("notes/设计.md")
        .expect("reopening the document");
    assert_eq!(reopened.text, contents);
    assert!(!reopened.is_dirty());
}

// `create` never replaces an existing file (`Data.write(.withoutOverwriting)`).
#[test]
fn create_never_replaces_an_existing_file() {
    let root = TempDirectory::new(false);
    let workspace = DocumentWorkspace::new(root.path());
    workspace
        .create("a.txt", "first")
        .expect("creating the file");
    assert_eq!(
        workspace.create("a.txt", "second"),
        Err(DocumentError::AlreadyExists)
    );
    assert_eq!(
        fs::read(root.path().join("a.txt")).expect("reading the file"),
        b"first"
    );
}

// `move` renames the file and carries open documents to the new path.
#[test]
fn move_carries_open_documents_to_the_new_path() {
    let root = TempDirectory::new(false);
    let workspace = DocumentWorkspace::new(root.path());
    workspace
        .create("notes/设计.md", "Body")
        .expect("creating the document");
    workspace
        .open("notes/设计.md")
        .expect("opening the document");

    workspace
        .move_to("notes", "archive")
        .expect("moving the folder");

    assert!(root.path().join("archive/设计.md").exists());
    assert!(!root.path().join("notes").exists());
    assert_eq!(
        workspace
            .documents()
            .first()
            .expect("the moved document")
            .path,
        "archive/设计.md"
    );
    assert_eq!(workspace.files(), vec!["archive/设计.md"]);
}

// `move` refuses while a document beneath the source is dirty.
#[test]
fn move_refuses_unsaved_documents() {
    let root = TempDirectory::new(false);
    let workspace = DocumentWorkspace::new(root.path());
    workspace
        .create("notes/a.md", "A")
        .expect("creating the document");
    workspace.open("notes/a.md").expect("opening the document");
    workspace.edit("notes/a.md", "changed").expect("editing");
    assert_eq!(
        workspace.move_to("notes", "archive"),
        Err(DocumentError::UnsavedChanges)
    );
}
