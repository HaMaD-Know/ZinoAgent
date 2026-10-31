// Lets services ask the user for confirmation or show notices without depending on React.
// The App component installs the real handlers; tests install their own.

export interface ConfirmRequest {
  title: string;
  message: string;
  details?: string[];
  confirmLabel?: string;
  cancelLabel?: string;
  destructive?: boolean;
}

export type ToastKind = 'info' | 'success' | 'warning' | 'error';
export interface Toast { id: string; kind: ToastKind; message: string; action?: { label: string; run: () => void } }

type ConfirmHandler = (req: ConfirmRequest) => Promise<boolean>;
type ToastHandler = (t: Toast) => void;

let confirmHandler: ConfirmHandler = async () => false; // safe default: never auto-approve
let toastHandler: ToastHandler = () => {};

export const uiBridge = {
  setConfirmHandler(h: ConfirmHandler) { confirmHandler = h; },
  setToastHandler(h: ToastHandler) { toastHandler = h; },
  confirm(req: ConfirmRequest) { return confirmHandler(req); },
  toast(kind: ToastKind, message: string, action?: Toast['action']) {
    toastHandler({ id: `${Date.now()}-${Math.random().toString(36).slice(2, 7)}`, kind, message, action });
  },
};
