/**
 * Typed wrappers around `citron.invoke()` for Guava Editor system operations.
 *
 * These call the Citron CEF backend directly — no WebSocket, no engine.
 * Categories: launcher, viewport, fs, build, popout, misc.
 *
 * When running in a normal browser (citron global absent), a lightweight
 * stub is injected so the editor can boot into editor mode directly.
 */

declare const citron: {
  invoke(method: string, params?: Record<string, unknown>): Promise<unknown>;
  on(event: string, callback: (...args: unknown[]) => void): () => void;
};

/** True when running inside the Citron CEF shell. */
export const isCitron: boolean = typeof citron !== 'undefined';

// Browser polyfill: stub out `citron` so the rest of the module can call
// citron.invoke / citron.on without guards everywhere.
if (!isCitron) {
  const noop = () => () => {};
  const stubs: Record<string, () => unknown> = {
    'launcher.getAppMode': () => 'editor',
    'launcher.getRecentProjects': () => [],
    'launcher.getTemplates': () => [],
  };
  (globalThis as Record<string, unknown>).citron = {
    invoke(method: string) {
      const stub = stubs[method];
      if (stub) return Promise.resolve(stub());
      return Promise.reject(new Error(`[citron-stub] ${method} not available in browser`));
    },
    on: noop,
  };
}

type CommandResult = { ok: boolean; error?: string };

function normalizeCommandResult(result: unknown): CommandResult {
  if (result && typeof result === 'object') {
    const record = result as Record<string, unknown>;
    if (typeof record.ok === 'boolean') {
      return {
        ok: record.ok,
        error: typeof record.error === 'string' ? record.error : undefined,
      };
    }
    if (typeof record.error === 'string') {
      return { ok: false, error: record.error };
    }
  }

  return { ok: true };
}

// ── Platform ──

export const platform: string = (() => {
  const p = (navigator.platform || '').toLowerCase();
  if (p.includes('mac')) return 'darwin';
  if (p.includes('win')) return 'win32';
  return 'linux';
})();

// ── Launcher / Project ──

export async function getAppMode(): Promise<string> {
  return citron.invoke('launcher.getAppMode') as Promise<string>;
}

export function getRecentProjects() {
  return citron.invoke('launcher.getRecentProjects');
}

export function removeRecentProject(projectPath: string) {
  return citron.invoke('launcher.removeRecentProject', { projectPath });
}

export function getTemplates() {
  return citron.invoke('launcher.getTemplates');
}

export async function openProject(projectPath: string): Promise<CommandResult> {
  const result = await citron.invoke('launcher.openProject', { projectPath });
  return normalizeCommandResult(result);
}

export async function createProject(projectPath: string, projectName: string, templateId?: string): Promise<CommandResult> {
  const result = await citron.invoke('launcher.createProject', { projectPath, projectName, templateId });
  return normalizeCommandResult(result);
}

// ── Dialog ──

export async function browseFolder(): Promise<string | null> {
  try {
    const result = await citron.invoke('dialog.open', { directory: true, multiple: false, title: 'Select Folder' }) as { paths?: string[] };
    return result?.paths?.[0] ?? null;
  } catch (e: unknown) {
    if (e && typeof e === 'object' && 'name' in e && (e as { name: string }).name === 'DialogCancelled') return null;
    throw e;
  }
}

// ── Viewport (IOSurface overlay) ──

export function viewportAttachSurface(surfaceId: number, x: number, y: number, w: number, h: number, shmName?: string) {
  return citron.invoke('viewport.attachSurface', { surfaceId, x, y, w, h, shmName });
}

export function viewportUpdateSurface(surfaceId: number, shmName?: string, width?: number, height?: number) {
  return citron.invoke('viewport.updateSurface', { surfaceId, shmName, width, height });
}

export function viewportDetach() {
  return citron.invoke('viewport.detach');
}

export function viewportUpdateBounds(x: number, y: number, w: number, h: number) {
  citron.invoke('viewport.updateBounds', { x, y, w, h }).catch(() => {});
}

export function viewportUpdateExclusions(rects: number[][]) {
  citron.invoke('viewport.updateExclusions', { rects }).catch(() => {});
}

export function onViewportOverlayActive(cb: (active: unknown) => void) {
  return citron.on('viewport.overlayActive', cb);
}

export function onViewportPixels(cb: (pixels: unknown, width: unknown, height: unknown) => void) {
  return citron.on('viewport.pixels', (data: unknown) => {
    const d = data as { pixels: unknown; width: unknown; height: unknown };
    cb(d.pixels, d.width, d.height);
  });
}

export function onViewportSharedBuffer(cb: (sab: unknown) => void) {
  return citron.on('viewport.sharedBuffer', cb);
}

// ── Filesystem ──

export function fsMkdir(relativePath: string) {
  return citron.invoke('fs.mkdir', { path: relativePath });
}

export function fsRename(oldPath: string, newPath: string) {
  return citron.invoke('fs.rename', { oldPath, newPath });
}

export function fsDelete(relativePath: string) {
  return citron.invoke('fs.delete', { path: relativePath });
}

export function fsCreateFile(relativePath: string, content?: string) {
  return citron.invoke('fs.createFile', { path: relativePath, content });
}

async function importPaths(targetRelDir: string, sourcePaths: string[]) {
  return citron.invoke('fs.importPaths', { targetDir: targetRelDir, sourcePaths });
}

export async function fsImportFiles(targetRelDir: string) {
  try {
    const result = await citron.invoke('dialog.open', { multiple: true, directory: false, title: 'Import Assets' }) as { paths?: string[] };
    const paths = result?.paths ?? [];
    if (paths.length === 0) return { ok: true, files: [], canceled: true };
    return importPaths(targetRelDir, paths);
  } catch (e: unknown) {
    if (e && typeof e === 'object' && 'name' in e && (e as { name: string }).name === 'DialogCancelled') {
      return { ok: true, files: [], canceled: true };
    }
    throw e;
  }
}

export function fsImportPaths(targetRelDir: string, sourcePaths: string[]) {
  return importPaths(targetRelDir, sourcePaths);
}

export function onImportProgress(cb: (progress: unknown) => void) {
  return citron.on('fs.importProgress', cb);
}

// ── Build ──

export async function buildPackage(opts?: Record<string, unknown>) {
  const options = { ...(opts ?? {}) } as Record<string, unknown>;
  if (options.choosePath) {
    const folder = await browseFolder();
    if (!folder) return { ok: false, error: 'Cancelled' };
    options.outputDir = folder;
    delete options.choosePath;
  }
  return citron.invoke('build.package', options);
}

export function cancelBuild() {
  return citron.invoke('build.cancel');
}

export function runBuiltGame(appPath?: string) {
  return citron.invoke('build.run', { appPath });
}

export function onBuildProgress(cb: (progress: unknown) => void) {
  return citron.on('build.progress', cb);
}

// ── Popout windows ──

export async function popoutPanel(panels: string[], state?: unknown, originInfo?: unknown, bounds?: unknown): Promise<number> {
  try {
    const panelId = Array.isArray(panels) ? panels.join(',') : panels;
    const url = `${window.location.origin}${window.location.pathname}?popout=${encodeURIComponent(panelId)}`;
    const result = await citron.invoke('window.create', {
      url,
      title: `Guava — ${panelId}`,
      width: 800,
      height: 600,
    });
    return result ? 1 : -1;
  } catch {
    return -1;
  }
}

export function closePopout() {
  if (new URLSearchParams(window.location.search).has('popout')) {
    citron.invoke('window.close');
  }
}

export function isPopoutWindow(): boolean {
  return new URLSearchParams(window.location.search).has('popout');
}

export function getPopoutPanels(): string[] {
  return [];
}

export function onPopoutClosed(_cb: (panels: string[], originInfo?: unknown, bounds?: unknown) => void): () => void {
  return () => {};
}

export function onInitState(_cb: (state: unknown) => void): () => void {
  return () => {};
}

// ── Status (merged engine + launcher) ──

export function onStatusChanged(cb: (status: unknown) => void) {
  return citron.on('engine.statusChanged', cb);
}
