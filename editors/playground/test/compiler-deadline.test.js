import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createCompiler} from '../../../runtime/luajit/host.mjs';
import {createDeadlines, requiredModules, DEADLINE_MS, IMPORT_DEADLINE_MS} from '../src/compiler-deadline.js';

const recorder = () => {
  const deadlines = [];
  return {deadlines, async request(request, {deadlineMs}) { deadlines.push(deadlineMs); return {request}; }};
};

test('required modules are read from each call form', () => {
  assert.deepEqual(requiredModules('local a = require("bytes")\nconst b = require \'types.derive\'\nlocal c = require "bytes"'),
    ['bytes', 'types.derive']);
  assert.deepEqual(requiredModules('local unfinished = require("byt'), []);
  assert.deepEqual(requiredModules(undefined), []);
});

test('only a request reaching an unchecked module gets the longer deadline', async () => {
  const compiler = recorder(), deadlines = createDeadlines();
  assert.equal(deadlines.deadlineMs, DEADLINE_MS);
  assert.ok(IMPORT_DEADLINE_MS > DEADLINE_MS);
  await deadlines.request(compiler, {kind: 'check', source: 'print(1)'});
  await deadlines.request(compiler, {kind: 'check', source: 'local b = require("bytes")'});
  await deadlines.request(compiler, {kind: 'compile', source: 'local b = require("bytes")'});
  await deadlines.request(compiler, {kind: 'hover', offset: 3});
  await deadlines.request(compiler, {kind: 'check', source: 'local b = require("bytes")\nlocal t = require("types")'});
  assert.deepEqual(compiler.deadlines, [DEADLINE_MS, IMPORT_DEADLINE_MS, DEADLINE_MS, DEADLINE_MS, IMPORT_DEADLINE_MS]);
});

test('a failed request leaves its modules unchecked', async () => {
  const deadlines = createDeadlines(), seen = [];
  const failing = {async request(request, {deadlineMs}) { seen.push(deadlineMs); throw new Error('Guest closed'); }};
  await assert.rejects(deadlines.request(failing, {kind: 'check', source: 'require("bytes")'}), /Guest closed/);
  await deadlines.request(recorder(), {kind: 'check', source: 'require("bytes")'});
  const compiler = recorder();
  await deadlines.request(compiler, {kind: 'check', source: 'require("bytes")'});
  assert.deepEqual([...seen, ...compiler.deadlines], [IMPORT_DEADLINE_MS, DEADLINE_MS]);
});

class Worker {
  static instances = [];
  constructor() { Worker.instances.push(this); this.sent = []; }
  postMessage(message) { this.sent.push(message); }
  terminate() { this.terminated = true; }
  deliver(data) { this.onmessage({data}); }
}

test('the first stdlib compile outlives the per-request deadline through the host', async () => {
  globalThis.Worker = Worker;
  const deadlines = createDeadlines({deadlineMs: 20, importDeadlineMs: 1000});
  const starting = createCompiler({manifestUrl: 'https://example.test/runtime/guest-manifest.json',
    app: new Uint8Array([1]), deadlineMs: deadlines.deadlineMs});
  const worker = Worker.instances.at(-1);
  worker.deliver({type: 'compiler', sequence: 0, result: {ready: true}});
  const compiler = await starting;
  const first = deadlines.request(compiler, {kind: 'compile', source: 'local b = require("bytes")', filename: 'browser-platform.nupp'});
  await new Promise(resolve => setTimeout(resolve, 100));
  worker.deliver({type: 'compiler', sequence: 1, result: {ok: true, response: {code: 'return 1', diagnostics: []}}});
  assert.deepEqual(await first, {code: 'return 1', diagnostics: []});
  assert.equal(worker.terminated, undefined);
  await assert.rejects(deadlines.request(compiler, {kind: 'compile', source: 'local b = require("bytes")', filename: 'browser-platform.nupp'}),
    /^Error: Compiler compile request for browser-platform\.nupp exceeded its 20 ms deadline$/);
  assert.equal(worker.terminated, true);
});
