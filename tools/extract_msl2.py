import re

with open('src/engine/generated/shaders.zig', 'r') as f:
    text = f.read()

# Find the start and end of the mesh_fragment_msl_code array
start = text.find('const mesh_fragment_msl_code = [_]u8{')
if start < 0:
    print("NOT FOUND")
    exit(1)

start += len('const mesh_fragment_msl_code = [_]u8{')
end = text.index('};', start)
content = text[start:end]

# Parse bytes
nums = re.findall(r'\d+', content)
msl_bytes = bytes([int(n) for n in nums])
msl_text = msl_bytes.decode('utf-8', errors='replace')

# Write full MSL for inspection
with open('/tmp/mesh_frag.msl', 'w') as f:
    f.write(msl_text)

# Print function signature and texture/sampler/buffer lines
for i, line in enumerate(msl_text.split('\n')):
    l = line.lower().strip()
    if ('texture' in l or 'sampler' in l or 'buffer' in l or 
        l.startswith('fragment') or '[[texture' in l or '[[sampler' in l or '[[buffer' in l):
        print(f"{i}: {line.rstrip()}")

print("\n=== DONE ===")
