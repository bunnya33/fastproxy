import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { initialState, renderNFT } from '../src/model.js';
import { NFTRuntime, nftBatch, runCommand } from '../src/runtime.js';
import { rule } from './fixtures.js';
import { Store } from '../src/store.js';
import { Service } from '../src/service.js';

// Run only inside a private network namespace: never alter the host firewall.
test('real nftables: TCP/UDP payloads and replies, SNAT, edits, disable, atomic rejection and unrelated firewall preservation', { skip: process.env.FASTPROXY_INTEGRATION !== '1', timeout: 45_000 }, async t => {
  assert.equal(process.platform, 'linux'); assert.equal(process.getuid?.(), 0);
  const interfaces = Object.keys(os.networkInterfaces());
  assert.ok(interfaces.every(name => name === 'lo'), 'integration test must be run under unshare --net, with no host interfaces');
  assert.notEqual(await fs.readlink('/proc/self/ns/net'), await fs.readlink('/proc/1/ns/net'), 'refuse to run in the init process network namespace');
  const helper = fileURLToPath(new URL('./network-helper.js', import.meta.url));
  const children: ChildProcess[] = [];
  const startNamespace = async (mode: string): Promise<{ pid: number; logs: () => string }> => {
    const child = spawn('unshare', ['--net', process.execPath, helper, mode]); children.push(child);
    let output = '';
    const ready = new Promise<number>((resolve, reject) => {
      child.stdout.on('data', chunk => {
        output += chunk.toString();
        for (const line of output.split('\n')) if (line.includes('"ready":true')) { resolve(JSON.parse(line).pid as number); return; }
      });
      child.stderr.on('data', chunk => reject(new Error(chunk.toString())));
      child.on('error', reject);
      child.on('exit', code => reject(new Error(`namespace helper exited: ${code}`)));
    });
    return { pid: await ready, logs: () => output };
  };
  t.after(() => { for (const child of children) child.kill('SIGTERM'); });
  const client = await startNamespace('hold'), backend = await startNamespace('backend');
  const ip = (...args: string[]) => runCommand('/usr/sbin/ip', args);
  const nsip = (pid: number, ...args: string[]) => runCommand('/usr/bin/nsenter', ['-t', String(pid), '-n', '/usr/sbin/ip', ...args]);
  await ip('link', 'set', 'lo', 'up');
  for (const [name, peer, pid, proxyIP, remoteIP] of [['fpclient', 'cpeer', client.pid, '10.250.1.1', '10.250.1.2'], ['fpbackend', 'bpeer', backend.pid, '10.250.2.1', '10.250.2.2']] as const) {
    await ip('link', 'add', name, 'type', 'veth', 'peer', 'name', peer);
    await ip('link', 'set', peer, 'netns', String(pid));
    await ip('addr', 'add', `${proxyIP}/24`, 'dev', name); await ip('link', 'set', name, 'up');
    await nsip(pid, 'link', 'set', 'lo', 'up'); await nsip(pid, 'addr', 'add', `${remoteIP}/24`, 'dev', peer); await nsip(pid, 'link', 'set', peer, 'up');
    // Backend deliberately has no route to the client subnet: SNAT is required.
  }
  await nsip(client.pid, 'route', 'add', 'default', 'via', '10.250.1.1');
  await fs.writeFile('/proc/sys/net/ipv4/ip_forward', '1');
  const nft = '/usr/sbin/nft';
  await nftBatch(nft, 'table ip unrelated {\n  chain sentinel {\n  }\n}\n');
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-network-')); t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const runtime = new NFTRuntime(nft), store = new Store(dir);
  const service = await Service.create(store, runtime, [22, 8080]);
  const mapping = rule({ protocol: 'both' });
  await service.change(0, state => state.rules.push(mapping));
  const payload = randomBytes(32 * 1024).toString('base64');
  const send = (protocol: string, listenPort = 18000, destination = '10.250.1.1') => runCommand('/usr/bin/nsenter', ['-t', String(client.pid), '-n', process.execPath, helper, `${protocol}-client`, destination, String(listenPort), payload]);
  assert.equal((await send('tcp')).trim(), payload);
  assert.equal((await send('udp')).trim(), payload);
  assert.match(backend.logs(), /"peer":"10.250.2.1"/);
  const counters = (await service.status()).runtime.counters[mapping.id];
  assert.ok(counters && counters.bytes > 64 * 1024 && counters.packets >= 4);
  await service.change(1, state => { state.rules[0]!.listen_port = 18001; state.rules[0]!.listen_ip = '10.250.1.1'; });
  await assert.rejects(send('tcp', 18000));
  assert.equal((await send('tcp', 18001)).trim(), payload);
  assert.equal((await send('udp', 18001)).trim(), payload);
  await assert.rejects(send('tcp', 18001, '10.250.2.1'));
  const before = await runCommand(nft, ['-j', 'list', 'table', 'ip', 'fastproxy']);
  await assert.rejects(runtime.apply(renderNFT(initialState()) + '\nthis_is_not_valid_nft_syntax\n'));
  const after = await runCommand(nft, ['-j', 'list', 'table', 'ip', 'fastproxy']);
  assert.equal(after, before);
  assert.equal((await send('tcp', 18001)).trim(), payload);
  await service.change(2, state => { state.rules[0]!.enabled = false; });
  await assert.rejects(send('tcp', 18001)); await assert.rejects(send('udp', 18001));
  await service.change(3, state => { state.rules[0]!.enabled = true; });
  await service.change(4, state => { state.forwarding = false; });
  await assert.rejects(send('tcp', 18001));
  await service.change(5, state => { state.forwarding = true; });
  assert.equal((await send('tcp', 18001)).trim(), payload);
  await service.close();
  await assert.rejects(runCommand(nft, ['list', 'table', 'ip', 'fastproxy']));
  const restarted = await Service.create(store, runtime, [22, 8080]);
  assert.equal(restarted.snapshot().revision, 6);
  assert.equal((await send('tcp', 18001)).trim(), payload);
  assert.match(await runCommand(nft, ['list', 'table', 'ip', 'unrelated']), /sentinel/);
  await restarted.close();
});
