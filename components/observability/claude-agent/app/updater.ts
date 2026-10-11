// Restarts the pod when a newer :latest image is published. Compares the digest the agent container
// runs with the registry's current digest and, once the service is idle (no run, nothing queued,
// no open question), bumps a pod-template annotation on its own Deployment.
import { readFileSync } from 'node:fs';
import { bus } from './store.ts';

const SA = '/var/run/secrets/kubernetes.io/serviceaccount';
const API = 'https://kubernetes.default.svc';
const CHECK_MS = Number(process.env.UPDATE_CHECK_MINUTES ?? 15) * 60_000;

export const update = {
  enabled: !!process.env.HOSTNAME && process.env.AUTO_UPDATE !== 'false',
  image: '',
  running: '',
  latest: '',
  checkedAt: '',
  error: '',
  restarting: false,
};

async function k8s(path: string, init: RequestInit = {}): Promise<any> {
  const token = readFileSync(`${SA}/token`, 'utf8');
  // The in-cluster CA isn't in Node's trust store; NODE_EXTRA_CA_CERTS points at it (see deployment)
  const res = await fetch(`${API}${path}`, { ...init, headers: { Authorization: `Bearer ${token}`, Accept: 'application/json', ...(init.headers ?? {}) } });
  if (!res.ok) throw new Error(`${init.method ?? 'GET'} ${path}: ${res.status} ${(await res.text()).slice(0, 200)}`);
  return res.json();
}

async function registryDigest(image: string): Promise<string> {
  // ghcr.io/<owner>/<repo>/<name>:<tag> — public package, anonymous pull token
  const m = image.match(/^ghcr\.io\/([^:@]+):([\w.-]+)$/);
  if (!m) throw new Error(`unsupported image reference ${image}`);
  const [, repo, tag] = m;
  const tok = await (await fetch(`https://ghcr.io/token?scope=repository:${repo}:pull&service=ghcr.io`)).json() as { token: string };
  const res = await fetch(`https://ghcr.io/v2/${repo}/manifests/${tag}`, {
    method: 'HEAD',
    headers: {
      Authorization: `Bearer ${tok.token}`,
      Accept: [
        'application/vnd.oci.image.index.v1+json',
        'application/vnd.docker.distribution.manifest.list.v2+json',
        'application/vnd.oci.image.manifest.v1+json',
        'application/vnd.docker.distribution.manifest.v2+json',
      ].join(', '),
    },
  });
  const digest = res.headers.get('docker-content-digest');
  if (!res.ok || !digest) throw new Error(`registry HEAD ${res.status}`);
  return digest;
}

async function check(isIdle: () => boolean): Promise<void> {
  if (update.restarting) return;
  try {
    const ns = readFileSync(`${SA}/namespace`, 'utf8').trim();
    const pod = await k8s(`/api/v1/namespaces/${ns}/pods/${process.env.HOSTNAME}`);
    const status = (pod.status?.containerStatuses ?? []).find((c: any) => c.name === 'agent');
    update.image = (pod.spec?.containers ?? []).find((c: any) => c.name === 'agent')?.image ?? '';
    update.running = String(status?.imageID ?? '').split('@')[1] ?? '';
    update.latest = await registryDigest(update.image);
    update.checkedAt = new Date().toISOString();
    update.error = '';
    if (update.running && update.latest !== update.running && isIdle()) {
      const owner = pod.metadata?.ownerReferences?.find((o: any) => o.kind === 'ReplicaSet')?.name ?? '';
      const deployment = owner.replace(/-[a-z0-9]+$/, '');
      console.log(`[update] ${update.running} -> ${update.latest}: restarting deployment ${deployment}`);
      update.restarting = true;
      await k8s(`/apis/apps/v1/namespaces/${ns}/deployments/${deployment}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/strategic-merge-patch+json' },
        body: JSON.stringify({ spec: { template: { metadata: { annotations: { 'claude-agent/image-digest': update.latest } } } } }),
      });
    }
  } catch (e) {
    update.error = String((e as Error).message ?? e);
    update.restarting = false;
    console.error(`[update] ${update.error}`);
  }
  bus.emit('state');
}

export function startUpdater(isIdle: () => boolean): void {
  if (!update.enabled) return;
  setTimeout(() => void check(isIdle), 60_000);
  setInterval(() => void check(isIdle), CHECK_MS);
}
