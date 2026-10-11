// Yes/no questions: sent to ntfy with one-time action tokens, answerable from the phone or the UI.
// A run waits on the promise; no answer before the timeout counts as "no".
import { randomBytes } from 'node:crypto';
import { appendEvent } from './store.ts';
import { clear, notify, runUrl, BASE_URL } from './ntfy.ts';

export type Answer = 'yes' | 'no';
type Pending = {
  id: string;
  token: string;
  runId: string;
  title: string;
  resolve: (a: Answer) => void;
  timer: NodeJS.Timeout;
};

const TIMEOUT_MS = Number(process.env.QUESTION_TIMEOUT_MINUTES ?? 240) * 60_000;
const pending = new Map<string, Pending>();
// Recently answered tokens, so a late tap on a stale notification gets a clear reply
const answered = new Map<string, { answer: Answer; by: string }>();

export const pendingFor = (runId: string) => [...pending.values()].filter((p) => p.runId === runId);

export function ask(runId: string, kind: 'command' | 'question' | 'apply', title: string, detail: string): Promise<Answer> {
  const id = randomBytes(6).toString('hex');
  const token = randomBytes(24).toString('base64url');
  appendEvent(runId, { type: 'question', qid: id, kind, title, detail });
  return new Promise<Answer>((resolve) => {
    const timer = setTimeout(() => settle(id, 'no', 'timeout'), TIMEOUT_MS);
    pending.set(id, { id, token, runId, title, resolve, timer });
    const answerUrl = (a: Answer) => `${BASE_URL}/answer/${token}/${a}`;
    void notify({
      title: `❓ ${title}`.slice(0, 120),
      message: detail,
      tags: ['question', 'robot'],
      priority: 4,
      sequence_id: `q-${id}`,
      click: runUrl(runId),
      actions: [
        { action: 'http', label: '✅ Yes', url: answerUrl('yes'), method: 'POST', clear: true },
        { action: 'http', label: '❌ No', url: answerUrl('no'), method: 'POST', clear: true },
        { action: 'view', label: '👁 Details', url: runUrl(runId) },
      ],
    });
  });
}

function settle(id: string, answer: Answer, by: string): boolean {
  const p = pending.get(id);
  if (!p) return false;
  pending.delete(id);
  clearTimeout(p.timer);
  appendEvent(p.runId, { type: 'answer', qid: id, answer, by });
  answered.set(p.token, { answer, by });
  if (answered.size > 500) answered.delete(answered.keys().next().value!);
  void clear(`q-${id}`);
  p.resolve(answer);
  return true;
}

export type TokenResult = { status: 'answered' } | { status: 'already'; answer: Answer; by: string } | { status: 'unknown' };

export function answerByToken(token: string, answer: Answer): TokenResult {
  const p = [...pending.values()].find((q) => q.token === token);
  if (p && settle(p.id, answer, 'ntfy')) return { status: 'answered' };
  const prev = answered.get(token);
  return prev ? { status: 'already', ...prev } : { status: 'unknown' };
}

export const answerById = (id: string, answer: Answer) => settle(id, answer, 'web');

export function cancelRun(runId: string): void {
  for (const p of pendingFor(runId)) settle(p.id, 'no', 'stopped');
}
