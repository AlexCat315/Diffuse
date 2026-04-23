// Source-level WGSL port. Runtime execution still needs clustered-light buffers and dispatch wiring.

fn flatten_cluster_id(cluster : vec3<u32>, dims : vec3<u32>) -> u32 {
    return cluster.x + dims.x * (cluster.y + dims.y * cluster.z);
}

@compute
@workgroup_size(64, 1, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
    let cluster_dims = vec3<u32>(16u, 9u, 24u);
    let cluster = vec3<u32>(gid.x % cluster_dims.x, (gid.x / cluster_dims.x) % cluster_dims.y, gid.x / (cluster_dims.x * cluster_dims.y));
    let cluster_id = flatten_cluster_id(cluster, cluster_dims);
    _ = cluster_id;
}