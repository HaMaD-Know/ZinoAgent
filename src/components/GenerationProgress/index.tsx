import { RotateCcw, Square, Trash2 } from 'lucide-react';
import type { GenerationTask } from '@/types';
import { cancelTask, removeTask } from '@/services/generation/queue';
import { Progress, Spinner } from '../ui';

export function TaskRow({ task, onRetry, onOpen }: { task: GenerationTask; onRetry?: (t: GenerationTask) => void; onOpen?: (t: GenerationTask) => void }) {
  const active = task.status === 'queued' || task.status === 'running';
  const p = task.params as { prompt?: string; modelLabel?: string };
  return (
    <div className="card stack-sm" style={{ padding: 10, cursor: onOpen && task.status === 'succeeded' ? 'pointer' : undefined }} onClick={() => task.status === 'succeeded' && onOpen?.(task)}>
      <div className="row">
        {active && <Spinner />}
        <div className="grow" style={{ minWidth: 0 }}>
          <div className="truncate small"><strong>{p.prompt || 'Untitled'}</strong></div>
          <div className="tiny faint truncate">{p.modelLabel ?? (task.modelRef.source === 'local' ? 'On device' : 'Cloud')} · {new Date(task.createdAt).toLocaleTimeString()}</div>
        </div>
        {active && <button className="icon-btn sm" title="Cancel" onClick={(e) => { e.stopPropagation(); void cancelTask(task.id); }}><Square size={14} /></button>}
        {!active && onRetry && task.status !== 'succeeded' && <button className="icon-btn sm" title="Retry" onClick={(e) => { e.stopPropagation(); onRetry(task); }}><RotateCcw size={14} /></button>}
        {!active && <button className="icon-btn sm" title="Remove from history (assets are kept)" onClick={(e) => { e.stopPropagation(); void removeTask(task.id); }}><Trash2 size={14} /></button>}
      </div>
      {active && <><Progress value={task.progress} /><div className="tiny muted">{task.progressLabel}</div></>}
      {task.status === 'failed' && <div className="tiny" style={{ color: 'var(--danger)' }}>{task.error}</div>}
      {task.status === 'cancelled' && <div className="tiny muted">Cancelled</div>}
      {task.status === 'interrupted' && <div className="tiny" style={{ color: 'var(--warning)' }}>{task.error ?? 'Interrupted'}</div>}
    </div>
  );
}
