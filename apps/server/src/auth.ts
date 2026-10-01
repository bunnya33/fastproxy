import { randomBytes, scrypt as derive, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';
import { ApiError, token } from './model.js';

const scrypt = promisify(derive);
interface Session { user: string; csrf: string; expires: number }

export class Auth {
  private sessions = new Map<string, Session>();
  private attempts = new Map<string, { count: number; until: number }>();
  private constructor(private user: string, private salt: Buffer, private hash: Buffer) {}
  static async create(user: string, password: string): Promise<Auth> {
    const salt = randomBytes(32);
    return new Auth(user, salt, await scrypt(password, salt, 64) as Buffer);
  }
  async login(user: unknown, password: unknown, address: string): Promise<{ id: string; session: Session }> {
    const now = Date.now();
    this.prune(now);
    const attempts = this.attempts.get(address) ?? { count: 0, until: now + 5 * 60_000 };
    if (attempts.count >= 10) throw new ApiError(429, '登录尝试过多，请 5 分钟后再试');
    attempts.count++;
    if (this.attempts.size >= 1024 && !this.attempts.has(address)) this.attempts.delete(this.attempts.keys().next().value!);
    this.attempts.set(address, attempts);
    if (typeof user !== 'string' || typeof password !== 'string' || password.length > 1024) throw new ApiError(401, '用户名或密码错误');
    const hash = await scrypt(password, this.salt, 64) as Buffer;
    if (!timingSafeEqual(hash, this.hash) || user !== this.user) throw new ApiError(401, '用户名或密码错误');
    this.attempts.delete(address);
    if (this.sessions.size >= 256) this.sessions.delete(this.sessions.keys().next().value!);
    const id = token();
    const session = { user: this.user, csrf: token(), expires: now + 8 * 60 * 60_000 };
    this.sessions.set(id, session);
    return { id, session };
  }
  session(id?: string): Session | undefined {
    if (!id) return;
    const session = this.sessions.get(id);
    if (session && session.expires > Date.now()) return session;
    this.sessions.delete(id);
  }
  logout(id?: string): void { if (id) this.sessions.delete(id); }
  private prune(now: number): void {
    for (const [id, s] of this.sessions) if (s.expires <= now) this.sessions.delete(id);
    for (const [ip, attempt] of this.attempts) if (attempt.until <= now) this.attempts.delete(ip);
  }
}
