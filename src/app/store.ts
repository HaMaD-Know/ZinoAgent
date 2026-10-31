import { create } from 'zustand';
import type { ModelRef, Studio } from '@/types';
import { DEFAULT_SETTINGS, saveSettings, type AppSettings } from '@/services/settings';
import { configureResources } from '@/services/resources';

export type Section = 'agent' | 'images' | 'threed' | 'video' | 'models' | 'assets' | 'settings';

interface AppState {
  ready: boolean;
  native: boolean;
  section: Section;
  settings: AppSettings;
  online: boolean;
  /** Navigation hints (e.g. open a chat from the asset library). */
  pendingChatId: string | null;
  pendingAssetId: string | null;
  settingsTab: string | null;
  setSection(s: Section): void;
  updateSettings(fn: (s: AppSettings) => AppSettings): Promise<void>;
  setStudioModel(studio: Studio, ref: ModelRef | null): Promise<void>;
  openChat(chatId: string): void;
  openAsset(assetId: string): void;
  openSettings(tab?: string): void;
}

export const useApp = create<AppState>((set, get) => ({
  ready: false,
  native: false,
  section: 'agent',
  settings: DEFAULT_SETTINGS,
  online: typeof navigator === 'undefined' ? true : navigator.onLine,
  pendingChatId: null,
  pendingAssetId: null,
  settingsTab: null,
  setSection: (section) => set({ section }),
  async updateSettings(fn) {
    const next = fn(get().settings);
    set({ settings: next });
    configureResources(next.resources);
    await saveSettings(next);
  },
  async setStudioModel(studio, ref) {
    await get().updateSettings((s) => ({ ...s, studioModels: { ...s.studioModels, [studio]: ref } }));
  },
  openChat: (chatId) => set({ section: 'agent', pendingChatId: chatId }),
  openAsset: (assetId) => set({ section: 'assets', pendingAssetId: assetId }),
  openSettings: (tab) => set({ section: 'settings', settingsTab: tab ?? null }),
}));

if (typeof window !== 'undefined') {
  window.addEventListener('online', () => useApp.setState({ online: true }));
  window.addEventListener('offline', () => useApp.setState({ online: false }));
}
