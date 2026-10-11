// ntfy notifications. The topic needs auth to read, so action tokens in messages stay private.
const SERVER = (process.env.NTFY_SERVER ?? 'http://ntfy.ntfy.svc.cluster.local').replace(/\/$/, '');
const TOPIC = process.env.NTFY_TOPIC ?? 'claude-agent';
const TOKEN = process.env.NTFY_TOKEN ?? '';
export const BASE_URL = (process.env.BASE_URL ?? '').replace(/\/$/, '');

export type NtfyAction =
  | { action: 'view'; label: string; url: string; clear?: boolean }
  | { action: 'http'; label: string; url: string; method?: string; clear?: boolean };

export type Notification = {
  title: string;
  message: string;
  tags?: string[];
  priority?: 1 | 2 | 3 | 4 | 5;
  actions?: NtfyAction[];
  click?: string;
  // Lets a later clear() dismiss this notification on every device
  sequence_id?: string;
};

export const runUrl = (id: string) => `${BASE_URL}/runs/${id}`;

// ntfy rejects messages over 4096 bytes
export function clip(s: string, max = 3500): string {
  return s.length <= max ? s : s.slice(0, max) + '\n\n… (truncated, see the run page)';
}

export async function notify(n: Notification): Promise<void> {
  try {
    const res = await fetch(`${SERVER}/`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...(TOKEN ? { Authorization: `Bearer ${TOKEN}` } : {}) },
      body: JSON.stringify({ topic: TOPIC, markdown: true, ...n, message: clip(n.message) }),
      signal: AbortSignal.timeout(10_000),
    });
    console.log(`[ntfy] '${n.title}' -> ${res.status}`);
  } catch (e) {
    console.error(`[ntfy] '${n.title}' failed: ${e}`);
  }
}

// Mark a notification read and dismiss it everywhere (e.g. a question answered from the web UI)
export async function clear(sequenceId: string): Promise<void> {
  try {
    const res = await fetch(`${SERVER}/${TOPIC}/${sequenceId}/clear`, {
      method: 'PUT',
      headers: TOKEN ? { Authorization: `Bearer ${TOKEN}` } : {},
      signal: AbortSignal.timeout(10_000),
    });
    if (!res.ok) console.error(`[ntfy] clear ${sequenceId} -> ${res.status}`);
  } catch (e) {
    console.error(`[ntfy] clear ${sequenceId} failed: ${e}`);
  }
}
