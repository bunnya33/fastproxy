import { randomBytes } from 'node:crypto';
import { isIP } from 'node:net';

export interface Rule {
  id: string;
  name: string;
  protocol: 'tcp' | 'udp';
  listen_ip: string;
  listen_port: number;
  target_ip: string;
  target_port: number;
  enabled: boolean;
}
export interface State {
  schema_version: 2;
  revision: number;
  forwarding: boolean;
  rules: Rule[];
  updated_at: string | null;
}
export class ApiError extends Error {
  constructor(public statusCode: number, message: string) { super(message); }
}
export const token = () => randomBytes(24).toString('hex');
export const initialState = (): State => ({ schema_version: 2, revision: 0, forwarding: true, rules: [], updated_at: null });
export const isPort = (value: unknown): value is number => Number.isInteger(value) && Number(value) >= 1 && Number(value) <= 65535;

export function object(value: unknown, keys: string[]): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new ApiError(400, '请求必须是 JSON 对象');
  const record = value as Record<string, unknown>;
  if (Object.keys(record).some(key => !keys.includes(key))) throw new ApiError(400, '请求包含未知字段');
  return record;
}
export function revision(value: unknown): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) throw new ApiError(400, '缺少有效的规则版本，请刷新页面');
  return value;
}

export function parseRule(value: unknown, id: string, allowArchivedUDP = false): Rule {
  const r = object(value, ['id', 'name', 'protocol', 'listen_ip', 'listen_port', 'target_ip', 'target_port', 'enabled']);
  if (typeof r.name !== 'string' || !r.name.trim() || [...r.name].length > 60 || /[\p{Cc}\p{Cf}]/u.test(r.name)) throw new ApiError(400, '规则名称应为 1–60 个可见字符');
  if (r.protocol !== 'tcp' && !(allowArchivedUDP && r.protocol === 'udp' && r.enabled === false)) throw new ApiError(400, 'HAProxy 仅支持 TCP 转发；旧 UDP 规则只能保留为停用状态，请改为 TCP 或删除');
  if (typeof r.listen_ip !== 'string' || isIP(r.listen_ip) !== 4 || invalidAddress(r.listen_ip, false)) throw new ApiError(400, '监听地址必须是本机 IPv4 地址，或 0.0.0.0');
  if (typeof r.target_ip !== 'string' || isIP(r.target_ip) !== 4 || invalidAddress(r.target_ip, true)) throw new ApiError(400, '目标必须是有效的非回环 IPv4 地址');
  if (!isPort(r.listen_port) || !isPort(r.target_port)) throw new ApiError(400, '端口范围为 1–65535');
  if (typeof r.enabled !== 'boolean') throw new ApiError(400, '启用状态必须是布尔值');
  if (!/^[a-f0-9]{48}$/.test(id)) throw new ApiError(400, '规则 ID 无效');
  if (r.listen_ip === r.target_ip && r.listen_port === r.target_port) throw new ApiError(400, '监听和目标不能是同一个端点');
  return { id, name: r.name.trim(), protocol: r.protocol, listen_ip: r.listen_ip, listen_port: r.listen_port, target_ip: r.target_ip, target_port: r.target_port, enabled: r.enabled };
}

function invalidAddress(ip: string, target: boolean): boolean {
  const first = Number(ip.split('.')[0]);
  return first >= 224 || (target && (first === 0 || first === 127));
}

export function validateState(state: State, protectedPorts: number[]): void {
  if (state.schema_version !== 2 || !Array.isArray(state.rules) || typeof state.forwarding !== 'boolean' || !Number.isSafeInteger(state.revision) || state.revision < 0) throw new ApiError(400, '规则文件格式或版本无效');
  if (state.rules.length > 500) throw new ApiError(400, '最多支持 500 条规则');
  const ids = new Set<string>();
  state.rules.forEach((rule, index) => {
    parseRule(rule, rule.id, true);
    if (ids.has(rule.id)) throw new ApiError(400, '规则 ID 重复');
    ids.add(rule.id);
    if (protectedPorts.includes(rule.listen_port)) throw new ApiError(400, `端口 ${rule.listen_port} 用于 SSH 或管理后台，不能用于转发`);
    if (!rule.enabled) return;
    for (const other of state.rules.slice(0, index)) {
      if (other.enabled && rule.listen_port === other.listen_port && (rule.listen_ip === other.listen_ip || rule.listen_ip === '0.0.0.0' || other.listen_ip === '0.0.0.0')) {
        throw new ApiError(400, `监听端口与规则「${other.name}」冲突`);
      }
    }
  });
}

export function migrateState(value: State): State {
  const legacy = value as unknown as { schema_version: number; rules?: Record<string, unknown>[] };
  if (legacy.schema_version !== 1) return value;
  if (!Array.isArray(legacy.rules)) throw new ApiError(400, '旧规则文件格式无效，已保留原文件');
  const state = structuredClone(value);
  state.schema_version = 2;
  for (const entry of state.rules) {
    const protocol = entry.protocol as string;
    if (protocol === 'both') entry.protocol = 'tcp';
    else if (protocol === 'udp') entry.enabled = false;
  }
  state.revision++;
  state.updated_at = new Date().toISOString();
  return state;
}

export function renderHAProxy(state: State, socketPath = '/run/fastproxy/haproxy.sock'): string {
  const lines = ['# Managed by FastProxy. Raw TCP forwarding.', 'global', '  maxconn 4096', '  nbthread 1',
    `  stats socket ${socketPath} mode 600 level admin expose-fd listeners`, '  stats timeout 2s', '',
    'defaults', '  mode tcp', '  option tcpka', '  timeout connect 5s', '  timeout client 1h', '  timeout server 1h', ''];
  for (const r of state.forwarding ? state.rules.filter(r => r.enabled && r.protocol === 'tcp') : []) {
    lines.push(`frontend fp_${r.id}`, `  bind ${r.listen_ip}:${r.listen_port}`, `  default_backend target_${r.id}`, '',
      `backend target_${r.id}`, `  server target ${r.target_ip}:${r.target_port}`, '');
  }
  return lines.join('\n');
}
