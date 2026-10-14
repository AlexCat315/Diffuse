// The types below are decoded directly from Swift's WITValueType encoding.
const camel = name => name.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
const typedArrays = { u8: Uint8Array, u16: Uint16Array, u32: Uint32Array, s8: Int8Array, s16: Int16Array, s32: Int32Array, f32: Float32Array, f64: Float64Array };
export function componentValue(value, type, depth = 0) {
  if (depth > 32) throw Error('Input type is too deep');
  const [kind, argument] = Object.entries(type)[0] ?? [];
  const child = argument?._0;
  const convert = (value, type) => componentValue(value, type, depth + 1);
  switch (kind) {
    case 'record': {
      if (!value || typeof value !== 'object' || Array.isArray(value)) throw Error('Expected a record');
      if (Object.keys(value).some(name => !child.some(field => field.name === name))) throw Error('Unknown input field');
      return Object.fromEntries(child.map(field => {
        if (!(field.name in value) && !('option' in field.type)) throw Error(`Missing input field: ${field.name}`);
        return [camel(field.name), convert(value[field.name], field.type)];
      }));
    }
    case 'option': {
      const tagged = 'option' in child; // Jco uses tagged options when nullability is ambiguous.
      if (value === null || value === undefined) return tagged ? { tag: 'none' } : undefined;
      const converted = convert(value, child);
      return tagged ? { tag: 'some', val: converted } : converted;
    }
    case 'list': {
      if (!Array.isArray(value) || value.length > 4096) throw Error('Expected a bounded list');
      const converted = value.map(item => convert(item, child));
      const Constructor = typedArrays[Object.keys(child)[0]];
      return Constructor ? new Constructor(converted) : converted;
    }
    case 'enumeration': if (child.includes(value)) return value; break;
    case 'bool': if (typeof value === 'boolean') return value; break;
    case 'string': if (typeof value === 'string') return value; break;
    case 'character': if (typeof value === 'string' && [...value].length === 1 && !/^[\uD800-\uDFFF]$/.test(value)) return value; break;
    case 'f32': case 'f64':
      if (typeof value === 'number' && Number.isFinite(value) && (kind !== 'f32' || Number.isFinite(Math.fround(value)))) return value;
      break;
    default: {
      const range = { u8: [0,255], u16: [0,65535], u32: [0,4294967295], s8: [-128,127], s16: [-32768,32767], s32: [-2147483648,2147483647] }[kind];
      if (range && Number.isInteger(value) && value >= range[0] && value <= range[1]) return value;
    }
  }
  throw Error(`Invalid WIT ${kind} value`);
}
export { camel };
