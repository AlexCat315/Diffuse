// Cap every core module memory at packaging time. Unbounded memory.grow must
// never rely on the browser's process limit. Only ordinary unshared wasm32
// memories are supported by the Cove browser plugin contract.
class Reader {
  constructor(bytes) { this.bytes = bytes; this.offset = 0; }
  byte() { if (this.offset >= this.bytes.length) throw Error('Truncated Wasm'); return this.bytes[this.offset++]; }
  uint() {
    let value = 0;
    for (let shift = 0; shift < 35; shift += 7) {
      const byte = this.byte(); value += (byte & 127) * 2 ** shift;
      if (!(byte & 128) && value <= 0xffffffff) return value;
    }
    throw Error('Invalid Wasm integer');
  }
  name() { const length = this.uint(); this.offset += length; if (this.offset > this.bytes.length) throw Error('Truncated name'); }
}
function uint(value) {
  const bytes = [];
  do { const part = value & 127; value = Math.floor(value / 128); bytes.push(part | (value ? 128 : 0)); } while (value);
  return bytes;
}
function memory(reader, pages) {
  const flags = reader.uint();
  if (flags > 1) throw Error('Browser plugins require unshared wasm32 memory');
  const minimum = reader.uint(); const maximum = flags ? reader.uint() : pages;
  if (minimum > pages) throw Error('Plugin initial memory exceeds its limit');
  return [1, ...uint(minimum), ...uint(Math.min(maximum, pages))];
}
function table(reader) {
  const flags = reader.uint(); const minimum = reader.uint(); const maximum = flags & 1 ? reader.uint() : 10000;
  if (flags > 1 || minimum > 10000) throw Error('Unsupported table limits');
  return [1, ...uint(minimum), ...uint(Math.min(maximum, 10000))];
}
function boundedSection(bytes, id, pages) {
  const reader = new Reader(bytes); const count = reader.uint();
  const output = [...uint(count)];
  if (count > (id === 2 ? 4096 : 16)) throw Error('Too many module imports or memories');
  for (let i = 0; i < count; i++) {
    const start = reader.offset;
    if (id === 5) { output.push(...memory(reader, pages)); continue; }
    if (id === 4) { output.push(reader.byte(), ...table(reader)); continue; }
    reader.name(); reader.name(); const kind = reader.byte();
    if (kind === 2) {
      output.push(...bytes.slice(start, reader.offset), ...memory(reader, pages)); continue;
    }
    switch (kind) {
      case 0: reader.uint(); break;
      case 1: {
        const element = reader.byte();
        output.push(...bytes.slice(start, reader.offset - 1), element, ...table(reader)); continue;
      }
      case 3: reader.byte(); reader.byte(); break;
      case 4: reader.byte(); reader.uint(); break;
      default: throw Error('Unsupported Wasm import');
    }
    output.push(...bytes.slice(start, reader.offset));
  }
  if (reader.offset !== bytes.length) throw Error('Unsupported Wasm section encoding');
  return Uint8Array.from(output);
}
export function boundResources(bytes, maximumBytes = 64 * 1024 * 1024) {
  if (bytes.length > 128 * 1024 * 1024 || !WebAssembly.validate(bytes)) throw Error('Invalid core Wasm');
  const reader = new Reader(bytes); reader.offset = 8;
  const chunks = [bytes.slice(0, 8)];
  while (reader.offset < bytes.length) {
    const id = reader.byte(); const length = reader.uint();
    const end = reader.offset + length;
    if (end > bytes.length) throw Error('Truncated Wasm section');
    let section = bytes.slice(reader.offset, end); reader.offset = end;
    if (id === 2 || id === 4 || id === 5) section = boundedSection(section, id, Math.floor(maximumBytes / 65536));
    chunks.push(Uint8Array.from([id, ...uint(section.length)]), section);
  }
  const result = new Uint8Array(chunks.reduce((n, chunk) => n + chunk.length, 0));
  let offset = 0; for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; }
  if (!WebAssembly.validate(result)) throw Error('Resource bounding produced an invalid module');
  return result;
}
