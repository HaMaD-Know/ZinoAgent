import { ChevronDown, Gauge } from 'lucide-react';
import type { EffortLevel } from '@/types';
import { EFFORT_LEVELS } from '@/types';
import type { EffortPlan } from '@/services/ai-router/effort';
import { Popover } from '../ui';

export const EFFORT_LABEL: Record<EffortLevel, string> = {
  minimal: 'Minimal', low: 'Low', medium: 'Medium', high: 'High', maximum: 'Maximum', auto: 'Auto',
};
const EFFORT_HINT: Record<EffortLevel, string> = {
  minimal: 'Fastest, shortest answers.', low: 'Quick answers with light reasoning.', medium: 'Balanced (default).',
  high: 'More reasoning, longer answers, deeper history retrieval and summary cross-checks.',
  maximum: 'Largest budgets the selected model supports. Slower and costs more on paid APIs.', auto: 'Chooses Low/Medium/High from the task.',
};

/** Effort picker. `plan` (when known) shows what the level actually changes for the selected model. */
export function EffortSelector({ value, onChange, plan, disabled, label = 'Effort' }: {
  value: EffortLevel; onChange: (e: EffortLevel) => void; plan?: EffortPlan | null; disabled?: boolean; label?: string;
}) {
  return (
    <Popover width={340} trigger={(toggle) => (
      <button className="btn" onClick={toggle} disabled={disabled} title="Effort level">
        <Gauge size={16} /> <span className="small">{label}: {EFFORT_LABEL[value]}{value === 'auto' && plan ? ` → ${EFFORT_LABEL[plan.level]}` : ''}</span> <ChevronDown size={14} />
      </button>
    )}>
      {(close) => (
        <div className="stack-sm">
          {EFFORT_LEVELS.map((e) => (
            <button key={e} className="menu-item" style={{ alignItems: 'flex-start', background: e === value ? 'var(--accent-weak)' : undefined }}
              onClick={() => { onChange(e); close(); }}>
              <div className="stack-sm" style={{ gap: 0 }}><strong>{EFFORT_LABEL[e]}</strong><span className="tiny muted">{EFFORT_HINT[e]}</span></div>
            </button>
          ))}
          {plan && (
            <div className="notice" style={{ flexDirection: 'column', gap: 4, margin: 4 }}>
              <strong className="small">For the selected model ({EFFORT_LABEL[plan.level]}{plan.autoReason ? ` — ${plan.autoReason}` : ''}):</strong>
              {plan.applied.map((a, i) => <div key={i} className="tiny">✓ {a}</div>)}
              {plan.notApplied.map((a, i) => <div key={`n${i}`} className="tiny" style={{ color: 'var(--warning)' }}>• {a}</div>)}
            </div>
          )}
        </div>
      )}
    </Popover>
  );
}
