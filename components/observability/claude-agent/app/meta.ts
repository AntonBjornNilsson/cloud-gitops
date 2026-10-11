// Service metadata for the UI (available models, account, versions) and plan-limit polling, both from
// an idle SDK session: initialization and the usage call answer without a model request.
import { query, type Query } from '@anthropic-ai/claude-agent-sdk';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { bus } from './store.ts';
import { recordUsage } from './limits.ts';

export type Model = { value: string; displayName: string; description?: string; efforts: string[] };

export const meta = {
  models: [] as Model[],
  account: {} as { email?: string; organization?: string; subscriptionType?: string },
  claudeCodeVersion: '',
  sdkVersion: '',
  defaultModel: process.env.CLAUDE_MODEL ?? 'sonnet',
  probedAt: '',
};

try {
  // package.json isn't in the SDK's exports map; find it next to the resolved entry point
  const entry = createRequire(import.meta.url).resolve('@anthropic-ai/claude-agent-sdk');
  meta.sdkVersion = JSON.parse(readFileSync(join(dirname(entry), 'package.json'), 'utf8')).version;
} catch {
  // version is cosmetic
}

// Runs fn against a Claude Code process that never receives a prompt
async function idleSession<T>(fn: (q: Query) => Promise<T>): Promise<T | undefined> {
  const abort = new AbortController();
  const never = (async function* () {
    await new Promise(() => {});
  })();
  const timer = setTimeout(() => abort.abort(), 60_000);
  try {
    const q = query({ prompt: never as any, options: { abortController: abort, settingSources: [] } });
    return await fn(q);
  } catch (e) {
    console.error(`[meta] idle session failed: ${e}`);
    return undefined;
  } finally {
    clearTimeout(timer);
    abort.abort();
  }
}

// The SDK marks this call experimental; if it disappears, rate-limit events still drive the guard
export async function readLimits(q: Query): Promise<boolean> {
  try {
    return recordUsage(await q.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET({ skipBehaviors: true }));
  } catch (e) {
    console.error(`[limits] usage read failed: ${e}`);
    return false;
  }
}

export const pollLimits = () => idleSession(readLimits);

export async function probe(): Promise<void> {
  await idleSession(async (q) => {
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
    await readLimits(q);
    bus.emit('state');
  });
}
