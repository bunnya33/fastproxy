import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { Auth } from '../src/auth.js';
import { buildApp } from '../src/http.js';
import { Service } from '../src/service.js';
import { Store } from '../src/store.js';
import { readConfig } from '../src/config.js';
import { FakeRuntime, rule } from './fixtures.js';

test('HTTP authentication, CSRF, CRUD, errors and root-only API share one state', async t => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-http-')); t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const config = readConfig({ FASTPROXY_MODE: 'demo', FASTPROXY_DATA_DIR: dir, FASTPROXY_ADMIN_PASSWORD: 'test-password-123456' });
  config.publicDir = path.join(dir, 'public');
  await fs.mkdir(config.publicDir);
  await fs.writeFile(path.join(config.publicDir, 'index.html'), '<html>FastProxy</html>');
  const runtime = new FakeRuntime();
  const service = await Service.create(new Store(dir), runtime, config.protectedPorts);
  const auth = await Auth.create(config.adminUser, config.adminPassword);
  const app = await buildApp(service, config, auth, false, false);
  const local = await buildApp(service, config, auth, true, false);
  t.after(async () => { await app.close(); await local.close(); });
  assert.equal((await app.inject('/')).statusCode, 200);
  await fs.writeFile(path.join(config.publicDir, 'new-build.js'), 'console.log("updated")');
  assert.equal((await app.inject('/new-build.js')).statusCode, 200, 'rebuilt assets must be served without enumerating old filenames');
  for (const url of ['/api/status', '/%61pi/status', '/api%2fstatus', '/api/../api/status', '/..%2fstate.json']) {
    assert.notEqual((await app.inject(url)).statusCode, 200, `unauthenticated path ${url}`);
  }
  assert.equal((await app.inject('/api/status')).statusCode, 401);
  assert.equal((await app.inject({ method: 'POST', url: '/api/login', payload: { username: 'admin', password: 'wrong' } })).statusCode, 401);
  const login = await app.inject({ method: 'POST', url: '/api/login', payload: { username: 'admin', password: config.adminPassword } });
  assert.equal(login.statusCode, 200);
  const cookie = String(login.headers['set-cookie']).split(';')[0]!;
  assert.match(String(login.headers['set-cookie']), /HttpOnly/); assert.match(String(login.headers['set-cookie']), /SameSite=Strict/i);
  const headers = { cookie, 'x-csrf-token': login.json().csrf as string };
  const payload = { revision: 0, rule: rule() };
  assert.equal((await app.inject({ method: 'POST', url: '/api/rules', headers: { cookie }, payload })).statusCode, 403);
  assert.equal((await app.inject({ method: 'POST', url: '/api/rules', headers: { ...headers, origin: 'https://evil.example' }, payload })).statusCode, 403);
  const created = await app.inject({ method: 'POST', url: '/api/rules', headers, payload }); assert.equal(created.statusCode, 200);
  const added = created.json().rules[0]; assert.notEqual(added.id, payload.rule.id);
  assert.equal((await local.inject('/api/status')).json().state.revision, 1);
  const edited = await local.inject({ method: 'PUT', url: `/api/rules/${added.id}`, payload: { revision: 1, rule: { ...added, target_port: 20000 } } }); assert.equal(edited.statusCode, 200);
  assert.equal((await app.inject({ method: 'DELETE', url: `/api/rules/${added.id}`, headers, payload: { revision: 1 } })).statusCode, 409);
  runtime.fail = true;
  assert.equal((await app.inject({ method: 'PUT', url: `/api/rules/${added.id}`, headers, payload: { revision: 2, rule: { ...added, target_port: 21000 } } })).statusCode, 503);
  runtime.fail = false;
  const paused = await local.inject({ method: 'POST', url: '/api/forwarding', payload: { revision: 2, forwarding: false } }); assert.equal(paused.statusCode, 200);
  assert.doesNotMatch(runtime.applied.at(-1)!, /dnat to/);
  assert.equal((await app.inject({ method: 'DELETE', url: `/api/rules/${added.id}`, headers, payload: { revision: 3 } })).statusCode, 200);
  const remaining = (await app.inject({ url: '/api/status', headers })).json(); assert.equal(remaining.state.rules.length, 0);
  await app.inject({ method: 'POST', url: '/api/logout', headers, payload: {} });
  assert.equal((await app.inject({ url: '/api/status', headers })).statusCode, 401);
  assert.equal((await app.inject('/healthz')).statusCode, 200);
});

test('login failures are throttled', async () => {
  const auth = await Auth.create('admin', 'test-password-123456');
  for (let i = 0; i < 10; i++) await assert.rejects(auth.login('admin', 'bad', '127.0.0.1'), /用户名或密码/);
  await assert.rejects(auth.login('admin', 'test-password-123456', '127.0.0.1'), /登录尝试过多/);
});
