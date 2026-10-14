import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parse } from '@bytecodealliance/jco';
import { boundResources } from '../src/packaging/resources.js';

test('unbounded guest memory.grow is capped in the emitted binary', async () => {
  const binary = await parse('(module (memory (export "memory") 1) (func (export "grow") (param i32) (result i32) local.get 0 memory.grow))');
  const { instance } = await WebAssembly.instantiate(boundResources(binary, 2 * 65536));
  assert.equal(instance.exports.grow(1), 1);
  assert.equal(instance.exports.grow(1), -1);
});
test('imported memories receive the same maximum and shared memory is denied', async () => {
  const binary = await parse('(module (import "host" "memory" (memory 1)))');
  const module = await WebAssembly.compile(boundResources(binary, 2 * 65536));
  assert.throws(() => new WebAssembly.Instance(module, { host: { memory: new WebAssembly.Memory({ initial: 1 }) } }));
  assert.doesNotThrow(() => new WebAssembly.Instance(module, { host: { memory: new WebAssembly.Memory({ initial: 1, maximum: 2 }) } }));
  assert.throws(() => boundResources(binary, 0));
  assert.throws(() => boundResources(new Uint8Array([0])));
  const shared = await parse('(module (memory 1 2 shared))');
  assert.throws(() => boundResources(shared));
});


test('table.grow is bounded and excessive initial tables are rejected', async () => {
  const bytes = await parse('(module (table (export "table") 1 funcref))');
  const { instance } = await WebAssembly.instantiate(boundResources(bytes));
  assert.throws(() => instance.exports.table.grow(10000));
  const excessive = await parse('(module (table 10001 funcref))');
  assert.throws(() => boundResources(excessive));
});
