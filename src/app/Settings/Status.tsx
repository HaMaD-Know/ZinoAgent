import { FEATURES, STATUS_LABEL, type Status } from './featureStatus';

const TONE: Record<Status, string> = { implemented: 'accent', tested: 'success', 'needs-config': 'warning', experimental: 'warning', 'not-implemented': 'danger' };

export function FeatureStatus() {
  return (
    <div className="stack">
      <p className="small muted">An honest overview of what this build does. "Tested" means automated tests or CI compilation, not on-device verification.</p>
      <table className="table">
        <thead><tr><th>Area</th><th>Feature</th><th>Status</th></tr></thead>
        <tbody>
          {FEATURES.map((f, i) => (
            <tr key={i}>
              <td className="small muted">{f.area}</td>
              <td className="small">{f.feature}{f.note && <div className="tiny faint">{f.note}</div>}</td>
              <td><div className="row wrap" style={{ gap: 4 }}>{f.status.map((s) => <span key={s} className={`badge ${TONE[s]}`}>{STATUS_LABEL[s]}</span>)}</div></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
