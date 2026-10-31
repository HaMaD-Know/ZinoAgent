import { useEffect, useMemo, useRef, useState } from 'react';
import { Download, ImageIcon, Minus, Plus, RefreshCw, Shuffle, Wand2, X } from 'lucide-react';
import type { Asset, EffortLevel, GenerationTask, ModelRef } from '@/types';
import { useApp } from '@/app/store';
import { generateImage, imageOptions, LOCAL_IMAGE_STEPS, useTasks } from '@/services/generation';
import { assetManager } from '@/services/asset-manager';
import { findSelectable } from '@/services/ai-router/models';
import { toZinoError } from '@/services/errors';
import { uiBridge } from '@/services/ui-bridge';
import { ModelSelector, refKey } from '@/components/ModelSelector';
import { EffortSelector, EFFORT_LABEL } from '@/components/EffortSelector';
import { AssetPicker } from '@/components/AssetPicker';
import { AssetMedia, useAssetUrl } from '@/components/AssetMedia';
import { TaskRow } from '@/components/GenerationProgress';
import { Empty, Field, Segmented, useAsync } from '@/components/ui';

function ZoomView({ asset }: { asset: Asset }) {
  const url = useAssetUrl(asset);
  const [scale, setScale] = useState(1);
  const [pan, setPan] = useState({ x: 0, y: 0 });
  const drag = useRef<{ x: number; y: number; px: number; py: number } | null>(null);
  useEffect(() => { setScale(1); setPan({ x: 0, y: 0 }); }, [asset.id]);
  if (!url) return null;
  return (
    <>
      <img src={url} alt={asset.name} className="zoomable" draggable={false}
        style={{ transform: `translate(${pan.x}px, ${pan.y}px) scale(${scale})`, cursor: scale > 1 ? 'grab' : 'zoom-in', transition: drag.current ? 'none' : 'transform 0.15s' }}
        onDoubleClick={() => { setScale(scale > 1 ? 1 : 2); setPan({ x: 0, y: 0 }); }}
        onWheel={(e) => setScale((s) => Math.max(1, Math.min(6, s * (e.deltaY < 0 ? 1.1 : 0.9))))}
        onPointerDown={(e) => { if (scale > 1) { drag.current = { x: e.clientX, y: e.clientY, px: pan.x, py: pan.y }; (e.target as Element).setPointerCapture(e.pointerId); } }}
        onPointerMove={(e) => { if (drag.current) setPan({ x: drag.current.px + e.clientX - drag.current.x, y: drag.current.py + e.clientY - drag.current.y }); }}
        onPointerUp={() => { drag.current = null; }} />
      <div className="row" style={{ position: 'absolute', bottom: 12, right: 12 }}>
        <button className="icon-btn" style={{ background: 'var(--surface)' }} onClick={() => setScale((s) => Math.max(1, s / 1.4))} aria-label="Zoom out"><Minus size={16} /></button>
        <span className="chip">{Math.round(scale * 100)}%</span>
        <button className="icon-btn" style={{ background: 'var(--surface)' }} onClick={() => setScale((s) => Math.min(6, s * 1.4))} aria-label="Zoom in"><Plus size={16} /></button>
      </div>
    </>
  );
}

/** Re-encode as JPEG into a new export asset (original PNG untouched). */
async function exportJpeg(asset: Asset) {
  const b64 = await assetManager.readBase64(asset);
  const img = new Image();
  img.src = `data:${asset.mime};base64,${b64}`;
  await img.decode();
  const c = document.createElement('canvas');
  c.width = img.naturalWidth; c.height = img.naturalHeight;
  const ctx = c.getContext('2d')!;
  ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, c.width, c.height); ctx.drawImage(img, 0, 0);
  const jpeg = c.toDataURL('image/jpeg', 0.92).split(',')[1];
  const out = await assetManager.save({ kind: 'export', name: `${asset.name}.jpg`, mime: 'image/jpeg', base64: jpeg, parentAssetId: asset.id, width: c.width, height: c.height, metadata: { exportedFrom: asset.id } });
  await assetManager.exportAsset(out.id);
}

export function ImageStudio() {
  const settings = useApp((s) => s.settings);
  const setStudioModel = useApp((s) => s.setStudioModel);
  const online = useApp((s) => s.online);
  const ref: ModelRef | null = settings.studioModels.image ?? settings.defaultModels.image;
  const { data: options } = useAsync(() => imageOptions(ref), [refKey(ref)]);
  const { data: selected } = useAsync(() => findSelectable(ref, 'image'), [refKey(ref)]);
  const allTasks = useTasks((s) => s.tasks);
  const tasks = useMemo(() => allTasks.filter((t) => t.kind === 'image'), [allTasks]);

  const [mode, setMode] = useState<'text' | 'image' | 'edit'>('text');
  const [prompt, setPrompt] = useState('');
  const [negative, setNegative] = useState('');
  const [reference, setReference] = useState<Asset | null>(null);
  const [size, setSize] = useState<string | undefined>();
  const [aspect, setAspect] = useState<string | undefined>();
  const [quality, setQuality] = useState<EffortLevel>('medium');
  const [steps, setSteps] = useState(25);
  const [guidance, setGuidance] = useState(7.5);
  const [seed, setSeed] = useState<number | null>(null);
  const [count, setCount] = useState(1);
  const [strength, setStrength] = useState(0.6);
  const [picker, setPicker] = useState(false);
  const [current, setCurrent] = useState<Asset | null>(null);
  const isLocal = ref?.source === 'local';

  useEffect(() => {
    if (!options) return;
    if (!options.modes.includes(mode)) setMode(options.modes[0] ?? 'text');
    setSize(options.sizes?.[0]); setAspect(options.aspectRatios?.[0]);
    if (options.steps) setSteps(options.steps.default);
    if (count > options.maxCount) setCount(options.maxCount);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [options]);
  useEffect(() => { if (isLocal && quality !== 'auto') setSteps(LOCAL_IMAGE_STEPS[quality]); }, [quality, isLocal]);

  const cloudQuality = useMemo(() => {
    const q = options?.qualities;
    if (!q?.length || isLocal) return undefined;
    const idx = ['minimal', 'low', 'medium', 'high', 'maximum'].indexOf(quality === 'auto' ? 'medium' : quality);
    if (q.includes('hd')) return idx >= 3 ? 'hd' : 'standard';
    const ladder = q.filter((x) => x !== 'auto');
    return ladder[Math.min(ladder.length - 1, Math.round((idx / 4) * (ladder.length - 1)))];
  }, [options, quality, isLocal]);

  const { data: currentTaskAssets } = useAsync(async () => {
    const latest = tasks.find((t) => t.status === 'succeeded');
    return latest ? assetManager.byIds(latest.resultAssetIds) : [];
  }, [tasks.find((t) => t.status === 'succeeded')?.id]);
  useEffect(() => { if (!current && currentTaskAssets?.[0]) setCurrent(currentTaskAssets[0]); }, [currentTaskAssets, current]);

  const submit = async (overrides: Record<string, unknown> = {}) => {
    if (!ref || ref.source === 'auto') { uiBridge.toast('warning', 'Choose an image model first.'); return; }
    if (ref.source === 'cloud' && !online) { uiBridge.toast('error', 'You are offline. Choose an offline image model.'); return; }
    if (!prompt.trim()) { uiBridge.toast('warning', 'Enter a prompt.'); return; }
    if ((mode === 'image' || mode === 'edit') && !reference) { uiBridge.toast('warning', 'Choose a reference image.'); return; }
    try {
      await generateImage(ref, {
        mode, prompt: prompt.trim(), negativePrompt: options?.supportsNegativePrompt ? negative.trim() || undefined : undefined,
        referenceAssetId: mode !== 'text' ? reference?.id : undefined, size, aspectRatio: aspect, quality: cloudQuality,
        steps: isLocal ? steps : undefined, guidance: isLocal ? guidance : undefined, seed: options?.supportsSeed && seed !== null ? seed : undefined,
        count, strength: options?.supportsStrength && mode === 'image' ? strength : undefined, modelLabel: selected ? `${selected.providerName} · ${selected.name}` : undefined,
        ...overrides,
      });
    } catch (e) { uiBridge.toast('error', toZinoError(e).message); }
  };
  const retry = (t: GenerationTask) => {
    if (!t.modelRef || t.modelRef.source === 'auto') return;
    void generateImage(t.modelRef, t.params);
  };

  return (
    <div className="studio">
      <div className="studio-controls">
        <div className="row"><h2 className="grow">Image Studio</h2></div>
        <ModelSelector studio="image" value={ref} onChange={(r) => setStudioModel('image', r)} allowAuto={false} />
        {options?.notes?.map((n, i) => <div key={i} className="hint">{n}</div>)}
        {options && options.modes.length > 1 && (
          <Segmented value={mode} onChange={setMode} options={options.modes.map((m) => ({ value: m, label: m === 'text' ? 'Text → Image' : m === 'image' ? 'Image → Image' : 'Edit' }))} />
        )}
        <Field label="Prompt"><textarea className="textarea" value={prompt} onChange={(e) => setPrompt(e.target.value)} placeholder="Describe the image" /></Field>
        {options?.supportsNegativePrompt && <Field label="Negative prompt"><input className="input" value={negative} onChange={(e) => setNegative(e.target.value)} placeholder="What to avoid" /></Field>}
        {mode !== 'text' && (
          <Field label="Reference image" hint={ref?.source === 'cloud' ? 'This image will be uploaded to the provider.' : 'Stays on this iPad.'}>
            {reference ? (
              <div className="row"><div className="thumb" style={{ width: 64, height: 64 }}><AssetMedia asset={reference} /></div><span className="grow truncate small">{reference.name}</span>
                <button className="icon-btn sm" onClick={() => setReference(null)}><X size={15} /></button></div>
            ) : <button className="btn" onClick={() => setPicker(true)}><ImageIcon size={16} /> Choose image</button>}
          </Field>
        )}
        {options?.sizes && options.sizes.length > 0 && (
          <Field label="Resolution">{options.sizes.length === 1 ? <span className="chip">{options.sizes[0]}</span> :
            <select className="select" value={size} onChange={(e) => setSize(e.target.value)}>{options.sizes.map((s) => <option key={s}>{s}</option>)}</select>}</Field>
        )}
        {options?.aspectRatios && options.aspectRatios.length > 0 && mode === 'text' && (
          <Field label="Aspect ratio"><select className="select" value={aspect} onChange={(e) => setAspect(e.target.value)}>{options.aspectRatios.map((s) => <option key={s}>{s}</option>)}</select></Field>
        )}
        {(isLocal || (options?.qualities?.length ?? 0) > 0) && (
          <Field label="Quality / effort" hint={isLocal ? `${EFFORT_LABEL[quality]} → ${steps} diffusion steps` : cloudQuality ? `Sends quality = "${cloudQuality}"` : undefined}>
            <EffortSelector label="Quality" value={quality} onChange={setQuality} />
          </Field>
        )}
        {isLocal && options?.steps && (
          <>
            <Field label={`Steps: ${steps}`}><input type="range" min={options.steps.min} max={options.steps.max} value={steps} onChange={(e) => setSteps(+e.target.value)} /></Field>
            {options.guidance && <Field label={`Guidance: ${guidance.toFixed(1)}`}><input type="range" min={options.guidance.min} max={options.guidance.max} step={0.5} value={guidance} onChange={(e) => setGuidance(+e.target.value)} /></Field>}
          </>
        )}
        {options?.supportsStrength && mode === 'image' && <Field label={`Strength: ${strength.toFixed(2)}`} hint="Higher changes the reference more."><input type="range" min={0.05} max={0.95} step={0.05} value={strength} onChange={(e) => setStrength(+e.target.value)} /></Field>}
        {options?.supportsSeed && (
          <Field label="Seed" hint="Same seed + settings reproduces an image (when the model is deterministic).">
            <div className="row"><input className="input" inputMode="numeric" placeholder="Random" value={seed ?? ''} onChange={(e) => setSeed(e.target.value === '' ? null : Math.max(0, Math.floor(+e.target.value) || 0))} />
              <button className="icon-btn" title="Random seed" onClick={() => setSeed(Math.floor(Math.random() * 2 ** 31))}><Shuffle size={16} /></button></div>
          </Field>
        )}
        {options && options.maxCount > 1 && <Field label={`Images: ${count}`}><input type="range" min={1} max={options.maxCount} value={count} onChange={(e) => setCount(+e.target.value)} /></Field>}
        <button className="btn primary" onClick={() => submit()} disabled={!ref || !options || options.modes.length === 0}><Wand2 size={16} /> Generate</button>
        <div className="section-title">Generation history</div>
        <div className="stack-sm">{tasks.slice(0, 30).map((t) => <TaskRow key={t.id} task={t} onRetry={retry}
          onOpen={async (tk) => { const [a] = await assetManager.byIds(tk.resultAssetIds); if (a) setCurrent(a); }} />)}</div>
      </div>
      <div className="studio-stage">
        <div className="stage-view">
          {current ? <ZoomView asset={current} /> : <Empty icon={<ImageIcon size={40} />} title="No image yet">Generated images appear here and are saved to Assets automatically.</Empty>}
        </div>
        {current && (
          <div className="row wrap" style={{ padding: '10px 14px', borderTop: '1px solid var(--border)', background: 'var(--surface)' }}>
            <div className="grow small truncate"><strong>{current.name}</strong> <span className="faint">{current.width && current.height ? `${current.width}×${current.height}` : ''} · saved in Assets</span></div>
            <button className="btn sm" onClick={() => { const p = current.metadata as Record<string, unknown>; setPrompt(String(p.prompt ?? prompt)); void submit({ prompt: p.prompt ?? prompt, seed: undefined }); }}><RefreshCw size={14} /> Regenerate</button>
            <button className="btn sm" onClick={() => { setReference(current); setMode(options?.modes.includes('image') ? 'image' : 'edit'); }}>Use as reference</button>
            <button className="btn sm" onClick={() => assetManager.exportAsset(current.id).catch((e) => uiBridge.toast('error', toZinoError(e).message))}><Download size={14} /> Export PNG</button>
            <button className="btn sm" onClick={() => exportJpeg(current).catch((e) => uiBridge.toast('error', toZinoError(e).message))}>Export JPEG</button>
          </div>
        )}
        <RecentStrip kind="image" currentId={current?.id ?? null} onSelect={setCurrent} />
      </div>
      {picker && <AssetPicker kind="image" title="Reference image" onPick={setReference} onClose={() => setPicker(false)} />}
    </div>
  );
}

export function RecentStrip({ kind, currentId, onSelect }: { kind: Asset['kind']; currentId: string | null; onSelect: (a: Asset) => void }) {
  const tasks = useTasks((s) => s.tasks);
  const { data } = useAsync(() => assetManager.list({ kind }), [kind, tasks.filter((t) => t.status === 'succeeded').length]);
  if (!data?.length) return null;
  return (
    <div className="stage-history">
      {data.slice(0, 40).map((a) => <div key={a.id} className={`thumb ${a.id === currentId ? 'active' : ''}`} onClick={() => onSelect(a)} title={a.name}><AssetMedia asset={a} /></div>)}
    </div>
  );
}
