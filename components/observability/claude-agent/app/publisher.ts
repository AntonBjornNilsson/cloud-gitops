// Publisher sidecar: the only container with the GitHub App key. Claude never runs here.
// On an approved apply it guards the diff, pushes a branch, opens a PR, waits for the required
// `validate` check and squash-merges. Listens on localhost only.
import { createServer } from 'node:http';
import { createSign } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const exec = promisify(execFile);
const REPO = process.env.GITHUB_REPO ?? '';
const BRANCH = process.env.GITHUB_BRANCH ?? 'main';
const APP_DIR = process.env.GITHUB_APP_DIR ?? '/etc/github-app';
const CHECK = process.env.REQUIRED_CHECK ?? 'validate';
const CHECK_TIMEOUT_MS = 20 * 60_000;
const FORBIDDEN = /^(cluster\/flux-system\/|\.github\/|\.claude\/|components\/storage\/longhorn\/config\/restore\/|components\/observability\/claude-agent\/)/;

type Job = { state: 'running' | 'merged' | 'failed'; message: string; prUrl?: string };
const jobs = new Map<string, Job>();

// ── GitHub App installation token (valid 1h, cached for 50 min) ─────────────
let cached: { token: string; until: number } | undefined;
const b64url = (b: Buffer | string) => Buffer.from(b).toString('base64url');

async function installationToken(): Promise<string> {
  if (cached && cached.until > Date.now()) return cached.token;
  const now = Math.floor(Date.now() / 1000);
  const appId = readFileSync(`${APP_DIR}/app-id`, 'utf8').trim();
  const body = `${b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))}.${b64url(JSON.stringify({ iat: now - 60, exp: now + 540, iss: appId }))}`;
  const jwt = `${body}.${b64url(createSign('RSA-SHA256').update(body).sign(readFileSync(`${APP_DIR}/private-key`, 'utf8')))}`;
  const installation = readFileSync(`${APP_DIR}/installation-id`, 'utf8').trim();
  const res = await fetch(`https://api.github.com/app/installations/${installation}/access_tokens`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${jwt}`, Accept: 'application/vnd.github+json' },
    body: JSON.stringify({ repositories: [REPO.split('/')[1]], permissions: { contents: 'write', pull_requests: 'write' } }),
  });
  if (!res.ok) throw new Error(`token exchange failed: ${res.status} ${await res.text()}`);
  cached = { token: ((await res.json()) as { token: string }).token, until: Date.now() + 50 * 60_000 };
  return cached.token;
}

async function github(method: string, path: string, body?: unknown, auth = true): Promise<any> {
  const res = await fetch(`https://api.github.com/repos/${REPO}${path}`, {
    method,
    headers: {
      Accept: 'application/vnd.github+json',
      'User-Agent': 'claude-agent',
      ...(auth ? { Authorization: `Bearer ${await installationToken()}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  if (!res.ok) throw Object.assign(new Error(`${method} ${path}: ${res.status} ${text.slice(0, 300)}`), { status: res.status });
  return text ? JSON.parse(text) : {};
}

const git = async (cwd: string, ...args: string[]) =>
  (await exec('git', ['-c', 'safe.directory=*', '-c', 'user.name=claude-agent', '-c', 'user.email=claude-agent@users.noreply.github.com', ...args], { cwd, maxBuffer: 64 << 20 })).stdout;

// ── apply ───────────────────────────────────────────────────────────────────
async function apply(runId: string, repo: string, kind: string, title: string, summary: string, job: Job): Promise<void> {
  const step = (message: string) => {
    job.message = message;
    console.log(`[apply ${runId}] ${message}`);
  };
  await git(repo, 'add', '--all');
  const files = (await git(repo, 'diff', '--cached', '--name-only')).split('\n').filter(Boolean);
  if (files.length === 0) throw new Error('nothing to apply');
  const forbidden = files.filter((f) => FORBIDDEN.test(f));
  if (forbidden.length) throw new Error(`change touches protected paths: ${forbidden.join(', ')}`);
  const patch = await git(repo, 'diff', '--cached');
  if (/-----BEGIN [A-Z ]*PRIVATE KEY-----/.test(patch) || (cached && patch.includes(cached.token))) throw new Error('diff contains a credential');
  await exec('kubectl', ['kustomize', 'components'], { cwd: repo, maxBuffer: 256 << 20 });
  await exec('kubectl', ['kustomize', 'services'], { cwd: repo, maxBuffer: 256 << 20 });

  const branch = `claude/${kind}-${runId}`;
  step(`Pushing ${branch}`);
  await git(repo, 'switch', '--quiet', '-C', branch);
  await git(repo, 'commit', '--quiet', '-m', `${title}\n\nApproved from ntfy, applied by the claude-agent service (run ${runId}).\n\nCo-Authored-By: Claude <noreply@anthropic.com>`);
  // The token is in the remote URL: never let git's error text (which echoes the command) escape
  await git(repo, 'push', '--quiet', '--force', `https://x-access-token:${await installationToken()}@github.com/${REPO}.git`, `HEAD:refs/heads/${branch}`)
    .catch((e) => {
      throw new Error(`git push failed: ${String(e.stderr ?? '').replace(/x-access-token:[^@]+@/g, 'x-access-token:***@').slice(0, 300)}`);
    });
  const sha = (await git(repo, 'rev-parse', 'HEAD')).trim();

  const pr = await github('POST', '/pulls', {
    title,
    head: branch,
    base: BRANCH,
    body: `${summary}\n\n---\n_Approved from ntfy and merged automatically by the claude-agent service once \`${CHECK}\` passes._\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)`,
  });
  job.prUrl = pr.html_url;
  step(`PR #${pr.number} opened, waiting for the ${CHECK} check`);

  // Public repo: check runs are readable without the token (whose permissions don't include checks)
  const deadline = Date.now() + CHECK_TIMEOUT_MS;
  let conclusion: string | null = null;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 30_000));
    const runs = await github('GET', `/commits/${sha}/check-runs?check_name=${CHECK}`, undefined, false).catch(() => ({ check_runs: [] }));
    const run = runs.check_runs?.[0];
    if (run?.status === 'completed') {
      conclusion = run.conclusion;
      break;
    }
  }
  if (conclusion !== 'success') throw new Error(`${CHECK} ${conclusion ?? 'did not finish in time'}; PR #${pr.number} left open: ${pr.html_url}`);

  await github('PUT', `/pulls/${pr.number}/merge`, { merge_method: 'squash', commit_title: `${title} (#${pr.number})` });
  await github('DELETE', `/git/refs/heads/${branch}`).catch(() => undefined);
  // Later changes in a continued run start from the merged main, not from this branch
  await git(repo, 'fetch', '--quiet', '--depth', '50', 'origin', BRANCH);
  await git(repo, 'switch', '--quiet', '-C', BRANCH, 'FETCH_HEAD');
  job.state = 'merged';
  step(`PR #${pr.number} merged into ${BRANCH}; Flux deploys it on its next sync.`);
}

// ── HTTP ────────────────────────────────────────────────────────────────────
const json = (res: import('node:http').ServerResponse, code: number, body: unknown) => {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
};

createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', 'http://localhost');
  if (req.method === 'GET' && url.pathname === '/healthz') return json(res, 200, { status: 'ok' });
  const m = url.pathname.match(/^\/apply\/([\w-]+)$/);
  if (req.method === 'GET' && m) return json(res, jobs.has(m[1]) ? 200 : 404, jobs.get(m[1]) ?? { state: 'failed', message: 'unknown run' });
  if (req.method === 'POST' && url.pathname === '/apply') {
    let raw = '';
    for await (const chunk of req) raw += chunk;
    const { runId, repo, kind, title, summary } = JSON.parse(raw || '{}');
    if (!/^[\w-]+$/.test(runId ?? '') || !resolve(String(repo ?? '/')).startsWith('/work/') || !title) return json(res, 400, { error: 'bad request' });
    if (jobs.get(runId)?.state === 'running') return json(res, 409, { error: 'already applying' });
    const job: Job = { state: 'running', message: 'Starting' };
    jobs.set(runId, job);
    apply(runId, resolve(repo), /^(health|task)$/.test(kind) ? kind : 'task', String(title).slice(0, 120), String(summary ?? ''), job).catch((e) => {
      job.state = 'failed';
      job.message = `Not applied: ${(e as Error).message}`;
      console.error(`[apply ${runId}] ${job.message}`);
    });
    return json(res, 202, job);
  }
  json(res, 404, { error: 'not found' });
}).listen(8081, '127.0.0.1', () => console.log(`[publisher] listening on 127.0.0.1:8081 repo=${REPO}`));
