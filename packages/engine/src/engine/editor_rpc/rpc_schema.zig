///! RPC contract schema — backward-compatible re-export.
///!
///! The schema has been split into `schema/` sub-modules for
///! maintainability.  This file re-exports the original top-level API
///! so existing consumers continue to compile unchanged.
///!
///! Workflow:
///!   1. Edit the files under schema/ to add/change methods or types.
///!   2. Run:  zig run tools/gen_rpc_types.zig > ../editor/src/shared/rpc-types.generated.ts
///!   3. Both Zig and TypeScript are now in sync.
const schema = @import("schema/mod.zig");

pub const SharedTypes = schema.types;
pub const Subscriptions = schema.subscriptions;
