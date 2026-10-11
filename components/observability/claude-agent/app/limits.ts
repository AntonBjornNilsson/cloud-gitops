// claude.ai plan limits: utilization per window from the SDK's usage call, plus status changes from
// rate-limit events. The service never runs into a limit: no new run starts at PAUSE_AT percent, and a
// running session is stopped at STOP_AT. The windows are shared with the user's own Claude usage,
// hence the margin below 100%. Extra (paid) usage is never used.
import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { bus, DATA } from './store.ts';

export const PAUSE_AT = Number(process.env.LIMIT_PAUSE_PERCENT ?? 80);
export const STOP_AT = Number(process.env.LIMIT_STOP_PERCENT ?? 90);

export type Limit = { type: string; label: string; utilization?: number; resetsAt?: number; status?: string; updatedAt: string };
export type Extra = { enabled?: boolean; inUse?: boolean; utilization?: number; updatedAt?: string };
type Saved = { limits: Record<string, Limit>; extra: Extra; readAt?: string };

const FILE = join(DATA, 'limits.json');
const saved: Saved = (() => {
  try {
    const s = existsSync(FILE) ? JSON.parse(readFileSync(FILE, 'utf8')) : {};
    // Older files held only the limit map
    return s.limits ? s : { limits: {}, extra: {} };
  } catch {
    return { limits: {}, extra: {} };
  }
})();
export const limits = saved.limits;
export const extra = saved.extra;

const LABELS: Record<string, string> = {
  five_hour: '5-hour',
  seven_day: 'Weekly',
  seven_day_opus: 'Weekly (Opus)',
  seven_day_sonnet: 'Weekly (Sonnet)',
  seven_day_oauth_apps: 'Weekly (apps)',
};

function persist(): void {
  writeFileSync(FILE + '.tmp', JSON.stringify(saved));
  renameSync(FILE + '.tmp', FILE);
  bus.emit('state');
}

// From Query.usage_EXPERIMENTAL...(): utilization is a percentage, resets_at an ISO time
export function recordUsage(res: any): boolean {
  const rl = res?.rate_limits;
  if (!res?.rate_limits_available || !rl) return false;
  const now = new Date().toISOString();
  const put = (key: string, label: string, w: any) => {
    if (!w || w.utilization == null) return;
    limits[key] = { ...limits[key], type: key, label, utilization: Number(w.utilization), resetsAt: w.resets_at ? Date.parse(w.resets_at) : undefined, updatedAt: now };
  };
  for (const key of Object.keys(LABELS)) put(key, LABELS[key], rl[key]);
  for (const m of rl.model_scoped ?? []) put(`model:${m.display_name}`, `Weekly (${m.display_name})`, m);
  if (rl.extra_usage) {
    Object.assign(extra, { enabled: !!rl.extra_usage.is_enabled, utilization: rl.extra_usage.utilization ?? undefined, updatedAt: now });
  }
  // Extra usage only kicks in past 100% of a window; once every window is below that, it is not in use
  if (Object.values(limits).every((l) => (l.utilization ?? 0) < 100)) extra.inUse = false;
  saved.readAt = now;
  persist();
  return true;
}

// From rate_limit_event messages during a run: status always, utilization (a fraction) sometimes
export function recordEvent(info: any): void {
  const type = info?.rateLimitType ?? 'unknown';
  const prev = limits[type];
  const u = typeof info?.utilization === 'number' ? (info.utilization <= 1 ? info.utilization * 100 : info.utilization) : prev?.utilization;
  limits[type] = {
    type,
    label: LABELS[type] ?? (type === 'overage' ? 'Extra usage' : type),
    status: info?.status,
    utilization: u,
    resetsAt: info?.resetsAt ? info.resetsAt * 1000 : prev?.resetsAt,
    updatedAt: new Date().toISOString(),
  };
  if (info?.isUsingOverage || info?.overageInUse) extra.inUse = true;
  persist();
}

export const readAge = () => (saved.readAt ? Date.now() - Date.parse(saved.readAt) : Infinity);

export type Verdict = { ok: true } | { ok: false; reason: string; until?: number };

// Windows past their reset time no longer count
export function check(threshold: number): Verdict {
  if (extra.inUse) return { ok: false, reason: 'extra (paid) usage is in use' };
  const now = Date.now();
  const live = Object.values(limits).filter((l) => !l.resetsAt || l.resetsAt > now);
  for (const l of live) {
    if (l.status === 'rejected') return { ok: false, reason: `${l.label} limit reached`, until: l.resetsAt };
    if (l.utilization != null && l.utilization >= threshold) return { ok: false, reason: `${l.label} limit at ${Math.round(l.utilization)}%`, until: l.resetsAt };
  }
  // Without any percentages, the SDK's own warning status is the signal
  if (!live.some((l) => l.utilization != null)) {
    const warn = live.find((l) => l.status === 'allowed_warning');
    if (warn) return { ok: false, reason: `${warn.label} limit is close`, until: warn.resetsAt };
  }
  return { ok: true };
}
