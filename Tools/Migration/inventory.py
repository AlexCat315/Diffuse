#!/usr/bin/env python3
"""Diffuse Swift -> Rust migration inventory.

One row per tracked Swift file: its planned Rust path, crate, kind and status.
The planned path is derived here and nowhere else, so every agent writes to the
same place.

    python3 Tools/Migration/inventory.py            # refresh rows, keep statuses
    python3 Tools/Migration/inventory.py --status   # counts per crate
    python3 Tools/Migration/inventory.py --check    # verify claimed statuses
    python3 Tools/Migration/inventory.py --next CRATE [--lines 900]
                                                    # next pending batch for a crate

Status values (agents set them; --check verifies them):
  pending   nothing written
  written   Rust file exists, translation complete, not yet compiled
  compiled  the crate passes `cargo check -p CRATE --all-targets`
  tested    the crate's tests pass
  blocked   cannot proceed; `blocked_by` names the decision or Cove gap

Rows marked `"d1": "rewrite"` are rewritten for Rust scripts (MIGRATION.md §4);
`"d1": "adjust"` rows are translated with Swift toolchain references replaced.
  removed   intentionally not migrated; `reason` says why
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "Docs/rust-migration-files.json"
STATUSES = ("pending", "written", "compiled", "tested", "blocked", "removed")

# Swift target directory -> (crate, crate-relative source root).
TARGETS = {
    "Engine/Sources/SIMDCompat": ("diffuse-math", "src/simd"),
    "Engine/Sources/EngineMath": ("diffuse-math", "src"),
    "Engine/Sources/EngineKernel": ("diffuse-kernel", "src"),
    "Engine/Sources/ObservationBus": ("diffuse-observation", "src"),
    "Engine/Sources/SceneRuntime": ("diffuse-scene", "src"),
    "Engine/Sources/AssetPipeline": ("diffuse-assets", "src"),
    "Engine/Sources/SequenceRuntime": ("diffuse-sequence", "src"),
    "Engine/Sources/ColorPipeline": ("diffuse-color", "src"),
    "Engine/Sources/EXRIO": ("diffuse-exr", "src"),
    "Engine/Sources/CinematicRenderer": ("diffuse-cinematic", "src"),
    "Engine/Sources/CardBattleRuntime": ("diffuse-card-battle", "src"),
    "Engine/Sources/AudioRuntime": ("diffuse-audio", "src"),
    "Engine/Sources/CapabilityRuntime": ("diffuse-capability", "src"),
    "Engine/Sources/PluginRuntime": ("diffuse-plugin", "src"),
    "Engine/Sources/LanguageServerRuntime": ("diffuse-lsp", "src"),
    "Engine/Sources/IntentRuntime": ("diffuse-intent", "src"),
    "Engine/Sources/PerceptionRuntime": ("diffuse-perception", "src"),
    "Engine/Sources/AIRuntime": ("diffuse-ai", "src"),
    "Engine/Sources/ContextMemory": ("diffuse-context-memory", "src"),
    "Engine/Sources/ScriptRuntime": ("diffuse-script", "src"),
    "Engine/Sources/SemanticPipeline": ("diffuse-semantic", "src"),
    "Engine/Sources/RenderBackend": ("diffuse-render", "src"),
    "Engine/Sources/NativeRendererValidation": ("diffuse-render-validation", "src"),
    "Engine/Sources/NativeRHIPassProbe": ("diffuse-render-validation", "src/bin/native_rhi_pass_probe"),
    "Engine/Sources/EngineCore": ("diffuse-engine", "src"),
    "Engine/Sources/DiffusePluginHost": ("diffuse-plugin-host", "src"),
    "Engine/Media/Sources/MediaRuntime": ("diffuse-media", "src"),
    "Engine/Benchmarks/SceneRuntimeBenchmarks": ("diffuse-scene", "benches/scene_runtime"),
    "Engine/Benchmarks/PhysicsRuntimeBenchmarks": ("diffuse-scene", "benches/physics_runtime"),
    "Engine/Benchmarks/RenderBackendBenchmarks": ("diffuse-render-validation", "benches/render_backend"),
    "Engine/Demos/StylizedCharacterPreviewDemo": ("diffuse-render", "examples/stylized_character_preview"),
    "Editor/Documents/Sources/StudioDocuments": ("diffuse-documents", "src"),
    "Editor/Sources/EditorCore": ("diffuse-editor-core", "src"),
    "Editor/Sources/EditorUI": ("diffuse-editor-ui", "src"),
    "Editor/Sources/EditorApp": ("diffuse-editor", "src"),
    "Editor/Sources/GameRuntime": ("diffuse-game-runtime", "src"),
    "Editor/Sources/CoveProjectExport": ("diffuse-export", "src"),
    "Editor/Sources/CovePlayer": ("diffuse-player", "src"),
    "Editor/Tests/Fixtures/LanguageServer": ("diffuse-editor-core", "src/bin/language_server_fixture"),
    "DiffuseMCP/Sources/DiffuseMCP": ("diffuse-mcp", "src"),
    "Platforms/Android/Sources/CoveAndroidApp": ("diffuse-android", "src"),
    "Tools/Developer/Sources/CoveDev": ("xtask", "src"),
    "Tools/Developer/Sources": ("xtask", "src"),
}

# Swift test target -> crate. Suites that use `@testable import` live in the
# crate (`src/tests/<suite>/`); the rest become one integration-test binary per
# suite (`tests/<suite>/main.rs`).
TEST_TARGETS = {
    "Engine/Tests/EngineMathTests": "diffuse-math",
    "Engine/Tests/ObservationBusTests": "diffuse-observation",
    "Engine/Tests/SceneRuntimeTests": "diffuse-scene",
    "Engine/Tests/ScriptRuntimeTests": "diffuse-script",
    "Engine/Tests/AssetPipelineTests": "diffuse-assets",
    "Engine/Tests/AudioRuntimeTests": "diffuse-audio",
    "Engine/Tests/SequenceRuntimeTests": "diffuse-sequence",
    "Engine/Tests/CardBattleRuntimeTests": "diffuse-card-battle",
    "Engine/Tests/CapabilityRuntimeTests": "diffuse-capability",
    "Engine/Tests/PluginRuntimeTests": "diffuse-plugin",
    "Engine/Tests/IntentRuntimeTests": "diffuse-intent",
    "Engine/Tests/SemanticPipelineTests": "diffuse-semantic",
    "Engine/Tests/PerceptionRuntimeTests": "diffuse-perception",
    "Engine/Tests/AIRuntimeTests": "diffuse-ai",
    "Engine/Tests/ContextMemoryTests": "diffuse-context-memory",
    "Engine/Tests/ColorPipelineTests": "diffuse-color",
    "Engine/Tests/EXRIOTests": "diffuse-exr",
    "Engine/Tests/CinematicRendererTests": "diffuse-cinematic",
    "Engine/Tests/EngineCoreTests": "diffuse-engine",
    "Engine/Tests/NativeRendererTests": "diffuse-render-validation",
    "Engine/Media/Tests/MediaRuntimeTests": "diffuse-media",
    "Editor/Documents/Tests/StudioDocumentsTests": "diffuse-documents",
    "Editor/Tests/EditorCoreTests": "diffuse-editor-core",
    "Editor/Tests/ScriptSystemTests": "diffuse-editor-core",
    "Editor/Tests/EditorAppTests": "diffuse-editor-ui",
    "Editor/Tests/EditorWorkbenchTests": "diffuse-editor-ui",
    "Editor/Tests/GameRuntimeTests": "diffuse-game-runtime",
}

# Sources that need a decision before translation. Empty: D1 and D2 are decided.
BLOCKED: dict[str, str] = {}

# D1 (decided): user scripts are Rust cdylibs behind a C ABI, built with cargo,
# served by rust-analyzer and highlighted with tree-sitter-rust. Files whose
# logic is specific to the Swift toolchain are rewritten for the Rust one
# ("rewrite"); files that only mention Swift are translated with those
# references replaced ("adjust"). Prefix match on the Swift path.
D1_REWRITE = (
    "Engine/Sources/ScriptRuntime/DynamicScript/",
    "Engine/Sources/EngineCore/Scripting/Syntax/TreeSitterBridge.swift",
    "Engine/Tests/ScriptRuntimeTests/SwiftScriptCompilerTests.swift",
    "Editor/Sources/EditorCore/Scripting/SourceKitLSP/",
    "Editor/Sources/EditorCore/Scripting/Toolchain/",
    "Editor/Sources/EditorCore/Scripting/Dynamic/DynamicScriptBuildCoordinator.swift",
    "Editor/Sources/EditorCore/Scripting/Dynamic/DynamicScriptManager.swift",
    "Editor/Sources/EditorCore/Scripting/Dynamic/ProjectCompiledScripts.swift",
    "Editor/Sources/EditorCore/Scripting/Static/ProjectStaticScripts.swift",
    "Editor/Sources/EditorCore/Scripting/ScriptLanguageSupport.swift",
    "Editor/Sources/EditorCore/Scripting/Assets/ScriptWorkspaceModel.swift",
    "Editor/Sources/EditorUI/Panels/ScriptEditor/Syntax/TreeSitterHighlighter.swift",
    "Editor/Sources/EditorUI/Shell/LanguageServices/Toolchains.swift",
    "Editor/Tests/EditorAppTests/ScriptEditor/TreeSitterHighlighterTests.swift",
    "Editor/Tests/EditorCoreTests/Scripting/SourceKitLSP/",
    "Editor/Tests/EditorCoreTests/Scripting/BundledSwiftSupportTests.swift",
    "Editor/Tests/EditorCoreTests/Scripting/SwiftToolchainInstallationTests.swift",
    "Editor/Tests/EditorCoreTests/Scripting/SwiftToolchainResolutionTests.swift",
    "Editor/Tests/EditorCoreTests/Scripting/DynamicScriptManagerTests.swift",
    "examples/CrystalRush/Scripts/CrystalRush.swift",
)
D1_ADJUST = (
    "Editor/Sources/EditorCore/Application/Plugins/Processes.swift",
    "Editor/Sources/EditorCore/Projects/EditorProjectLifecycle.swift",
    "Editor/Sources/EditorCore/VersionControl/Workspace.swift",
    "Editor/Sources/EditorUI/Panels/Console/EditorOutputPanel.swift",
    "Editor/Sources/EditorUI/Panels/Inspector/Scripting/InspectorScriptSectionLayout.swift",
    "Editor/Sources/EditorUI/Settings/Plugins/Cards.swift",
    "Editor/Sources/EditorUI/Shell/LanguageServer.swift",
    "Editor/Sources/EditorUI/ai/CommandPaletteOverlay.swift",
    "Engine/Sources/LanguageServerRuntime/LSP/",
)
# Target renames for rewritten files: the Rust module is named for what it does now.
D1_RENAMES = (
    ("/source_kit_lsp/source_kit/source_kit_lsp_", "/rust_analyzer/server/"),
    ("/source_kit_lsp/", "/rust_analyzer/"),
    ("source_kit_lsp_", "rust_analyzer_"),
    ("swift_script_", "script_"),
    ("swift_toolchain_", "toolchain_"),
    ("bundled_swift_support", "bundled_rust_support"),
)

# Crate order: a crate's dependencies appear before it.
CRATE_ORDER = [
    "diffuse-script-api", "diffuse-math", "diffuse-kernel", "diffuse-observation", "diffuse-sequence",
    "diffuse-color", "diffuse-card-battle", "diffuse-capability", "diffuse-documents",
    "diffuse-media", "diffuse-exr", "diffuse-scene", "diffuse-assets", "diffuse-cinematic",
    "diffuse-audio", "diffuse-plugin", "diffuse-lsp", "diffuse-script", "diffuse-render",
    "diffuse-intent", "diffuse-render-validation", "diffuse-engine", "diffuse-context-memory",
    "diffuse-perception", "diffuse-semantic", "diffuse-ai", "diffuse-plugin-host",
    "diffuse-mcp", "diffuse-editor-core", "diffuse-game-runtime", "diffuse-export",
    "diffuse-editor-ui", "diffuse-editor", "diffuse-player", "diffuse-android", "xtask",
]

RUST_KEYWORDS = {
    "as", "break", "const", "continue", "crate", "else", "enum", "extern", "false", "fn",
    "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref",
    "return", "self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use",
    "where", "while", "async", "await", "dyn", "abstract", "become", "box", "do", "final",
    "macro", "override", "priv", "typeof", "unsized", "virtual", "yield", "try", "gen",
}


def snake(name: str) -> str:
    name = name.replace("+", "_").replace("-", "_").replace(" ", "_")
    name = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", name)
    name = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", name)
    name = re.sub(r"_+", "_", name).strip("_").lower()
    # `Bounds3D` -> `bounds_3d`, not `bounds3_d`.
    name = re.sub(r"([a-z])(\d+)_([a-z])(?=_|$)", r"\1_\2\3", name)
    return name + "_" if name in RUST_KEYWORDS else name


def crate_dir(crate: str) -> str:
    return "xtask" if crate == "xtask" else f"crates/{crate}"


def module_path(relative: Path, siblings: set[str]) -> str:
    """Swift path below a target root -> Rust path below the crate's module root."""
    parts = [snake(part) for part in relative.parts[:-1]]
    stem = relative.stem
    if stem == "main":
        return "/".join(parts + ["main.rs"])
    leaf = snake(stem)
    # `Foo.swift` beside a `Foo/` directory: Rust cannot have both `foo.rs` and
    # `foo/mod.rs`, so the file's contents become the directory's `mod.rs`.
    if stem in siblings:
        return "/".join(parts + [leaf, "mod.rs"])
    return "/".join(parts + [leaf + ".rs"])


def tracked_swift() -> list[str]:
    listing = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode()
    return sorted(
        path for path in listing.split("\0")
        if path.endswith(".swift") and "/third-party/" not in path and not path.startswith("CoveUI/")
    )


def testable_suites(files: list[str]) -> set[str]:
    suites = set()
    for path in files:
        for suite in TEST_TARGETS:
            if path.startswith(suite + "/") and "@testable import" in (ROOT / path).read_text(errors="ignore"):
                suites.add(suite)
    return suites


def plan(path: str, testable: set[str]) -> dict:
    p = Path(path)
    if p.name == "Package.swift":
        package_dir = str(p.parent) if str(p.parent) != "." else ""
        return {"kind": "manifest", "crate": None,
                "rust": [f"{package_dir}/Package.swift -> Cargo.toml (see MIGRATION.md crate map)".lstrip("/")]}
    if path.startswith("examples/") and "/Scripts/" in path:
        project = path.split("/Scripts/")[0]
        return {"kind": "script", "crate": None, "rust": [f"{project}/Scripts/src/lib.rs"]}
    for suite, crate in TEST_TARGETS.items():
        if path.startswith(suite + "/"):
            relative = p.relative_to(suite)
            siblings = {child.name for child in (ROOT / suite / relative.parent).iterdir() if child.is_dir()}
            suite_name = snake(Path(suite).name.removesuffix("Tests")) or "tests"
            module = module_path(relative, siblings)
            if suite in testable:
                return {"kind": "test", "crate": crate,
                        "rust": [f"{crate_dir(crate)}/src/tests/{suite_name}/{module}"]}
            return {"kind": "test", "crate": crate,
                    "rust": [f"{crate_dir(crate)}/tests/{suite_name}/{module}"]}
    if path.startswith("Tools/Developer/Tests/"):
        relative = p.relative_to("Tools/Developer/Tests")
        suite_name = snake(relative.parts[0].removesuffix("Tests"))
        rest = Path(*relative.parts[1:])
        return {"kind": "test", "crate": "xtask",
                "rust": [f"xtask/src/tests/{suite_name}/{module_path(rest, set())}"]}
    for target in sorted(TARGETS, key=len, reverse=True):
        if path.startswith(target + "/"):
            crate, root = TARGETS[target]
            relative = p.relative_to(target)
            siblings = {child.name for child in (ROOT / target / relative.parent).iterdir() if child.is_dir()}
            if target == "Tools/Developer/Sources/CoveDev" and relative == Path("Entry.swift"):
                return {"kind": "production", "crate": crate, "rust": ["xtask/src/main.rs"]}
            module = module_path(relative, siblings)
            # A single-file executable target is the binary's root.
            if module == "main.rs" and root.startswith(("src/bin/", "benches/", "examples/")):
                return {"kind": "production", "crate": crate, "rust": [f"{crate_dir(crate)}/{root}.rs"]}
            return {"kind": "production", "crate": crate, "rust": [f"{crate_dir(crate)}/{root}/{module}"]}
    return {"kind": "unmapped", "crate": None, "rust": []}


def refresh() -> dict:
    previous = {}
    if OUTPUT.exists():
        previous = {row["source"]: row for row in json.loads(OUTPUT.read_text())["entries"]}
    files = tracked_swift()
    testable = testable_suites(files)
    entries = []
    for path in files:
        data = (ROOT / path).read_bytes()
        row = {"source": path, "source_lines": len(data.splitlines()),
               "source_sha256": hashlib.sha256(data).hexdigest(), **plan(path, testable)}
        if path.startswith(D1_REWRITE):
            row["d1"] = "rewrite"
            for old, new in D1_RENAMES:
                row["rust"] = [target.replace(old, new) for target in row["rust"]]
        elif path.startswith(D1_ADJUST):
            row["d1"] = "adjust"
        old = previous.get(path, {})
        row["status"] = old.get("status", "blocked" if path in BLOCKED else "pending")
        if row["status"] == "blocked" and old.get("blocked_by") in ("D1", "D2"):
            row["status"] = "pending"
            old = {key: value for key, value in old.items() if key != "blocked_by"}
        for key in ("blocked_by", "reason", "notes"):
            if key in old:
                row[key] = old[key]
        if path in BLOCKED and row["status"] == "blocked":
            row.setdefault("blocked_by", BLOCKED[path])
        if old and old.get("source_sha256") not in (None, row["source_sha256"]) and row["status"] != "pending":
            row["notes"] = "Swift source changed after translation; re-diff before trusting the Rust file"
        entries.append(row)
    unmapped = [row["source"] for row in entries if row["kind"] == "unmapped"]
    if unmapped:
        sys.exit("unmapped Swift files (add them to TARGETS/TEST_TARGETS):\n  " + "\n  ".join(unmapped))
    return {"schema": 1, "crate_order": CRATE_ORDER, "entries": entries}


def status(document: dict) -> None:
    rows = document["entries"]
    width = max(len(crate) for crate in CRATE_ORDER)
    print(f"{'crate':{width}}  {'files':>5} {'lines':>7}  " + " ".join(f"{s:>8}" for s in STATUSES))
    for crate in CRATE_ORDER:
        mine = [row for row in rows if row["crate"] == crate]
        counts = [sum(row["status"] == s for row in mine) for s in STATUSES]
        lines = sum(row["source_lines"] for row in mine)
        print(f"{crate:{width}}  {len(mine):>5} {lines:>7}  " + " ".join(f"{c:>8}" for c in counts))
    other = [row for row in rows if row["crate"] is None]
    print(f"{'(manifests/scripts)':{width}}  {len(other):>5}")
    total = [sum(row["status"] == s for row in rows) for s in STATUSES]
    print(f"{'total':{width}}  {len(rows):>5} {sum(r['source_lines'] for r in rows):>7}  "
          + " ".join(f"{c:>8}" for c in total))


PLACEHOLDER = re.compile(r"\b(todo!|unimplemented!)\s*\(")


def check(document: dict) -> int:
    problems = []
    for row in document["entries"]:
        if row["status"] not in STATUSES:
            problems.append(f"{row['source']}: unknown status {row['status']}")
        if row["status"] in ("written", "compiled", "tested") and row["kind"] in ("production", "test"):
            for target in row["rust"]:
                file = ROOT / target
                if not file.is_file():
                    problems.append(f"{row['source']}: {target} is missing")
                elif PLACEHOLDER.search(file.read_text(errors="ignore")):
                    problems.append(f"{target}: contains todo!/unimplemented!")
        if row["status"] == "blocked" and "blocked_by" not in row:
            problems.append(f"{row['source']}: blocked without blocked_by")
        if row["status"] == "removed" and "reason" not in row:
            problems.append(f"{row['source']}: removed without reason")
    for problem in problems:
        print(problem)
    print(f"{len(problems)} problem(s)")
    return 1 if problems else 0


def next_batch(document: dict, crate: str, budget: int) -> None:
    batch, lines = [], 0
    for row in document["entries"]:
        if row["crate"] != crate or row["status"] != "pending" or row["kind"] != "production":
            continue
        if batch and lines + row["source_lines"] > budget:
            break
        batch.append(row)
        lines += row["source_lines"]
    if not batch:
        for row in document["entries"]:
            if row["crate"] == crate and row["status"] == "pending" and row["kind"] == "test":
                if batch and lines + row["source_lines"] > budget:
                    break
                batch.append(row)
                lines += row["source_lines"]
    for row in batch:
        tag = f"  [D1 {row['d1']}]" if "d1" in row else ""
        print(f"{row['source_lines']:>5}  {row['source']}  ->  {row['rust'][0]}{tag}")
    print(f"{len(batch)} file(s), {lines} Swift lines")


def write_markdown(document: dict) -> None:
    lines = ["# Diffuse Swift → Rust file inventory", "",
             "Generated by `Tools/Migration/inventory.py`; edit statuses in the JSON, not here.", "",
             "| Status | Lines | Swift | Rust |", "|---|---:|---|---|"]
    for row in document["entries"]:
        lines.append(f"| {row['status']} | {row['source_lines']} | `{row['source']}` | "
                     + ", ".join(f"`{target}`" for target in row["rust"]) + " |")
    (ROOT / "Docs/rust-migration-files.md").write_text("\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--status", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--next", metavar="CRATE")
    parser.add_argument("--lines", type=int, default=900)
    args = parser.parse_args()
    if args.status or args.check or args.next:
        document = json.loads(OUTPUT.read_text())
        if args.status:
            status(document)
        if args.next:
            next_batch(document, args.next, args.lines)
        return check(document) if args.check else 0
    document = refresh()
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n")
    write_markdown(document)
    status(document)
    return 0


if __name__ == "__main__":
    sys.exit(main())
