// Publisher sidecar: the only container with the GitHub App key. Claude never runs here.
// On an approved apply it squash-merges the Renovate PRs Claude picked, then guards the local diff, commits
// it, rebases onto the latest main, validates and pushes straight to main (the App bypasses the main
// ruleset, like a person at the desk). Localhost only.
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
const PUSH_ATTEMPTS = 3;
const CHECK = process.env.REQUIRED_CHECK ?? 'validate';
// The agent may change its own component; like everything else it only lands after a yes on the diff
const FORBIDDEN = /^(cluster\/flux-system\/|\.github\/|\.claude\/|components\/storage\/longhorn\/config\/restore\/)/;

type Job = { state: 'running' | 'pushed' | 'failed'; message: string; commitUrl?: string };
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

const git = async (cwd: string, ...args: string[]) =>
  (await exec('git', ['-c', 'safe.directory=*', '-c', 'user.name=claude-agent', '-c', 'user.email=claude-agent@users.noreply.github.com', ...args], { cwd, maxBuffer: 64 << 20 })).stdout;

async function github(method: string, path: string, body?: unknown, auth = true): Promise<any> {
  const res = await fetch(`https://api.github.com/repos/${REPO}${path}`, {
    method,
    headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'claude-agent', ...(auth ? { Authorization: `Bearer ${await installationToken()}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path}: ${res.status} ${text.slice(0, 300)}`);
  return text ? JSON.parse(text) : {};
}

// Only Renovate's own open PRs into main, and never one whose required check already failed
async function renovatePr(n: number): Promise<{ number: number; sha: string }> {
  const pr = await github('GET', `/pulls/${n}`);
  if (pr.state !== 'open' || pr.base.ref !== BRANCH || !String(pr.head.ref).startsWith('renovate/') || pr.head.repo?.full_name !== REPO || pr.user?.login !== 'renovate[bot]') {
    throw new Error(`#${n} is not an open Renovate PR into ${BRANCH}`);
  }
  const files = (await github('GET', `/pulls/${n}/files?per_page=100`)) as { filename: string }[];
  const forbidden = files.map((f) => f.filename).filter((f) => FORBIDDEN.test(f));
  if (forbidden.length) throw new Error(`#${n} touches protected paths: ${forbidden.join(', ')}`);
  // Public repo: check runs are readable without the token (whose permissions don't include checks)
  const runs = await github('GET', `/commits/${pr.head.sha}/check-runs?check_name=${CHECK}`, undefined, false);
  const failed = runs.check_runs?.find((r: any) => r.status === 'completed' && !['success', 'skipped', 'neutral'].includes(r.conclusion));
  if (failed) throw new Error(`#${n}: ${CHECK} ${failed.conclusion}`);
  return { number: n, sha: pr.head.sha };
}

// ── apply ───────────────────────────────────────────────────────────────────
// merge: Renovate PRs to squash-merge as they are. supersedes: Renovate PRs whose bump is part of the local
// change (with the edits it needed); they are closed once that change is on main.
async function apply(runId: string, repo: string, title: string, summary: string, merge: number[], supersedes: number[], job: Job): Promise<void> {
  const step = (message: string) => {
    job.message = message;
    console.log(`[apply ${runId}] ${message}`);
  };
  await git(repo, 'add', '--all');
  const files = (await git(repo, 'diff', '--cached', '--name-only')).split('\n').filter(Boolean);
  if (files.length === 0 && merge.length === 0) throw new Error('nothing to apply');
  if (files.length === 0 && supersedes.length) throw new Error('PRs to supersede but no change that includes them');
  const forbidden = files.filter((f) => FORBIDDEN.test(f));
  if (forbidden.length) throw new Error(`change touches protected paths: ${forbidden.join(', ')}`);
  const patch = await git(repo, 'diff', '--cached');
  if (/-----BEGIN [A-Z ]*PRIVATE KEY-----/.test(patch) || (cached && patch.includes(cached.token))) throw new Error('diff contains a credential');
  step('Checking the Renovate PRs');
  const toMerge = await Promise.all(merge.map(renovatePr));
  await Promise.all(supersedes.map(renovatePr));

  const merged: string[] = [];
  for (const pr of toMerge) {
    step(`Merging #${pr.number}`);
    // sha: refuse if Renovate pushed to the branch since the check above
    await github('PUT', `/pulls/${pr.number}/merge`, { merge_method: 'squash', sha: pr.sha }).catch((e) => {
      throw new Error(`${merged.length ? `merged ${merged.join(', ')}; ` : ''}#${pr.number} not merged: ${(e as Error).message}`);
    });
    merged.push(`#${pr.number}`);
  }
  if (files.length === 0) {
    job.commitUrl = `https://github.com/${REPO}/commits/${BRANCH}`;
    job.state = 'pushed';
    step(`Merged ${merged.join(', ')} into ${BRANCH}; Flux deploys them on its next sync.`);
    return;
  }

  const base = (await git(repo, 'rev-parse', 'HEAD')).trim();
  const closes = supersedes.length ? `\n\nSupersedes ${supersedes.map((n) => `#${n}`).join(', ')}.` : '';
  await git(repo, 'commit', '--quiet', '-m', `${title}\n\n${summary}${closes}\n\nApproved from ntfy, applied by the claude-agent service (run ${runId}).\n\nCo-Authored-By: Claude <noreply@anthropic.com>`);
  try {
    for (let attempt = 1; ; attempt++) {
      // Like `git pull --rebase` before a push: the backup bot, Renovate merges and people push to main too
      step(attempt === 1 ? `Rebasing onto the latest ${BRANCH}` : `${BRANCH} moved, rebasing again`);
      await git(repo, 'fetch', '--quiet', 'origin', BRANCH);
      await git(repo, 'rebase', '--quiet', 'FETCH_HEAD').catch(async (e) => {
        await git(repo, 'rebase', '--abort').catch(() => undefined);
        throw new Error(`conflicts with the latest ${BRANCH}; continue the run to redo the change. ${String(e.stdout ?? '').slice(0, 300)}`);
      });
      await exec('kubectl', ['kustomize', 'components'], { cwd: repo, maxBuffer: 256 << 20 });
      await exec('kubectl', ['kustomize', 'services'], { cwd: repo, maxBuffer: 256 << 20 });
      step(`Pushing to ${BRANCH}`);
      // The token is in the remote URL: never let git's error text (which echoes the command) escape
      const pushed = await git(repo, 'push', '--quiet', `https://x-access-token:${await installationToken()}@github.com/${REPO}.git`, `HEAD:refs/heads/${BRANCH}`)
        .then(() => true, (e) => {
          const err = String(e.stderr ?? '').replace(/x-access-token:[^@]+@/g, 'x-access-token:***@');
          if (attempt < PUSH_ATTEMPTS && /\[rejected\]|fetch first|non-fast-forward/.test(err)) return false;
          throw new Error(`git push failed: ${err.slice(0, 300)}`);
        });
      if (pushed) break;
    }
  } catch (e) {
    // Leave the change uncommitted on top of whatever HEAD is now, so a continued run sees it as its diff
    if ((await git(repo, 'rev-parse', 'HEAD')).trim() !== base) await git(repo, 'reset', '--quiet', '--soft', 'HEAD~1').catch(() => undefined);
    throw new Error(`${merged.length ? `merged ${merged.join(', ')}; ` : ''}${(e as Error).message}`);
  }

  const sha = (await git(repo, 'rev-parse', 'HEAD')).trim();
  job.commitUrl = `https://github.com/${REPO}/commit/${sha}`;
  job.state = 'pushed';
  for (const n of supersedes) {
    await github('POST', `/issues/${n}/comments`, { body: `Applied in ${sha} by the claude-agent service (run ${runId}), with the changes this update needed.` })
      .then(() => github('PATCH', `/pulls/${n}`, { state: 'closed' }))
      .catch((e) => console.error(`[apply ${runId}] closing #${n}: ${(e as Error).message}`));
  }
  step(`${merged.length ? `Merged ${merged.join(', ')}, then pushed` : 'Pushed'} ${sha.slice(0, 7)} to ${BRANCH}; Flux deploys it on its next sync.`);
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
    const { runId, repo, title, summary, merge, supersedes } = JSON.parse(raw || '{}');
    const prs = (v: unknown) => (Array.isArray(v) ? [...new Set(v.filter((n) => Number.isInteger(n) && n > 0))] as number[] : []);
    if (!/^[\w-]+$/.test(runId ?? '') || !resolve(String(repo ?? '/')).startsWith('/work/') || !title) return json(res, 400, { error: 'bad request' });
    if (jobs.get(runId)?.state === 'running') return json(res, 409, { error: 'already applying' });
    const job: Job = { state: 'running', message: 'Starting' };
    jobs.set(runId, job);
    apply(runId, resolve(repo), String(title).slice(0, 120), String(summary ?? ''), prs(merge), prs(supersedes), job).catch((e) => {
      job.state = 'failed';
      job.message = `Not applied: ${(e as Error).message}`;
      console.error(`[apply ${runId}] ${job.message}`);
    });
    return json(res, 202, job);
  }
  json(res, 404, { error: 'not found' });
}).listen(8081, '127.0.0.1', () => console.log(`[publisher] listening on 127.0.0.1:8081 repo=${REPO}`));
