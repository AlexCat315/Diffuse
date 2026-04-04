import re, sys
data = open('src/engine/generated/shaders.zig','rb').read()
m = re.search(rb'const mesh_fragment_msl_code = \[_\]u8\{([^;]+)\};', data)
if m:
    content = m.group(1)
    nums = re.findall(rb'\d+', content)
    msl_bytes = bytes([int(n) for n in nums])
    msl_text = msl_bytes.decode('utf-8', errors='replace')
    for line in msl_text.split('\n'):
        l = line.lower()
        if 'texture' in l or 'sampler' in l or 'buffer' in l or l.strip().startswith('fragment'):
            print(line.rstrip())
