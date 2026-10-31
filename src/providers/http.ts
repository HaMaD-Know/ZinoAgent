// HTTP for cloud providers, routed through the native ZinoHttp plugin so API keys stay in the
// Keychain. Maps HTTP failures to ZinoError codes with useful messages.
import { ZinoHttp, type HttpAuth, type HttpRequestOptions, type HttpResponse, type MultipartPart } from '@/native';
import { ZinoError, scrubSecrets, toZinoError } from '@/services/errors';
import { uid } from '@/database/repositories';

export interface RequestOpts {
  url: string;
  method?: string;
  headers?: Record<string, string>;
  json?: unknown;
  body?: string;
  multipart?: MultipartPart[];
  auth?: HttpAuth;
  responseType?: 'text' | 'base64' | 'file';
  saveTo?: string;
  timeoutSeconds?: number;
  signal?: AbortSignal;
  /** Provider label used in error messages. */
  provider?: string;
}

function extractErrorMessage(body: string | undefined): string {
  if (!body) return '';
  try {
    const j = JSON.parse(body);
    const m = j?.error?.message ?? j?.error?.msg ?? j?.message ?? j?.detail ?? j?.errors?.[0]?.message ?? j?.error ?? j?.msg;
    if (typeof m === 'string') return m;
    if (m) return JSON.stringify(m).slice(0, 300);
  } catch { /* not JSON */ }
  return body.slice(0, 300);
}

export function httpError(status: number, body: string | undefined, provider = 'The provider', headers: Record<string, string> = {}): ZinoError {
  const detail = scrubSecrets(extractErrorMessage(body));
  const suffix = detail ? ` (${detail})` : '';
  if (status === 401) return new ZinoError('INVALID_API_KEY', `${provider} rejected the API key${suffix}.`, { status });
  if (status === 403) return new ZinoError('INVALID_API_KEY', `${provider} denied access — the key may lack permission for this model or feature${suffix}.`, { status });
  if (status === 402) return new ZinoError('INSUFFICIENT_CREDITS', `${provider} reports insufficient credits or billing is not set up${suffix}.`, { status, recovery: ['open_settings_providers'] });
  if (status === 404) return new ZinoError('MODEL_NOT_FOUND', `${provider} could not find that model or endpoint${suffix}.`, { status, recovery: ['open_settings_providers'] });
  if (status === 408) return new ZinoError('NETWORK_TIMEOUT', `${provider} timed out${suffix}.`, { status });
  if (status === 413) return new ZinoError('REQUEST_TOO_LARGE', `The request was too large for ${provider}${suffix}.`, { status, recovery: ['reduce_context'] });
  if (status === 429) {
    const retry = headers['retry-after'];
    return new ZinoError('RATE_LIMITED', `${provider} rate limit reached${retry ? `; retry after ${retry}s` : ''}${suffix}.`, { status });
  }
  if (status >= 500) return new ZinoError('PROVIDER_UNAVAILABLE', `${provider} is having problems (HTTP ${status})${suffix}.`, { status });
  return new ZinoError('PROVIDER_REJECTED', `${provider} rejected the request (HTTP ${status})${suffix}.`, { status });
}

function build(o: RequestOpts, id: string, extra: Partial<HttpRequestOptions> = {}): HttpRequestOptions {
  const headers = { ...(o.headers ?? {}) };
  let body = o.body;
  if (o.json !== undefined) {
    headers['Content-Type'] = 'application/json';
    body = JSON.stringify(o.json);
  }
  return { id, url: o.url, method: o.method ?? (body || o.multipart ? 'POST' : 'GET'), headers, body, multipart: o.multipart, auth: o.auth,
    responseType: o.responseType, saveTo: o.saveTo, timeoutSeconds: o.timeoutSeconds, ...extra };
}

function linkAbort(signal: AbortSignal | undefined, id: string) {
  if (!signal) return () => {};
  if (signal.aborted) throw new ZinoError('CANCELLED', 'Cancelled.');
  const onAbort = () => { void ZinoHttp.cancel({ id }); };
  signal.addEventListener('abort', onAbort, { once: true });
  return () => signal.removeEventListener('abort', onAbort);
}

export async function request(o: RequestOpts): Promise<HttpResponse> {
  const id = uid();
  const unlink = linkAbort(o.signal, id);
  try {
    const res = await ZinoHttp.request(build(o, id));
    if (res.status < 200 || res.status >= 300) throw httpError(res.status, res.body, o.provider, res.headers);
    return res;
  } catch (e) {
    if (o.signal?.aborted) throw new ZinoError('CANCELLED', 'Cancelled.');
    throw toZinoError(e, 'NETWORK_ERROR');
  } finally {
    unlink();
  }
}

export async function requestJson<T = unknown>(o: RequestOpts): Promise<T> {
  const res = await request(o);
  try {
    return JSON.parse(res.body ?? 'null') as T;
  } catch {
    throw new ZinoError('PROVIDER_REJECTED', `${o.provider ?? 'The provider'} returned an unexpected (non-JSON) response.`);
  }
}

/** Incremental Server-Sent Events parser (also handles NDJSON when `ndjson` is true). */
export class SSEParser {
  private buf = '';
  private dataLines: string[] = [];
  private event: string | null = null;
  constructor(private readonly onEvent: (data: string, event: string | null) => void, private readonly ndjson = false) {}

  push(chunk: string) {
    this.buf += chunk;
    let nl: number;
    while ((nl = this.buf.indexOf('\n')) >= 0) {
      let line = this.buf.slice(0, nl);
      this.buf = this.buf.slice(nl + 1);
      if (line.endsWith('\r')) line = line.slice(0, -1);
      this.line(line);
    }
  }
  end() {
    if (this.buf) { this.line(this.buf); this.buf = ''; }
    this.line('');
  }
  private line(line: string) {
    if (this.ndjson) {
      if (line.trim()) this.onEvent(line, null);
      return;
    }
    if (line === '') {
      if (this.dataLines.length) this.onEvent(this.dataLines.join('\n'), this.event);
      this.dataLines = [];
      this.event = null;
      return;
    }
    if (line.startsWith(':')) return;
    const idx = line.indexOf(':');
    const field = idx < 0 ? line : line.slice(0, idx);
    let value = idx < 0 ? '' : line.slice(idx + 1);
    if (value.startsWith(' ')) value = value.slice(1);
    if (field === 'data') this.dataLines.push(value);
    else if (field === 'event') this.event = value;
  }
}

/** Streaming request: invokes onEvent for every SSE event. Resolves when the stream ends. */
export async function streamSSE(o: RequestOpts, onEvent: (data: string, event: string | null) => void): Promise<void> {
  const id = uid();
  const parser = new SSEParser(onEvent);
  const handle = await ZinoHttp.addListener('httpChunk', (e) => { if (e.id === id) parser.push(e.chunk); });
  const unlink = linkAbort(o.signal, id);
  try {
    const res = await ZinoHttp.request(build(o, id, { stream: true }));
    if (!res.streamed) {
      if (res.status < 200 || res.status >= 300) throw httpError(res.status, res.body, o.provider, res.headers);
      // Some servers ignore stream=true and send a normal body.
      if (res.body) { parser.push(res.body); }
    }
    parser.end();
  } catch (e) {
    if (o.signal?.aborted) throw new ZinoError('CANCELLED', 'Cancelled.');
    throw toZinoError(e, 'NETWORK_ERROR');
  } finally {
    unlink();
    await handle.remove();
  }
}

export const sleep = (ms: number, signal?: AbortSignal) =>
  new Promise<void>((resolve, reject) => {
    if (signal?.aborted) return reject(new ZinoError('CANCELLED', 'Cancelled.'));
    const t = setTimeout(resolve, ms);
    signal?.addEventListener('abort', () => { clearTimeout(t); reject(new ZinoError('CANCELLED', 'Cancelled.')); }, { once: true });
  });
