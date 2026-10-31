import { isNative } from '@/native';
import { migrate, recoverAfterRestart, setDb, NativeDriver, openWebDriver, type DbDriver } from '@/database';
import { loadSettings, type AppSettings } from '@/services/settings';
import { configureResources, startResourceMonitoring } from '@/services/resources';
import { initDownloads } from '@/services/download-manager';
import { loadTasks, resumeCloudTasks } from '@/services/generation';
import { toZinoError } from '@/services/errors';

export interface BootResult { settings: AppSettings; driver: DbDriver; native: boolean; migrations: number[] }

export async function bootstrap(): Promise<BootResult> {
  const native = isNative();
  let driver: DbDriver;
  try {
    driver = native ? await NativeDriver.open('zino') : await openWebDriver();
  } catch (e) {
    throw toZinoError(e, 'DATABASE_ERROR');
  }
  const migrations = await migrate(driver);
  setDb(driver);
  await recoverAfterRestart(driver);
  const settings = await loadSettings();
  configureResources(settings.resources);
  await startResourceMonitoring();
  await initDownloads().catch(() => {});
  await loadTasks();
  await resumeCloudTasks().catch(() => {});
  return { settings, driver, native, migrations };
}
