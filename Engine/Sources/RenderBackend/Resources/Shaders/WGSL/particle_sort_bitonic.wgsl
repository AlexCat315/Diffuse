struct ParticleSortBitonicUniforms {
    params: vec4<u32>,
};

struct ParticleSortItem {
    key: f32,
    index: u32,
    padding0: u32,
    padding1: u32,
};

@group(0) @binding(0) var<uniform> uniforms: ParticleSortBitonicUniforms;
@group(0) @binding(1) var<storage, read_write> sort_items: array<ParticleSortItem>;

fn particle_sort_item_less(lhs: ParticleSortItem, rhs: ParticleSortItem) -> bool {
    if (abs(lhs.key - rhs.key) <= 0.000001) {
        return lhs.index < rhs.index;
    }
    return lhs.key < rhs.key;
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let index = gid.x;
    let count = uniforms.params.x;
    let k = uniforms.params.y;
    let j = uniforms.params.z;
    if (index >= count) {
        return;
    }

    let partner = index ^ j;
    if (partner <= index || partner >= count) {
        return;
    }

    let left = sort_items[index];
    let right = sort_items[partner];
    let ascending = (index & k) == 0u;
    let should_swap = select(
        particle_sort_item_less(left, right),
        particle_sort_item_less(right, left),
        ascending
    );
    if (should_swap) {
        sort_items[index] = right;
        sort_items[partner] = left;
    }
}
