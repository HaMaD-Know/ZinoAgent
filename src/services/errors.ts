// Error model: every failure surfaces a stable code, a human message and recovery actions.
// Messages never include secrets (native code scrubs them; we scrub again defensively).

export type RecoveryAction =
  | 'open_settings_providers'
  | 'check_api_key'
  | 'retry'
  | 'retry_later'
  | 'choose_smaller_model'
  | 'reduce_context'
  | 'free_storage'
  | 'unload_models'
  | 'reauthorize_folder'
  | 'redownload'
  | 'use_cloud_with_permission'
  | 'open_models';

export class ZinoError extends Error {
  readonly code: string;
  readonly recovery: RecoveryAction[];
  readonly status?: number;
  readonly details?: unknown;

  constructor(code: string, message: string, opts: { recovery?: RecoveryAction[]; status?: number; details?: unknown; cause?: unknown } = {}) {
    super(message);
    this.name = 'ZinoError';
    this.code = code;
    this.recovery = opts.recovery ?? defaultRecovery(code);
    this.status = opts.status;
    this.details = opts.details;
    if (opts.cause !== undefined) (this as { cause?: unknown }).cause = opts.cause;
  }
}

export function defaultRecovery(code: string): RecoveryAction[] {
  switch (code) {
    case 'INVALID_API_KEY':
    case 'MISSING_API_KEY':
      return ['check_api_key', 'open_settings_providers'];
    case 'RATE_LIMITED':
      return ['retry_later'];
    case 'NETWORK_OFFLINE':
    case 'NETWORK_TIMEOUT':
    case 'NETWORK_UNREACHABLE':
    case 'NETWORK_ERROR':
    case 'PROVIDER_UNAVAILABLE':
      return ['retry'];
    case 'INSUFFICIENT_MEMORY':
      return ['unload_models', 'choose_smaller_model', 'reduce_context'];
    case 'CONTEXT_FULL':
      return ['reduce_context'];
    case 'INSUFFICIENT_STORAGE':
      return ['free_storage'];
    case 'MODEL_LOAD_FAILED':
    case 'UNSUPPORTED_MODEL':
      return ['choose_smaller_model', 'open_models'];
    case 'DOWNLOAD_CORRUPT':
    case 'CHECKSUM_MISMATCH':
      return ['redownload'];
    case 'FOLDER_NOT_AUTHORIZED':
    case 'FOLDER_ACCESS_LOST':
    case 'PERMISSION_DENIED':
      return ['reauthorize_folder'];
    default:
      return [];
  }
}

export const RECOVERY_LABELS: Record<RecoveryAction, string> = {
  open_settings_providers: 'Open provider settings',
  check_api_key: 'Check the API key',
  retry: 'Try again',
  retry_later: 'Wait and try again',
  choose_smaller_model: 'Choose a smaller model',
  reduce_context: 'Reduce context length',
  free_storage: 'Free up storage',
  unload_models: 'Unload other models',
  reauthorize_folder: 'Choose the folder again',
  redownload: 'Download again',
  use_cloud_with_permission: 'Use a cloud model (asks first)',
  open_models: 'Open Models',
};

/** Normalise anything thrown (Capacitor errors carry `.code`) into a ZinoError. */
export function toZinoError(err: unknown, fallbackCode = 'UNKNOWN_ERROR'): ZinoError {
  if (err instanceof ZinoError) return err;
  if (err && typeof err === 'object') {
    const e = err as { code?: unknown; message?: unknown; errorMessage?: unknown };
    const code = typeof e.code === 'string' && e.code ? e.code : fallbackCode;
    const message = typeof e.message === 'string' && e.message
      ? e.message
      : typeof e.errorMessage === 'string' ? e.errorMessage : 'Something went wrong.';
    if (code === 'CANCELLED' || /abort/i.test(String((err as Error).name ?? ''))) {
      return new ZinoError('CANCELLED', 'Cancelled.', { cause: err });
    }
    return new ZinoError(code, scrubSecrets(message), { cause: err });
  }
  return new ZinoError(fallbackCode, scrubSecrets(String(err)));
}

const SECRET_PATTERNS = [
  /sk-[A-Za-z0-9_-]{12,}/g, // OpenAI / Anthropic style
  /AIza[0-9A-Za-z_-]{20,}/g, // Google API keys
  /msy_[A-Za-z0-9]{12,}/g,
  /Bearer\s+[A-Za-z0-9._-]{12,}/gi,
  /key=[A-Za-z0-9._-]{16,}/gi,
];

export function scrubSecrets(text: string): string {
  let out = text;
  for (const p of SECRET_PATTERNS) out = out.replace(p, '••••');
  return out;
}

export function isCancelled(err: unknown): boolean {
  return err instanceof ZinoError ? err.code === 'CANCELLED' : toZinoError(err).code === 'CANCELLED';
}
