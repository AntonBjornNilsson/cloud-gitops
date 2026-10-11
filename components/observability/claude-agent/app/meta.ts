// Service metadata for the UI: available models, account, versions (from an idle SDK session),
// plus the latest claude.ai plan rate-limit readings reported during runs.
import { query } from '@anthropic-ai/claude-agent-sdk';
import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { bus, DATA } from './store.ts';

export type Model = { value: string; displayName: string; description?: string; efforts: string[] };
export type Limit = { type: string; status: string; utilization?: number; resetsAt?: number; updatedAt: string };

export const meta = {
  models: [] as Model[],
  account: {} as { email?: string; organization?: string; subscriptionType?: string },
  claudeCodeVersion: '',
  sdkVersion: '',
  defaultModel: process.env.CLAUDE_MODEL ?? 'sonnet',
  probedAt: '',
};

try {
  const require = createRequire(import.meta.url);
  meta.sdkVersion = require('@anthropic-ai/claude-agent-sdk/package.json').version;
} catch {
  // version is cosmetic
}

// Spawns Claude Code without sending a prompt: initialization answers without an API call
export async function probe(): Promise<void> {
  const abort = new AbortController();
  const never = (async function* () {
    await new Promise(() => {});
  })();
  const timer = setTimeout(() => abort.abort(), 60_000);
  try {
    const q = query({ prompt: never as any, options: { abortController: abort, settingSources: [] } });
    const init: any = await q.initializationResult();
    meta.models = (init.models ?? []).map((m: any) => ({
      value: m.value,
      displayName: m.displayName,
      description: m.description,
      efforts: m.supportedEffortLevels ?? [],
    }));
    meta.account = { email: init.account?.email, organization: init.account?.organization, subscriptionType: init.account?.subscriptionType };
    meta.claudeCodeVersion = init.claude_code_version ?? '';
    meta.probedAt = new Date().toISOString();
    bus.emit('state');
  } catch (e) {
    console.error(`[meta] probe failed: ${e}`);
  } finally {
    clearTimeout(timer);
    abort.abort();
  }
}

// ── plan limits ─────────────────────────────────────────────────────────────
const LIMITS = join(DATA, 'limits.json');
export const limits: Record<string, Limit> = existsSync(LIMITS) ? JSON.parse(readFileSync(LIMITS, 'utf8')) : {};

export function recordLimit(info: any): void {
  const type = info?.rateLimitType ?? 'unknown';
  // utilization may come as a fraction or a percentage
  const u = typeof info?.utilization === 'number' ? (info.utilization <= 1 ? info.utilization * 100 : info.utilization) : undefined;
  limits[type] = { type, status: info?.status ?? 'allowed', utilization: u, resetsAt: info?.resetsAt, updatedAt: new Date().toISOString() };
  writeFileSync(LIMITS + '.tmp', JSON.stringify(limits));
  renameSync(LIMITS + '.tmp', LIMITS);
  bus.emit('state');
}
