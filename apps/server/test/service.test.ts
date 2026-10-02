import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { initialState, parseRule, token, validateState } from '../src/model.js';
import { Store } from '../src/store.js';
import { Service } from '../src/service.js';
import { parseCounters } from '../src/runtime.js';
import { FakeRuntime, rule } from './fixtures.js';
import { acquireLock } from '../src/lock.js';

test('conflicting listeners, reserved ports, UDP and config injection are rejected', () => {
  const state = initialState(); state.rules = [rule(), rule({ listen_ip: '10.0.0.1' })];
  assert.throws(() => validateState(state, [22, 8080]), /冲突/);
  state.rules[1]!.protocol = 'udp'; assert.throws(() => validateState(state, [22, 8080]), /仅支持 TCP/);
  state.rules[1]!.enabled = false; validateState(state, [22, 8080]);
  state.rules[0]!.listen_port = 22; assert.throws(() => validateState(state, [22, 8080]), /SSH/);
  assert.throws(() => parseRule({ ...rule(), target_ip: '10.0.0.1; flush ruleset' }, token()), /目标/);
  assert.throws(() => parseRule({ ...rule(), listen_port: '8000' }, token()), /端口/);
  assert.throws(() => parseRule({ ...rule(), name: '\x1b[2J' }, token()), /可见/);
  assert.throws(() => parseRule({ ...rule(), target_ip: '127.0.0.1' }, token()), /目标/);
});

test('failed HAProxy reload preserves disk, memory and prior configuration', async t => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-test-')); t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const runtime = new FakeRuntime(), store = new Store(dir);
  const service = await Service.create(store, runtime, [22, 8080]);
  const first = await service.change(0, s => s.rules.push(rule()));
  runtime.fail = true;
  await assert.rejects(service.change(1, s => { s.rules[0]!.target_port = 23456; }), /原规则已保留/);
  assert.deepEqual(service.snapshot(), first);
  assert.deepEqual(await store.load(), first);
  assert.equal(runtime.applied.length, 2);
  runtime.fail = false;
  const recovered = await Service.create(store, runtime, [22, 8080]);
  assert.deepEqual(recovered.snapshot(), first);
  assert.match(runtime.applied.at(-1)!, /19000/);
});

test('concurrent web/console writes use revision locking to avoid lost updates', async t => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-test-')); t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const service = await Service.create(new Store(dir), new FakeRuntime(), [22, 8080]);
  const results = await Promise.allSettled([service.change(0, s => s.rules.push(rule())), service.change(0, s => s.rules.push(rule({ listen_port: 18001 })))]);
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 1);
  assert.equal(service.snapshot().rules.length, 1);
  assert.equal(service.snapshot().revision, 1);
  assert.match((results.find(r => r.status === 'rejected') as PromiseRejectedResult).reason.message, /其他页面/);
});

test('invalid disk data is preserved instead of silently resetting rules', async t => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-test-')); t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const filename = path.join(dir, 'state.json'); await fs.writeFile(filename, '{broken');
  await assert.rejects(Service.create(new Store(dir), new FakeRuntime(), [22]), /保留原文件/);
  assert.equal(await fs.readFile(filename, 'utf8'), '{broken');
});

test('HAProxy counters count frontend bytes without counting backend copies', () => {
  const id = token();
  const parsed = parseCounters(`# pxname,svname,bin,bout,stot,\nfp_${id},FRONTEND,100,200,2,\ntarget_${id},BACKEND,100,200,2,`);
  assert.deepEqual(parsed[id], { bytes: 300, connections: 2 });
});

test('legacy rules migrate with a backup: TCP preserved, both becomes TCP, UDP archived', async t => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-migrate-')); t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const legacy = { ...initialState(), schema_version: 1, revision: 5, rules: [rule(), { ...rule({ listen_port: 18001 }), protocol: 'both' }, rule({ listen_port: 18002, protocol: 'udp' })] };
  const filename = path.join(dir, 'state.json'); await fs.writeFile(filename, JSON.stringify(legacy));
  const runtime = new FakeRuntime();
  const service = await Service.create(new Store(dir), runtime, [22]);
  assert.equal(service.snapshot().schema_version, 2);
  assert.equal(service.snapshot().revision, 6);
  assert.deepEqual(service.snapshot().rules.map(r => [r.protocol, r.enabled]), [['tcp', true], ['tcp', true], ['udp', false]]);
  assert.deepEqual(JSON.parse(await fs.readFile(path.join(dir, 'state.nftables-backup.json'), 'utf8')), legacy);
  assert.doesNotMatch(runtime.applied.at(-1)!, /18002/);
  await assert.rejects(service.change(6, s => { s.rules[2]!.enabled = true; }), /仅支持 TCP/);
  assert.equal(service.snapshot().revision, 6);
  const restarted = await Service.create(new Store(dir), runtime, [22]);
  assert.equal(restarted.snapshot().revision, 6);
  assert.deepEqual(JSON.parse(await fs.readFile(path.join(dir, 'state.nftables-backup.json'), 'utf8')), legacy);
});

test('a second process is refused, and stale service locks can recover after a crash', async t => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-lock-')); t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const unlock = await acquireLock(dir);
  await assert.rejects(acquireLock(dir), /已在运行/);
  await unlock();
  await fs.writeFile(path.join(dir, 'server.lock'), JSON.stringify({ pid: 2147483647, token: 'old' }));
  const recovered = await acquireLock(dir); await recovered();
  await assert.rejects(fs.stat(path.join(dir, 'server.lock')), { code: 'ENOENT' });
});
