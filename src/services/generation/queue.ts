// Persistent generation queue for image / 3D / video tasks.
//  * Local (on-device) tasks are heavy: they run one at a time and wait while the device is hot.
//  * Cloud tasks run concurrently (max 3) and keep their provider job id, so polling resumes after
//    the app restarts.
import { create } from 'zustand';
import type { GenerationTask, ModelRef, TaskKind } from '@/types';
import { tasksRepo, uid } from '@/database/repositories';
import { ZinoError, toZinoError } from '@/services/errors';
import { useResources } from '@/services/resources';
import { uiBridge } from '@/services/ui-bridge';

export interface TaskContext {
  task: GenerationTask;
  signal: AbortSignal;
  progress(p: number, label?: string, externalId?: string): void;
}

export type TaskRunner = (ctx: TaskContext) => Promise<string[]>; // returns asset ids

interface QueueState { tasks: GenerationTask[] }
export const useTasks = create<QueueState>(() => ({ tasks: [] }));

const runners = new Map<TaskKind, (task: GenerationTask) => TaskRunner>();
const controllers = new Map<string, AbortController>();
const pending: { task: GenerationTask; run: TaskRunner }[] = [];
let localBusy = false;
let cloudRunning = 0;

/** Each studio registers how to (re)build a runner from a stored task (used for resume). */
export function registerRunner(kind: TaskKind, factory: (task: GenerationTask) => TaskRunner) { runners.set(kind, factory); }

async function save(task: GenerationTask) {
  task.updatedAt = Date.now();
  await tasksRepo.save(task);
  useTasks.setState((s) => {
    const others = s.tasks.filter((t) => t.id !== task.id);
    return { tasks: [{ ...task }, ...others].sort((a, b) => b.createdAt - a.createdAt).slice(0, 300) };
  });
}

export async function loadTasks() { useTasks.setState({ tasks: await tasksRepo.list(undefined, 300) }); }

const isLocal = (ref: ModelRef) => ref.source === 'local';

function pump() {
  for (let i = 0; i < pending.length; i++) {
    const item = pending[i];
    const local = isLocal(item.task.modelRef);
    if (local && (localBusy || useResources.getState().paused)) continue;
    if (!local && cloudRunning >= 3) continue;
    pending.splice(i, 1); i--;
    void execute(item.task, item.run);
  }
}
// Re-check periodically (e.g. when the device cools down).
setInterval(pump, 3000);

async function execute(task: GenerationTask, run: TaskRunner) {
  const local = isLocal(task.modelRef);
  if (local) localBusy = true; else cloudRunning++;
  const ctrl = controllers.get(task.id) ?? new AbortController();
  controllers.set(task.id, ctrl);
  task.status = 'running';
  task.progressLabel = 'Starting';
  await save(task);
  let lastSaved = 0;
  try {
    const assetIds = await run({
      task, signal: ctrl.signal,
      progress: (p, label, externalId) => {
        task.progress = Math.max(0, Math.min(1, p));
        if (label) task.progressLabel = label;
        if (externalId) task.externalId = externalId;
        useTasks.setState((s) => ({ tasks: s.tasks.map((t) => (t.id === task.id ? { ...task } : t)) }));
        if (externalId || Date.now() - lastSaved > 2000) { lastSaved = Date.now(); void tasksRepo.save({ ...task, updatedAt: Date.now() }); }
      },
    });
    task.status = 'succeeded';
    task.progress = 1;
    task.progressLabel = 'Done';
    task.resultAssetIds = assetIds;
    task.error = null;
  } catch (e) {
    const err = toZinoError(e);
    task.status = err.code === 'CANCELLED' ? 'cancelled' : 'failed';
    task.error = err.code === 'CANCELLED' ? null : err.message;
    task.progressLabel = null;
    if (task.status === 'failed') uiBridge.toast('error', `${task.kind === 'threed' ? '3D' : task.kind === 'image' ? 'Image' : 'Video'} generation failed: ${err.message}`);
  } finally {
    controllers.delete(task.id);
    if (local) localBusy = false; else cloudRunning--;
    await save(task);
    pump();
  }
}

export async function enqueue(input: { kind: TaskKind; modelRef: ModelRef; params: Record<string, unknown>; chatId?: string | null }, run?: TaskRunner): Promise<GenerationTask> {
  const task: GenerationTask = {
    id: uid(), kind: input.kind, status: 'queued', modelRef: input.modelRef, params: input.params, progress: 0, progressLabel: 'Queued',
    error: null, resultAssetIds: [], chatId: input.chatId ?? null, externalId: null, createdAt: Date.now(), updatedAt: Date.now(),
  };
  const runner = run ?? runners.get(input.kind)?.(task);
  if (!runner) throw new ZinoError('INVALID_ARGUMENT', `No runner registered for ${input.kind}.`);
  await save(task);
  if (isLocal(task.modelRef) && (localBusy || useResources.getState().paused)) {
    task.progressLabel = useResources.getState().paused ? 'Waiting — device is hot' : 'Waiting for the current on-device task';
    await save(task);
  }
  pending.push({ task, run: runner });
  pump();
  return task;
}

export async function cancelTask(id: string) {
  const idx = pending.findIndex((p) => p.task.id === id);
  if (idx >= 0) {
    const [item] = pending.splice(idx, 1);
    item.task.status = 'cancelled';
    item.task.progressLabel = null;
    await save(item.task);
    return;
  }
  controllers.get(id)?.abort();
}

export async function removeTask(id: string) {
  await tasksRepo.remove(id);
  useTasks.setState((s) => ({ tasks: s.tasks.filter((t) => t.id !== id) }));
}

/** After a restart, resume polling for cloud jobs that were submitted but not finished. */
export async function resumeCloudTasks() {
  const tasks = await tasksRepo.list(undefined, 300);
  for (const t of tasks) {
    if (t.status !== 'running' || t.modelRef.source !== 'cloud' || !t.externalId) continue;
    const factory = runners.get(t.kind);
    if (!factory) continue;
    t.progressLabel = 'Resuming after restart';
    pending.push({ task: t, run: factory({ ...t, params: { ...t.params, resumeExternalId: t.externalId } }) });
  }
  pump();
}
