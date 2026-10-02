import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Auth } from './auth.js';
import { readConfig } from './config.js';
import { buildApp } from './http.js';
import { DemoRuntime, HAProxyRuntime } from './runtime.js';
import { Service } from './service.js';
import { Store } from './store.js';
import { acquireLock } from './lock.js';

export async function start(): Promise<void> {
  const config = readConfig();
  config.publicDir = process.env.FASTPROXY_PUBLIC_DIR ?? fileURLToPath(new URL('../public/', import.meta.url));
  const auth = await Auth.create(config.adminUser, config.adminPassword);
  const unlock = await acquireLock(config.dataDir);
  let service: Service | undefined;
  let failed = false;
  const runtime = config.mode === 'demo' ? new DemoRuntime() : new HAProxyRuntime(config.haproxyBinary, config.runtimeDir, error => {
    if (failed) return;
    failed = true;
    console.error('HAProxy worker failed:', error.message);
    // Queue cleanup after any in-flight change so disk rollback finishes first.
    void (service?.close() ?? runtime.clear()).catch(() => undefined).finally(() => process.exit(1));
  });
  try { service = await Service.create(new Store(config.dataDir), runtime, config.protectedPorts); }
  catch (error) { await unlock(); throw error; }
  let web: Awaited<ReturnType<typeof buildApp>>;
  try { web = await buildApp(service, config, auth); }
  catch (error) { await service.close().catch(() => undefined); await unlock(); throw error; }
  let control: Awaited<ReturnType<typeof buildApp>> | undefined;
  try {
    if (config.mode === 'haproxy') {
      const dir = path.dirname(config.socketPath);
      await fs.mkdir(dir, { recursive: true, mode: 0o700 });
      await fs.chmod(dir, 0o700);
      await fs.rm(config.socketPath, { force: true });
      control = await buildApp(service, config, auth, true);
      await control.listen({ path: config.socketPath });
      await fs.chmod(config.socketPath, 0o600);
    }
    await web.listen({ host: config.host, port: config.port });
  } catch (error) {
    await Promise.allSettled([web.close(), control?.close()]);
    await service.close().catch(() => undefined);
    await unlock();
    throw error;
  }
  let stopping = false;
  const stop = async () => {
    if (stopping) return; stopping = true;
    const timer = setTimeout(() => process.exit(1), 20_000).unref();
    try {
      await Promise.all([web.close(), control?.close()]);
      await service!.close();
      if (control) await fs.rm(config.socketPath, { force: true });
      await unlock();
      clearTimeout(timer); process.exit(0);
    } catch (error) { console.error(error); process.exit(1); }
  };
  process.on('SIGTERM', () => void stop());
  process.on('SIGINT', () => void stop());
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  start().catch(error => { console.error((error as Error).message); process.exitCode = 1; });
}
