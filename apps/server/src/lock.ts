import fs from 'node:fs/promises';
import path from 'node:path';
import { token } from './model.js';

// An accidental second process must not replace the live process's socket/table.
export async function acquireLock(dir: string): Promise<() => Promise<void>> {
  await fs.mkdir(dir, { recursive: true, mode: 0o700 });
  const filename = path.join(dir, 'server.lock');
  const id = token();
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const handle = await fs.open(filename, 'wx', 0o600);
      try { await handle.writeFile(JSON.stringify({ pid: process.pid, token: id })); } finally { await handle.close(); }
      return async () => {
        const lock = JSON.parse(await fs.readFile(filename, 'utf8')) as { token: string };
        if (lock.token === id) await fs.rm(filename, { force: true });
      };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error;
      let pid: number;
      try { pid = (JSON.parse(await fs.readFile(filename, 'utf8')) as { pid: number }).pid; }
      catch { throw new Error('锁文件无法读取，请确认没有其他 FastProxy 进程后检查 server.lock'); }
      if (!Number.isSafeInteger(pid) || pid < 1) throw new Error('锁文件 PID 无效，请检查 server.lock');
      try { process.kill(pid, 0); }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ESRCH') { await fs.rm(filename, { force: true }); continue; }
        throw error;
      }
      throw new Error(`FastProxy 已在运行（PID ${pid}），请使用 fastproxy restart`);
    }
  }
  throw new Error('无法获取服务锁');
}
