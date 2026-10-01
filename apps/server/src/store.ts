import { constants, type FileHandle } from 'node:fs/promises';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { initialState, type State } from './model.js';

export async function atomicWrite(filename: string, value: string): Promise<void> {
  const temp = path.join(path.dirname(filename), `.fastproxy-${randomBytes(8).toString('hex')}`);
  let file: FileHandle | undefined;
  try {
    file = await fs.open(temp, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY, 0o600);
    await file.writeFile(value, 'utf8');
    await file.sync();
    await file.close(); file = undefined;
    await fs.rename(temp, filename);
    // Windows cannot open a directory for fsync. Linux can and should.
    if (process.platform === 'linux') {
      const dir = await fs.open(path.dirname(filename), constants.O_RDONLY);
      try { await dir.sync(); } finally { await dir.close(); }
    }
  } finally {
    await file?.close();
    await fs.rm(temp, { force: true });
  }
}

export class Store {
  constructor(public dir: string) {}
  async load(): Promise<State> {
    await fs.mkdir(this.dir, { recursive: true, mode: 0o700 });
    try {
      return JSON.parse(await fs.readFile(path.join(this.dir, 'state.json'), 'utf8')) as State;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return initialState();
      throw new Error('规则文件无法读取，已保留原文件，请检查 state.json', { cause: error });
    }
  }
  async save(state: State): Promise<void> { await atomicWrite(path.join(this.dir, 'state.json'), JSON.stringify(state, null, 2) + '\n'); }
  async audit(actor: string, action: string): Promise<void> {
    await fs.appendFile(path.join(this.dir, 'audit.jsonl'), JSON.stringify({ time: new Date().toISOString(), actor, action }) + '\n', { mode: 0o600 });
  }
}
