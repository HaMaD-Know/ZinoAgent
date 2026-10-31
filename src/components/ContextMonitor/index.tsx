// Context dashboard: capacity, usage, remaining, and a breakdown by source. Shows whether the
// counts are exact (llama.cpp tokenizer) or estimated (cloud models).
import { Layers } from 'lucide-react';
import type { ContextReport } from '@/services/context-engine';
import { Popover } from '../ui';

const PARTS: { key: keyof ContextReport; label: string; color: string }[] = [
  { key: 'systemTokens', label: 'System instructions', color: '#8e8e96' },
  { key: 'memoryTokens', label: 'Long-term memory', color: '#a855f7' },
  { key: 'summaryTokens', label: 'Summaries', color: '#0ea5e9' },
  { key: 'retrievedTokens', label: 'Retrieved history', color: '#14b8a6' },
  { key: 'recentTokens', label: 'Recent messages', color: '#0a6cff' },
  { key: 'toolTokens', label: 'Tool results', color: '#f59e0b' },
];

export function ContextBreakdown({ report, onCompact }: { report: ContextReport; onCompact?: () => void }) {
  const usable = report.usable || 1;
  return (
    <div className="stack">
      <div className="row">
        <div className="stat grow"><span className="value">{report.total.toLocaleString()}</span><span className="label">of {report.usable.toLocaleString()} usable tokens ({Math.round(report.percent * 100)}%)</span></div>
        <span className={`badge ${report.exact ? 'success' : 'warning'}`}>{report.exact ? 'Exact (model tokenizer)' : 'Estimated'}</span>
      </div>
      <div className="stack-bar">
        {PARTS.map((p) => <div key={p.key} style={{ width: `${((report[p.key] as number) / usable) * 100}%`, background: p.color }} title={p.label} />)}
      </div>
      <div className="legend">{PARTS.map((p) => <span key={p.key}><i style={{ background: p.color }} />{p.label}: {(report[p.key] as number).toLocaleString()}</span>)}</div>
      <dl className="kv">
        <dt>Model context</dt><dd>{report.capacity.toLocaleString()} tokens</dd>
        <dt>Reserved for reply</dt><dd>{report.reservedOutput.toLocaleString()} tokens</dd>
        <dt>Remaining</dt><dd>{report.remaining.toLocaleString()} tokens</dd>
        <dt>Summaries</dt><dd>{report.summaryCount} ({report.summarisedMessageCount} original messages kept on device)</dd>
        {report.preservedRawBatches > 0 && <><dt>Kept verbatim</dt><dd>{report.preservedRawBatches} batch(es) failed summary verification</dd></>}
        <dt>Last query</dt><dd>{report.queryType === 'complex' ? `Complex — retrieved ${report.retrievedBatchIds.length} original batch(es)` : 'Simple — summaries + recent messages'}</dd>
        <dt>Tokenizer</dt><dd className="mono tiny">{report.tokenizer}</dd>
      </dl>
      {report.compaction && (
        <div className="notice info small">Compacted {report.compaction.batches} batch(es): {report.compaction.before.toLocaleString()} → {report.compaction.after.toLocaleString()} tokens.
          {report.compaction.failedVerification > 0 && ` ${report.compaction.failedVerification} summary(ies) failed verification; originals stayed in context.`}</div>
      )}
      {report.warnings.map((w, i) => <div key={i} className="notice warning small">{w}</div>)}
      <p className="tiny faint">Summaries make better use of the window; they do not increase the model's native context limit.</p>
      {onCompact && <button className="btn sm" onClick={onCompact}>Compact now</button>}
    </div>
  );
}

export function ContextMonitor({ report, onCompact }: { report: ContextReport | null; onCompact?: () => void }) {
  if (!report) return <span className="chip faint"><Layers size={14} /> Context —</span>;
  const pct = Math.round(report.percent * 100);
  const tone = report.percent >= 0.85 ? 'var(--danger)' : report.percent >= 0.65 ? 'var(--warning)' : 'var(--success)';
  return (
    <Popover width={380} align="right" trigger={(toggle) => (
      <button className="chip" onClick={toggle} style={{ cursor: 'pointer' }} title="Context usage">
        <Layers size={14} />
        <span className="small">{report.exact ? '' : '~'}{pct}%</span>
        <span style={{ width: 48, height: 5, borderRadius: 3, background: 'var(--surface-3)', overflow: 'hidden', display: 'inline-block' }}>
          <span style={{ display: 'block', height: '100%', width: `${pct}%`, background: tone }} />
        </span>
      </button>
    )}>
      <div style={{ padding: 8 }}><ContextBreakdown report={report} onCompact={onCompact} /></div>
    </Popover>
  );
}
