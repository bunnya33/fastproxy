import { token, type Rule } from '../src/model.js';
import type { Runtime, RuntimeStatus } from '../src/runtime.js';

export class FakeRuntime implements Runtime {
  applied: string[] = [];
  fail = false;
  async apply(config: string): Promise<void> { if (this.fail) throw new Error('simulated HAProxy rejection'); this.applied.push(config); }
  async clear(): Promise<void> {}
  async status(): Promise<RuntimeStatus> { return { mode: 'haproxy', healthy: true, counters: {} }; }
}
export const rule = (changes: Partial<Rule> = {}): Rule => ({ id: token(), name: '测试规则', protocol: 'tcp', listen_ip: '0.0.0.0', listen_port: 18000, target_ip: '10.250.2.2', target_port: 19000, enabled: true, ...changes });
