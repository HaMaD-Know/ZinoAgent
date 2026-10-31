// ResourceManager (JS side): live device telemetry + the heavy-model coordinator.
// Policy: one heavy model (llama.cpp or Core ML diffusion) loaded at a time by default, idle models
// are unloaded, memory warnings unload idle models, and serious thermal state pauses queued work.
import { create } from 'zustand';
import { ZinoDiffusion, ZinoLlama, ZinoResources, type ResourceSnapshot } from '@/native';
import { uiBridge } from '@/services/ui-bridge';

export type HeavyKind = 'llama' | 'diffusion';

export interface LoadedModel {
  kind: HeavyKind;
  modelId: string;
  name: string;
  path: string;
  loadedAt: number;
  lastUsed: number;
  busy: boolean;
  contextLength?: number;
  estimatedBytes?: number;
  loadMs?: number;
}

interface ResourceState {
  snapshot: ResourceSnapshot | null;
  loaded: LoadedModel[];
  loading: { kind: HeavyKind; name: string; progress: number } | null;
  pressure: 'normal' | 'warning' | 'critical';
  paused: boolean;
  pauseReason: string | null;
  history: { t: number; footprint: number; available: number }[];
}

export const useResources = create<ResourceState>(() => ({
  snapshot: null, loaded: [], loading: null, pressure: 'normal', paused: false, pauseReason: null, history: [],
}));

let settingsRef = { singleHeavyModel: true, idleUnloadMinutes: 10, pauseHeavyTasksAt: 'serious' as 'serious' | 'critical' | 'never', warnBeforeHighMemory: true };
export function configureResources(s: typeof settingsRef) { settingsRef = s; }

export async function refreshSnapshot(): Promise<ResourceSnapshot | null> {
  try {
    const s = await ZinoResources.snapshot();
    useResources.setState((st) => ({
      snapshot: s,
      history: [...st.history.slice(-119), { t: s.timestamp, footprint: s.appFootprint, available: s.availableMemory }],
    }));
    applyThermal(s.thermalState);
    return s;
  } catch { return null; }
}

function applyThermal(state: ResourceSnapshot['thermalState']) {
  const limit = settingsRef.pauseHeavyTasksAt;
  const hot = (limit === 'serious' && (state === 'serious' || state === 'critical')) || (limit === 'critical' && state === 'critical');
  const st = useResources.getState();
  if (hot && !st.paused) {
    useResources.setState({ paused: true, pauseReason: `Device is ${state === 'critical' ? 'critically hot' : 'hot'}; queued heavy tasks are paused.` });
    uiBridge.toast('warning', 'iPad is running hot. New heavy generation tasks are paused until it cools down.');
  } else if (!hot && st.paused && st.pauseReason?.startsWith('Device')) {
    useResources.setState({ paused: false, pauseReason: null });
    uiBridge.toast('info', 'Device temperature is back to normal. Queued tasks resume.');
  }
}

let started = false;
export async function startResourceMonitoring() {
  if (started) return;
  started = true;
  await refreshSnapshot();
  setInterval(() => { void refreshSnapshot(); void unloadIdle(); }, 5000);
  await ZinoResources.addListener('memoryWarning', (s) => {
    useResources.setState({ snapshot: s, pressure: 'warning' });
    void unloadIdle(true).then((n) => uiBridge.toast('warning', n ? `iPadOS reported low memory. Unloaded ${n} idle model(s).` : 'iPadOS reported low memory.'));
  }).catch(() => {});
  await ZinoResources.addListener('memoryPressure', (e) => {
    useResources.setState({ pressure: e.level });
    if (e.level === 'critical') void unloadIdle(true);
  }).catch(() => {});
  await ZinoResources.addListener('thermalChange', (e) => applyThermal(e.thermalState)).catch(() => {});
}

// --- Heavy model coordination --------------------------------------------------------------------

async function unloadNative(kind: HeavyKind) {
  if (kind === 'llama') await ZinoLlama.unload();
  else await ZinoDiffusion.unload();
}

export async function unloadModel(kind: HeavyKind, opts: { force?: boolean } = {}) {
  const m = useResources.getState().loaded.find((x) => x.kind === kind);
  if (!m) return;
  if (m.busy && !opts.force) {
    const ok = await uiBridge.confirm({ title: 'Model is busy', message: `${m.name} is generating right now. Unloading it will cancel that generation.`, confirmLabel: 'Cancel generation and unload', destructive: true });
    if (!ok) return;
  }
  await unloadNative(kind);
  useResources.setState((s) => ({ loaded: s.loaded.filter((x) => x.kind !== kind) }));
  void refreshSnapshot();
}

/** Unload idle heavy models. With `aggressive`, any non-busy model is unloaded. Returns count. */
export async function unloadIdle(aggressive = false): Promise<number> {
  const now = Date.now();
  const limit = settingsRef.idleUnloadMinutes * 60_000;
  let n = 0;
  for (const m of useResources.getState().loaded) {
    if (m.busy) continue;
    if (aggressive || (limit > 0 && now - m.lastUsed > limit)) {
      await unloadNative(m.kind).catch(() => {});
      useResources.setState((s) => ({ loaded: s.loaded.filter((x) => x.kind !== m.kind) }));
      n++;
    }
  }
  return n;
}

export function markUsed(kind: HeavyKind, busy: boolean) {
  useResources.setState((s) => ({ loaded: s.loaded.map((m) => (m.kind === kind ? { ...m, busy, lastUsed: Date.now() } : m)) }));
}

export function loadedModel(kind: HeavyKind) { return useResources.getState().loaded.find((m) => m.kind === kind) ?? null; }

/**
 * Make room for a heavy model: enforces the one-heavy-model policy and warns (never silently)
 * when the estimated memory exceeds what iPadOS currently allows. Returns false if the user declined.
 */
export async function prepareForHeavyLoad(target: { kind: HeavyKind; name: string; estimatedBytes?: number }): Promise<boolean> {
  const others = useResources.getState().loaded.filter((m) => m.kind !== target.kind);
  if (settingsRef.singleHeavyModel && others.length) {
    const busy = others.filter((m) => m.busy);
    if (busy.length) {
      const ok = await uiBridge.confirm({
        title: 'Another model is busy',
        message: `Loading ${target.name} requires unloading ${busy.map((b) => b.name).join(', ')}, which will cancel its current generation.`,
        confirmLabel: 'Cancel it and continue', destructive: true,
      });
      if (!ok) return false;
    }
    for (const m of others) await unloadModel(m.kind, { force: true });
    uiBridge.toast('info', `Unloaded ${others.map((o) => o.name).join(', ')} to free memory for ${target.name}.`);
  }
  if (target.estimatedBytes && settingsRef.warnBeforeHighMemory) {
    const snap = await refreshSnapshot();
    if (snap && snap.availableMemory > 0 && !snap.estimated) {
      const currentKind = loadedModel(target.kind);
      const reclaim = currentKind?.estimatedBytes ?? 0;
      const free = snap.availableMemory + reclaim;
      if (target.estimatedBytes > free * 0.9) {
        const gb = (b: number) => (b / 1024 ** 3).toFixed(1);
        const ok = await uiBridge.confirm({
          title: 'This may exceed available memory',
          message: `${target.name} needs about ${gb(target.estimatedBytes)} GB, but iPadOS currently allows ZinoAgent about ${gb(free)} GB more. Loading may fail or the app may be closed by the system.`,
          details: ['Try a smaller context length or a smaller quantisation.', 'Closing other apps can free memory.'],
          confirmLabel: 'Load anyway', destructive: true,
        });
        if (!ok) return false;
      }
    }
  }
  return true;
}

export function registerLoaded(m: Omit<LoadedModel, 'loadedAt' | 'lastUsed' | 'busy'>) {
  useResources.setState((s) => ({
    loaded: [...s.loaded.filter((x) => x.kind !== m.kind), { ...m, loadedAt: Date.now(), lastUsed: Date.now(), busy: false }],
    loading: null,
  }));
  void refreshSnapshot();
}

export function setLoading(l: ResourceState['loading']) { useResources.setState({ loading: l }); }

export const formatBytes = (b: number | null | undefined) => {
  if (b === null || b === undefined || b < 0 || Number.isNaN(b)) return '—';
  if (b < 1024) return `${b} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let v = b / 1024; let i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(v >= 100 ? 0 : v >= 10 ? 1 : 2)} ${units[i]}`;
};
