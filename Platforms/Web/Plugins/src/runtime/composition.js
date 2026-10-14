function validate(value, schema, depth = 0) {
  if (depth > 32) throw Error('Host arguments are too deep');
  if (schema.enum && !schema.enum.includes(value)) throw Error('Invalid host enum');
  if (schema.oneOf) {
    if (schema.oneOf.filter(item => { try { validate(value, item, depth + 1); return true; } catch { return false; } }).length !== 1) throw Error('Invalid host argument variant');
    return;
  }
  if (Array.isArray(schema.type)) {
    return validate(value, { ...schema, type: value === null && schema.type.includes('null') ? 'null' : schema.type.find(type => type !== 'null') }, depth + 1);
  }
  switch (schema.type) {
    case 'object':
      if (!value || typeof value !== 'object' || Array.isArray(value)) throw Error('Expected host argument object');
      if ((schema.required ?? []).some(name => !(name in value))) throw Error('Missing host argument');
      for (const [name, child] of Object.entries(value)) {
        if (!Object.hasOwn(schema.properties ?? {}, name)) { if (schema.additionalProperties !== true) throw Error('Unknown host argument'); }
        else validate(child, schema.properties[name], depth + 1);
      }
      break;
    case 'array':
      if (!Array.isArray(value) || value.length > (schema.maxItems ?? 4096) || value.length < (schema.minItems ?? 0)) throw Error('Invalid host argument array');
      if (!schema.items) throw Error('Unbounded host argument schema');
      for (const item of value) validate(item, schema.items, depth + 1);
      break;
    case 'string':
      if (typeof value !== 'string' || value.length > (schema.maxLength ?? 1048576) || value.length < (schema.minLength ?? 0) || (schema.pattern && !new RegExp(schema.pattern).test(value))) throw Error('Invalid host argument string');
      break;
    case 'number': case 'integer':
      if (typeof value !== 'number' || !Number.isFinite(value) || (schema.type === 'integer' && !Number.isInteger(value)) || value < (schema.minimum ?? -Infinity) || value > (schema.maximum ?? Infinity)) throw Error('Invalid host argument number');
      break;
    case 'boolean': if (typeof value !== 'boolean') throw Error('Invalid host argument boolean'); break;
    case 'null': if (value !== null) throw Error('Invalid host null'); break;
    default: throw Error('Unsupported host schema');
  }
}
export function validateComposition(calls, descriptor) {
  const grants = descriptor.inspection.manifest.composable_host_capabilities;
  if (!Array.isArray(calls) || !calls.length || calls.length > 64) throw Error('Invalid host composition');
  for (const call of calls) {
    const contract = descriptor.hostContracts.find(item => item.id === call.capabilityID);
    if (!grants.includes(call.capabilityID) || !contract || call.version !== contract.version || contract.source.kind !== 'builtin' || !['reversible_write', 'destructive_write'].includes(contract.access)) throw Error('Host capability is not granted');
    if (typeof call.arguments !== 'string' || call.arguments.length > 1398104) throw Error('Invalid host argument encoding');
    const bytes = Uint8Array.from(atob(call.arguments), char => char.charCodeAt(0));
    const value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
    validate(value, contract.inputSchema);
  }
  return calls;
}
