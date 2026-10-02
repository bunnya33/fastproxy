import { networkInterfaces } from 'node:os';
import { ApiError, migrateState, renderHAProxy, validateState, type State } from './model.js';
import type { Store } from './store.js';
import type { Runtime, RuntimeStatus } from './runtime.js';

export interface Status {
  state: State;
  runtime: RuntimeStatus;
  uptime_seconds: number;
  protected_ports: number[];
}

export class Service {
  private tail: Promise<unknown> = Promise.resolve();
  private started = Date.now();
  private lastError = '';
  private constructor(private state: State, private store: Store, private runtime: Runtime, private protectedPorts: number[]) {}

  static async create(store: Store, runtime: Runtime, protectedPorts: number[]): Promise<Service> {
    const loaded = await store.load();
    const state = migrateState(loaded);
    validateState(state, protectedPorts);
    if (state !== loaded) await store.backupLegacy(loaded);
    await runtime.apply(renderHAProxy(state));
    if (state !== loaded) {
      try { await store.save(state); }
      catch (error) { await runtime.clear(); throw error; }
      console.log('旧规则已备份到 state.nftables-backup.json；both 已迁移为 TCP，UDP 已停用。');
    }
    return new Service(state, store, runtime, protectedPorts);
  }
  private serial<T>(fn: () => Promise<T>): Promise<T> {
    const pending = this.tail.then(fn, fn);
    this.tail = pending.catch(() => undefined);
    return pending;
  }
  snapshot(): State { return structuredClone(this.state); }

  async change(revision: number, mutate: (state: State) => void): Promise<State> {
    return this.serial(async () => {
      if (revision !== this.state.revision) throw new ApiError(409, '规则已被其他页面或控制台修改，请刷新后重试');
      const candidate = this.snapshot();
      mutate(candidate);
      validateState(candidate, this.protectedPorts);
      // Prevent redirecting a local endpoint back into the same listener.
      const localIPs = new Set(Object.values(networkInterfaces()).flat().filter(Boolean).map(i => i!.address));
      for (const r of candidate.rules) {
        if (r.enabled && r.listen_port === r.target_port && localIPs.has(r.target_ip) && (r.listen_ip === '0.0.0.0' || r.listen_ip === r.target_ip)) throw new ApiError(400, '目标指向本机同一个监听端口，会形成循环');
      }
      candidate.revision++;
      candidate.updated_at = new Date().toISOString();
      // Durable intent first. On crash, startup reapplies this intent. No reader
      // can observe it before the new HAProxy worker is ready.
      await this.store.save(candidate);
      try { await this.runtime.apply(renderHAProxy(candidate)); }
      catch (error) {
        try { await this.store.save(this.state); }
        catch (restoreError) {
          this.lastError = `应用失败且磁盘恢复失败，重启前请检查 state.json: ${(error as Error).message}; ${(restoreError as Error).message}`;
          throw new ApiError(503, this.lastError);
        }
        throw new ApiError(503, `应用失败，原规则已保留: ${(error as Error).message}`);
      }
      this.state = candidate; this.lastError = '';
      return this.snapshot();
    });
  }

  async reapply(): Promise<void> {
    return this.serial(async () => {
      // Also repair disk after a previous persistence rollback failure.
      await this.store.save(this.state);
      await this.runtime.apply(renderHAProxy(this.state));
      this.lastError = '';
    });
  }
  async status(): Promise<Status> {
    return this.serial(async () => {
      const runtime = await this.runtime.status();
      if (this.lastError) { runtime.healthy = false; runtime.error = this.lastError; }
      return { state: this.snapshot(), runtime, uptime_seconds: Math.floor((Date.now() - this.started) / 1000), protected_ports: this.protectedPorts };
    });
  }
  async audit(actor: string, action: string): Promise<void> {
    try { await this.store.audit(actor, action); }
    catch (error) { console.error('audit write failed', (error as Error).message); }
  }
  async close(): Promise<void> { return this.serial(() => this.runtime.clear()); }
}
