// Registers the ZinoNative plugins. On iPad these resolve to the Swift implementations;
// in a desktop browser they fall back to the web implementations in ./web.ts.
import { Capacitor, registerPlugin } from '@capacitor/core';
import type {
  ZinoCoreMLPlugin, ZinoDatabasePlugin, ZinoDiffusionPlugin, ZinoDownloadsPlugin, ZinoFilesPlugin,
  ZinoHttpPlugin, ZinoKeychainPlugin, ZinoLlamaPlugin, ZinoResourcesPlugin, ZinoStoragePlugin,
} from './definitions';

export * from './definitions';

export const isNative = () => Capacitor.isNativePlatform();

export const ZinoDatabase = registerPlugin<ZinoDatabasePlugin>('ZinoDatabase');
export const ZinoKeychain = registerPlugin<ZinoKeychainPlugin>('ZinoKeychain', {
  web: () => import('./web').then((m) => new m.ZinoKeychainWeb()),
});
export const ZinoHttp = registerPlugin<ZinoHttpPlugin>('ZinoHttp', {
  web: () => import('./web').then((m) => new m.ZinoHttpWeb()),
});
export const ZinoFiles = registerPlugin<ZinoFilesPlugin>('ZinoFiles', {
  web: () => import('./web').then((m) => new m.ZinoFilesWeb()),
});
export const ZinoStorage = registerPlugin<ZinoStoragePlugin>('ZinoStorage', {
  web: () => import('./web').then((m) => new m.ZinoStorageWeb()),
});
export const ZinoLlama = registerPlugin<ZinoLlamaPlugin>('ZinoLlama', {
  web: () => import('./web').then((m) => new m.NativeOnlyWeb('Offline GGUF chat (llama.cpp)')),
});
export const ZinoDiffusion = registerPlugin<ZinoDiffusionPlugin>('ZinoDiffusion', {
  web: () => import('./web').then((m) => new m.NativeOnlyWeb('Offline image generation (Core ML)')),
});
export const ZinoDownloads = registerPlugin<ZinoDownloadsPlugin>('ZinoDownloads', {
  web: () => import('./web').then((m) => new m.NativeOnlyWeb('Model downloads')),
});
export const ZinoResources = registerPlugin<ZinoResourcesPlugin>('ZinoResources', {
  web: () => import('./web').then((m) => new m.ZinoResourcesWeb()),
});
export const ZinoCoreML = registerPlugin<ZinoCoreMLPlugin>('ZinoCoreML', {
  web: () => import('./web').then((m) => new m.NativeOnlyWeb('Core ML model inspection')),
});

/** URL usable in <img>/<video>/Three.js loaders for an app-storage path. */
export async function displayUrl(appPath: string): Promise<string> {
  const { url } = await ZinoStorage.fileUrl({ path: appPath });
  return isNative() ? Capacitor.convertFileSrc(url) : url;
}
