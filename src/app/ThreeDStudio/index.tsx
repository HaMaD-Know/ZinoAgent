import { useEffect, useMemo, useState } from 'react';
import { Box, Download, FolderOpen, ImageIcon, Wand2, X } from 'lucide-react';
import type { Asset, ModelRef } from '@/types';
import { useApp } from '@/app/store';
import { generate3D, threeDOptions, useTasks } from '@/services/generation';
import { assetManager } from '@/services/asset-manager';
import { findSelectable } from '@/services/ai-router/models';
import { toZinoError } from '@/services/errors';
import { uiBridge } from '@/services/ui-bridge';
import { ModelSelector, refKey } from '@/components/ModelSelector';
import { ThreeDViewer, type MaterialInfo, type MeshStats } from '@/components/ThreeDViewer';
import { AssetPicker } from '@/components/AssetPicker';
import { AssetMedia, useAssetUrl } from '@/components/AssetMedia';
import { TaskRow } from '@/components/GenerationProgress';
import { Empty, Field, Segmented, Toggle, useAsync } from '@/components/ui';
import { RecentStrip } from '@/app/Images';

const formatOf = (a: Asset): 'glb' | 'gltf' | 'obj' | null => {
  const ext = a.path.split('.').pop()?.toLowerCase();
  return ext === 'glb' || ext === 'gltf' || ext === 'obj' ? ext : null;
};

function arrayBufferToBase64(buf: ArrayBuffer) {
  const bytes = new Uint8Array(buf);
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

export function ThreeDStudio() {
  const settings = useApp((s) => s.settings);
  const setStudioModel = useApp((s) => s.setStudioModel);
  const online = useApp((s) => s.online);
  const ref: ModelRef | null = settings.studioModels.threed ?? settings.defaultModels.threed;
  const { data: options } = useAsync(() => threeDOptions(ref), [refKey(ref)]);
  const { data: selected } = useAsync(() => findSelectable(ref, 'threed'), [refKey(ref)]);
  const allTasks = useTasks((s) => s.tasks);
  const tasks = useMemo(() => allTasks.filter((t) => t.kind === 'threed'), [allTasks]);
  const [mode, setMode] = useState<'text' | 'image'>('text');
  const [prompt, setPrompt] = useState('');
  const [reference, setReference] = useState<Asset | null>(null);
  const [topology, setTopology] = useState<'triangle' | 'quad'>('triangle');
  const [polycount, setPolycount] = useState(0);
  const [texture, setTexture] = useState(true);
  const [pbr, setPbr] = useState(true);
  const [texRes, setTexRes] = useState(1024);
  const [geomQuality, setGeomQuality] = useState<string | undefined>();
  const [current, setCurrent] = useState<Asset | null>(null);
  const [picker, setPicker] = useState<'reference' | 'model' | null>(null);
  const [info, setInfo] = useState<{ stats: MeshStats; materials: MaterialInfo[] } | null>(null);
  const url = useAssetUrl(current);

  useEffect(() => {
    if (!options) return;
    if (options.modes.length && !options.modes.includes(mode)) setMode(options.modes[0]);
    if (options.polycount) setPolycount(Math.max(0, options.polycount.default));
    if (options.textureResolutions) setTexRes(options.textureResolutions[1] ?? options.textureResolutions[0]);
    setGeomQuality(options.geometryQualities?.[0]);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [options]);
  useEffect(() => { setInfo(null); }, [current?.id]);

  const submit = async () => {
    if (!ref || ref.source === 'auto') return uiBridge.toast('warning', 'Choose a 3D model first.');
    if (ref.source === 'cloud' && !online) return uiBridge.toast('error', 'You are offline. Cloud 3D generation needs internet.');
    if (mode === 'text' && !prompt.trim()) return uiBridge.toast('warning', 'Enter a prompt.');
    if (mode === 'image' && !reference) return uiBridge.toast('warning', 'Choose a reference image.');
    try {
      await generate3D(ref, {
        mode, prompt: prompt.trim(), referenceAssetId: mode === 'image' ? reference?.id : undefined, topology: options?.topologies ? topology : undefined,
        targetPolycount: polycount > 0 ? polycount : undefined, texture: options?.supportsTexture ? texture : false, pbr: options?.supportsPBR ? pbr : false,
        textureResolution: options?.textureResolutions ? texRes : undefined, geometryQuality: geomQuality,
        modelLabel: selected ? `${selected.providerName} · ${selected.name}` : undefined,
      });
    } catch (e) { uiBridge.toast('error', toZinoError(e).message); }
  };

  const saveCopy = async (glb: ArrayBuffer, note: string) => {
    if (!current) return;
    try {
      const a = await assetManager.save({ kind: 'model3d', name: `${current.name} (optimised copy)`, mime: 'model/gltf-binary', base64: arrayBufferToBase64(glb),
        parentAssetId: current.id, chatId: current.chatId, metadata: { note, derivedFrom: current.id } });
      uiBridge.toast('success', 'Saved as a new asset. The original model was not changed.');
      setCurrent(a);
    } catch (e) { uiBridge.toast('error', toZinoError(e).message); }
  };

  const fmt = current ? formatOf(current) : null;
  return (
    <div className="studio">
      <div className="studio-controls">
        <h2>3D Studio</h2>
        <ModelSelector studio="threed" value={ref} onChange={(r) => setStudioModel('threed', r)} allowAuto={false} />
        {options?.notes?.map((n, i) => <div key={i} className={`hint ${options.modes.length === 0 ? 'notice warning' : ''}`}>{n}</div>)}
        {options && options.modes.length > 0 && (
          <>
            {options.modes.length > 1 && <Segmented value={mode} onChange={setMode} options={options.modes.map((m) => ({ value: m, label: m === 'text' ? 'Text → 3D' : 'Image → 3D' }))} />}
            {mode === 'text' ? (
              <Field label="Prompt"><textarea className="textarea" value={prompt} onChange={(e) => setPrompt(e.target.value)} placeholder="e.g. a detailed die-cast toy car, red, with chrome wheels" /></Field>
            ) : (
              <Field label="Reference image" hint="It will be uploaded to the provider.">
                {reference ? <div className="row"><div className="thumb" style={{ width: 64, height: 64 }}><AssetMedia asset={reference} /></div><span className="grow truncate small">{reference.name}</span><button className="icon-btn sm" onClick={() => setReference(null)}><X size={15} /></button></div>
                  : <button className="btn" onClick={() => setPicker('reference')}><ImageIcon size={16} /> Choose image</button>}
              </Field>
            )}
            {options.topologies && <Field label="Topology"><Segmented value={topology} onChange={setTopology} options={options.topologies.map((t) => ({ value: t, label: t === 'triangle' ? 'Triangles' : 'Quads' }))} /></Field>}
            {options.polycount && <Field label={`Geometry detail: ${polycount > 0 ? `${polycount.toLocaleString()} polygons` : 'provider default'}`} hint="ZinoAgent never lowers this for you.">
              <input type="range" min={0} max={options.polycount.max} step={Math.max(100, Math.round(options.polycount.max / 200))} value={polycount} onChange={(e) => setPolycount(+e.target.value)} /></Field>}
            {options.geometryQualities && <Field label="Texture quality"><Segmented value={geomQuality ?? options.geometryQualities[0]} onChange={setGeomQuality} options={options.geometryQualities.map((q) => ({ value: q, label: q }))} /></Field>}
            {options.supportsTexture && <div className="row"><span className="grow small">Generate textures</span><Toggle on={texture} onChange={setTexture} /></div>}
            {options.supportsPBR && <div className="row"><span className="grow small">PBR materials</span><Toggle on={pbr && texture} onChange={setPbr} disabled={!texture} /></div>}
            {options.textureResolutions && <Field label="Texture resolution"><Segmented value={String(texRes)} onChange={(v) => setTexRes(+v)} options={options.textureResolutions.map((r) => ({ value: String(r), label: `${r}px` }))} /></Field>}
            <button className="btn primary" onClick={submit}><Wand2 size={16} /> Generate</button>
          </>
        )}
        <button className="btn" onClick={() => setPicker('model')}><FolderOpen size={16} /> Open a 3D model</button>
        <div className="section-title">Generation history</div>
        <div className="stack-sm">{tasks.slice(0, 30).map((t) => <TaskRow key={t.id} task={t} onRetry={(tk) => tk.modelRef.source !== 'auto' && void generate3D(tk.modelRef, tk.params)}
          onOpen={async (tk) => { const [a] = await assetManager.byIds(tk.resultAssetIds); if (a) setCurrent(a); }} />)}</div>
      </div>
      <div className="studio-stage">
        <div className="stage-view">
          {current && url && fmt ? <ThreeDViewer key={current.id} url={url} format={fmt} onStats={(stats, materials) => setInfo({ stats, materials })} onExportCopy={saveCopy} />
            : current && !fmt ? <Empty icon={<Box size={40} />} title="Preview not available">{current.name} is not GLB, GLTF or OBJ. It can still be exported.</Empty>
              : <Empty icon={<Box size={40} />} title="No model open">Generate a model or open one from your library. Originals are never modified.</Empty>}
        </div>
        {current && (
          <div className="row wrap" style={{ padding: '10px 14px', borderTop: '1px solid var(--border)', background: 'var(--surface)', alignItems: 'flex-start' }}>
            <div className="grow small">
              <strong>{current.name}</strong>{current.parentAssetId && <span className="badge" style={{ marginLeft: 6 }}>derived copy</span>}
              {info && <div className="tiny muted">{info.stats.bounds.x} × {info.stats.bounds.y} × {info.stats.bounds.z} units · Materials: {info.materials.map((m) => `${m.name} (${m.type.replace('Mesh', '').replace('Material', '')}${m.maps.length ? `: ${m.maps.join(', ')}` : ''})`).join('; ') || 'none'}</div>}
            </div>
            <button className="btn sm" onClick={() => assetManager.exportAsset(current.id).catch((e) => uiBridge.toast('error', toZinoError(e).message))}><Download size={14} /> Export {fmt?.toUpperCase() ?? ''}</button>
          </div>
        )}
        <RecentStrip kind="model3d" currentId={current?.id ?? null} onSelect={setCurrent} />
      </div>
      {picker === 'reference' && <AssetPicker kind="image" title="Reference image" onPick={setReference} onClose={() => setPicker(null)} />}
      {picker === 'model' && <AssetPicker kind="model3d" title="Open a 3D model" onPick={setCurrent} onClose={() => setPicker(null)} />}
    </div>
  );
}
