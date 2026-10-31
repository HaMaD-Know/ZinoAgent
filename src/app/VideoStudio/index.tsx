import { useEffect, useMemo, useState } from 'react';
import { Clapperboard, Download, ImageIcon, Wand2, X } from 'lucide-react';
import type { Asset, ModelRef } from '@/types';
import { useApp } from '@/app/store';
import { generateVideo, useTasks, videoOptions } from '@/services/generation';
import { assetManager } from '@/services/asset-manager';
import { findSelectable } from '@/services/ai-router/models';
import { formatBytes } from '@/services/resources';
import { toZinoError } from '@/services/errors';
import { uiBridge } from '@/services/ui-bridge';
import { ModelSelector, refKey } from '@/components/ModelSelector';
import { AssetPicker } from '@/components/AssetPicker';
import { AssetMedia, useAssetUrl } from '@/components/AssetMedia';
import { TaskRow } from '@/components/GenerationProgress';
import { Empty, Field, Segmented, useAsync } from '@/components/ui';
import { RecentStrip } from '@/app/Images';

export function VideoStudio() {
  const settings = useApp((s) => s.settings);
  const setStudioModel = useApp((s) => s.setStudioModel);
  const online = useApp((s) => s.online);
  const ref: ModelRef | null = settings.studioModels.video ?? settings.defaultModels.video;
  const { data: options } = useAsync(() => videoOptions(ref), [refKey(ref)]);
  const { data: selected } = useAsync(() => findSelectable(ref, 'video'), [refKey(ref)]);
  const allTasks = useTasks((s) => s.tasks);
  const tasks = useMemo(() => allTasks.filter((t) => t.kind === 'video'), [allTasks]);
  const [mode, setMode] = useState<'text' | 'image'>('text');
  const [prompt, setPrompt] = useState('');
  const [negative, setNegative] = useState('');
  const [reference, setReference] = useState<Asset | null>(null);
  const [duration, setDuration] = useState<number | undefined>();
  const [size, setSize] = useState<string | undefined>();
  const [resolution, setResolution] = useState<string | undefined>();
  const [aspect, setAspect] = useState<string | undefined>();
  const [fps, setFps] = useState<number | undefined>();
  const [current, setCurrent] = useState<Asset | null>(null);
  const [picker, setPicker] = useState(false);
  const url = useAssetUrl(current);

  useEffect(() => {
    if (!options) return;
    if (options.modes.length && !options.modes.includes(mode)) setMode(options.modes[0]);
    setDuration(options.durations?.[0]); setSize(options.sizes?.[0]); setResolution(options.resolutions?.[0]); setAspect(options.aspectRatios?.[0]); setFps(options.fps?.[0]);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [options]);

  const submit = async () => {
    if (!ref || ref.source === 'auto') return uiBridge.toast('warning', 'Choose a video model first.');
    if (ref.source === 'cloud' && !online) return uiBridge.toast('error', 'You are offline. Cloud video generation needs internet.');
    if (mode === 'image' && !reference) return uiBridge.toast('warning', 'Choose a starting image.');
    if (mode === 'text' && !prompt.trim()) return uiBridge.toast('warning', 'Enter a prompt.');
    try {
      await generateVideo(ref, { mode, prompt: prompt.trim(), negativePrompt: options?.supportsNegativePrompt ? negative || undefined : undefined,
        referenceAssetId: mode === 'image' ? reference?.id : undefined, durationSec: duration, size, resolution, aspectRatio: aspect, fps,
        modelLabel: selected ? `${selected.providerName} · ${selected.name}` : undefined });
    } catch (e) { uiBridge.toast('error', toZinoError(e).message); }
  };

  return (
    <div className="studio">
      <div className="studio-controls">
        <h2>Video Studio</h2>
        <ModelSelector studio="video" value={ref} onChange={(r) => setStudioModel('video', r)} allowAuto={false} />
        {options?.notes?.map((n, i) => <div key={i} className={`hint ${options.modes.length === 0 ? 'notice warning' : ''}`}>{n}</div>)}
        {options && options.modes.length > 0 && (
          <>
            {options.modes.length > 1 && <Segmented value={mode} onChange={setMode} options={options.modes.map((m) => ({ value: m, label: m === 'text' ? 'Text → Video' : 'Image → Video' }))} />}
            <Field label="Prompt"><textarea className="textarea" value={prompt} onChange={(e) => setPrompt(e.target.value)} placeholder="Describe the scene and motion" /></Field>
            {options.supportsNegativePrompt && <Field label="Negative prompt"><input className="input" value={negative} onChange={(e) => setNegative(e.target.value)} /></Field>}
            {mode === 'image' && (
              <Field label="Starting image" hint="It will be uploaded to the provider.">
                {reference ? <div className="row"><div className="thumb" style={{ width: 64, height: 64 }}><AssetMedia asset={reference} /></div><span className="grow truncate small">{reference.name}</span><button className="icon-btn sm" onClick={() => setReference(null)}><X size={15} /></button></div>
                  : <button className="btn" onClick={() => setPicker(true)}><ImageIcon size={16} /> Choose image</button>}
              </Field>
            )}
            {options.durations && <Field label="Duration"><Segmented value={String(duration)} onChange={(v) => setDuration(+v)} options={options.durations.map((d) => ({ value: String(d), label: `${d}s` }))} /></Field>}
            {options.sizes && <Field label="Size"><select className="select" value={size} onChange={(e) => setSize(e.target.value)}>{options.sizes.map((s) => <option key={s}>{s}</option>)}</select></Field>}
            {options.resolutions && <Field label="Resolution"><Segmented value={resolution ?? ''} onChange={setResolution} options={options.resolutions.map((r) => ({ value: r, label: r }))} /></Field>}
            {options.aspectRatios && <Field label="Aspect ratio"><Segmented value={aspect ?? ''} onChange={setAspect} options={options.aspectRatios.map((r) => ({ value: r, label: r }))} /></Field>}
            {options.fps && <Field label="Frame rate"><Segmented value={String(fps)} onChange={(v) => setFps(+v)} options={options.fps.map((r) => ({ value: String(r), label: `${r} fps` }))} /></Field>}
            <button className="btn primary" onClick={submit}><Wand2 size={16} /> Generate video</button>
            <div className="hint">Cloud video generation can take several minutes and may cost credits. Progress continues after you leave this screen.</div>
          </>
        )}
        <div className="section-title">Generation history</div>
        <div className="stack-sm">{tasks.slice(0, 30).map((t) => <TaskRow key={t.id} task={t} onRetry={(tk) => tk.modelRef.source !== 'auto' && void generateVideo(tk.modelRef, tk.params)}
          onOpen={async (tk) => { const [a] = await assetManager.byIds(tk.resultAssetIds); if (a) setCurrent(a); }} />)}</div>
      </div>
      <div className="studio-stage">
        <div className="stage-view">
          {current && url ? <video key={current.id} src={url} controls playsInline style={{ maxWidth: '100%', maxHeight: '100%' }} />
            : <Empty icon={<Clapperboard size={40} />} title="No video yet">Generated videos play here and are saved to Assets.</Empty>}
        </div>
        {current && (
          <div className="row wrap" style={{ padding: '10px 14px', borderTop: '1px solid var(--border)', background: 'var(--surface)' }}>
            <div className="grow small truncate"><strong>{current.name}</strong> <span className="faint">{current.durationSec ? `${current.durationSec}s · ` : ''}{formatBytes(current.sizeBytes)}</span></div>
            <button className="btn sm" onClick={() => assetManager.exportAsset(current.id).catch((e) => uiBridge.toast('error', toZinoError(e).message))}><Download size={14} /> Export video</button>
          </div>
        )}
        <RecentStrip kind="video" currentId={current?.id ?? null} onSelect={setCurrent} />
      </div>
      {picker && <AssetPicker kind="image" title="Starting image" onPick={setReference} onClose={() => setPicker(false)} />}
    </div>
  );
}
