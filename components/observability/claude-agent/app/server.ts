// claude-agent service: scheduler, run queue (one run at a time), web UI and the ntfy answer endpoint.
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { bus, getRun, listRuns, markInterrupted, newRunId, readEvents, saveRun, type Run, type RunEvent } from './store.ts';
import { answerById, answerByToken, cancelRun, type Answer } from './questions.ts';
import { execute } from './agent.ts';
import { cronMatches, validCron } from './cron.ts';
import { BASE_URL } from './ntfy.ts';
import { indexPage, runPage } from './ui.ts';

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

function enqueue(kind: Run['kind'], trigger: string, prompt?: string, continueFrom?: string): Run {
  const run: Run = { id: newRunId(), kind, trigger, prompt, continueFrom, createdAt: new Date().toISOString(), status: 'queued' };
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
  try {
    await execute(run, current.abort);
  } catch (e) {
    console.error(`[run ${run.id}]`, e);
  } finally {
    current = undefined;
    void pump();
  }
}

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
    else enqueue('health', `schedule:${s.name}`);
  }
}, 15_000);

// ── HTTP ────────────────────────────────────────────────────────────────────
const send = (res: ServerResponse, code: number, type: string, body: string, headers: Record<string, string> = {}) => {
  res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store', ...headers });
  res.end(body);
};

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
const json = (res: ServerResponse, code: number, body: unknown) => send(res, code, 'application/json', JSON.stringify(body));

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

function stream(req: IncomingMessage, res: ServerResponse, runId?: string): void {
  res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', 'X-Accel-Buffering': 'no' });
  const onEvent = (id: string, ev: RunEvent) => {
    if (id === runId) res.write(`data: ${JSON.stringify(ev)}\n\n`);
  };
  const onRun = (run: Run) => {
    if (!runId || run.id === runId) res.write(`event: run\ndata: ${JSON.stringify(run)}\n\n`);
  };
  const ping = setInterval(() => res.write(': ping\n\n'), 25_000);
  bus.on('event', onEvent);
  bus.on('run', onRun);
  req.on('close', () => {
    clearInterval(ping);
    bus.off('event', onEvent);
    bus.off('run', onRun);
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
  return true;
}

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
        const ok = answerByToken(m[1], m[2] as Answer);
        return send(res, ok ? 200 : 404, 'text/plain', ok ? `Answered ${m[2]}.\n` : 'Unknown or already answered.\n', cors);
      }
    }

    if (get && path === '/') return send(res, 200, 'text/html; charset=utf-8', indexPage(SCHEDULES));
    if (get && (m = path.match(/^\/runs\/([\w-]+)$/))) {
      const run = getRun(m[1]);
      return run ? send(res, 200, 'text/html; charset=utf-8', runPage(run)) : send(res, 404, 'text/plain', 'Not found\n');
    }
    if (get && path === '/api/runs') return json(res, 200, listRuns(Number(url.searchParams.get('limit') ?? 100)));
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
        if (body.kind === 'health') return json(res, 201, enqueue('health', 'web'));
        const prompt = String(body.prompt ?? '').trim();
        if (!prompt) return json(res, 400, { error: 'prompt is required' });
        const prev = body.continueFrom ? getRun(String(body.continueFrom)) : undefined;
        if (body.continueFrom && !prev?.sessionId) return json(res, 400, { error: 'that run has no session to continue' });
        if (prev && [current?.run, ...queue].some((r) => r?.workdir === prev.workdir || r?.continueFrom === prev.id)) {
          return json(res, 409, { error: 'that session is still in use' });
        }
        return json(res, 201, enqueue('task', 'web', prompt, prev?.id));
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
