import type { DbDriver } from './driver';
import { MIGRATIONS } from './migrations';

let current: DbDriver | null = null;

export function db(): DbDriver {
  if (!current) throw new Error('Database not initialised');
  return current;
}

export function setDb(driver: DbDriver) {
  current = driver;
}

export async function migrate(driver: DbDriver): Promise<number[]> {
  await driver.execute('CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at INTEGER NOT NULL);');
  const rows = await driver.query<{ version: number }>('SELECT version FROM schema_migrations');
  const applied = new Set(rows.map((r) => Number(r.version)));
  const ran: number[] = [];
  for (const m of [...MIGRATIONS].sort((a, b) => a.version - b.version)) {
    if (applied.has(m.version)) continue;
    await driver.execute(`BEGIN;\n${m.sql}\nINSERT INTO schema_migrations (version, name, applied_at) VALUES (${m.version}, '${m.name.replace(/'/g, "''")}', ${Date.now()});\nCOMMIT;`);
    ran.push(m.version);
  }
  return ran;
}

/**
 * Safe recovery after the app was terminated (iPadOS can kill the app under memory pressure):
 * half-written messages are marked interrupted, local generation tasks are marked interrupted,
 * cloud tasks keep their external id so polling resumes, downloads become resumable/paused.
 */
export async function recoverAfterRestart(driver: DbDriver) {
  const now = Date.now();
  await driver.batch([
    { sql: "UPDATE messages SET status='error', meta=json_set(meta, '$.interrupted', 1) WHERE status='streaming'" },
    { sql: "UPDATE generation_tasks SET status='interrupted', error='The app was closed before this finished.', updated_at=? WHERE status IN ('running','queued') AND (external_id IS NULL OR json_extract(model_ref, '$.source')='local')", values: [now] },
    { sql: "UPDATE downloads SET status='paused', updated_at=? WHERE status IN ('downloading','queued','verifying')", values: [now] },
  ]);
}

export * from './driver';
