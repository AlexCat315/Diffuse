//! Navigation module — Recast/Detour integration.
//!
//! Provides NavMesh building, pathfinding queries, and crowd-based agent
//! avoidance for the Guava Engine.

pub const navigation = @import("navigation.zig");
pub const nav_system = @import("nav_system.zig");

pub const NavMesh = navigation.NavMesh;
pub const NavMeshParams = navigation.NavMeshParams;
pub const Crowd = navigation.Crowd;
pub const AgentParams = navigation.AgentParams;
pub const NavSystem = nav_system.NavSystem;

test {
    _ = navigation;
    _ = nav_system;
}
