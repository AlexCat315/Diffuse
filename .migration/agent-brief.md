# Diffuse migration — batch brief

Paste this into each translation agent, with the batch list from
`python3 Tools/Migration/inventory.py --next <crate>` appended.

You are translating part of Diffuse from Swift to Rust. Read `MIGRATION.md` sections 1–5 before writing anything; this brief does not replace them.

1. Translate exactly the files listed below. The Rust path for each is given; do not rename or move it.
2. Faithful translation: every branch, early return, constant, default value and error case of the Swift file exists in the Rust file. No `todo!()`, `unimplemented!()`, empty bodies or simplified logic.
3. Use names already defined in the crate and in `MIGRATION.md` §8 (shared vocabulary). If something you need is not translated yet, reference its planned path from `Docs/rust-migration-files.json` and keep going.
4. Cove and Natsel APIs: look them up through `MIGRATION.md` §3 and `.migration/cove-api-map.json`. Never edit `../Cove` or `../Natsel`. A missing Cove API goes into `.migration/cove-gaps.md`.
5. Hard rules: SIMD/GPU layouts match `.migration/simd-layout.json` (§5.3); persisted JSON stays byte-compatible with Swift `Codable` (§5.4); every `#if os`/`canImport` branch becomes a `#[cfg]` for all platforms; no async runtime (§5.5); no new third-party crates.
6. Rows marked `[D1 rewrite]` by `--next` are rewritten for Rust user scripts (cargo, rust-analyzer, tree-sitter-rust, the `diffuse-script-api` C ABI), following `MIGRATION.md` §4 D1; `[D1 adjust]` rows are translated with Swift toolchain references replaced. Diffuse contains no JSON-RPC/MCP/JSON-Schema code (use `cove_agent`) and no HTTP stack (use `cove_http`).
7. Do not run `cargo` during translation unless the crate's gate (MIGRATION.md §6.2) is assigned to you.
8. When done: set each translated row's `status` to `"written"` in `Docs/rust-migration-files.json`, run `python3 Tools/Migration/inventory.py --check`, and append one line to `MIGRATION.md` §9.
9. Report: files written, any shared types you introduced (add them to §8), assumptions about not-yet-translated code, Cove gaps filed, and anything you could not translate faithfully and why.
