import { test } from 'node:test';
import assert from 'node:assert/strict';
import { componentValue } from '../src/runtime/values.js';
import { validateComposition } from '../src/runtime/composition.js';
const bool = { bool: {} }; const u16 = { u16: {} };

test('Swift WIT records adapt field names and enforce exact input types', () => {
  const record = { record: { _0: [{ name: 'include-all', type: bool }, { name: 'count', type: u16 }] } };
  assert.deepEqual(componentValue({ 'include-all': true, count: 1 }, record), { includeAll: true, count: 1 });
  for (const input of [{ 'include-all': 1, count: 1 }, { 'include-all': true, count: -1 }, { 'include-all': true, count: 1, extra: 1 }]) {
    assert.throws(() => componentValue(input, record));
  }
});
test('bounded lists, Unicode scalars, numeric overflow, and nested options', () => {
  assert.deepEqual(componentValue([1, 2], { list: { _0: u16 } }), new Uint16Array([1, 2]));
  assert.throws(() => componentValue(Array(4097).fill(1), { list: { _0: u16 } }));
  assert.equal(componentValue('😀', { character: {} }), '😀');
  assert.throws(() => componentValue('\ud800', { character: {} }));
  assert.throws(() => componentValue(1e100, { f32: {} }));
  const nested = { option: { _0: { option: { _0: bool } } } };
  assert.deepEqual(componentValue(null, nested), { tag: 'none' });
  assert.deepEqual(componentValue(true, nested), { tag: 'some', val: true });
});
test('write composition validates exact grants, version, and host schemas', () => {
  const descriptor = { inspection: { manifest: { composable_host_capabilities: ['scene.modify'] } }, hostContracts: [
    { id: 'scene.modify', version: 2, source: { kind: 'builtin' }, access: 'reversible_write', inputSchema: { type: 'object', required: ['enabled'], additionalProperties: false, properties: { enabled: { type: 'boolean' } } } },
  ] };
  const call = { capabilityID: 'scene.modify', version: 2, arguments: btoa('{"enabled":true}') };
  assert.deepEqual(validateComposition([call], descriptor), [call]);
  for (const change of [{ capabilityID: 'other' }, { version: 1 }, { arguments: btoa('{"enabled":1}') }]) assert.throws(() => validateComposition([{ ...call, ...change }], descriptor));
});
