import initSqlJs from 'sql.js';
import { SqlJsDriver } from '@/database/driver';
import { migrate, setDb } from '@/database';

/** Fresh in-memory SQLite (sql.js) with all migrations applied, installed as the app DB. */
export async function freshDb() {
  const SQL = await initSqlJs();
  const driver = await SqlJsDriver.create(SQL);
  await migrate(driver);
  setDb(driver);
  return driver;
}
