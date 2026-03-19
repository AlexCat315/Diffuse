with open("src/engine/physics/system.zig", "r") as f:
    code = f.read()

new_code = code.replace("fn applyJoltBodyStates(world: *scene_mod.World, body_states: []const JoltBodyState) void {", """fn applyJoltBodyStates(world: *scene_mod.World, body_states: []const JoltBodyState) void {
    for (body_states) |state| {
        std.debug.print("apply state id: {d}, v: {d}\\n", .{state.entity_id, state.linear_velocity[0]});
    }""")

with open("src/engine/physics/system.zig", "w") as f:
    f.write(new_code)
