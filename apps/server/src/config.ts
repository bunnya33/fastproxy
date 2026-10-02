import path from 'node:path';
import { isIP } from 'node:net';
import { fileURLToPath } from 'node:url';
import { isPort } from './model.js';

export interface Config {
  mode: 'haproxy' | 'demo';
  host: string;
  port: number;
  dataDir: string;
  socketPath: string;
  haproxyBinary: string;
  runtimeDir: string;
  adminUser: string;
  adminPassword: string;
  cookieSecure: boolean;
  protectedPorts: number[];
  publicDir: string;
}

export function readConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const mode = env.FASTPROXY_MODE ?? 'haproxy';
  if (mode !== 'haproxy' && mode !== 'demo') throw new Error('FASTPROXY_MODE 必须是 haproxy 或 demo；旧安装请重新运行安装器迁移');
  if (mode === 'haproxy' && process.platform !== 'linux') throw new Error('HAProxy 部署需要 Linux；本地预览请使用 npm run dev');
  const listen = env.FASTPROXY_LISTEN ?? '127.0.0.1:8080';
  const split = listen.lastIndexOf(':');
  const host = listen.slice(0, split);
  const port = Number(listen.slice(split + 1));
  if (isIP(host) !== 4 || !isPort(port)) throw new Error('FASTPROXY_LISTEN 必须是 IPv4:端口，例如 127.0.0.1:8080');
  const adminUser = env.FASTPROXY_ADMIN_USER ?? 'admin';
  const adminPassword = env.FASTPROXY_ADMIN_PASSWORD ?? '';
  if (!adminUser.trim() || adminUser.length > 64 || /[\p{Cc}\p{Cf}]/u.test(adminUser)) throw new Error('管理用户名无效');
  if (adminPassword.length < 12) throw new Error('必须设置 FASTPROXY_ADMIN_PASSWORD，且至少 12 个字符');
  const ports = (env.FASTPROXY_PROTECTED_PORTS ?? '22').split(',').filter(Boolean).map(Number);
  if (ports.some(p => !isPort(p))) throw new Error('FASTPROXY_PROTECTED_PORTS 端口无效');
  const dataDir = path.resolve(env.FASTPROXY_DATA_DIR ?? (mode === 'demo' ? './data' : '/var/lib/fastproxy'));
  return {
    mode, host, port, dataDir,
    socketPath: env.FASTPROXY_SOCKET ?? '/run/fastproxy/control.sock',
    haproxyBinary: env.FASTPROXY_HAPROXY_BINARY ?? '/usr/sbin/haproxy',
    runtimeDir: env.FASTPROXY_RUNTIME_DIR ?? path.dirname(env.FASTPROXY_SOCKET ?? '/run/fastproxy/control.sock'),
    adminUser, adminPassword, cookieSecure: env.FASTPROXY_COOKIE_SECURE === 'true',
    protectedPorts: [...new Set([...ports, port])],
    publicDir: path.resolve(env.FASTPROXY_PUBLIC_DIR ?? fileURLToPath(new URL('../public', import.meta.url))),
  };
}
