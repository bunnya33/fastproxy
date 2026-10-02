import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import fs from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { renderHAProxy } from '../src/model.js';
import { HAProxyRuntime, runCommand } from '../src/runtime.js';
import { rule } from './fixtures.js';
import { Store } from '../src/store.js';
import { Service } from '../src/service.js';

test('real HAProxy: raw TCP replies, seamless reload, bind failure rollback, pause, restoration and cleanup without IP forwarding', { skip: process.env.FASTPROXY_INTEGRATION !== '1', timeout: 60_000 }, async t => {
  assert.equal(process.platform, 'linux'); assert.equal(process.getuid?.(), 0);
  assert.ok(Object.keys(os.networkInterfaces()).every(name => name === 'lo'), 'run under unshare --net without host interfaces');
  assert.notEqual(await fs.readlink('/proc/self/ns/net'), await fs.readlink('/proc/1/ns/net'), 'refuse host network namespace');
  const helper = fileURLToPath(new URL('./network-helper.js', import.meta.url));
  const children: ChildProcess[] = [];
  const startNamespace = async (mode: string): Promise<{ pid: number; logs: () => string }> => {
    const child = spawn('unshare', ['--net', process.execPath, helper, mode]); children.push(child);
    let output = '';
    const ready = new Promise<number>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('namespace helper timeout')), 5000);
      child.stdout.on('data', chunk => {
        output += chunk.toString();
        for (const line of output.split('\n')) if (line.includes('"ready":true')) { clearTimeout(timer); resolve(JSON.parse(line).pid as number); return; }
      });
      child.stderr.on('data', chunk => { clearTimeout(timer); reject(new Error(chunk.toString())); });
      child.on('error', error => { clearTimeout(timer); reject(error); });
      child.on('exit', code => { clearTimeout(timer); reject(new Error(`namespace helper exited: ${code}`)); });
    });
    return { pid: await ready, logs: () => output };
  };
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-ha-'));
  const runtime = new HAProxyRuntime('/usr/sbin/haproxy', dir);
  t.after(async () => { await runtime.clear(); for (const child of children) child.kill('SIGTERM'); await fs.rm(dir, { recursive: true, force: true }); });
  const client = await startNamespace('hold'), backend = await startNamespace('backend');
  const ip = (...args: string[]) => runCommand('/usr/sbin/ip', args);
  const nsip = (pid: number, ...args: string[]) => runCommand('/usr/bin/nsenter', ['-t', String(pid), '-n', '/usr/sbin/ip', ...args]);
  await ip('link', 'set', 'lo', 'up');
  for (const [name, peer, pid, proxyIP, remoteIP] of [['fpclient', 'cpeer', client.pid, '10.250.1.1', '10.250.1.2'], ['fpbackend', 'bpeer', backend.pid, '10.250.2.1', '10.250.2.2']] as const) {
    await ip('link', 'add', name, 'type', 'veth', 'peer', 'name', peer);
    await ip('link', 'set', peer, 'netns', String(pid));
    await ip('addr', 'add', `${proxyIP}/24`, 'dev', name); await ip('link', 'set', name, 'up');
    await nsip(pid, 'link', 'set', 'lo', 'up'); await nsip(pid, 'addr', 'add', `${remoteIP}/24`, 'dev', peer); await nsip(pid, 'link', 'set', peer, 'up');
  }
  // The target has no route to the client. A userspace TCP connection supplies
  // the reply path; neither NAT nor kernel forwarding is required.
  await fs.writeFile('/proc/sys/net/ipv4/ip_forward', '0');
  const store = new Store(dir), service = await Service.create(store, runtime, [22, 8080]);
  const mapping = rule();
  await service.change(0, state => state.rules.push(mapping));
  const payload = randomBytes(32 * 1024).toString('base64');
  const send = (listenPort = 18000, destination = '10.250.1.1') => runCommand('/usr/bin/nsenter', ['-t', String(client.pid), '-n', process.execPath, helper, 'tcp-client', destination, String(listenPort), payload]);
  assert.equal((await send()).trim(), payload);
  assert.match(backend.logs(), /"peer":"10.250.2.1"/);
  const counters = (await service.status()).runtime.counters[mapping.id];
  assert.ok(counters && counters.bytes >= 64 * 1024 && counters.connections >= 1);
  const session = net.createConnection({ host: '10.250.1.1', port: 18000 });
  session.on('error', () => undefined); t.after(() => session.destroy());
  const echo = (data = randomBytes(2048)) => new Promise<void>((resolve, reject) => {
    const chunks: Buffer[] = [];
    const timer = setTimeout(() => { cleanup(); reject(new Error('persistent session timeout')); }, 3000);
    const receive = (chunk: Buffer) => {
      chunks.push(chunk);
      const response = Buffer.concat(chunks);
      if (response.length >= data.length) { cleanup(); try { assert.deepEqual(response, data); resolve(); } catch (error) { reject(error); } }
    };
    const error = (err: Error) => { cleanup(); reject(err); };
    const cleanup = () => { clearTimeout(timer); session.off('data', receive); session.off('error', error); };
    session.on('data', receive); session.on('error', error); session.write(data);
  });
  await echo();
  await service.change(1, state => { state.rules[0]!.target_port = 19001; });
  await echo(); // established TCP session survives reloading the same listener.
  assert.equal((await send()).trim(), payload);
  await service.change(2, state => { state.rules[0]!.listen_port = 18001; state.rules[0]!.listen_ip = '10.250.1.1'; });
  await assert.rejects(send());
  assert.equal((await send(18001)).trim(), payload);
  await assert.rejects(send(18001, '10.250.2.1'));
  await echo();
  const before = service.snapshot(), pid = (await runtime.status()).pid;
  await assert.rejects(runtime.apply(renderHAProxy(before) + '\nnot_valid_haproxy_syntax\n'));
  assert.equal((await runtime.status()).pid, pid);
  const occupied = net.createServer();
  await new Promise<void>(resolve => occupied.listen(18002, '0.0.0.0', resolve));
  t.after(() => occupied.close());
  await assert.rejects(service.change(3, state => { state.rules[0]!.listen_port = 18002; }), /原规则已保留/);
  assert.deepEqual(service.snapshot(), before); assert.deepEqual(await store.load(), before);
  assert.equal((await runtime.status()).pid, pid);
  assert.equal((await send(18001)).trim(), payload);
  await echo();
  await service.change(3, state => { state.rules[0]!.enabled = false; });
  await assert.rejects(send(18001));
  await echo();
  await service.change(4, state => { state.rules[0]!.enabled = true; });
  await service.change(5, state => { state.forwarding = false; });
  await assert.rejects(send(18001));
  await service.change(6, state => { state.forwarding = true; });
  assert.equal((await send(18001)).trim(), payload);
  await service.close();
  await assert.rejects(send(18001));
  assert.equal((await runtime.status()).healthy, false);
  const restarted = await Service.create(store, runtime, [22, 8080]);
  assert.equal(restarted.snapshot().revision, 7);
  assert.equal((await send(18001)).trim(), payload);
  assert.equal((await fs.readFile('/proc/sys/net/ipv4/ip_forward', 'utf8')).trim(), '0');
  await restarted.close();
});
