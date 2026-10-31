// Database driver abstraction: native SQLite on iPad, sql.js (WASM) in the browser and tests.
import type { Database as SqlJsDatabase, SqlJsStatic } from 'sql.js';
import { ZinoError } from '@/services/errors';

export type SqlValue = string | number | null;
export interface Statement { sql: string; values?: SqlValue[] }

export interface DbDriver {
  readonly kind: 'native' | 'sqljs';
  execute(sql: string): Promise<void>;
  run(sql: string, values?: SqlValue[]): Promise<{ changes: number; lastId: number }>;
  query<T = Record<string, unknown>>(sql: string, values?: SqlValue[]): Promise<T[]>;
  batch(statements: Statement[]): Promise<void>;
  close(): Promise<void>;
}

const wrap = (e: unknown): never => {
  if (e instanceof ZinoError) throw e;
  const msg = e instanceof Error ? e.message : String(e);
  throw new ZinoError('DATABASE_ERROR', `Database error: ${msg}`, { cause: e });
};

export class NativeDriver implements DbDriver {
  readonly kind = 'native' as const;
  private constructor(private readonly plugin: import('@/native/definitions').ZinoDatabasePlugin) {}

  static async open(name = 'zino'): Promise<NativeDriver> {
    const { ZinoDatabase } = await import('@/native');
    await ZinoDatabase.open({ name }).catch(wrap);
    return new NativeDriver(ZinoDatabase);
  }
  async execute(sql: string) { await this.plugin.execute({ sql }).catch(wrap); }
  async run(sql: string, values: SqlValue[] = []) { return this.plugin.run({ sql, values }).catch(wrap); }
  async query<T>(sql: string, values: SqlValue[] = []) {
    const r = await this.plugin.query({ sql, values }).catch(wrap);
    return r.rows as T[];
  }
  async batch(statements: Statement[]) {
    await this.plugin.batch({ statements: statements.map((s) => ({ sql: s.sql, values: s.values ?? [] })) }).catch(wrap);
  }
  async close() { await this.plugin.close(); }
}

/** sql.js driver. `persist` is called (debounced) after writes; the web build saves to IndexedDB. */
export class SqlJsDriver implements DbDriver {
  readonly kind = 'sqljs' as const;
  private timer: ReturnType<typeof setTimeout> | null = null;

  constructor(private readonly db: SqlJsDatabase, private readonly persist?: (data: Uint8Array) => Promise<void>) {
    db.run('PRAGMA foreign_keys=ON;');
  }

  static async create(SQL: SqlJsStatic, data?: Uint8Array | null, persist?: (data: Uint8Array) => Promise<void>) {
    return new SqlJsDriver(data ? new SQL.Database(data) : new SQL.Database(), persist);
  }

  private schedulePersist() {
    if (!this.persist) return;
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => { void this.flush(); }, 250);
  }
  async flush() {
    if (!this.persist) return;
    if (this.timer) { clearTimeout(this.timer); this.timer = null; }
    await this.persist(this.db.export());
  }
  async execute(sql: string) {
    try { this.db.exec(sql); } catch (e) { wrap(e); }
    this.schedulePersist();
  }
  async run(sql: string, values: SqlValue[] = []) {
    try {
      this.db.run(sql, values);
      const changes = this.db.getRowsModified();
      const last = this.db.exec('SELECT last_insert_rowid() AS id');
      this.schedulePersist();
      return { changes, lastId: Number(last[0]?.values[0]?.[0] ?? 0) };
    } catch (e) { return wrap(e); }
  }
  async query<T>(sql: string, values: SqlValue[] = []) {
    try {
      const stmt = this.db.prepare(sql);
      stmt.bind(values);
      const rows: T[] = [];
      while (stmt.step()) rows.push(stmt.getAsObject() as T);
      stmt.free();
      return rows;
    } catch (e) { return wrap(e); }
  }
  async batch(statements: Statement[]) {
    try {
      this.db.run('BEGIN');
      try {
        for (const s of statements) this.db.run(s.sql, s.values ?? []);
        this.db.run('COMMIT');
      } catch (e) {
        this.db.run('ROLLBACK');
        throw e;
      }
    } catch (e) { wrap(e); }
    this.schedulePersist();
  }
  async close() { await this.flush(); this.db.close(); }
}

/** Browser driver persisted in IndexedDB. */
export async function openWebDriver(): Promise<SqlJsDriver> {
  const [{ default: initSqlJs }, { default: wasmUrl }, { webKV }] = await Promise.all([
    import('sql.js'),
    import('sql.js/dist/sql-wasm.wasm?url'),
    import('@/native/web'),
  ]);
  const SQL = await initSqlJs({ locateFile: () => wasmUrl });
  const saved = await webKV.get<Uint8Array>('sqlite');
  const driver = await SqlJsDriver.create(SQL, saved ?? null, (data) => webKV.set('sqlite', data).then(() => undefined));
  window.addEventListener('pagehide', () => { void driver.flush(); });
  return driver;
}
