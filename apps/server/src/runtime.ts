import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

export interface Counter { packets: number; bytes: number }
export interface RuntimeStatus {
  mode: 'nftables' | 'demo';
  healthy: boolean;
  ip_forward: boolean;
  counters: Record<string, Counter>;
  error?: string;
}
export interface Runtime {
  apply(config: string): Promise<void>;
  status(): Promise<RuntimeStatus>;
  clear(): Promise<void>;
}

export function runCommand(binary: string, args: string[], input = '', timeout = 8_000): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(binary, args, { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
    let stdout = '', stderr = '', size = 0, failure: Error | undefined;
    const timer = setTimeout(() => { failure = new Error('命令执行超时'); child.kill('SIGKILL'); }, timeout);
    const collect = (chunk: Buffer, output: 'stdout' | 'stderr') => {
      size += chunk.length;
      if (size > 8 * 1024 * 1024) { failure = new Error('命令输出过大'); child.kill('SIGKILL'); return; }
      if (output === 'stdout') stdout += chunk.toString(); else stderr += chunk.toString();
    };
    child.stdout.on('data', chunk => collect(chunk, 'stdout'));
    child.stderr.on('data', chunk => collect(chunk, 'stderr'));
    child.once('error', error => { clearTimeout(timer); reject(error); });
    child.once('close', code => {
      clearTimeout(timer);
      if (failure) reject(failure);
      else if (code !== 0) reject(new Error(`${binary} 执行失败: ${stderr.trim().slice(0, 3000) || `退出码 ${code}`}`));
      else resolve(stdout);
    });
    child.stdin.on('error', () => { /* process error/exit contains the useful diagnostic */ });
    child.stdin.end(input);
  });
}

export function parseCounters(json: string): Record<string, Counter> {
  const result = JSON.parse(json) as { nftables: { rule?: { comment?: string; expr?: { counter?: Counter }[] } }[] };
  if (!Array.isArray(result.nftables)) throw new Error('nftables 返回格式无效');
  const counters: Record<string, Counter> = {};
  for (const entry of result.nftables) {
    const parts = entry.rule?.comment?.split(':');
    if (!parts || parts.length !== 4 || parts[0] !== 'fp' || !['in', 'out'].includes(parts[2]!) || !/^[a-f0-9]{48}$/.test(parts[1]!)) continue;
    for (const expr of entry.rule?.expr ?? []) {
      if (expr.counter && typeof expr.counter.bytes === 'number' && typeof expr.counter.packets === 'number') {
        const counter = counters[parts[1]!] ?? { bytes: 0, packets: 0 };
        counter.bytes += expr.counter.bytes; counter.packets += expr.counter.packets;
        counters[parts[1]!] = counter;
      }
    }
  }
  return counters;
}

export async function nftBatch(binary: string, config: string, checkFirst = true): Promise<void> {
  // nft 1.0.9+ can reject piped /dev/stdin as "Not a regular file".
  // Keep a single private regular file for both validation and application.
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fastproxy-nft-'));
  try {
    const filename = path.join(dir, 'batch.nft');
    await fs.writeFile(filename, config, { mode: 0o600 });
    if (checkFirst) await runCommand(binary, ['-c', '-f', filename]);
    await runCommand(binary, ['-f', filename]);
  } finally { await fs.rm(dir, { recursive: true, force: true }); }
}

export class NFTRuntime implements Runtime {
  constructor(private binary: string) {}
  async apply(config: string): Promise<void> {
    const forward = await fs.readFile('/proc/sys/net/ipv4/ip_forward', 'utf8');
    if (forward.trim() !== '1') throw new Error('IPv4 转发未开启，请执行 sysctl -w net.ipv4.ip_forward=1');
    await nftBatch(this.binary, config);
  }
  async status(): Promise<RuntimeStatus> {
    const status: RuntimeStatus = { mode: 'nftables', healthy: false, ip_forward: false, counters: {} };
    try {
      status.ip_forward = (await fs.readFile('/proc/sys/net/ipv4/ip_forward', 'utf8')).trim() === '1';
      status.counters = parseCounters(await runCommand(this.binary, ['-j', 'list', 'table', 'ip', 'fastproxy']));
      status.healthy = status.ip_forward;
      if (!status.ip_forward) status.error = 'IPv4 转发未开启';
    } catch (error) { status.error = (error as Error).message; }
    return status;
  }
  async clear(): Promise<void> { await nftBatch(this.binary, 'add table ip fastproxy\ndelete table ip fastproxy\n', false); }
}

export class DemoRuntime implements Runtime {
  async apply(_config: string): Promise<void> {}
  async clear(): Promise<void> {}
  async status(): Promise<RuntimeStatus> { return { mode: 'demo', healthy: true, ip_forward: false, counters: {} }; }
}
