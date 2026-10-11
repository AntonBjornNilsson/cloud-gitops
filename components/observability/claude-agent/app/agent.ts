// One agent run: prepare a repo clone, run Claude with the permission hook, then offer the diff for apply.
import { query, tool, createSdkMcpServer, type CanUseTool, type PermissionResult } from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { existsSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs';
import { isAbsolute, join, relative, resolve } from 'node:path';
import { appendEvent, getRun, saveRun, type Report, type Run } from './store.ts';
import { ask } from './questions.ts';
import { checkCommand } from './policy.ts';
import { clip, notify, runUrl } from './ntfy.ts';

const exec = promisify(execFile);
const APP = new URL('.', import.meta.url).pathname;
const WORK = process.env.WORK_DIR ?? '/work';
const REPO = process.env.GITHUB_REPO ?? '';
const BRANCH = process.env.GITHUB_BRANCH ?? 'main';
const MODEL = process.env.CLAUDE_MODEL ?? 'claude-sonnet-5-5';
const MAX_TURNS = Number(process.env.CLAUDE_MAX_TURNS ?? 80);
const PUBLISHER = process.env.PUBLISHER_URL ?? 'http://127.0.0.1:8081';
const KEEP_WORKDIRS = 10;
const MAX_OUTPUT = 20_000;

// Tools that never change anything outside the session
const SAFE_TOOLS = new Set(['Read', 'Glob', 'Grep', 'LS', 'TodoWrite', 'Task', 'Agent', 'Skill', 'ToolSearch', 'NotebookRead']);
const EDIT_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit']);

const git = async (cwd: string, ...args: string[]) =>
  (await exec('git', ['-c', 'safe.directory=*', ...args], { cwd, maxBuffer: 64 << 20 })).stdout;

function update(run: Run, patch: Partial<Run>): Run {
  Object.assign(run, patch);
  saveRun(run);
  return run;
}

async function prepareWorkdir(run: Run): Promise<string> {
  const prev = run.continueFrom ? getRun(run.continueFrom) : undefined;
  // A continued session must keep its working directory: the transcript is stored per path
  const dir = prev?.workdir ?? join(WORK, run.id);
  const repo = join(dir, 'repo');
  if (!existsSync(join(repo, '.git'))) {
    rmSync(dir, { recursive: true, force: true });
    await exec('git', ['clone', '--quiet', '--depth', '50', '--branch', BRANCH, `https://github.com/${REPO}.git`, repo]);
  }
  const dirs = readdirSync(WORK).map((d) => join(WORK, d)).filter((d) => d !== dir && statSync(d).isDirectory())
    .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs);
  for (const old of dirs.slice(KEEP_WORKDIRS - 1)) rmSync(old, { recursive: true, force: true });
  update(run, { workdir: dir });
  return repo;
}

async function openPrList(prefix: string): Promise<string> {
  try {
    const res = await fetch(`https://api.github.com/repos/${REPO}/pulls?state=open&per_page=100`, { signal: AbortSignal.timeout(15_000) });
    const prs = (await res.json()) as { number: number; title: string; head: { ref: string } }[];
    const lines = prs.filter((p) => p.head.ref.startsWith(prefix)).map((p) => `- #${p.number} ${p.title}`);
    return lines.length ? lines.join('\n') : '(none)';
  } catch {
    return '(could not list)';
  }
}

async function buildPrompt(run: Run): Promise<string> {
  if (run.kind === 'task') return run.prompt ?? '';
  return `${readFileSync(join(APP, 'health.md'), 'utf8')}\n\nOpen Renovate update PRs:\n${await openPrList('renovate/')}`;
}

function describeTool(name: string, input: Record<string, unknown>): { title: string; detail: string } {
  if (name === 'Bash') {
    const cmd = String(input.command ?? '');
    const why = input.description ? `${input.description}\n\n` : '';
    return { title: `Run: ${cmd.split('\n')[0].slice(0, 80)}`, detail: `${why}\`\`\`\n${cmd}\n\`\`\`` };
  }
  const path = String(input.file_path ?? input.notebook_path ?? input.url ?? '');
  return { title: `${name}${path ? ` ${path}` : ''}`.slice(0, 100), detail: `\`\`\`json\n${JSON.stringify(input, null, 2).slice(0, 2500)}\n\`\`\`` };
}

function textOf(content: unknown): string {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content.map((c: any) => (c?.type === 'text' ? c.text : c?.type ? `[${c.type}]` : '')).join('\n');
  }
  return '';
}

const trim = (s: string) => (s.length > MAX_OUTPUT ? `${s.slice(0, MAX_OUTPUT)}\n… (${s.length - MAX_OUTPUT} more characters)` : s);

export async function execute(run: Run, abort: AbortController): Promise<void> {
  update(run, { status: 'running', startedAt: new Date().toISOString() });
  appendEvent(run.id, { type: 'status', text: run.continueFrom ? `Continuing run ${run.continueFrom}` : `Started (${run.trigger})` });
  let report: Report | undefined;
  try {
    const repo = await prepareWorkdir(run);
    const prev = run.continueFrom ? getRun(run.continueFrom) : undefined;

    const askUser = async (kind: 'command' | 'question', title: string, detail: string) => {
      update(run, { status: 'waiting' });
      const answer = await ask(run.id, kind, title, detail);
      update(run, { status: 'running' });
      return answer;
    };

    const canUseTool: CanUseTool = async (name, input, opts): Promise<PermissionResult> => {
      const allow: PermissionResult = { behavior: 'allow', updatedInput: input };
      if (opts.mcpServer?.source === 'sdk' || SAFE_TOOLS.has(name)) return allow;
      let reason = `${name} is not pre-approved`;
      if (EDIT_TOOLS.has(name)) {
        const p = String(input.file_path ?? input.notebook_path ?? '');
        const rel = relative(repo, resolve(repo, p));
        if (rel && !rel.startsWith('..') && !isAbsolute(rel) && !/^(\.claude|\.git)(\/|$)/.test(rel)) return allow;
        reason = 'writes outside the editable part of the repo clone';
      }
      if (name === 'Bash') {
        const v = checkCommand(String(input.command ?? ''));
        if (v.ok) return allow;
        reason = v.reason;
      }
      const { title, detail } = describeTool(name, input);
      const answer = await askUser('command', `Claude wants to ${title}`, `${detail}\n\nAsked because: ${reason}`);
      return answer === 'yes'
        ? allow
        : { behavior: 'deny', message: 'The user declined (or did not answer in time). Do not try to get the same effect another way; mention it in the report.' };
    };

    const tools = createSdkMcpServer({
      name: 'agent',
      version: '1.0.0',
      tools: [
        tool(
          'ask_user',
          'Ask the user a yes/no question on their phone and wait for the answer. Use it for decisions only the user can make. Answers can take hours; no answer counts as no.',
          { question: z.string().describe('Short yes/no question'), details: z.string().optional().describe('Markdown context: evidence, options, consequences') },
          async ({ question, details }) => {
            const answer = await askUser('question', question, details ?? question);
            return { content: [{ type: 'text', text: answer === 'yes' ? 'The user answered YES.' : 'The user answered NO (or did not answer in time).' }] };
          },
        ),
        tool(
          'submit_report',
          'Finish the run with a report. Call exactly once, as the last step.',
          {
            status: z.enum(['healthy', 'findings', 'fixed']).describe('"fixed" if you edited files, "findings" for problems you did not fix, "healthy" if nothing is wrong'),
            title: z.string().describe('Conventional commit subject, e.g. fix(grafana): raise memory limit to stop OOMKills'),
            summary: z.string().describe('Markdown, under 3000 characters, no hostnames, IPs or secrets'),
          },
          async (r) => {
            report = r;
            appendEvent(run.id, { type: 'report', report: r });
            return { content: [{ type: 'text', text: 'Report recorded.' }] };
          },
        ),
      ],
    });

    const q = query({
      prompt: await buildPrompt(run),
      options: {
        cwd: repo,
        model: MODEL,
        maxTurns: MAX_TURNS,
        resume: prev?.sessionId,
        permissionMode: 'default',
        canUseTool,
        settingSources: ['project'],
        skills: ['cloud-gitops'],
        systemPrompt: { type: 'preset', preset: 'claude_code', append: readFileSync(join(APP, 'rules.md'), 'utf8') },
        mcpServers: { agent: tools },
        disallowedTools: ['WebFetch', 'WebSearch', 'AskUserQuestion'],
        thinking: { type: 'adaptive', display: 'summarized' },
        abortController: abort,
        env: { ...process.env, MCP_TOOL_TIMEOUT: String(6 * 3600_000) },
        stderr: (s: string) => console.error(`[claude ${run.id}] ${s.trimEnd()}`),
      },
    });

    for await (const msg of q) {
      const m = msg as any;
      if (m.type === 'system' && m.subtype === 'init') update(run, { sessionId: m.session_id });
      else if (m.type === 'assistant') {
        const sub = m.parent_tool_use_id ? true : undefined;
        for (const b of m.message.content ?? []) {
          if (b.type === 'text' && b.text.trim()) appendEvent(run.id, { type: 'text', text: b.text, sub });
          else if (b.type === 'thinking' && b.thinking?.trim()) appendEvent(run.id, { type: 'thinking', text: b.thinking, sub });
          else if (b.type === 'tool_use') appendEvent(run.id, { type: 'tool_use', id: b.id, name: b.name, input: b.input, sub });
        }
      } else if (m.type === 'user' && Array.isArray(m.message?.content)) {
        for (const b of m.message.content) {
          if (b.type === 'tool_result') {
            appendEvent(run.id, { type: 'tool_result', id: b.tool_use_id, output: trim(textOf(b.content)), isError: !!b.is_error });
          }
        }
      } else if (m.type === 'result') {
        update(run, { costUsd: m.total_cost_usd });
        appendEvent(run.id, { type: 'result', subtype: m.subtype, turns: m.num_turns, costUsd: m.total_cost_usd, durationMs: m.duration_ms });
        if (m.subtype !== 'success') throw new Error(`Claude stopped: ${m.subtype}`);
      }
    }

    if (abort.signal.aborted) throw new Error('stopped');
    if (!report) throw new Error('Claude finished without submitting a report');
    update(run, { report });
    await finish(run, repo, report);
  } catch (e) {
    const stopped = abort.signal.aborted;
    const error = stopped ? 'stopped from the web UI' : String((e as Error)?.message ?? e);
    appendEvent(run.id, { type: 'status', text: `Run ${stopped ? 'stopped' : 'failed'}: ${error}` });
    update(run, { status: stopped ? 'stopped' : 'failed', error, endedAt: new Date().toISOString(), report });
    if (!stopped) {
      await notify({ title: '🚨 Claude Agent run failed', message: error, tags: ['rotating_light', 'robot'], priority: 4, click: runUrl(run.id) });
    }
  }
}

async function finish(run: Run, repo: string, report: Report): Promise<void> {
  await git(repo, 'add', '--intent-to-add', '--all');
  const stat = (await git(repo, 'diff', 'HEAD', '--stat')).trim();
  const view = { action: 'view' as const, label: '👁 Details', url: runUrl(run.id) };

  if (!stat) {
    const healthy = report.status === 'healthy';
    const title = run.kind === 'task'
      ? `✅ Claude Agent: ${report.title}`
      : healthy ? '✅ Claude Agent: all clear' : '✅ Claude Agent: all clear, with notable problems';
    const intro = run.kind === 'task' ? '' : healthy
      ? 'Looked into the cluster and everything was good.\n\n'
      : 'Looked into the cluster. Nothing to change in the repo; these need manual action:\n\n';
    await notify({ title, message: `${intro}${report.summary}`, tags: healthy ? ['white_check_mark', 'robot'] : ['white_check_mark', 'warning', 'robot'], click: runUrl(run.id), actions: [view] });
    return done(run, healthy ? 'no changes' : 'findings reported');
  }

  appendEvent(run.id, { type: 'diff', stat, patch: trim((await git(repo, 'diff', 'HEAD')).slice(0, 400_000)) });
  update(run, { status: 'waiting' });
  const answer = await ask(run.id, 'apply', `Apply: ${report.title}`, `${clip(report.summary, 2500)}\n\n\`\`\`\n${stat.slice(-800)}\n\`\`\``);
  update(run, { status: 'running' });
  if (answer === 'no') {
    appendEvent(run.id, { type: 'status', text: 'Change not applied. Continue the run to adjust it.' });
    return done(run, 'change declined');
  }

  appendEvent(run.id, { type: 'status', text: 'Applying: opening a PR and merging it once the validate check passes' });
  const res = await fetch(`${PUBLISHER}/apply`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ runId: run.id, repo, kind: run.kind, title: report.title, summary: report.summary }),
  });
  if (res.status !== 202) throw new Error(`publisher refused: ${await res.text()}`);
  let state: { state: string; message: string; prUrl?: string };
  do {
    await new Promise((r) => setTimeout(r, 15_000));
    state = await (await fetch(`${PUBLISHER}/apply/${run.id}`)).json() as typeof state;
  } while (state.state === 'running');

  appendEvent(run.id, { type: 'status', text: state.message, prUrl: state.prUrl });
  const actions = [view, ...(state.prUrl ? [{ action: 'view' as const, label: 'PR', url: state.prUrl }] : [])];
  if (state.state === 'merged') {
    await notify({ title: `🚀 Applied: ${report.title}`.slice(0, 120), message: state.message, tags: ['rocket', 'robot'], click: runUrl(run.id), actions });
    return done(run, 'applied');
  }
  await notify({ title: `⚠️ Not applied: ${report.title}`.slice(0, 120), message: state.message, tags: ['warning', 'robot'], priority: 4, click: runUrl(run.id), actions });
  return done(run, 'apply failed');
}

function done(run: Run, outcome: string): void {
  appendEvent(run.id, { type: 'status', text: `Finished: ${outcome}` });
  update(run, { status: 'done', outcome, endedAt: new Date().toISOString() });
}
