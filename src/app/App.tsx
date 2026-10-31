import type { ReactNode } from 'react';
import { useEffect } from 'react';
import { Box, Clapperboard, Cpu, FolderArchive, Image, MessageSquare, Settings, WifiOff } from 'lucide-react';
import { useApp, type Section } from './store';
import { UIHost } from '@/components/UIHost';
import { RamMeter } from '@/components/RamMonitor';
import { AgentView } from './Agent';
import { ImageStudio } from './Images';
import { ThreeDStudio } from './ThreeDStudio';
import { VideoStudio } from './VideoStudio';
import { ModelsView } from './Models';
import { AssetsView } from './Assets';
import { SettingsView } from './Settings';

const NAV: { id: Section; label: string; icon: ReactNode }[] = [
  { id: 'agent', label: 'Agent', icon: <MessageSquare size={20} /> },
  { id: 'images', label: 'Images', icon: <Image size={20} /> },
  { id: 'threed', label: '3D Studio', icon: <Box size={20} /> },
  { id: 'video', label: 'Video Studio', icon: <Clapperboard size={20} /> },
  { id: 'models', label: 'Models', icon: <Cpu size={20} /> },
  { id: 'assets', label: 'Assets', icon: <FolderArchive size={20} /> },
  { id: 'settings', label: 'Settings', icon: <Settings size={20} /> },
];

export function App() {
  const section = useApp((s) => s.section);
  const setSection = useApp((s) => s.setSection);
  const theme = useApp((s) => s.settings.theme);
  const online = useApp((s) => s.online);

  useEffect(() => {
    if (theme === 'system') document.documentElement.removeAttribute('data-theme');
    else document.documentElement.setAttribute('data-theme', theme);
  }, [theme]);

  return (
    <div className="app">
      <nav className="sidebar" aria-label="Main">
        <div className="brand"><div className="brand-mark">Z</div><span>ZinoAgent</span></div>
        <div className="nav">
          {NAV.map((n) => (
            <button key={n.id} className={section === n.id ? 'active' : ''} onClick={() => setSection(n.id)} aria-current={section === n.id ? 'page' : undefined} title={n.label}>
              {n.icon}<span>{n.label}</span>
            </button>
          ))}
        </div>
        <div className="sidebar-footer">
          {!online && <div className="meter row"><WifiOff size={14} /><span className="meter-text">Offline — local models only</span></div>}
          <RamMeter />
        </div>
      </nav>
      <main className="main">
        {section === 'agent' && <AgentView />}
        {section === 'images' && <ImageStudio />}
        {section === 'threed' && <ThreeDStudio />}
        {section === 'video' && <VideoStudio />}
        {section === 'models' && <ModelsView />}
        {section === 'assets' && <AssetsView />}
        {section === 'settings' && <SettingsView />}
      </main>
      <UIHost />
    </div>
  );
}
