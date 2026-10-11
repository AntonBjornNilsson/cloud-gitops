// claude-agent service: scheduler, run queue (one run at a time), web UI and the ntfy answer endpoint.
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { bus, getRun, listRuns, markInterrupted, newRunId, readEvents, saveRun, type Run, type RunEvent, type Tokens } from './store.ts';
import { answerById, answerByToken, cancelRun, listPending, type Answer } from './questions.ts';
import { execute, sendMessage } from './agent.ts';
import { cronMatches, validCron } from './cron.ts';
import { BASE_URL } from './ntfy.ts';
import { limits, meta, probe } from './meta.ts';
import { startUpdater, update } from './updater.ts';

const APP = new URL('.', import.meta.url).pathname;

// In-pod kubeconfig; the prompts map the skill's --context=<admin> to this context
const SA = '/var/run/secrets/kubernetes.io/serviceaccount';
const home = process.env.HOME ?? '/data/home';
mkdirSync(join(home, '.kube'), { recursive: true });
writeFileSync(join(home, '.kube', 'config'), `apiVersion: v1
kind: Config
clusters:
  - name: in-cluster
    cluster:
      server: https://kubernetes.default.svc
      certificate-authority: ${SA}/ca.crt
users:
  - name: claude-agent
    user:
      tokenFile: ${SA}/token
contexts:
  - name: in-cluster
    context:
      cluster: in-cluster
      user: claude-agent
current-context: in-cluster
`);

markInterrupted();

// ── queue ───────────────────────────────────────────────────────────────────
const queue: Run[] = [];
let current: { run: Run; abort: AbortController } | undefined;

function enqueue(fields: Pick<Run, 'kind' | 'trigger'> & Partial<Run>): Run {
  const run: Run = { id: newRunId(), createdAt: new Date().toISOString(), status: 'queued', ...fields };
  saveRun(run);
  queue.push(run);
  void pump();
  return run;
}

async function pump(): Promise<void> {
  if (current) return;
  const run = queue.shift();
  if (!run) return;
  current = { run, abort: new AbortController() };
  bus.emit('state');
  try {
    await execute(run, current.abort);
  } catch (e) {
    console.error(`[run ${run.id}]`, e);
  } finally {
    current = undefined;
    bus.emit('state');
    void pump();
  }
}

const isIdle = () => !current && queue.length === 0 && listPending().length === 0;

// ── scheduler ───────────────────────────────────────────────────────────────
type Schedule = { name: string; cron: string };
const SCHEDULES: Schedule[] = JSON.parse(process.env.SCHEDULES ?? '[{"name":"health","cron":"30 6,18 * * *"}]');
for (const s of SCHEDULES) if (!validCron(s.cron)) throw new Error(`invalid cron for ${s.name}: ${s.cron}`);
const lastFired = new Map<string, string>();
setInterval(() => {
  const now = new Date();
  const minute = now.toISOString().slice(0, 16);
  for (const s of SCHEDULES) {
    if (lastFired.get(s.name) === minute || !cronMatches(s.cron, now)) continue;
    lastFired.set(s.name, minute);
    // Don't pile up health reviews behind a run that is waiting for an answer
    const busy = [current?.run, ...queue].some((r) => r?.kind === 'health');
    if (busy) console.log(`[schedule] ${s.name}: a health review is already queued or running, skipping`);
    else enqueue({ kind: 'health', trigger: `schedule:${s.name}` });
  }
}, 15_000);

void probe();
setInterval(() => void probe(), 6 * 3600_000);
startUpdater(isIdle);

// ── views ───────────────────────────────────────────────────────────────────
function state() {
  return {
    current: current?.run.id ?? null,
    queued: queue.map((r) => r.id),
    pending: listPending(),
    limits,
    meta,
    update: { ...update, current: update.running && update.latest ? update.running === update.latest : null },
    schedules: SCHEDULES,
  };
}

// Daily token totals (UTC days) and per-model totals over the last 30 days
function usage() {
  const zero = (): Tokens & { cost: number; runs: number } => ({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, runs: 0 });
  const days: Record<string, ReturnType<typeof zero>> = {};
  for (let i = 29; i >= 0; i--) days[new Date(Date.now() - i * 86_400_000).toISOString().slice(0, 10)] = zero();
  const models: Record<string, Tokens> = {};
  for (const r of listRuns(5000)) {
    const day = days[(r.startedAt ?? r.createdAt).slice(0, 10)];
    if (!day || !r.usage) continue;
    day.runs++;
    day.cost += r.costUsd ?? 0;
    for (const k of ['input', 'output', 'cacheRead', 'cacheWrite'] as const) day[k] += r.usage[k];
    for (const [model, t] of Object.entries(r.usage.byModel ?? {})) {
      const m = (models[model] ??= { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 });
      for (const k of ['input', 'output', 'cacheRead', 'cacheWrite'] as const) m[k] += t[k];
    }
  }
  return { days: Object.entries(days).map(([day, v]) => ({ day, ...v })), models, limits };
}

// ── HTTP ────────────────────────────────────────────────────────────────────
const send = (res: ServerResponse, code: number, type: string, body: string | Buffer, headers: Record<string, string> = {}) => {
  res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store', ...headers });
  res.end(body);
};
const json = (res: ServerResponse, code: number, body: unknown) => send(res, code, 'application/json', JSON.stringify(body));

// Web assets from the ConfigMap, revalidated by ETag
const ASSETS: Record<string, string> = {
  '/app.js': 'text/javascript; charset=utf-8',
  '/app.css': 'text/css; charset=utf-8',
  '/favicon.svg': 'image/svg+xml',
  '/manifest.webmanifest': 'application/manifest+json',
};
function asset(req: IncomingMessage, res: ServerResponse, file: string, type: string): void {
  const body = readFileSync(join(APP, file));
  const etag = `"${createHash('sha1').update(body).digest('base64url').slice(0, 16)}"`;
  if (req.headers['if-none-match'] === etag) return send(res, 304, type, '', { ETag: etag, 'Cache-Control': 'no-cache' });
  send(res, 200, type, body, { ETag: etag, 'Cache-Control': 'no-cache' });
}

async function readJson(req: IncomingMessage): Promise<any> {
  let raw = '';
  for await (const chunk of req) {
    raw += chunk;
    if (raw.length > 100_000) throw new Error('body too large');
  }
  return raw ? JSON.parse(raw) : {};
}

// UI POSTs come from our own pages; reject cross-site requests that ride on the Authelia session
function sameOrigin(req: IncomingMessage): boolean {
  const origin = req.headers.origin;
  return !origin || !BASE_URL || origin === new URL(BASE_URL).origin;
}

// The ntfy web app runs action buttons as a cross-origin fetch, so /answer/ allows that origin only
const NTFY_ORIGIN = process.env.NTFY_WEB_URL ? new URL(process.env.NTFY_WEB_URL).origin : '';
function answerCors(req: IncomingMessage): Record<string, string> {
  if (!NTFY_ORIGIN || req.headers.origin !== NTFY_ORIGIN) return {};
  return {
    'Access-Control-Allow-Origin': NTFY_ORIGIN,
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Access-Control-Max-Age': '600',
    Vary: 'Origin',
  };
}

function stream(req: IncomingMessage, res: ServerResponse, runId?: string): void {
  res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', 'X-Accel-Buffering': 'no' });
  const onEvent = (id: string, ev: RunEvent) => {
    if (id === runId) res.write(`data: ${JSON.stringify(ev)}\n\n`);
  };
  const onRun = (run: Run) => {
    if (!runId || run.id === runId) res.write(`event: run\ndata: ${JSON.stringify(run)}\n\n`);
  };
  // State changes are frequent during a run; coalesce them
  let pendingState: NodeJS.Timeout | undefined;
  const onState = () => {
    pendingState ??= setTimeout(() => {
      pendingState = undefined;
      res.write(`event: state\ndata: ${JSON.stringify(state())}\n\n`);
    }, 300);
  };
  const ping = setInterval(() => res.write(': ping\n\n'), 25_000);
  bus.on('event', onEvent);
  bus.on('run', onRun);
  if (!runId) bus.on('state', onState);
  req.on('close', () => {
    clearInterval(ping);
    clearTimeout(pendingState);
    bus.off('event', onEvent);
    bus.off('run', onRun);
    bus.off('state', onState);
  });
}

function stop(id: string): boolean {
  if (current?.run.id === id) {
    cancelRun(id);
    current.abort.abort();
    return true;
  }
  const i = queue.findIndex((r) => r.id === id);
  if (i < 0) return false;
  const [run] = queue.splice(i, 1);
  saveRun({ ...run, status: 'stopped', endedAt: new Date().toISOString(), error: 'removed from the queue' });
  bus.emit('state');
  return true;
}

const pick = (v: unknown, allowed: string[]) => (typeof v === 'string' && allowed.includes(v) ? v : undefined);

createServer(async (req, res) => {
  try {
    const url = new URL(req.url ?? '/', 'http://localhost');
    const path = url.pathname;
    const get = req.method === 'GET';
    const post = req.method === 'POST';
    let m: RegExpMatchArray | null;

    if (get && path === '/healthz') return json(res, 200, { status: 'ok', running: current?.run.id ?? null, queued: queue.length });

    // ntfy action buttons (the only path the Ingress exposes without Authelia)
    if (path.startsWith('/answer/')) {
      const cors = answerCors(req);
      if (req.method === 'OPTIONS') return send(res, 204, 'text/plain', '', cors);
      if (post && (m = path.match(/^\/answer\/([\w-]+)\/(yes|no)$/))) {
        const r = answerByToken(m[1], m[2] as Answer);
        if (r.status === 'answered') return send(res, 200, 'text/plain', `Answered ${m[2]}.\n`, cors);
        if (r.status === 'already') return send(res, 409, 'text/plain', `Already answered: ${r.answer} (via ${r.by}).\n`, cors);
        return send(res, 410, 'text/plain', 'This question expired or the service restarted.\n', cors);
      }
    }

    if (get && ASSETS[path]) return asset(req, res, path.slice(1), ASSETS[path]);
    if (get && (path === '/' || path === '/new' || path === '/usage' || /^\/runs\/[\w-]+$/.test(path))) {
      return asset(req, res, 'index.html', 'text/html; charset=utf-8');
    }

    if (get && path === '/api/state') return json(res, 200, state());
    if (get && path === '/api/usage') return json(res, 200, usage());
    if (get && path === '/api/runs') return json(res, 200, listRuns(Number(url.searchParams.get('limit') ?? 200)));
    if (get && path === '/api/stream') return stream(req, res);
    if (get && (m = path.match(/^\/api\/runs\/([\w-]+)$/))) {
      const run = getRun(m[1]);
      return run ? json(res, 200, { run, events: readEvents(run.id) }) : json(res, 404, { error: 'not found' });
    }
    if (get && (m = path.match(/^\/api\/runs\/([\w-]+)\/stream$/))) return stream(req, res, m[1]);

    if (post && path.startsWith('/api/')) {
      if (!sameOrigin(req)) return json(res, 403, { error: 'cross-origin request' });
      if (path === '/api/runs') {
        const body = await readJson(req);
        const models = meta.models.map((x) => x.value);
        const model = pick(body.model, models) ?? (typeof body.model === 'string' && /^claude-[\w.-]+$/.test(body.model) ? body.model : undefined);
        const effort = pick(body.effort, ['low', 'medium', 'high', 'xhigh', 'max']);
        if (body.kind === 'health') return json(res, 201, enqueue({ kind: 'health', trigger: 'web', model, effort }));
        const prompt = String(body.prompt ?? '').trim();
        if (!prompt) return json(res, 400, { error: 'Write what Claude should do first.' });
        const prev = body.continueFrom ? getRun(String(body.continueFrom)) : undefined;
        if (body.continueFrom && !prev?.sessionId) return json(res, 400, { error: 'That run has no session to continue.' });
        if (prev && [current?.run, ...queue].some((r) => r?.workdir === prev.workdir || r?.continueFrom === prev.id)) {
          return json(res, 409, { error: 'That session is still in use.' });
        }
        return json(res, 201, enqueue({ kind: 'task', trigger: 'web', prompt, continueFrom: prev?.id, model: model ?? prev?.model, effort: effort ?? prev?.effort }));
      }
      if ((m = path.match(/^\/api\/runs\/([\w-]+)\/messages$/))) {
        const text = String((await readJson(req)).text ?? '').trim();
        if (!text) return json(res, 400, { error: 'Empty message.' });
        return sendMessage(m[1], text) ? json(res, 202, {}) : json(res, 409, { error: 'This session is not live any more; continue it instead.' });
      }
      if ((m = path.match(/^\/api\/runs\/([\w-]+)\/stop$/))) return json(res, stop(m[1]) ? 200 : 404, {});
      if ((m = path.match(/^\/api\/questions\/(\w+)\/(yes|no)$/))) {
        return json(res, answerById(m[1], m[2] as Answer) ? 200 : 404, {});
      }
    }
    send(res, 404, 'text/plain', 'Not found\n');
  } catch (e) {
    console.error('[http]', e);
    if (!res.headersSent) json(res, 500, { error: String((e as Error).message ?? e) });
  }
}).listen(Number(process.env.PORT ?? 8080), () => console.log(`[startup] claude-agent on :${process.env.PORT ?? 8080} base_url=${BASE_URL} schedules=${JSON.stringify(SCHEDULES)}`));
