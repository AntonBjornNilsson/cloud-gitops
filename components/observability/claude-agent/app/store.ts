// Run history on the data volume: one directory per run with run.json and events.jsonl.
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { EventEmitter } from 'node:events';
import { randomBytes } from 'node:crypto';

export const DATA = process.env.DATA_DIR ?? '/data';
const RUNS = join(DATA, 'runs');
mkdirSync(RUNS, { recursive: true });

export type RunStatus = 'queued' | 'running' | 'waiting' | 'done' | 'failed' | 'stopped' | 'interrupted';
export type Report = { status: 'healthy' | 'findings' | 'fixed'; title: string; summary: string };
export type Tokens = { input: number; output: number; cacheRead: number; cacheWrite: number };
export type Usage = Tokens & { byModel: Record<string, Tokens> };
export type Todo = { content: string; status: string; activeForm?: string };
export type Run = {
  id: string;
  kind: 'health' | 'updates' | 'task';
  prompt?: string;
  trigger: string;
  continueFrom?: string;
  createdAt: string;
  startedAt?: string;
  endedAt?: string;
  status: RunStatus;
  model?: string;
  effort?: string;
  sessionId?: string;
  workdir?: string;
  report?: Report;
  outcome?: string;
  // Estimated API-equivalent cost of this run; sessionCostUsd is the SDK's running total for the session
  costUsd?: number;
  sessionCostUsd?: number;
  usage?: Usage;
  // The SDK's running per-model totals for the session (a continued run subtracts its parent's)
  sessionUsage?: Usage;
  context?: { percentage: number; totalTokens: number; maxTokens: number };
  todos?: Todo[];
  turns?: number;
  error?: string;
};
export type RunEvent = { t: string; type: string; [k: string]: unknown };

// 'event' (runId, RunEvent) and 'run' (Run) for the live UI
export const bus = new EventEmitter();
bus.setMaxListeners(100);

const runFile = (id: string) => join(RUNS, id, 'run.json');
const eventsFile = (id: string) => join(RUNS, id, 'events.jsonl');

export function newRunId(): string {
  const d = new Date().toISOString().replace(/[-:]/g, '').replace('T', '-').slice(0, 13);
  return `${d}-${randomBytes(2).toString('hex')}`;
}

export function saveRun(run: Run): void {
  mkdirSync(join(RUNS, run.id), { recursive: true });
  const tmp = runFile(run.id) + '.tmp';
  writeFileSync(tmp, JSON.stringify(run, null, 2));
  renameSync(tmp, runFile(run.id));
  bus.emit('run', run);
}

export function getRun(id: string): Run | undefined {
  if (!/^[\w-]+$/.test(id) || !existsSync(runFile(id))) return undefined;
  return JSON.parse(readFileSync(runFile(id), 'utf8'));
}

export function listRuns(limit = 100): Run[] {
  return readdirSync(RUNS).sort().reverse().slice(0, limit)
    .map(getRun).filter((r): r is Run => !!r);
}

export function appendEvent(id: string, ev: Omit<RunEvent, 't'>): RunEvent {
  const full = { t: new Date().toISOString(), ...ev } as RunEvent;
  appendFileSync(eventsFile(id), JSON.stringify(full) + '\n');
  bus.emit('event', id, full);
  return full;
}

export function readEvents(id: string): RunEvent[] {
  if (!existsSync(eventsFile(id))) return [];
  return readFileSync(eventsFile(id), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
}

// A restart kills whatever was in flight
export function markInterrupted(): void {
  for (const run of listRuns(1000)) {
    if (['queued', 'running', 'waiting'].includes(run.status)) {
      saveRun({ ...run, status: 'interrupted', endedAt: new Date().toISOString(), error: 'service restarted' });
    }
  }
}
