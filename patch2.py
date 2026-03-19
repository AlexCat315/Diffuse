with open("src/engine/physics/system.zig", "r") as f:
    code = f.read()

new_code = code.replace("""        if (world.getEntity(state.entity_id)) |entity_mut| {
            if (entity_mut.rigidbody != null) {
                entity_mut.rigidbody.?.linear_velocity = state.linear_velocity;
                entity_mut.rigidbody.?.angular_velocity = state.angular_velocity;
            }
        }""", """        if (world.getEntity(state.entity_id)) |entity_mut| {
            if (entity_mut.rigidbody) |body_val| {
                var new_body = body_val;
                new_body.linear_velocity = state.linear_velocity;
                entity_mut.rigidbody = new_body;
            }
        }""")

with open("src/engine/physics/system.zig", "w") as f:
    f.write(new_code)
