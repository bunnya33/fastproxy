import { spawn, type ChildProcess } from 'node:child_process';
import fs from 'node:fs/promises';
import net from 'node:net';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

export interface Counter { connections: number; bytes: number }
export interface RuntimeStatus {
  mode: 'haproxy' | 'demo';
  healthy: boolean;
  counters: Record<string, Counter>;
  version?: string;
  pid?: number;
  draining_workers?: number;
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

export function statsCommand(socketPath: string, command: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ path: socketPath });
    let output = '';
    socket.setTimeout(2000, () => socket.destroy(new Error('HAProxy 状态查询超时')));
    socket.on('connect', () => socket.end(command + '\n'));
    socket.on('data', data => {
      output += data.toString();
      if (output.length > 8 * 1024 * 1024) socket.destroy(new Error('HAProxy 状态输出过大'));
    });
    socket.on('error', reject);
    socket.on('end', () => resolve(output));
  });
}

export function parseCounters(csv: string): Record<string, Counter> {
  const rows = csv.trim().split('\n');
  const header = rows.shift()?.replace(/^#\s*/, '').trim().split(',');
  if (!header || ['pxname', 'svname', 'bin', 'bout', 'stot'].some(key => !header.includes(key))) throw new Error('HAProxy 返回的统计格式无效');
  const counters: Record<string, Counter> = {};
  for (const row of rows) {
    const fields = row.trim().split(',');
    const get = (key: string) => fields[header.indexOf(key)] ?? '';
    const name = get('pxname');
    if (get('svname') !== 'FRONTEND' || !/^fp_[a-f0-9]{48}$/.test(name)) continue;
    const bytesIn = Number(get('bin')), bytesOut = Number(get('bout')), connections = Number(get('stot'));
    if ([bytesIn, bytesOut, connections].some(value => !Number.isFinite(value) || value < 0)) throw new Error('HAProxy 流量统计无效');
    counters[name.slice(3)] = { bytes: bytesIn + bytesOut, connections };
  }
  return counters;
}

interface Worker {
  child: ChildProcess;
  dir: string;
  socket: string;
  exited: boolean;
  error: string;
  done: Promise<void>;
}

export class HAProxyRuntime implements Runtime {
  private active?: Worker;
  private workers = new Set<Worker>();
  private applying = false;
  private closing = false;
  constructor(private binary: string, private runDir: string, private onFailure?: (error: Error) => void) {
    if (!path.isAbsolute(runDir) || !/^[A-Za-z0-9_/.\-]+$/.test(runDir) || runDir.length > 65) throw new Error('HAProxy 运行目录必须是较短的绝对路径，且不能包含空格');
  }
  async apply(config: string): Promise<void> {
    if (this.workers.size >= 32) throw new Error('等待旧连接结束的 HAProxy 进程过多，请等待会话结束或重启服务');
    this.applying = true;
    this.closing = false;
    let worker: Worker | undefined;
    let dir = '';
    try {
      await fs.mkdir(this.runDir, { recursive: true, mode: 0o700 });
      dir = await fs.mkdtemp(path.join(this.runDir, 'g-'));
      const socket = path.join(dir, 'stats.sock');
      const filename = path.join(dir, 'haproxy.cfg');
      await fs.writeFile(filename, config.replace('stats socket /run/fastproxy/haproxy.sock', `stats socket ${socket}`), { mode: 0o600 });
      await runCommand(this.binary, ['-c', '-f', filename]);
      const previous = this.active && !this.active.exited ? this.active : undefined;
      const args = ['-db', '-f', filename];
      // Transfer listener FDs and retire the old worker only after a successful
      // bind. Each generation has its own private admin socket and config.
      if (previous) args.push('-x', previous.socket, '-sf', String(previous.child.pid));
      const child = spawn(this.binary, args, { stdio: ['ignore', 'pipe', 'pipe'] });
      worker = { child, dir, socket, exited: false, error: '', done: Promise.resolve() };
      const current = worker;
      this.workers.add(current);
      const capture = (data: Buffer) => { current.error = (current.error + data.toString()).slice(-3000); };
      child.stdout!.on('data', capture);
      child.stderr!.on('data', capture);
      child.on('error', error => { current.error = error.message; });
      current.done = new Promise(resolve => child.once('close', () => {
        current.exited = true;
        this.workers.delete(current);
        void fs.rm(current.dir, { recursive: true, force: true }).catch(() => undefined);
        resolve();
        if (this.active === current && !this.applying && !this.closing) this.onFailure?.(new Error(current.error || 'HAProxy 进程退出'));
      }));
      const deadline = Date.now() + 8000;
      while (Date.now() < deadline) {
        if (current.exited) throw new Error(current.error || 'HAProxy 进程启动失败');
        const info = await statsCommand(socket, 'show info').catch(() => '');
        if (Number(info.match(/^Pid: (\d+)/m)?.[1]) === child.pid && !current.exited) {
          this.active = current;
          return;
        }
        await delay(50);
      }
      throw new Error(current.error || 'HAProxy 未就绪');
    } catch (error) {
      if (worker) await this.stop(worker);
      else if (dir) await fs.rm(dir, { recursive: true, force: true });
      throw error;
    } finally {
      this.applying = false;
      // A worker can exit while a replacement is being validated or started.
      // Report a lost active worker once the replacement attempt has finished.
      if (this.active?.exited && !this.closing) this.onFailure?.(new Error(this.active.error || 'HAProxy 进程退出'));
    }
  }
  async status(): Promise<RuntimeStatus> {
    const status: RuntimeStatus = { mode: 'haproxy', healthy: false, counters: {}, draining_workers: Math.max(0, this.workers.size - 1) };
    try {
      if (!this.active || this.active.exited) throw new Error('HAProxy 未运行');
      const [info, stats] = await Promise.all([statsCommand(this.active.socket, 'show info'), statsCommand(this.active.socket, 'show stat')]);
      status.pid = Number(info.match(/^Pid: (\d+)/m)?.[1]);
      if (status.pid !== this.active.child.pid) throw new Error('HAProxy 进程状态不一致');
      status.version = info.match(/^Version: (.+)/m)?.[1];
      status.counters = parseCounters(stats);
      status.healthy = true;
    } catch (error) { status.error = (error as Error).message; }
    return status;
  }
  private async stop(worker: Worker): Promise<void> {
    if (!worker.exited) {
      worker.child.kill('SIGTERM');
      await Promise.race([worker.done, delay(2000)]);
      if (!worker.exited) { worker.child.kill('SIGKILL'); await worker.done; }
    }
    await fs.rm(worker.dir, { recursive: true, force: true });
  }
  async clear(): Promise<void> {
    this.closing = true;
    this.active = undefined;
    await Promise.all([...this.workers].map(worker => this.stop(worker)));
  }
}

export class DemoRuntime implements Runtime {
  async apply(_config: string): Promise<void> {}
  async clear(): Promise<void> {}
  async status(): Promise<RuntimeStatus> { return { mode: 'demo', healthy: true, counters: {} }; }
}
