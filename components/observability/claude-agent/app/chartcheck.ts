// Pre-renders the chart updates of a version-update run, so the unattended agent can judge them without helm
// or web access of its own: what the bump really changes, and whether the new chart would be admitted.
// Runs before Claude starts. Anything missing (helm or the YAML parser in an older image, a registry
// error) ends up as "unavailable" in the text, never as a failed run.
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const exec = promisify(execFile);
const DEADLINE_MS = 10 * 60_000;
const MAX_TOTAL = 90_000;
const MAX_DIFF_LINES = 40;
const MAX_DEFAULT_LINES = 25;
const FLUX_FILE = 'cluster/flux-system/gotk-components.yaml';

export type RenovatePr = { number: number; title: string; head: { ref: string } };
type Doc = Record<string, any>;
type Job = { hr: Doc; chart: string; from: string; to: string; url: string; oci: boolean; viaRef: boolean };

// Upstream upgrade notes for core charts, from these fixed pages only: the agent has no web access, and PR
// bodies are thin or cut off for exactly these charts. `app`: the releases are tagged with the app version.
const NOTES: Record<string, { docs?: (v: string) => string; releases?: string; app?: boolean }> = {
  kyverno: { releases: 'kyverno/kyverno', app: true },
  'kyverno-policies': { releases: 'kyverno/kyverno', app: true },
  traefik: { releases: 'traefik/traefik-helm-chart' },
};

// Field names kept out of the diff: version stamps that change on every release, and images (listed apart)
const NOISE = /labels\.helm\.sh\/chart|labels\.app\.kubernetes\.io\/version|checksum\/|caBundle|\.image$|kyverno-version/;
const SAFE_SYSCTLS = new Set(['kernel.shm_rmid_forced', 'net.ipv4.ip_local_port_range', 'net.ipv4.tcp_syncookies',
  'net.ipv4.ping_group_range', 'net.ipv4.ip_unprivileged_port_start', 'net.ipv4.ip_local_reserved_ports',
  'net.ipv4.tcp_keepalive_time', 'net.ipv4.tcp_fin_timeout', 'net.ipv4.tcp_keepalive_intvl', 'net.ipv4.tcp_keepalive_probes']);
const VOLUME_TYPES = ['configMap', 'csi', 'downwardAPI', 'emptyDir', 'ephemeral', 'image', 'persistentVolumeClaim', 'projected', 'secret'];

const short = (v: unknown) => String(v).replace(/\s+/g, ' ').slice(0, 100);
const failure = (e: any) => short(String(e.stderr ?? '').trim().split('\n').pop() || e.message);
const renderError = (e: any) => String(e.stderr ?? e.message).trim().replace(/\s+/g, ' ').slice(0, 600);
const nums = (v: string) => (v.match(/\d+/g) ?? []).slice(0, 3).map(Number);
function cmp(a: string, b: string): number {
  const [x, y] = [nums(a), nums(b)];
  for (let i = 0; i < 3; i++) if ((x[i] ?? 0) !== (y[i] ?? 0)) return (x[i] ?? 0) - (y[i] ?? 0);
  return 0;
}
const capped = (lines: string[], max: number) =>
  lines.length > max ? [...lines.slice(0, max), `(${lines.length - max} more not shown)`] : lines;

// path -> value; list items of named objects (containers, ports, ...) are keyed by name, so a reorder is no change
function flat(v: unknown, path = '', out: Record<string, string> = {}): Record<string, string> {
  if (Array.isArray(v) && v.length) {
    const named = v.every((x) => x && typeof x === 'object' && 'name' in x);
    v.forEach((x, i) => flat(x, `${path}[${named ? x.name : i}]`, out));
  } else if (v && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length) {
    for (const [k, x] of Object.entries(v)) flat(x, path ? `${path}.${k}` : k, out);
  } else out[path] = JSON.stringify(v) ?? 'null';
  return out;
}

const podSpec = (d: Doc): Doc | undefined => (['Deployment', 'DaemonSet', 'StatefulSet', 'Job'].includes(d.kind)
  ? d.spec?.template?.spec : d.kind === 'CronJob' ? d.spec?.jobTemplate?.spec?.template?.spec : undefined);
const hooks = (d: Doc) => String(d.metadata?.annotations?.['helm.sh/hook'] ?? '');
// Hooks for uninstall, rollback or tests don't run in an upgrade, so they can't fail one
const runsOnUpgrade = (d: Doc) => !hooks(d) || /install|upgrade/.test(hooks(d));
const allContainers = (p: Doc): Doc[] => [...(p.initContainers ?? []), ...(p.containers ?? []), ...(p.ephemeralContainers ?? [])];

// Mirrors the enforced restricted profile, honouring the policyExclude allowlist in the repo
function restrictedProblems(d: Doc, ns: string, excludes: Doc, postRenderers: string): { denied: string[]; noLimits: string[] } {
  const p = podSpec(d);
  if (!p || !runsOnUpgrade(d)) return { denied: [], noLimits: [] };
  const name = String(d.metadata.name);
  const excluded = (policy: string) => (excludes[policy]?.any ?? []).some((e: Doc) => {
    const r = e.resources ?? {};
    return (!r.namespaces || r.namespaces.includes(ns)) && (!r.names || r.names.some((n: string) =>
      new RegExp(`^${n.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*')}$`).test(name)));
  });
  const fail = (out: string[], policy: string, what: string) => { if (!excluded(policy)) out.push(what); };
  const pod: string[] = [];
  const psc = p.securityContext ?? {};
  const containers = allContainers(p);
  if (p.hostNetwork || p.hostPID || p.hostIPC) fail(pod, 'disallow-host-namespaces', 'host namespaces');
  for (const v of p.volumes ?? []) {
    if (v.hostPath) fail(pod, 'disallow-host-path', `hostPath volume ${v.name}`);
    if (!VOLUME_TYPES.some((t) => v[t])) fail(pod, 'restrict-volume-types', `volume type of ${v.name}`);
  }
  for (const s of psc.sysctls ?? []) if (!SAFE_SYSCTLS.has(s.name)) fail(pod, 'restrict-sysctls', `sysctl ${s.name}`);
  if (psc.runAsUser === 0) fail(pod, 'require-run-as-non-root-user', 'runs as uid 0');
  const nonRoot = (psc.runAsNonRoot === true && containers.every((c) => c.securityContext?.runAsNonRoot !== false))
    || containers.every((c) => c.securityContext?.runAsNonRoot === true);
  if (!nonRoot) fail(pod, 'require-run-as-nonroot', 'runAsNonRoot not set');

  const hook = hooks(d) ? ' [helm hook: only runs during the upgrade, and fails it when denied]' : '';
  const denied = pod.length ? [`${d.kind}/${name}${hook}: ${pod.join(', ')}`] : [];
  const noLimits: string[] = [];
  for (const c of containers) {
    const sc = c.securityContext ?? {};
    const bad: string[] = [];
    if (sc.privileged) fail(bad, 'disallow-privileged-containers', 'privileged');
    if (sc.allowPrivilegeEscalation !== false) fail(bad, 'disallow-privilege-escalation', 'allowPrivilegeEscalation not false');
    const caps = sc.capabilities ?? {};
    if (!(caps.drop ?? []).includes('ALL') || (caps.add ?? []).some((a: string) => a !== 'NET_BIND_SERVICE')) {
      fail(bad, 'disallow-capabilities-strict', 'capabilities (must drop ALL, add at most NET_BIND_SERVICE)');
    }
    if (sc.runAsUser === 0) fail(bad, 'require-run-as-non-root-user', 'runs as uid 0');
    const seccomp = sc.seccompProfile?.type ?? psc.seccompProfile?.type;
    if (seccomp !== 'RuntimeDefault' && seccomp !== 'Localhost') fail(bad, 'restrict-seccomp-strict', 'seccomp profile not set');
    if ((c.ports ?? []).some((x: Doc) => x.hostPort)) fail(bad, 'disallow-host-ports', 'hostPort');
    if (bad.length) denied.push(`${d.kind}/${name}${hook} container ${c.name}: ${bad.join(', ')}`);
    const l = c.resources?.limits ?? {};
    if (!l.cpu || !l.memory) {
      noLimits.push(`${d.kind}/${name} container ${c.name}${postRenderers.includes(String(c.name)) ? ' (a postRenderer in the repo names this container: probably set there)' : ''}`);
    }
  }
  return { denied, noLimits };
}

function walk(dir: string, out: string[] = []): string[] {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory()) { if (!['vendor', 'generated', '.git'].includes(e.name)) walk(join(dir, e.name), out); }
    else if (/\.ya?ml$/.test(e.name)) out.push(join(dir, e.name));
  }
  return out;
}

async function upstreamNotes(chart: string, from: string, to: string, shown: Set<string>): Promise<string> {
  const source = NOTES[chart];
  if (!source) return '';
  if (source.docs) return page(source.docs(to.replace(/^v/, '')), shown);
  return source.releases ? releases(source.releases, from, to, shown) : '';
}

async function page(url: string, shown: Set<string>): Promise<string> {
  if (shown.has(url)) return '';
  shown.add(url);
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(20_000) });
    if (!res.ok) return `Upstream notes (${url}): HTTP ${res.status}\n`;
    const text = (await res.text()).replace(/<(script|style|nav|header|footer)\b[\s\S]*?<\/\1>/gi, ' ').replace(/<[^>]+>/g, '\n')
      .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
      .replace(/[ \t]+/g, ' ').replace(/\s*\n\s*/g, '\n').trim();
    return `Upstream notes (${url}):\n${text.slice(0, 12_000)}\n`;
  } catch {
    return `Upstream notes (${url}): could not fetch\n`;
  }
}

async function releases(repo: string, from: string, to: string, shown: Set<string>): Promise<string> {
  const id = `${repo} ${from} ${to}`;
  if (shown.has(id)) return '';
  shown.add(id);
  try {
    const res = await fetch(`https://api.github.com/repos/${repo}/releases?per_page=60`, { signal: AbortSignal.timeout(20_000) });
    const list = (await res.json()) as { tag_name: string; body: string | null; prerelease: boolean; draft: boolean }[];
    const hits = list.filter((r) => !r.prerelease && !r.draft && /\d+\.\d+/.test(r.tag_name) && cmp(r.tag_name, from) > 0 && cmp(r.tag_name, to) <= 0)
      .sort((a, b) => cmp(a.tag_name, b.tag_name));
    const text = hits.map((r) => `#### ${r.tag_name}\n${(r.body ?? '').slice(0, 4000)}`).join('\n').slice(0, 14_000);
    return `Upstream release notes (${repo}, ${from} to ${to}):\n${text || '(none found)'}\n`;
  } catch {
    return `Upstream release notes (${repo}): could not fetch\n`;
  }
}

export async function chartChecks(repo: string, remote: string, branch: string, prs: RenovatePr[]): Promise<string> {
  const stop = Date.now() + DEADLINE_MS;
  let YAML: typeof import('yaml');
  try {
    YAML = await import('yaml');
    await exec('helm', ['version', '--short']);
  } catch {
    return '(chart analysis unavailable: this image has no helm or YAML parser yet)';
  }
  const parseAll = (text: string): Doc[] => YAML.parseAllDocuments(text, { logLevel: 'silent', uniqueKeys: false, merge: true })
    .map((d: any) => { try { return d.toJS(); } catch { return null; } }).filter((d: any) => d?.kind && d?.metadata?.name);

  const tmp = mkdtempSync(join(tmpdir(), 'chartcheck-'));
  const env = { ...process.env, HELM_CACHE_HOME: join(tmp, 'c'), HELM_CONFIG_HOME: join(tmp, 'h'), HELM_DATA_HOME: join(tmp, 'd') };
  const run = async (cmd: string, args: string[], cwd = tmp) =>
    (await exec(cmd, args, { cwd, env, maxBuffer: 256 << 20, timeout: 150_000 })).stdout;
  const bare = join(tmp, 'git');
  const g = (...args: string[]) => run('git', ['-c', 'safe.directory=*', ...args], bare);
  try {
    // What the cluster has now: the render must see the real API, and CRD stored versions must survive the bump
    const apis = (await run('kubectl', ['api-versions']).catch(() => '')).split('\n').filter(Boolean);
    const kube = await run('kubectl', ['version', '-o', 'json']).then((o) => String(JSON.parse(o).serverVersion?.gitVersion ?? '').replace(/\+.*/, '')).catch(() => '');
    const crds = await run('kubectl', ['get', 'crd', '-o', 'json']).then((o) => JSON.parse(o).items as Doc[]).catch(() => [] as Doc[]);
    const stored = new Map(crds.map((c) => [c.metadata.name, c.status?.storedVersions ?? []] as [string, string[]]));

    const manifests: Doc[] = [];
    for (const top of ['components', 'services']) {
      if (!existsSync(join(repo, top))) continue;
      for (const f of walk(join(repo, top))) {
        const text = readFileSync(f, 'utf8');
        if (/kind: *(HelmRepository|OCIRepository|HelmRelease)/.test(text)) { try { manifests.push(...parseAll(text)); } catch { /* not plain YAML */ } }
      }
    }
    // Some manifests leave the namespace to their kustomization
    const find = (kind: string, ns: string, name: string) => manifests.find((d) => d.kind === kind && d.metadata.name === name && (d.metadata.namespace ?? ns) === ns);
    const excludes = manifests.find((d) => d.kind === 'HelmRelease' && d.metadata.name === 'kyverno-policies')?.spec?.values?.policyExclude ?? {};

    mkdirSync(bare);
    await g('init', '--quiet', '--bare');
    await g('fetch', '--quiet', '--depth', '1', remote, `refs/heads/${branch}:refs/heads/base`);

    const shown = new Set<string>();
    const sections: string[] = [];
    for (const pr of prs) {
      if (Date.now() > stop) { sections.push(`### #${pr.number}\nNot analysed: ran out of time.`); continue; }
      try {
        // Depth 2 and pr~1: Renovate branches are one commit, and they lag behind main, so a diff against main
        // would list everything merged since as a downgrade
        await g('fetch', '--quiet', '--depth', '2', remote, `+refs/heads/${pr.head.ref}:refs/heads/pr`);
        const files = (await g('diff', '--name-only', 'pr~1', 'pr')).split('\n').filter(Boolean);
        const show = (rev: string, f: string) => g('show', `${rev}:${f}`).catch(() => '');
        if (files.includes(FLUX_FILE)) {
          const flux = (t: string) => t.match(/^# Flux Version: (\S+)/m)?.[1] ?? '';
          const [from, to] = [flux(await show('base', FLUX_FILE)), flux(await show('pr', FLUX_FILE))];
          if (from && to && from !== to) sections.push(`### #${pr.number} Flux ${from} to ${to}\n${await releases('fluxcd/flux2', from, to, shown)}`);
        }
        const jobs: Job[] = [];
        for (const f of files.filter((x) => /^(components|services)\/.*\.ya?ml$/.test(x))) {
          const [a, b] = [parseAll(await show('base', f)), parseAll(await show('pr', f))];
          for (const hr of b.filter((d) => d.kind === 'HelmRelease')) {
            const old = a.find((d) => d.kind === 'HelmRelease' && d.metadata.name === hr.metadata.name && d.metadata.namespace === hr.metadata.namespace);
            const [to, from] = [hr.spec?.chart?.spec?.version, old?.spec?.chart?.spec?.version];
            if (!old || !to || !from || cmp(String(to), String(from)) <= 0) continue;
            const src = hr.spec.chart.spec.sourceRef;
            const r = find('HelmRepository', src.namespace ?? hr.metadata.namespace, src.name);
            if (r) jobs.push({ hr: old, chart: hr.spec.chart.spec.chart, from: String(from), to: String(to), url: r.spec.url, oci: String(r.spec.url).startsWith('oci://'), viaRef: false });
            else sections.push(`### #${pr.number} ${hr.spec.chart.spec.chart} ${from} to ${to}\nNot analysed: HelmRepository ${src.name} not found.`);
          }
          for (const oci of b.filter((d) => d.kind === 'OCIRepository')) {
            const old = a.find((d) => d.kind === 'OCIRepository' && d.metadata.name === oci.metadata.name);
            const [to, from] = [oci.spec?.ref?.tag, old?.spec?.ref?.tag];
            if (!to || !from || cmp(String(to), String(from)) <= 0) continue;
            const hr = manifests.find((d) => d.kind === 'HelmRelease' && d.spec?.chartRef?.name === oci.metadata.name && d.metadata.namespace === oci.metadata.namespace);
            if (hr) jobs.push({ hr, chart: String(oci.spec.url).split('/').pop()!, from: String(from), to: String(to), url: oci.spec.url, oci: true, viaRef: true });
            else sections.push(`### #${pr.number} ${oci.metadata.name} ${from} to ${to}\nNot analysed: no HelmRelease uses this OCIRepository.`);
          }
        }
        for (const job of jobs) {
          const dir = mkdtempSync(join(tmp, 'pr-'));
          const pull = async (label: string, v: string): Promise<string> => {
            const into = join(dir, label);
            const target = job.viaRef ? job.url : job.oci ? `${job.url}/${job.chart}` : job.chart;
            const repoArgs = job.oci ? [] : ['--repo', job.url];
            // Renovate and the repo differ on a leading v; the chart repositories are strict about it
            for (const version of [v, v.startsWith('v') ? v.slice(1) : `v${v}`]) {
              try {
                await run('helm', ['pull', target, ...repoArgs, '--version', version, '--untar', '--untardir', into]);
                break;
              } catch (e) { if (version !== v) throw e; }
            }
            return join(into, readdirSync(into)[0]);
          };
          const hr = job.hr;
          const ns = hr.spec.targetNamespace ?? hr.metadata.namespace;
          const values = join(dir, 'values.json');
          writeFileSync(values, JSON.stringify(hr.spec.values ?? {}));
          const render = async (chart: string) => parseAll(await run('helm', ['template', hr.spec.releaseName ?? hr.metadata.name, chart, '--namespace', ns,
            '--include-crds', '-f', values, ...(kube ? ['--kube-version', kube] : []), ...apis.flatMap((a) => ['--api-versions', a])]));
          const [oldDir, newDir] = [await pull('old', job.from), await pull('new', job.to)];
          const title = `### #${pr.number} ${job.chart} ${job.from} to ${job.to} (HelmRelease ${hr.metadata.namespace}/${hr.metadata.name})\n`;
          const oldDocs = await render(oldDir);
          // The old version renders and the new one doesn't: Flux would fail on it the same way
          const newDocs = await render(newDir).catch((e) => {
            sections.push(`${title}**BLOCKER: the new chart does not render with the repo's values (adapt or skip)**\n- ${renderError(e)}`);
            return null;
          });
          if (newDocs) sections.push(title
            + compare(oldDocs, newDocs, ns, excludes, stored, hr, parseValues(YAML, oldDir), parseValues(YAML, newDir))
            + await upstreamNotes(job.chart, NOTES[job.chart]?.app ? appVersion(YAML, oldDir) ?? job.from : job.from, NOTES[job.chart]?.app ? appVersion(YAML, newDir) ?? job.to : job.to, shown));
          rmSync(dir, { recursive: true, force: true });
        }
      } catch (e) {
        sections.push(`### #${pr.number}\nCould not analyse: ${failure(e)}`);
      }
    }
    return sections.join('\n\n').slice(0, MAX_TOTAL) || '(no chart version changes in the open PRs)';
  } catch (e) {
    return `(chart analysis failed: ${failure(e)})`;
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

const parseValues = (YAML: typeof import('yaml'), dir: string): Doc => {
  try { return YAML.parse(readFileSync(join(dir, 'values.yaml'), 'utf8'), { logLevel: 'silent', uniqueKeys: false }) ?? {}; } catch { return {}; }
};
const appVersion = (YAML: typeof import('yaml'), dir: string): string | undefined => {
  try { return YAML.parse(readFileSync(join(dir, 'Chart.yaml'), 'utf8')).appVersion; } catch { return undefined; }
};

function compare(oldDocs: Doc[], newDocs: Doc[], ns: string, excludes: Doc, stored: Map<string, string[]>, hr: Doc, oldDefaults: Doc, newDefaults: Doc): string {
  const key = (d: Doc) => `${d.kind}/${d.metadata.name}`;
  const [o, n] = [new Map(oldDocs.map((d) => [key(d), d])), new Map(newDocs.map((d) => [key(d), d]))];
  const out: string[] = [];
  const section = (title: string, lines: string[], max = MAX_DIFF_LINES) => {
    if (lines.length) out.push(`**${title}**`, ...capped(lines, max).map((l) => `- ${l}`));
  };

  // Blockers first
  const postRenderers = JSON.stringify(hr.spec.postRenderers ?? '');
  const results = newDocs.map((d) => restrictedProblems(d, ns, excludes, postRenderers));
  section('BLOCKER: denied by the enforced restricted profile (adapt or skip, never a plain apply)', results.flatMap((r) => r.denied));

  const removedNames = new Map([...o.values()].filter((d) => !n.has(key(d))).map((d) => [d.metadata.name, d]));
  const kindChanges = [...n.values()].filter((d) => !o.has(key(d)) && removedNames.has(d.metadata.name));
  section('BLOCKER: same object name, different kind (adapt or skip: settings for the old kind may be ignored)',
    kindChanges.map((d) => `${d.metadata.name}: ${removedNames.get(d.metadata.name)!.kind} (${removedNames.get(d.metadata.name)!.apiVersion}) to ${d.kind} (${d.apiVersion})`));

  const crdGaps = newDocs.filter((d) => d.kind === 'CustomResourceDefinition').flatMap((d) => {
    const versions = (d.spec?.versions ?? []).map((v: Doc) => v.name);
    return (stored.get(d.metadata.name) ?? []).filter((v) => !versions.includes(v)).map((v) => `${d.metadata.name}: stored version ${v} is gone from the new chart`);
  });
  section('BLOCKER: CRD stored versions missing from the new chart (skip: needs a storage migration)', crdGaps);

  // Values the repo sets that the chart no longer has are usually renames, silently ignored by helm
  const [oldFlat, newFlat, mine] = [flat(oldDefaults), flat(newDefaults), flat(hr.spec.values ?? {})];
  const isSet = (p: string) => Object.keys(mine).some((m) => m === p || m.startsWith(`${p}.`) || m.startsWith(`${p}[`) || p.startsWith(`${m}.`) || p.startsWith(`${m}[`));
  section('Values the repo sets that are in the old chart defaults but not the new (renamed or removed?)',
    Object.keys(mine).filter((m) => m in oldFlat && !(m in newFlat)));

  const added = [...n.values()].filter((d) => !o.has(key(d)) && !kindChanges.includes(d)).map(key);
  const removed = [...o.values()].filter((d) => !n.has(key(d)) && !kindChanges.some((k) => k.metadata.name === d.metadata.name)).map(key);
  section('Objects added', added);
  section('Objects removed', removed);

  const images = (docs: Doc[]) => new Set(docs.flatMap((d) => { const p = podSpec(d); return p ? allContainers(p).map((c) => String(c.image)) : []; }));
  const [oi, ni] = [images(oldDocs), images(newDocs)];
  section('Image changes', [...[...oi].filter((i) => !ni.has(i)).map((i) => `removed ${i}`), ...[...ni].filter((i) => !oi.has(i)).map((i) => `added ${i}`)]);

  // Field by field, skipping Secrets (generated certificates) and CRD schemas (noise; stored versions are checked above)
  const changes: string[] = [];
  for (const [k, d] of n) {
    const before = o.get(k);
    if (!before || d.kind === 'Secret' || d.kind === 'CustomResourceDefinition') continue;
    const [a, b] = [flat(before), flat(d)];
    for (const p of new Set([...Object.keys(a), ...Object.keys(b)])) {
      if (a[p] !== b[p] && !NOISE.test(p)) changes.push(`${k} ${p}: ${short(a[p] ?? '(unset)')} to ${short(b[p] ?? '(unset)')}`);
    }
  }
  section('Rendered changes with the repo\'s values (pod templates first)', changes.sort((a, b) => Number(b.includes('.template.')) - Number(a.includes('.template.'))));
  section('Changed chart defaults the repo does not set',
    Object.keys(newFlat).filter((p) => p in oldFlat && oldFlat[p] !== newFlat[p] && !isSet(p) && !NOISE.test(p) && !/\.(tag|digest|version)$/.test(p))
      .map((p) => `${p}: ${short(oldFlat[p])} to ${short(newFlat[p])}`), MAX_DEFAULT_LINES);
  section('Containers without CPU/memory limits (repo rule: set them via chart values or a postRenderer)', results.flatMap((r) => r.noLimits));
  if (hr.spec.valuesFrom) out.push('Note: this HelmRelease also uses valuesFrom, which the render above does not include.');
  return `${out.join('\n') || 'No differences in the rendered objects.'}\n`;
}
