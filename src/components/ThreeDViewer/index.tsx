// Three.js viewer for GLB / GLTF / OBJ with touch orbit, zoom and pan, view modes, lighting,
// material inspection, mesh statistics and animation playback. The original file is never
// modified: "Save optimised copy" writes a new asset.
import { useEffect, useRef, useState } from 'react';
import * as THREE from 'three';
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js';
import { GLTFLoader, type GLTF } from 'three/examples/jsm/loaders/GLTFLoader.js';
import { OBJLoader } from 'three/examples/jsm/loaders/OBJLoader.js';
import { GLTFExporter } from 'three/examples/jsm/exporters/GLTFExporter.js';
import { mergeVertices } from 'three/examples/jsm/utils/BufferGeometryUtils.js';
import { Box, Maximize2, Minimize2, Pause, Play, RotateCcw, Sun } from 'lucide-react';
import { Segmented, Spinner } from '../ui';

export interface MeshStats {
  meshes: number; triangles: number; vertices: number; materials: number; textures: number; animations: number;
  bounds: { x: number; y: number; z: number }; hasUVs: boolean;
}
export interface MaterialInfo { name: string; type: string; color?: string; metalness?: number; roughness?: number; maps: string[]; transparent: boolean }

type ViewMode = 'textured' | 'solid' | 'wireframe';

function collect(root: THREE.Object3D, animations: THREE.AnimationClip[]): { stats: MeshStats; materials: MaterialInfo[] } {
  let meshes = 0, triangles = 0, vertices = 0; let hasUVs = false;
  const mats = new Map<string, THREE.Material>();
  const textures = new Set<string>();
  root.traverse((o) => {
    const m = o as THREE.Mesh;
    if (!m.isMesh) return;
    meshes++;
    const g = m.geometry as THREE.BufferGeometry;
    const pos = g.getAttribute('position');
    vertices += pos?.count ?? 0;
    triangles += g.index ? g.index.count / 3 : (pos?.count ?? 0) / 3;
    if (g.getAttribute('uv')) hasUVs = true;
    for (const mat of Array.isArray(m.material) ? m.material : [m.material]) {
      mats.set(mat.uuid, mat);
      for (const v of Object.values(mat)) if (v && (v as THREE.Texture).isTexture) textures.add((v as THREE.Texture).uuid);
    }
  });
  const box = new THREE.Box3().setFromObject(root);
  const size = box.getSize(new THREE.Vector3());
  const materials: MaterialInfo[] = [...mats.values()].map((mat) => {
    const std = mat as THREE.MeshStandardMaterial;
    const maps = ['map', 'normalMap', 'roughnessMap', 'metalnessMap', 'aoMap', 'emissiveMap'].filter((k) => (std as unknown as Record<string, unknown>)[k]);
    return { name: mat.name || '(unnamed)', type: mat.type, color: std.color ? `#${std.color.getHexString()}` : undefined,
      metalness: std.metalness, roughness: std.roughness, maps, transparent: mat.transparent };
  });
  return {
    stats: { meshes, triangles: Math.round(triangles), vertices, materials: mats.size, textures: textures.size, animations: animations.length,
      bounds: { x: +size.x.toFixed(3), y: +size.y.toFixed(3), z: +size.z.toFixed(3) }, hasUVs },
    materials,
  };
}

export function ThreeDViewer({ url, format, onStats, onExportCopy }: {
  url: string; format: 'glb' | 'gltf' | 'obj';
  onStats?: (s: MeshStats, m: MaterialInfo[]) => void;
  /** Receives a GLB (ArrayBuffer) of an optimised copy — the caller saves it as a NEW asset. */
  onExportCopy?: (glb: ArrayBuffer, note: string) => void;
}) {
  const host = useRef<HTMLDivElement>(null);
  const wrap = useRef<HTMLDivElement>(null);
  const api = useRef<{ setMode(m: ViewMode): void; setLight(v: number): void; reset(): void; toggleAnim(): boolean; exportCopy(weld: boolean): Promise<ArrayBuffer> } | null>(null);
  const [mode, setMode] = useState<ViewMode>('textured');
  const [light, setLight] = useState(1);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [stats, setStats] = useState<MeshStats | null>(null);
  const [playing, setPlaying] = useState(true);
  const [fullscreen, setFullscreen] = useState(false);

  useEffect(() => {
    const el = host.current!;
    const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, preserveDrawingBuffer: false });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    el.appendChild(renderer.domElement);
    const scene = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(45, 1, 0.01, 1000);
    const controls = new OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true;
    controls.screenSpacePanning = true;
    const hemi = new THREE.HemisphereLight(0xffffff, 0x444455, 1.2);
    const dir = new THREE.DirectionalLight(0xffffff, 2.2);
    dir.position.set(3, 5, 4);
    scene.add(hemi, dir);
    const grid = new THREE.GridHelper(10, 20, 0x888888, 0xcccccc);
    (grid.material as THREE.Material).opacity = 0.25; (grid.material as THREE.Material).transparent = true;
    scene.add(grid);

    let root: THREE.Object3D | null = null;
    let mixer: THREE.AnimationMixer | null = null;
    let animations: THREE.AnimationClip[] = [];
    const originals = new Map<THREE.Mesh, THREE.Material | THREE.Material[]>();
    const solid = new THREE.MeshStandardMaterial({ color: 0xb8bcc6, roughness: 0.65, metalness: 0.05 });
    const wire = new THREE.MeshBasicMaterial({ color: 0x0a6cff, wireframe: true });
    const clock = new THREE.Clock();
    let home = { pos: new THREE.Vector3(2, 1.5, 3), target: new THREE.Vector3() };
    let disposed = false;
    let animPlaying = true;

    const resize = () => {
      const w = el.clientWidth || 1, h = el.clientHeight || 1;
      renderer.setSize(w, h, false);
      camera.aspect = w / h; camera.updateProjectionMatrix();
    };
    const ro = new ResizeObserver(resize); ro.observe(el); resize();

    const frame = (obj: THREE.Object3D) => {
      const box = new THREE.Box3().setFromObject(obj);
      const size = box.getSize(new THREE.Vector3()).length() || 1;
      const center = box.getCenter(new THREE.Vector3());
      grid.position.y = box.min.y;
      grid.scale.setScalar(size / 4);
      camera.near = size / 200; camera.far = size * 100; camera.updateProjectionMatrix();
      home = { pos: center.clone().add(new THREE.Vector3(size * 0.6, size * 0.4, size * 0.8)), target: center };
      camera.position.copy(home.pos); controls.target.copy(center); controls.update();
    };

    const onLoaded = (obj: THREE.Object3D, anims: THREE.AnimationClip[]) => {
      if (disposed) return;
      root = obj; animations = anims;
      scene.add(obj);
      obj.traverse((o) => { const m = o as THREE.Mesh; if (m.isMesh) originals.set(m, m.material); });
      if (anims.length) { mixer = new THREE.AnimationMixer(obj); anims.forEach((a) => mixer!.clipAction(a).play()); }
      frame(obj);
      const info = collect(obj, anims);
      setStats(info.stats); onStats?.(info.stats, info.materials);
      setLoading(false);
    };
    const onError = (e: unknown) => { if (!disposed) { setError(`Could not load this model: ${(e as Error)?.message ?? e}`); setLoading(false); } };
    if (format === 'obj') new OBJLoader().load(url, (o) => onLoaded(o, []), undefined, onError);
    else new GLTFLoader().load(url, (g: GLTF) => onLoaded(g.scene, g.animations), undefined, onError);

    renderer.setAnimationLoop(() => {
      const dt = clock.getDelta();
      if (mixer && animPlaying) mixer.update(dt);
      controls.update();
      renderer.render(scene, camera);
    });

    api.current = {
      setMode(m) {
        for (const [mesh, mat] of originals) mesh.material = m === 'textured' ? mat : m === 'solid' ? solid : wire;
      },
      setLight(v) { hemi.intensity = 1.2 * v; dir.intensity = 2.2 * v; },
      reset() { camera.position.copy(home.pos); controls.target.copy(home.target); controls.update(); },
      toggleAnim() { animPlaying = !animPlaying; return animPlaying; },
      async exportCopy(weld) {
        if (!root) throw new Error('No model loaded');
        const copy = root.clone(true);
        copy.traverse((o) => {
          const m = o as THREE.Mesh;
          if (!m.isMesh) return;
          const orig = [...originals.entries()].find(([mesh]) => mesh.geometry === m.geometry)?.[1];
          if (orig) m.material = orig;
          if (weld) m.geometry = mergeVertices(m.geometry.clone());
        });
        return new Promise<ArrayBuffer>((resolve, reject) => {
          new GLTFExporter().parse(copy, (r) => resolve(r as ArrayBuffer), reject, { binary: true, animations });
        });
      },
    };

    return () => {
      disposed = true;
      renderer.setAnimationLoop(null);
      ro.disconnect();
      controls.dispose();
      scene.traverse((o) => {
        const m = o as THREE.Mesh;
        if (m.isMesh) { m.geometry?.dispose(); (Array.isArray(m.material) ? m.material : [m.material]).forEach((x) => x?.dispose()); }
      });
      solid.dispose(); wire.dispose();
      renderer.dispose();
      el.removeChild(renderer.domElement);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [url, format]);

  useEffect(() => { api.current?.setMode(mode); }, [mode, stats]);
  useEffect(() => { api.current?.setLight(light); }, [light, stats]);

  const toggleFullscreen = async () => {
    const el = wrap.current as (HTMLDivElement & { webkitRequestFullscreen?: () => Promise<void> }) | null;
    if (!document.fullscreenElement && el) {
      try { await (el.requestFullscreen?.() ?? el.webkitRequestFullscreen?.()); setFullscreen(true); } catch { setFullscreen((f) => !f); }
    } else { await document.exitFullscreen?.().catch(() => {}); setFullscreen(false); }
  };

  return (
    <div ref={wrap} className="viewer3d" style={fullscreen ? { position: 'fixed', inset: 0, zIndex: 150, background: 'var(--surface-2)' } : undefined}>
      <div ref={host} style={{ position: 'absolute', inset: 0 }} />
      <div className="viewer-toolbar">
        <Segmented value={mode} onChange={setMode} options={[{ value: 'textured', label: 'Textured' }, { value: 'solid', label: 'Solid' }, { value: 'wireframe', label: 'Wireframe' }]} />
        <div className="chip"><Sun size={14} /><input type="range" min={0.2} max={3} step={0.1} value={light} onChange={(e) => setLight(+e.target.value)} style={{ width: 90 }} aria-label="Lighting" /></div>
        <span style={{ flex: 1 }} />
        {stats?.animations ? <button className="btn sm" onClick={() => setPlaying(api.current?.toggleAnim() ?? true)}>{playing ? <Pause size={14} /> : <Play size={14} />} Animation</button> : null}
        <button className="btn sm" onClick={() => api.current?.reset()}><RotateCcw size={14} /> Reset view</button>
        {onExportCopy && stats && (
          <button className="btn sm" title="Writes a NEW file; the original is untouched" onClick={async () => {
            const glb = await api.current!.exportCopy(true);
            onExportCopy(glb, 'Optimised copy (duplicate vertices welded). Original unchanged.');
          }}><Box size={14} /> Save optimised copy</button>
        )}
        <button className="btn sm" onClick={toggleFullscreen} aria-label="Fullscreen">{fullscreen ? <Minimize2 size={14} /> : <Maximize2 size={14} />}</button>
      </div>
      {loading && <div style={{ position: 'absolute', inset: 0, display: 'grid', placeItems: 'center' }}><Spinner /></div>}
      {error && <div style={{ position: 'absolute', inset: 0, display: 'grid', placeItems: 'center', padding: 20 }}><div className="notice danger">{error}</div></div>}
      {stats && (
        <div className="viewer-stats">
          {stats.triangles.toLocaleString()} triangles · {stats.vertices.toLocaleString()} vertices · {stats.meshes} meshes · {stats.materials} materials · {stats.textures} textures
          {stats.animations ? ` · ${stats.animations} animations` : ''}{stats.hasUVs ? ' · UVs' : ''}
        </div>
      )}
    </div>
  );
}
