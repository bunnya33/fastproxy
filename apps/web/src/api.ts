export interface Rule {
  id: string;
  name: string;
  protocol: 'tcp' | 'udp' | 'both';
  listen_ip: string;
  listen_port: number;
  target_ip: string;
  target_port: number;
  enabled: boolean;
}
export interface Status {
  state: { schema_version: number; revision: number; forwarding: boolean; rules: Rule[]; updated_at: string | null };
  runtime: { mode: 'nftables' | 'demo'; healthy: boolean; ip_forward: boolean; error?: string; counters: Record<string, { packets: number; bytes: number }> };
  uptime_seconds: number;
  protected_ports: number[];
}
export class RequestError extends Error {
  constructor(public status: number, message: string) { super(message); }
}
let csrf = '';
export function setCSRF(value: string): void { csrf = value; }
export async function api<T>(url: string, method = 'GET', body?: unknown): Promise<T> {
  const response = await fetch(`/api${url}`, {
    method, credentials: 'same-origin',
    headers: { ...(body === undefined ? {} : { 'Content-Type': 'application/json' }), 'X-CSRF-Token': csrf },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(25_000),
  });
  const data = await response.json();
  if (!response.ok) throw new RequestError(response.status, data.error ?? '请求失败');
  return data as T;
}
