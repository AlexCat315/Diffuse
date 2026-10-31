# AGENTS.md

Use Rust 2024 for all new implementations. Migrate existing Swift capabilities to Rust; do not add Swift code.

Read [MIGRATION.md](MIGRATION.md) before starting migration work. It is the single operating manual: crate map, translation rules, gates and process.

Avoid unnecessary supporting text, descriptive copy, and redundant UI microcopy.


Please refer to this for UI design agent/skills/

A changelog must be written for every new version release.

You must not omit the implementation for any platform simply because it cannot be tested; code must be implemented for all platforms. It is mandatory to provide implementations across the board to avoid gaps in the codebase. Should any such issues be discovered, they must be reported immediately.

For performance-critical sections, please use C, or even C with inline assembly.

Apply breaking changes without requiring confirmation prior to the release of version 1.0.0.

## Rust specifics

- Workspace layout and per-crate dependencies are fixed by [MIGRATION.md](MIGRATION.md) §2. Do not add third-party crates without recording them in §10 and getting the user's confirmation.
- Never edit `../Cove` or `../Natsel`. Missing or broken Cove APIs go into [.migration/cove-gaps.md](.migration/cove-gaps.md).
- `todo!()`, `unimplemented!()`, empty bodies and simplified logic are forbidden; `python3 Tools/Migration/inventory.py --check` enforces the first two.
- Persisted JSON stays byte-compatible with Swift `Codable` (§5.4). SIMD and GPU layouts match `.migration/simd-layout.json` (§5.3).
- No async runtime. `async`/`actor`/`Task` become threads, channels and locks (§5.5).
- Logging goes through `cove_logging`, never `println!`.
