import Fastify, { type FastifyInstance } from 'fastify';
import cookie from '@fastify/cookie';
import staticFiles from '@fastify/static';
import fs from 'node:fs/promises';
import { Auth } from './auth.js';
import type { Config } from './config.js';
import { ApiError, object, parseRule, renderNFT, revision, token } from './model.js';
import type { Service } from './service.js';

export async function buildApp(service: Service, config: Config, auth: Auth, local = false, logging = true): Promise<FastifyInstance> {
  const app = Fastify({ logger: logging, bodyLimit: 64 * 1024, requestTimeout: 30_000, connectionTimeout: 10_000 });
  await app.register(cookie);
  app.setErrorHandler((error, request, reply) => {
    const err = error as Error & { statusCode?: number };
    const status = err.statusCode ?? 500;
    if (status >= 500) request.log.error({ err }, 'request failed');
    reply.code(status).send({ error: status === 500 ? '服务内部错误，请查看服务日志' : err.message });
  });
  app.addHook('onSend', async (request, reply, payload) => {
    reply.header('X-Content-Type-Options', 'nosniff');
    reply.header('X-Frame-Options', 'DENY');
    reply.header('Referrer-Policy', 'same-origin');
    reply.header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'");
    if (request.routeOptions.url?.startsWith('/api') || request.routeOptions.url === '/healthz') reply.header('Cache-Control', 'no-store');
    return payload;
  });
  app.addHook('preHandler', async request => {
    // Fastify decodes URL segments before matching. Authorize the matched route,
    // not the raw URL, so /%61pi/status cannot bypass the API login guard.
    const url = request.routeOptions.url;
    if (!url?.startsWith('/api/') || local) return;
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      const origin = request.headers.origin;
      if (origin) {
        let host: string;
        try { host = new URL(origin).host; } catch { throw new ApiError(403, '请求来源无效'); }
        if (host !== request.headers.host) throw new ApiError(403, '跨站请求已拒绝');
      }
      if (!request.headers['content-type']?.startsWith('application/json')) throw new ApiError(415, '请求必须使用 application/json');
    }
    if (url === '/api/login') return;
    const session = auth.session(request.cookies.fastproxy_session);
    if (!session) throw new ApiError(401, '请先登录');
    if (request.method !== 'GET' && request.method !== 'HEAD' && request.headers['x-csrf-token'] !== session.csrf) throw new ApiError(403, 'CSRF 校验失败，请刷新页面');
  });

  app.get('/healthz', async (_request, reply) => {
    const status = await service.status();
    reply.code(status.runtime.healthy ? 200 : 503).send({ status: status.runtime.healthy ? 'ok' : 'unhealthy' });
  });
  if (!local) {
    app.post('/api/login', async (request, reply) => {
      const body = object(request.body, ['username', 'password']);
      const { id, session } = await auth.login(body.username, body.password, request.ip);
      reply.setCookie('fastproxy_session', id, { path: '/', httpOnly: true, sameSite: 'strict', secure: config.cookieSecure, maxAge: 8 * 60 * 60 });
      await service.audit(session.user, 'login');
      return { user: session.user, csrf: session.csrf };
    });
    app.get('/api/session', async request => {
      const session = auth.session(request.cookies.fastproxy_session)!;
      return { user: session.user, csrf: session.csrf };
    });
    app.post('/api/logout', async (request, reply) => {
      auth.logout(request.cookies.fastproxy_session);
      reply.clearCookie('fastproxy_session', { path: '/' });
      return { ok: true };
    });
  }
  const actor = (id?: string) => local ? 'root-console' : auth.session(id)?.user ?? 'unknown';
  app.get('/api/status', () => service.status());
  app.get('/api/config', () => ({ config: renderNFT(service.snapshot()), revision: service.snapshot().revision }));
  app.post('/api/rules', async request => {
    const body = object(request.body, ['revision', 'rule']);
    const rule = parseRule(body.rule, token());
    const state = await service.change(revision(body.revision), state => state.rules.push(rule));
    await service.audit(actor(request.cookies.fastproxy_session), `rule.create:${rule.id}`);
    return state;
  });
  app.put<{ Params: { id: string } }>('/api/rules/:id', async request => {
    const body = object(request.body, ['revision', 'rule']);
    const rule = parseRule(body.rule, request.params.id);
    const state = await service.change(revision(body.revision), state => {
      const index = state.rules.findIndex(r => r.id === rule.id);
      if (index === -1) throw new ApiError(404, '规则不存在');
      state.rules[index] = rule;
    });
    await service.audit(actor(request.cookies.fastproxy_session), `rule.update:${rule.id}`);
    return state;
  });
  app.delete<{ Params: { id: string } }>('/api/rules/:id', async request => {
    const body = object(request.body, ['revision']);
    const state = await service.change(revision(body.revision), state => {
      const index = state.rules.findIndex(r => r.id === request.params.id);
      if (index === -1) throw new ApiError(404, '规则不存在');
      state.rules.splice(index, 1);
    });
    await service.audit(actor(request.cookies.fastproxy_session), `rule.delete:${request.params.id}`);
    return state;
  });
  app.post('/api/forwarding', async request => {
    const body = object(request.body, ['revision', 'forwarding']);
    if (typeof body.forwarding !== 'boolean') throw new ApiError(400, '转发状态必须是布尔值');
    const state = await service.change(revision(body.revision), state => { state.forwarding = body.forwarding as boolean; });
    await service.audit(actor(request.cookies.fastproxy_session), `forwarding:${state.forwarding}`);
    return state;
  });
  app.post('/api/reapply', async request => {
    object(request.body, []);
    await service.reapply();
    await service.audit(actor(request.cookies.fastproxy_session), 'rules.reapply');
    return { ok: true };
  });
  if (!local) {
    const hasWeb = await fs.stat(config.publicDir).then(s => s.isDirectory()).catch(() => false);
    if (hasWeb) await app.register(staticFiles, { root: config.publicDir });
    else app.get('/', async (_request, reply) => reply.type('text/plain').send('FastProxy API 已启动。前端开发：npm run dev；部署前请执行 npm run build。'));
  }
  return app;
}
