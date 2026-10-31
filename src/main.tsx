import { StrictMode, useEffect, useState } from 'react';
import { createRoot } from 'react-dom/client';
import '@/styles/global.css';
import { App } from '@/app/App';
import { useApp } from '@/app/store';
import { bootstrap } from '@/services/bootstrap';
import { toZinoError } from '@/services/errors';

function Root() {
  const ready = useApp((s) => s.ready);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    bootstrap()
      .then(({ settings, native }) => useApp.setState({ ready: true, settings, native }))
      .catch((e) => setError(toZinoError(e).message));
  }, []);
  if (error) {
    return (
      <div className="empty" style={{ height: '100%' }}>
        <h2>ZinoAgent could not start</h2>
        <p className="muted">{error}</p>
        <button className="btn primary" onClick={() => location.reload()}>Try again</button>
      </div>
    );
  }
  if (!ready) return <div className="empty" style={{ height: '100%' }}><span className="spinner" /><span className="muted">Starting…</span></div>;
  return <App />;
}

createRoot(document.getElementById('root')!).render(<StrictMode><Root /></StrictMode>);
