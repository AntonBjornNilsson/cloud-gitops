// Claude Agent web UI: a small client-side app over the service's JSON API and SSE streams.
const $ = (sel, el = document) => el.querySelector(sel);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
const view = $('#view');
// localStorage can throw (private mode, blocked storage); it only holds view preferences
const store = {
  get: (k) => { try { return localStorage.getItem(k); } catch { return null; } },
  set: (k, v) => { try { localStorage.setItem(k, v); } catch {} },
};

// ── formatting ──────────────────────────────────────────────────────────────
const fmtTokens = (n) => {
  n = Number(n) || 0;
  if (n >= 1e9) return `${(n / 1e9).toFixed(n >= 1e10 ? 0 : 1)}B`;
  if (n >= 1e6) return `${(n / 1e6).toFixed(n >= 1e7 ? 0 : 1)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(n >= 1e4 ? 0 : 1)}k`;
  return String(n);
};
const fmtCost = (n) => (n == null ? '–' : `$${Number(n).toFixed(n >= 100 ? 0 : 2)}`);
const fmtTime = (t) => (t ? new Date(t).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '');
const fmtDateTime = (t) => (t ? new Date(t).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }) : '');
function fmtDuration(ms) {
  if (ms == null || ms < 0) return '–';
  const s = Math.round(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${s % 60}s`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}
function rel(t) {
  if (!t) return '';
  const d = (Date.now() - new Date(t).getTime()) / 1000;
  if (d < 45) return 'just now';
  if (d < 3600) return `${Math.round(d / 60)}m ago`;
  if (d < 86400) return `${Math.round(d / 3600)}h ago`;
  return `${Math.round(d / 86400)}d ago`;
}
function until(t) {
  const d = (new Date(t).getTime() - Date.now()) / 1000;
  if (d <= 0) return 'now';
  if (d < 3600) return `in ${Math.round(d / 60)}m`;
  if (d < 86400) return `in ${Math.floor(d / 3600)}h ${Math.round((d % 3600) / 60)}m`;
  return `in ${Math.round(d / 86400)}d`;
}
const totalTokens = (u) => (u ? u.input + u.output + u.cacheRead + u.cacheWrite : 0);
const runTitle = (r) => r.report?.title || (r.prompt || '').split('\n')[0].slice(0, 140) || (r.kind === 'health' ? 'Health review' : 'Task');
const isLive = (r) => ['queued', 'running', 'waiting'].includes(r?.status);
const GLYPH = { done: '●', failed: '✕', interrupted: '!', running: '◐', waiting: '◆', queued: '○', stopped: '■' };

// ── markdown (escaped first; small safe subset) ─────────────────────────────
function inline(s) {
  return esc(s)
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[\s(])\*([^*\s][^*]*)\*(?=[\s).,;:!?]|$)/g, '$1<em>$2</em>')
    .replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
}
function md(src) {
  const lines = String(src ?? '').replace(/\r/g, '').split('\n');
  const out = [];
  let para = [];
  const flush = () => {
    if (para.length) out.push(`<p>${inline(para.join(' '))}</p>`);
    para = [];
  };
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (/^\s*```/.test(l)) {
      flush();
      const buf = [];
      for (i++; i < lines.length && !/^\s*```/.test(lines[i]); i++) buf.push(lines[i]);
      out.push(`<pre><code>${esc(buf.join('\n'))}</code></pre>`);
      continue;
    }
    if (/^\s*\|.*\|\s*$/.test(l) && /^\s*\|?[\s:-]+\|[\s|:-]*$/.test(lines[i + 1] ?? '')) {
      flush();
      const cells = (row) => row.trim().replace(/^\||\|$/g, '').split('|').map((c) => inline(c.trim()));
      const head = cells(l);
      const body = [];
      for (i += 2; i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i]); i++) body.push(cells(lines[i]));
      i--;
      out.push(`<table><thead><tr>${head.map((c) => `<th>${c}</th>`).join('')}</tr></thead><tbody>${body.map((r) => `<tr>${r.map((c) => `<td>${c}</td>`).join('')}</tr>`).join('')}</tbody></table>`);
      continue;
    }
    const list = l.match(/^\s*([-*]|\d+[.)])\s+(.*)/);
    if (list) {
      flush();
      const ordered = /\d/.test(list[1]);
      const items = [];
      for (; i < lines.length; i++) {
        const m = lines[i].match(/^\s*([-*]|\d+[.)])\s+(.*)/);
        if (m) items.push(m[2]);
        else if (/^\s{2,}\S/.test(lines[i]) && items.length) items[items.length - 1] += ` ${lines[i].trim()}`;
        else break;
      }
      i--;
      out.push(`<${ordered ? 'ol' : 'ul'}>${items.map((x) => `<li>${inline(x)}</li>`).join('')}</${ordered ? 'ol' : 'ul'}>`);
      continue;
    }
    const h = l.match(/^(#{1,4})\s+(.*)/);
    if (h) {
      flush();
      out.push(`<h${h[1].length + 1}>${inline(h[2])}</h${h[1].length + 1}>`);
      continue;
    }
    const q = l.match(/^>\s?(.*)/);
    if (q) {
      flush();
      out.push(`<blockquote>${inline(q[1])}</blockquote>`);
      continue;
    }
    if (!l.trim()) flush();
    else para.push(l.trim());
  }
  flush();
  return `<div class="md">${out.join('')}</div>`;
}

// ── api ─────────────────────────────────────────────────────────────────────
async function api(url, body) {
  const res = await fetch(url, body === undefined ? {} : { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `${res.status} ${res.statusText}`);
  return data;
}
function toast(msg) {
  const t = $('#toast');
  t.textContent = msg;
  t.classList.add('show');
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => t.classList.remove('show'), 3200);
}

// ── cron (server runs in UTC) ───────────────────────────────────────────────
function cronField(spec, v, min, max) {
  return spec.split(',').some((part) => {
    const [range, stepStr] = part.split('/');
    const step = stepStr ? Number(stepStr) : 1;
    let lo = min, hi = max;
    if (range !== '*') {
      const [a, b] = range.split('-').map(Number);
      lo = a;
      hi = b ?? (stepStr ? max : a);
    }
    return v >= lo && v <= hi && (v - lo) % step === 0;
  });
}
function nextCron(expr) {
  const [mi, h, dom, mon, dow] = expr.trim().split(/\s+/);
  const d = new Date();
  d.setUTCSeconds(0, 0);
  for (let i = 0; i < 60 * 24 * 8; i++) {
    d.setUTCMinutes(d.getUTCMinutes() + 1);
    if (cronField(mi, d.getUTCMinutes(), 0, 59) && cronField(h, d.getUTCHours(), 0, 23) && cronField(dom, d.getUTCDate(), 1, 31)
      && cronField(mon, d.getUTCMonth() + 1, 1, 12) && (cronField(dow, d.getUTCDay(), 0, 6) || (d.getUTCDay() === 0 && cronField(dow, 7, 0, 7)))) return new Date(d);
  }
  return null;
}

// ── global state + sidebar ──────────────────────────────────────────────────
const app = { state: null, runs: [], route: null, cleanup: [] };

function statusPill() {
  const el = $('#agent-status');
  const s = app.state;
  if (!s) return;
  let cls = 'idle', text = 'Idle';
  if (s.pending.length) { cls = 'waiting'; text = `${s.pending.length} waiting`; }
  else if (s.current) { cls = 'working'; text = 'Working'; }
  el.className = `pill ${cls}`;
  el.innerHTML = `<span class="dot"></span>${text}`;
  document.title = `${s.pending.length ? `(${s.pending.length}) ` : ''}${app.routeTitle || 'Claude Agent'}`;
}

function renderInbox() {
  const s = app.state;
  const box = $('#inbox');
  if (!s?.pending.length) { box.hidden = true; return; }
  box.hidden = false;
  $('#inbox-list').innerHTML = s.pending.map((q) => `
    <div class="inbox-item">
      <a href="/runs/${esc(q.runId)}" data-link>${esc(q.title)}</a>
      <div class="row"><button class="btn sm yes" data-answer="${esc(q.id)}" data-a="yes">Yes</button>
      <button class="btn sm no" data-answer="${esc(q.id)}" data-a="no">No</button><span class="small muted">${rel(q.createdAt)}</span></div>
    </div>`).join('');
}

function renderHistory() {
  const filter = $('#history-filter').value.trim().toLowerCase();
  const runs = app.runs.filter((r) => !filter || runTitle(r).toLowerCase().includes(filter) || r.id.includes(filter));
  const now = new Date();
  const startOfDay = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const group = (r) => {
    const t = new Date(r.startedAt || r.createdAt).getTime();
    if (t >= startOfDay) return 'Today';
    if (t >= startOfDay - 86400000) return 'Yesterday';
    if (t >= startOfDay - 6 * 86400000) return 'This week';
    return 'Older';
  };
  const activeId = app.route?.name === 'run' ? app.route.id : null;
  let last = '';
  const html = runs.slice(0, 150).map((r) => {
    const g = group(r);
    const head = g !== last ? `<div class="history-group">${g}</div>` : '';
    last = g;
    return `${head}<a href="/runs/${esc(r.id)}" data-link class="history-item${r.id === activeId ? ' active' : ''}" title="${esc(runTitle(r))}">
      <span class="glyph ${r.status}">${GLYPH[r.status] || '·'}</span><span class="t">${esc(runTitle(r))}</span><span class="when">${fmtTime(r.startedAt || r.createdAt)}</span></a>`;
  }).join('');
  $('#history-list').innerHTML = html || '<div class="empty small">No runs yet</div>';
}

const guardOf = () => app.state?.guard ?? { pauseAt: 80, stopAt: 90, paused: null };
const limitClass = (l) => {
  const g = guardOf();
  return l.status === 'rejected' || (l.utilization ?? 0) >= g.stopAt ? 'bad' : l.status === 'allowed_warning' || (l.utilization ?? 0) >= g.pauseAt ? 'warn' : '';
};
// Windows past their reset no longer apply; the most used first
function activeLimits(map) {
  const now = Date.now();
  return Object.values(map || {}).filter((l) => !l.resetsAt || l.resetsAt > now)
    .sort((a, b) => (b.utilization ?? -1) - (a.utilization ?? -1));
}
// A meter with tick marks where new runs pause and running sessions stop
function limitBar(l) {
  const g = guardOf();
  return `<div class="bar ${limitClass(l)}" role="meter" aria-label="${esc(l.label)}" aria-valuenow="${Math.round(l.utilization)}" aria-valuemin="0" aria-valuemax="100">
    <span style="width:${Math.min(100, l.utilization)}%"></span><i class="mark" style="left:${g.pauseAt}%" title="New runs pause at ${g.pauseAt}%"></i><i class="mark stop" style="left:${g.stopAt}%" title="Running sessions stop at ${g.stopAt}%"></i></div>`;
}
function pausedBanner() {
  const p = guardOf().paused;
  if (!p) return '';
  return `<div class="banner"><b>⏸ Paused to stay under the plan limit.</b> ${esc(p.reason)}. Queued runs start by themselves${p.until ? ` ${esc(until(p.until))}` : ' once usage drops'}.</div>`;
}

function renderFoot() {
  const s = app.state;
  if (!s) return;
  const lim = activeLimits(s.limits).filter((l) => l.utilization != null).slice(0, 3);
  $('#limits-mini').innerHTML = (guardOf().paused ? `<div class="mini-paused">⏸ Paused: ${esc(guardOf().paused.reason)}</div>` : '')
    + lim.map((l) => `<a class="mini-meter" href="/usage" data-link title="${esc(l.label)}: ${Math.round(l.utilization)}%${l.resetsAt ? `, resets ${until(l.resetsAt)}` : ''}">
    <span>${esc(l.label.replace(/^Weekly \((.*)\)$/, '7d $1').replace('Weekly', '7-day'))}</span>${limitBar(l)}<span>${Math.round(l.utilization)}%</span></a>`).join('');
  const u = s.update;
  const upd = u.current === true ? 'up to date' : u.current === false ? (u.restarting ? 'updating…' : 'update pending') : '';
  $('#version').textContent = [s.meta.claudeCodeVersion && `Claude Code ${s.meta.claudeCodeVersion}`, upd].filter(Boolean).join(' · ');
  $('#version').title = `Agent SDK ${s.meta.sdkVersion}${u.running ? `\nimage ${u.running.slice(7, 19)}` : ''}${u.error ? `\nupdate check: ${u.error}` : ''}`;
}

function renderSidebar() {
  statusPill();
  renderInbox();
  renderHistory();
  renderFoot();
  document.querySelectorAll('[data-nav]').forEach((a) => a.classList.toggle('active', a.dataset.nav === app.route?.name));
}

async function answer(qid, a) {
  try {
    await api(`/api/questions/${qid}/${a}`, {});
    toast(a === 'yes' ? 'Approved' : 'Declined');
  } catch (e) {
    toast(e.message);
  }
}

function connectGlobal() {
  const es = new EventSource('/api/stream');
  es.addEventListener('state', (e) => {
    app.state = JSON.parse(e.data);
    renderSidebar();
    app.onState?.();
  });
  es.addEventListener('run', (e) => {
    const r = JSON.parse(e.data);
    const i = app.runs.findIndex((x) => x.id === r.id);
    if (i >= 0) app.runs[i] = r;
    else app.runs.unshift(r);
    renderHistory();
    app.onRun?.(r);
  });
  es.onerror = () => setTimeout(async () => { if (es.readyState === 2) { await refresh(); connectGlobal(); } }, 3000);
}

async function refresh() {
  [app.state, app.runs] = await Promise.all([api('/api/state'), api('/api/runs')]);
  renderSidebar();
}

// ── composer (shared by home, new run and the run dock) ─────────────────────
function modelOptions(selected) {
  const models = app.state?.meta.models ?? [];
  const def = app.state?.meta.defaultModel ?? '';
  return `<option value="">Default${def ? ` (${esc(def)})` : ''}</option>` + models.filter((m) => m.value !== 'default')
    .map((m) => `<option value="${esc(m.value)}"${m.value === selected ? ' selected' : ''} title="${esc(m.description || '')}">${esc(m.displayName)}</option>`).join('');
}
function effortOptions(selected) {
  return ['', 'low', 'medium', 'high', 'xhigh', 'max'].map((e) => `<option value="${e}"${e === (selected ?? '') ? ' selected' : ''}>${e ? `Effort: ${e}` : 'Effort: default'}</option>`).join('');
}
function bindSubmit(textarea, submit) {
  textarea.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      submit();
    }
  });
}

const SUGGESTIONS = [
  'Why did any pod restart in the last 24 hours? Fix it if it is a manifest problem.',
  'Check certificate expiry across the cluster and summarise.',
  'Which HelmReleases are behind their latest chart version?',
  'Explain what the Longhorn backup setup does and whether recent backups succeeded.',
];

function composerHtml({ placeholder, models = true, health = true }) {
  return `<div class="composer">
    <div class="row" style="align-items:flex-start;gap:0"><span class="prompt-sign">&gt;</span>
    <textarea id="prompt" rows="3" class="grow" placeholder="${esc(placeholder)}"></textarea></div>
    <div class="actions">
      ${models ? `<select id="model" aria-label="Model">${modelOptions()}</select><select id="effort" aria-label="Effort">${effortOptions()}</select>` : ''}
      <span class="grow"></span>
      ${health ? '<button class="btn" id="health">Run health review</button>' : ''}
      <button class="btn primary" id="start">Start <span class="muted small" style="color:inherit;opacity:.75">↵</span></button>
    </div></div>
    <div class="chips">${SUGGESTIONS.map((s) => `<button class="chip" data-suggest="${esc(s)}">${esc(s.length > 60 ? `${s.slice(0, 58)}…` : s)}</button>`).join('')}</div>`;
}
function bindComposer() {
  const ta = $('#prompt');
  const opts = () => ({ model: $('#model')?.value || undefined, effort: $('#effort')?.value || undefined });
  const start = async () => {
    if (!ta.value.trim()) return ta.focus();
    try {
      const r = await api('/api/runs', { prompt: ta.value, ...opts() });
      navigate(`/runs/${r.id}`);
    } catch (e) { toast(e.message); }
  };
  bindSubmit(ta, start);
  $('#start').onclick = start;
  const h = $('#health');
  if (h) h.onclick = async () => {
    try {
      const r = await api('/api/runs', { kind: 'health', ...opts() });
      navigate(`/runs/${r.id}`);
    } catch (e) { toast(e.message); }
  };
  view.querySelectorAll('[data-suggest]').forEach((c) => (c.onclick = () => { ta.value = c.dataset.suggest; ta.focus(); }));
  ta.focus({ preventScroll: true });
}

// ── views ───────────────────────────────────────────────────────────────────
function viewHome() {
  app.routeTitle = 'Claude Agent';
  const s = app.state;
  const runs = app.runs;
  const lastHealth = runs.find((r) => r.kind === 'health' && !isLive(r));
  const next = (s?.schedules ?? []).map((x) => ({ ...x, at: nextCron(x.cron) })).filter((x) => x.at).sort((a, b) => a.at - b.at)[0];
  const today = new Date().toISOString().slice(0, 10);
  const todayTokens = runs.filter((r) => (r.startedAt || r.createdAt).slice(0, 10) === today).reduce((n, r) => n + totalTokens(r.usage), 0);
  const current = runs.find((r) => r.id === s?.current);
  view.className = 'view';
  view.innerHTML = `${pausedBanner()}
    <div class="welcome">
      <div class="head"><span class="spark">✻</span><div><b>Claude in the cluster</b><div class="small muted">Read-only commands run straight away. Cluster writes and repo changes come to you as yes/no questions here and on ntfy.</div></div></div>
      ${composerHtml({ placeholder: 'What should Claude look into? (Enter to start, Shift+Enter for a new line)' })}
    </div>
    <div class="cards" style="margin-top:18px">
      <div class="card stat"><div class="label">Now</div><div class="value">${current ? 'Working' : s?.pending.length ? 'Waiting' : 'Idle'}</div>
        <div class="hint">${current ? `<a href="/runs/${esc(current.id)}" data-link>${esc(runTitle(current))}</a>` : s?.pending.length ? `${s.pending.length} question${s.pending.length > 1 ? 's' : ''} for you` : `${s?.queued.length || 0} queued`}</div></div>
      <div class="card stat"><div class="label">Next health review</div><div class="value">${next ? esc(until(next.at)) : '–'}</div><div class="hint">${next ? `${fmtDateTime(next.at)} · <code>${esc(next.cron)}</code> UTC` : 'no schedule'}</div></div>
      <div class="card stat"><div class="label">Last health review</div><div class="value">${lastHealth?.report ? `<span class="badge ${esc(lastHealth.report.status)}">${esc(lastHealth.report.status)}</span>` : lastHealth ? `<span class="badge ${esc(lastHealth.status)}">${esc(lastHealth.status)}</span>` : '–'}</div>
        <div class="hint">${lastHealth ? `<a href="/runs/${esc(lastHealth.id)}" data-link>${esc(rel(lastHealth.startedAt))}</a>` : 'none yet'}</div></div>
      <div class="card stat"><div class="label">Tokens today</div><div class="value">${fmtTokens(todayTokens)}</div><div class="hint"><a href="/usage" data-link>Usage and plan limits →</a></div></div>
    </div>
    <h2 class="section">Recent runs</h2>
    <div class="card" style="padding:4px 10px">${runsTable(runs.slice(0, 12))}</div>`;
  bindComposer();
  app.onRun = app.onState = debounce(() => app.route?.name === 'home' && document.activeElement?.id !== 'prompt' && !$('#prompt')?.value && viewHome(), 400);
}

function runsTable(runs) {
  if (!runs.length) return '<div class="empty">No runs yet. Start one above.</div>';
  return `<table class="list"><thead><tr><th>Run</th><th>Status</th><th class="num">Tokens</th><th class="num">When</th></tr></thead><tbody>${runs.map((r) => `
    <tr><td><a href="/runs/${esc(r.id)}" data-link>${esc(runTitle(r))}</a><div class="small muted">${esc(r.trigger)}${r.model ? ` · ${esc(r.model)}` : ''}${r.outcome ? ` · ${esc(r.outcome)}` : ''}</div></td>
    <td><span class="badge ${esc(r.status)}">${esc(r.status)}</span></td><td class="num">${r.usage ? fmtTokens(totalTokens(r.usage)) : '–'}</td>
    <td class="num small muted">${esc(rel(r.startedAt || r.createdAt))}</td></tr>`).join('')}</tbody></table>`;
}

function viewNew() {
  app.routeTitle = 'New run · Claude Agent';
  view.className = 'view';
  view.innerHTML = `<h1 class="page">New run</h1><p class="subtitle">Give Claude a task in the cluster, or start a health review now. You'll get questions on ntfy for anything that changes something.</p>
    ${composerHtml({ placeholder: 'Describe the task. Claude works in a fresh clone of the repo with read access to the cluster.' })}`;
  bindComposer();
}

// ── usage ───────────────────────────────────────────────────────────────────
async function viewUsage() {
  app.routeTitle = 'Usage · Claude Agent';
  view.className = 'view wide';
  view.innerHTML = '<h1 class="page">Usage</h1><p class="subtitle">Tokens per run as reported by the Agent SDK, and the latest claude.ai plan limit readings.</p><div class="skeleton"></div><div class="skeleton"></div>';
  const u = await api('/api/usage');
  const sum = (days) => days.reduce((a, d) => ({ tokens: a.tokens + totalTokens(d), output: a.output + d.output, cost: a.cost + d.cost, runs: a.runs + d.runs }), { tokens: 0, output: 0, cost: 0, runs: 0 });
  const today = sum(u.days.slice(-1)), week = sum(u.days.slice(-7)), month = sum(u.days);
  const cat = u.days.reduce((a, d) => ({ input: a.input + d.input, output: a.output + d.output, cacheRead: a.cacheRead + d.cacheRead, cacheWrite: a.cacheWrite + d.cacheWrite }), { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 });
  const limits = activeLimits(u.limits);
  const g = guardOf();
  view.innerHTML = `<h1 class="page">Usage</h1><p class="subtitle">Tokens per run as reported by the Agent SDK, and the latest claude.ai plan limit readings.</p>
    <div class="cards">
      <div class="card stat"><div class="label">Today</div><div class="value">${fmtTokens(today.tokens)}</div><div class="hint">${today.runs} run${today.runs === 1 ? '' : 's'} · ${fmtTokens(today.output)} output</div></div>
      <div class="card stat"><div class="label">Last 7 days</div><div class="value">${fmtTokens(week.tokens)}</div><div class="hint">${week.runs} runs · ${fmtTokens(week.output)} output</div></div>
      <div class="card stat"><div class="label">Last 30 days</div><div class="value">${fmtTokens(month.tokens)}</div><div class="hint">${month.runs} runs · ${fmtTokens(month.output)} output</div></div>
      <div class="card stat"><div class="label">API-equivalent, 30 days</div><div class="value">${fmtCost(month.cost)}</div><div class="hint">SDK estimate; the subscription is not billed per token</div></div>
    </div>
    <h2 class="section">Plan limits</h2>
    ${pausedBanner()}
    <div class="card">${limits.length ? limits.map((l) => `<div class="meter"><span>${esc(l.label)}</span>
      ${l.utilization != null ? limitBar(l) : `<span><span class="badge ${l.status === 'allowed' ? 'healthy' : l.status === 'rejected' ? 'failed' : 'findings'}">${esc({ allowed: 'within limit', allowed_warning: 'near limit', rejected: 'limit reached' }[l.status] || l.status || 'unknown')}</span></span>`}
      <span class="val">${l.utilization != null ? `${Math.round(l.utilization)}%` : ''}${l.resetsAt ? ` <span class="muted small">resets ${esc(until(l.resetsAt))}</span>` : ''}</span></div>`).join('')
      : '<div class="muted">No readings yet.</div>'}
      <div class="guard-note small">
        <span><i class="mark-key"></i>New runs wait from <b>${g.pauseAt}%</b></span>
        <span><i class="mark-key stop"></i>Running sessions stop at <b>${g.stopAt}%</b></span>
        <span>Extra (paid) usage: <b>never used</b>${u.extra?.enabled != null ? ` · ${u.extra.enabled ? 'enabled' : 'disabled'} on the account` : ''}</span>
        <span class="muted">Updated ${esc(rel(limits.map((l) => l.updatedAt).sort().pop()))}. The windows are shared with your own Claude usage.</span>
      </div></div>
    <h2 class="section">Tokens per day</h2>
    <div class="card"><div class="row spread" style="margin-bottom:6px"><span class="small muted">All tokens processed (input, output and cache), UTC days</span>
      <button class="btn sm ghost" id="toggle-table">Show table</button></div>
      <div class="chart" id="chart"></div><div id="chart-table" hidden></div></div>
    <div class="cards" style="margin-top:12px;grid-template-columns:repeat(auto-fit,minmax(320px,1fr))">
      <div class="card"><h4 class="muted small" style="margin:0 0 8px;text-transform:uppercase;letter-spacing:.06em">By kind, 30 days</h4>
        <table class="list"><tbody>
          <tr><td>Output</td><td class="num">${fmtTokens(cat.output)}</td></tr>
          <tr><td>Input (uncached)</td><td class="num">${fmtTokens(cat.input)}</td></tr>
          <tr><td>Cache writes</td><td class="num">${fmtTokens(cat.cacheWrite)}</td></tr>
          <tr><td>Cache reads</td><td class="num">${fmtTokens(cat.cacheRead)}</td></tr></tbody></table></div>
      <div class="card"><h4 class="muted small" style="margin:0 0 8px;text-transform:uppercase;letter-spacing:.06em">By model, 30 days</h4>
        ${Object.keys(u.models).length ? `<table class="list"><thead><tr><th>Model</th><th class="num">Output</th><th class="num">Total</th></tr></thead><tbody>${Object.entries(u.models).sort((a, b) => totalTokens(b[1]) - totalTokens(a[1]))
          .map(([m, t]) => `<tr><td class="mono">${esc(m)}</td><td class="num">${fmtTokens(t.output)}</td><td class="num">${fmtTokens(totalTokens(t))}</td></tr>`).join('')}</tbody></table>` : '<div class="muted">No runs with usage yet.</div>'}</div>
    </div>`;
  drawChart($('#chart'), u.days);
  $('#chart-table').innerHTML = `<table class="list"><thead><tr><th>Day</th><th class="num">Runs</th><th class="num">Output</th><th class="num">Input</th><th class="num">Cache read</th><th class="num">Cache write</th><th class="num">Total</th></tr></thead><tbody>${u.days.slice().reverse()
    .map((d) => `<tr><td>${esc(d.day)}</td><td class="num">${d.runs}</td><td class="num">${fmtTokens(d.output)}</td><td class="num">${fmtTokens(d.input)}</td><td class="num">${fmtTokens(d.cacheRead)}</td><td class="num">${fmtTokens(d.cacheWrite)}</td><td class="num">${fmtTokens(totalTokens(d))}</td></tr>`).join('')}</tbody></table>`;
  $('#toggle-table').onclick = (e) => {
    const t = $('#chart-table');
    t.hidden = !t.hidden;
    $('#chart').hidden = !t.hidden;
    e.target.textContent = t.hidden ? 'Show table' : 'Show chart';
  };
}

function niceMax(v) {
  if (v <= 0) return 1;
  const p = 10 ** Math.floor(Math.log10(v));
  return [1, 2, 2.5, 5, 10].map((m) => m * p).find((m) => m >= v);
}

function drawChart(el, days) {
  const draw = () => {
    const W = el.clientWidth || 600, H = 240, L = 46, R = 8, T = 10, B = 26;
    const max = niceMax(Math.max(...days.map(totalTokens)));
    const bw = (W - L - R) / days.length;
    const y = (v) => T + (H - T - B) * (1 - v / max);
    const ticks = [0, 0.25, 0.5, 0.75, 1].map((f) => f * max);
    const step = Math.ceil(days.length / (W < 500 ? 4 : 8));
    const bar = (d, i) => {
      const v = totalTokens(d);
      if (!v) return '';
      const x = L + i * bw + 1, w = Math.max(1, bw - 2), top = y(v), base = y(0), r = Math.min(4, w / 2, base - top);
      return `<path data-i="${i}" d="M${x},${base}V${top + r}Q${x},${top} ${x + r},${top}H${x + w - r}Q${x + w},${top} ${x + w},${top + r}V${base}Z"/>`;
    };
    el.innerHTML = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Tokens per day, last 30 days">
      <g class="grid">${ticks.map((t) => `<line x1="${L}" x2="${W - R}" y1="${y(t)}" y2="${y(t)}"/>`).join('')}</g>
      <g class="axis">${ticks.map((t) => `<text x="${L - 8}" y="${y(t) + 4}" text-anchor="end">${fmtTokens(t)}</text>`).join('')}
      ${days.map((d, i, all) => ((i % step === 0 && all.length - 1 - i >= step / 2) || i === all.length - 1 ? `<text x="${L + i * bw + bw / 2}" y="${H - 6}" text-anchor="middle">${esc(new Date(`${d.day}T00:00:00Z`).toLocaleDateString([], { month: 'short', day: 'numeric', timeZone: 'UTC' }))}</text>` : '')).join('')}</g>
      <g class="bars">${days.map(bar).join('')}</g>
      <g>${days.map((d, i) => `<rect class="hit" data-i="${i}" x="${L + i * bw}" y="${T}" width="${bw}" height="${H - T - B}"/>`).join('')}</g></svg>
      <div class="tooltip" hidden></div>`;
    const tip = $('.tooltip', el);
    el.querySelectorAll('.hit').forEach((h) => {
      h.addEventListener('mouseenter', () => {
        const i = Number(h.dataset.i), d = days[i];
        el.querySelectorAll('.bars path').forEach((p) => p.classList.toggle('dim', p.dataset.i !== String(i)));
        tip.hidden = false;
        tip.innerHTML = `<b>${esc(new Date(`${d.day}T00:00:00Z`).toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric', timeZone: 'UTC' }))}</b>
          <dl class="kv"><dt>Total</dt><dd>${fmtTokens(totalTokens(d))}</dd><dt>Output</dt><dd>${fmtTokens(d.output)}</dd><dt>Input</dt><dd>${fmtTokens(d.input)}</dd>
          <dt>Cache read</dt><dd>${fmtTokens(d.cacheRead)}</dd><dt>Cache write</dt><dd>${fmtTokens(d.cacheWrite)}</dd><dt>Runs</dt><dd>${d.runs}</dd><dt>API-equiv.</dt><dd>${fmtCost(d.cost)}</dd></dl>`;
        const x = L + i * bw + bw / 2;
        tip.style.left = `${Math.min(Math.max(0, x - 85), W - 180)}px`;
        tip.style.top = '0px';
      });
      h.addEventListener('mouseleave', () => {
        tip.hidden = true;
        el.querySelectorAll('.bars path').forEach((p) => p.classList.remove('dim'));
      });
    });
  };
  draw();
  const ro = new ResizeObserver(debounce(draw, 100));
  ro.observe(el);
  app.cleanup.push(() => ro.disconnect());
}

// ── run transcript ──────────────────────────────────────────────────────────
const TOOL_LABEL = { Edit: 'Update', MultiEdit: 'Update', Write: 'Write', Read: 'Read', Grep: 'Search', Glob: 'Search', TodoWrite: 'Update Todos', mcp__agent__ask_user: 'Ask', mcp__agent__submit_report: 'Report', Task: 'Task', Agent: 'Task' };
function toolArgs(name, i = {}) {
  if (name === 'Bash') return i.command ?? '';
  if (name === 'Read' || name === 'Write' || name === 'Edit' || name === 'MultiEdit') return i.file_path ?? '';
  if (name === 'Grep') return `pattern: "${i.pattern ?? ''}"${i.path ? `, path: ${i.path}` : ''}`;
  if (name === 'Glob') return i.pattern ?? '';
  if (name === 'Task' || name === 'Agent') return i.description ?? '';
  if (name === 'Skill') return i.skill ?? i.name ?? '';
  if (name === 'mcp__agent__ask_user') return i.question ?? '';
  if (name === 'mcp__agent__submit_report') return `${i.status ?? ''}: ${i.title ?? ''}`;
  if (name === 'TodoWrite') return '';
  const s = JSON.stringify(i);
  return s.length > 160 ? `${s.slice(0, 160)}…` : s;
}
function diffLines(oldS, newS) {
  return `${String(oldS ?? '').split('\n').map((l) => `<span class="del">- ${esc(l)}</span>`).join('')}${String(newS ?? '').split('\n').map((l) => `<span class="add">+ ${esc(l)}</span>`).join('')}`;
}
function resultHtml(ev, out) {
  const text = String(out ?? '');
  const lines = text.split('\n');
  if (ev.name === 'Read' && !ev.isError) return `Read ${lines.length} line${lines.length === 1 ? '' : 's'}`;
  const short = lines.slice(0, 4).join('\n');
  const more = lines.length > 4 ? `<button class="more" data-expand>… +${lines.length - 4} lines (expand)</button>` : '';
  return `<pre data-full="${esc(text)}">${esc(short || '(no output)')}</pre>${more}`;
}

function questionHtml(ev) {
  return `<div class="prompt-box" id="q-${esc(ev.qid)}"><div class="q-title"><span class="glyph-q">?</span><span>${esc(ev.title)}</span></div>
    ${ev.detail && ev.detail !== ev.title ? `<div class="q-body">${md(ev.detail)}</div>` : ''}<div class="small muted" style="margin-bottom:6px">Do you want to proceed?</div>
    <div class="options"><button class="opt y" data-answer="${esc(ev.qid)}" data-a="yes"><span class="n">1.</span>Yes</button>
    <button class="opt n2" data-answer="${esc(ev.qid)}" data-a="no"><span class="n">2.</span>No</button></div></div>`;
}

const VERBS = ['Reconciling', 'Herding pods', 'Grepping logs', 'Consulting etcd', 'Tailing events', 'Diffing manifests', 'Kustomizing', 'Untangling YAML', 'Asking Flux nicely', 'Counting replicas'];
const SPIN = ['·', '✢', '✳', '✶', '✻', '✽', '✻', '✶', '✳', '✢'];

async function viewRun(id) {
  view.className = 'view wide';
  view.innerHTML = '<div class="skeleton" style="width:40%;height:22px"></div><div class="skeleton"></div><div class="skeleton"></div>';
  let data;
  try {
    data = await api(`/api/runs/${id}`);
  } catch (e) {
    view.innerHTML = `<div class="empty">Run not found. <a href="/" data-link>Back to the overview</a></div>`;
    return;
  }
  let run = data.run;
  const tools = new Map();
  const showThinking = store.get('showThinking') !== 'false';

  view.innerHTML = `
    <div class="run-head"><div><h1 id="run-title"></h1></div><div class="row"><span id="run-badge" class="badge"></span>
      <button class="btn sm ghost" id="toggle-thinking">${showThinking ? 'Hide' : 'Show'} reasoning</button>
      <button class="btn sm" id="stop" hidden>Stop</button></div></div>
    <div class="run-meta" id="run-meta"></div>
    <div class="run-grid">
      <div>
        <div class="transcript" id="transcript"></div>
        <div class="working" id="working" hidden><span class="spin"></span><span class="verb"></span><span class="detail"></span></div>
        <div class="dock" id="dock">
          <div class="composer"><div class="row" style="align-items:flex-start;gap:0"><span class="prompt-sign">&gt;</span>
            <textarea id="msg" rows="2" class="grow"></textarea></div>
            <div class="actions"><span class="grow small muted" id="dock-hint"></span><button class="btn primary sm" id="send">Send ↵</button></div></div>
          <div class="statusline" id="statusline"></div>
        </div>
      </div>
      <aside class="run-side" id="run-side"></aside>
    </div>`;
  const tr = $('#transcript');

  const add = (ev) => {
    const d = document.createElement('div');
    d.className = `ev${ev.sub ? ' sub' : ''}`;
    switch (ev.type) {
      case 'user':
        d.classList.add('user');
        d.innerHTML = ev.auto
          ? `<div class="bubble"><span class="sign">&gt;</span><details><summary>${esc(ev.text)}</summary><div class="body small">${esc(ev.auto)}</div></details></div>`
          : `<div class="bubble"><span class="sign">&gt;</span><div class="body">${esc(ev.text)}</div></div>`;
        break;
      case 'thinking':
        d.classList.add('thinking');
        d.innerHTML = `<details${showThinking ? ' open' : ''}><summary><span class="spark">✻</span>Thinking</summary><div class="body">${md(ev.text)}</div></details>`;
        break;
      case 'text':
        d.classList.add('text');
        d.innerHTML = `<div class="line"><span class="bullet">⏺</span><div class="body">${md(ev.text)}</div></div>`;
        break;
      case 'tool_use': {
        d.classList.add('tool', 'pending');
        const label = TOOL_LABEL[ev.name] || ev.name.replace(/^mcp__\w+__/, '');
        const args = toolArgs(ev.name, ev.input);
        let extra = '';
        if (ev.name === 'Edit' || ev.name === 'MultiEdit') {
          const edits = ev.input?.edits ?? [{ old_string: ev.input?.old_string, new_string: ev.input?.new_string }];
          extra = `<div class="result"><span class="elbow">⎿</span><pre class="diff-inline">${edits.map((x) => diffLines(x.old_string, x.new_string)).join('')}</pre></div>`;
        } else if (ev.name === 'TodoWrite') {
          extra = `<div class="result"><span class="elbow">⎿</span><ul class="todos">${(ev.input?.todos ?? []).map((t) => `<li class="${esc(t.status)}"><span>${t.status === 'completed' ? '☒' : '☐'}</span><span>${esc(t.content)}</span></li>`).join('')}</ul></div>`;
        }
        d.innerHTML = `<div class="line"><span class="bullet">⏺</span><div><span class="name">${esc(label)}</span>${args ? `<span class="args">(${esc(args)})</span>` : ''}</div></div>${extra}<div class="out"></div>`;
        tools.set(ev.id, { el: d, ev });
        break;
      }
      case 'tool_result': {
        const t = tools.get(ev.id);
        if (!t) return;
        t.el.classList.remove('pending');
        if (ev.isError) t.el.classList.add('err');
        if (['Edit', 'MultiEdit', 'TodoWrite'].includes(t.ev.name) && !ev.isError) return;
        $('.out', t.el).innerHTML = `<div class="result"><span class="elbow">⎿</span><div>${resultHtml({ ...t.ev, isError: ev.isError }, ev.output)}</div></div>`;
        return;
      }
      case 'question': {
        // A permission prompt belongs to the tool call that triggered it, like in Claude Code
        const owner = [...tools.values()].reverse().find((t) => t.el.classList.contains('pending'));
        if (owner && !owner.ev.sub) {
          const box = document.createElement('div');
          box.className = 'q-inline';
          box.innerHTML = questionHtml(ev);
          owner.el.insertBefore(box, $('.out', owner.el));
          return;
        }
        d.innerHTML = questionHtml(ev);
        break;
      }
      case 'answer': {
        const q = document.getElementById(`q-${ev.qid}`);
        if (q) {
          q.classList.add('answered');
          $('.options', q).outerHTML = `<div class="answer"><span class="muted">⎿</span> ${ev.answer === 'yes' ? '<span style="color:var(--ok)">Yes</span>' : '<span style="color:var(--bad)">No</span>'} <span class="muted">· via ${esc(ev.by)} · ${fmtTime(ev.t)}</span></div>`;
        }
        return;
      }
      case 'diff':
        d.innerHTML = `<details class="diff-card" open><summary><b>Proposed change</b><span class="small muted mono">${esc(ev.stat.split('\n').pop())}</span></summary>
          <pre>${String(ev.patch ?? '').split('\n').map((l) => { const c = l.startsWith('+') && !l.startsWith('+++') ? 'add' : l.startsWith('-') && !l.startsWith('---') ? 'del' : l.startsWith('@@') ? 'hunk' : ''; return c ? `<span class="${c}">${esc(l)}</span>` : `${esc(l)}\n`; }).join('')}</pre></details>`;
        break;
      case 'report':
        d.innerHTML = `<div class="report-card"><div class="rc-head"><span class="badge ${esc(ev.report.status)}">${esc(ev.report.status)}</span><b>${esc(ev.report.title)}</b></div><div class="rc-body">${md(ev.report.summary)}</div></div>`;
        break;
      case 'result':
        d.className = 'ev status';
        d.textContent = `${ev.turns ?? 0} turns · ${fmtDuration(ev.durationMs)}${ev.costUsd != null ? ` · ${fmtCost(ev.costUsd)} API-equiv.` : ''}${ev.subtype !== 'success' ? ` · ${ev.subtype}` : ''}`;
        break;
      case 'status':
        d.className = 'ev status';
        d.innerHTML = `<span>${fmtTime(ev.t)} · ${esc(ev.text)}${ev.prUrl ? ` · <a href="${esc(ev.prUrl)}" target="_blank" rel="noopener">PR</a>` : ''}</span>`;
        break;
      default:
        return;
    }
    const atBottom = $('.main').scrollTop + $('.main').clientHeight >= $('.main').scrollHeight - 160;
    tr.appendChild(d);
    if (atBottom) $('.main').scrollTop = $('.main').scrollHeight;
  };

  const renderRun = () => {
    app.routeTitle = `${runTitle(run)} · Claude Agent`;
    statusPill();
    $('#run-title').textContent = runTitle(run);
    $('#topbar-title').textContent = runTitle(run);
    const b = $('#run-badge');
    b.className = `badge ${run.status}`;
    b.textContent = run.status;
    const live = isLive(run);
    $('#stop').hidden = !live;
    const dur = run.startedAt ? (run.endedAt ? new Date(run.endedAt) : new Date()) - new Date(run.startedAt) : null;
    $('#run-meta').innerHTML = [esc(run.trigger), run.startedAt && fmtDateTime(run.startedAt), dur != null && fmtDuration(dur),
      run.continueFrom && `continues <a href="/runs/${esc(run.continueFrom)}" data-link>${esc(run.continueFrom)}</a>`, run.outcome && esc(run.outcome),
      run.error && `<span style="color:var(--bad)">${esc(run.error)}</span>`].filter(Boolean).map((x) => `<span>${x}</span>`).join('');
    const u = run.usage;
    const ctx = run.context;
    $('#statusline').innerHTML = [
      `<span>${esc(run.model || app.state?.meta.defaultModel || '')}${run.effort ? ` · ${esc(run.effort)}` : ''}</span>`,
      ctx ? `<span class="ctx">ctx <span class="bar ${ctx.percentage > 85 ? 'bad' : ctx.percentage > 65 ? 'warn' : ''}"><span style="width:${Math.min(100, ctx.percentage)}%"></span></span>${ctx.percentage.toFixed(0)}%</span>` : '',
      u ? `<span>↑ ${fmtTokens(u.input + u.cacheRead + u.cacheWrite)} ↓ ${fmtTokens(u.output)}</span>` : '',
      run.costUsd != null ? `<span>${fmtCost(run.costUsd)}</span>` : '',
    ].filter(Boolean).join('');
    const msg = $('#msg');
    msg.placeholder = live ? 'Message Claude while it works (Enter to send)' : run.sessionId ? 'Continue this session with a follow-up (Enter to send)' : 'This run has no session to continue';
    msg.disabled = !live && !run.sessionId;
    $('#dock-hint').textContent = live ? 'Claude reads it at its next step' : run.sessionId ? 'Starts a new run with this context and repo clone' : '';
    // side panel
    const todos = run.todos ?? [];
    const pending = (app.state?.pending ?? []).filter((q) => q.runId === run.id);
    $('#run-side').innerHTML = `
      <div class="card"><h4>Details</h4><dl class="kv">
        <dt>Status</dt><dd>${esc(run.status)}</dd><dt>Model</dt><dd>${esc(run.model || '–')}</dd><dt>Effort</dt><dd>${esc(run.effort || 'default')}</dd>
        <dt>Turns</dt><dd>${run.turns ?? '–'}</dd><dt>Output</dt><dd>${u ? fmtTokens(u.output) : '–'}</dd><dt>Input</dt><dd>${u ? fmtTokens(u.input) : '–'}</dd>
        <dt>Cache read</dt><dd>${u ? fmtTokens(u.cacheRead) : '–'}</dd><dt>Cache write</dt><dd>${u ? fmtTokens(u.cacheWrite) : '–'}</dd>
        <dt>API-equiv.</dt><dd>${fmtCost(run.costUsd)}</dd></dl></div>
      ${ctx ? `<div class="card"><h4>Context</h4><div class="bar ${ctx.percentage > 85 ? 'bad' : ctx.percentage > 65 ? 'warn' : ''}"><span style="width:${Math.min(100, ctx.percentage)}%"></span></div>
        <div class="small muted" style="margin-top:6px">${fmtTokens(ctx.totalTokens)} of ${fmtTokens(ctx.maxTokens)} (${ctx.percentage.toFixed(0)}%)</div></div>` : ''}
      ${todos.length ? `<div class="card"><h4>Todos</h4><ul class="todos">${todos.map((t) => `<li class="${esc(t.status)}"><span>${t.status === 'completed' ? '☒' : t.status === 'in_progress' ? '◐' : '☐'}</span><span>${esc(t.status === 'in_progress' && t.activeForm ? t.activeForm : t.content)}</span></li>`).join('')}</ul></div>` : ''}
      ${pending.length ? `<div class="card" style="border-color:var(--warn)"><h4 style="color:var(--warn)">Waiting for you</h4>${pending.map((q) => `<div class="small" style="margin-bottom:6px">${esc(q.title)}</div>`).join('')}</div>` : ''}`;
    // working indicator
    const w = $('#working');
    w.hidden = !live;
    if (live) {
      $('.detail', w).textContent = run.status === 'waiting' ? '(waiting for your answer)' : `(${fmtDuration(dur)}${u ? ` · ↓ ${fmtTokens(u.output)} tokens` : ''})`;
      w.style.color = run.status === 'waiting' ? 'var(--warn)' : '';
    }
  };

  // spinner + rotating verb while live
  let tick = 0;
  const spinTimer = setInterval(() => {
    if (!isLive(run)) return;
    tick++;
    $('#working .spin').textContent = run.status === 'waiting' ? '◆' : SPIN[tick % SPIN.length];
    if (tick % 30 === 1) $('#working .verb').textContent = run.status === 'waiting' ? 'Waiting' : `${VERBS[Math.floor(tick / 30) % VERBS.length]}…`;
    if (tick % 10 === 0) renderRun();
  }, 120);
  app.cleanup.push(() => clearInterval(spinTimer));

  // history first, then live events (buffered so nothing between the two is lost)
  let buf = [];
  const es = new EventSource(`/api/runs/${id}/stream`);
  es.onmessage = (e) => { const ev = JSON.parse(e.data); buf ? buf.push(ev) : add(ev); };
  es.addEventListener('run', (e) => { run = JSON.parse(e.data); renderRun(); });
  app.cleanup.push(() => es.close());
  data.events.forEach(add);
  const last = data.events.length ? data.events[data.events.length - 1].t : '';
  buf.filter((ev) => ev.t > last).forEach(add);
  buf = null;
  renderRun();
  $('.main').scrollTop = $('.main').scrollHeight;
  app.onState = renderRun;

  $('#toggle-thinking').onclick = (e) => {
    const show = store.get('showThinking') === 'false';
    store.set('showThinking', String(show));
    tr.querySelectorAll('.ev.thinking details').forEach((d) => (d.open = show));
    e.target.textContent = `${show ? 'Hide' : 'Show'} reasoning`;
  };
  $('#stop').onclick = async () => {
    if (!confirm('Stop this run? Pending questions are answered "no".')) return;
    try { await api(`/api/runs/${id}/stop`, {}); } catch (e) { toast(e.message); }
  };
  const send = async () => {
    const msg = $('#msg');
    const text = msg.value.trim();
    if (!text) return;
    try {
      if (isLive(run)) {
        await api(`/api/runs/${id}/messages`, { text });
        msg.value = '';
      } else {
        const r = await api('/api/runs', { prompt: text, continueFrom: id });
        navigate(`/runs/${r.id}`);
      }
    } catch (e) { toast(e.message); }
  };
  bindSubmit($('#msg'), send);
  $('#send').onclick = send;
}

// ── router ──────────────────────────────────────────────────────────────────
function debounce(fn, ms) {
  let t;
  return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); };
}
function parse(path) {
  const m = path.match(/^\/runs\/([\w-]+)$/);
  if (m) return { name: 'run', id: m[1] };
  if (path === '/new') return { name: 'new' };
  if (path === '/usage') return { name: 'usage' };
  return { name: 'home' };
}
async function render() {
  app.cleanup.splice(0).forEach((f) => f());
  app.onRun = app.onState = undefined;
  app.route = parse(location.pathname);
  document.body.classList.remove('menu-open');
  $('#topbar-title').textContent = { home: 'Claude Agent', new: 'New run', usage: 'Usage', run: 'Run' }[app.route.name];
  renderSidebar();
  $('.main').scrollTop = 0;
  try {
    if (app.route.name === 'run') await viewRun(app.route.id);
    else if (app.route.name === 'new') viewNew();
    else if (app.route.name === 'usage') await viewUsage();
    else viewHome();
  } catch (e) {
    view.innerHTML = `<div class="empty">Something went wrong: ${esc(e.message)}</div>`;
  }
  statusPill();
  if (app.route.name !== 'run') $('.main').scrollTop = 0;
}
function navigate(path) {
  if (path !== location.pathname) history.pushState({}, '', path);
  render();
}

document.addEventListener('click', (e) => {
  const a = e.target.closest('a[data-link], a[href^="/runs/"], a[href="/"], a[href="/usage"], a[href="/new"]');
  if (a && !e.metaKey && !e.ctrlKey && !e.shiftKey && a.origin === location.origin) {
    e.preventDefault();
    navigate(a.pathname);
    return;
  }
  const ans = e.target.closest('[data-answer]');
  if (ans) {
    ans.disabled = true;
    answer(ans.dataset.answer, ans.dataset.a);
    return;
  }
  const more = e.target.closest('[data-expand]');
  if (more) {
    const pre = more.previousElementSibling;
    pre.textContent = pre.dataset.full;
    more.remove();
  }
});
window.addEventListener('popstate', render);
document.addEventListener('keydown', (e) => {
  const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName);
  if (e.key === 'Escape') document.body.classList.remove('menu-open');
  if (!typing && !e.metaKey && !e.ctrlKey && !e.altKey && e.key === 'n') { e.preventDefault(); navigate('/new'); }
  if (!typing && e.key === '/') { e.preventDefault(); $('#history-filter').focus(); }
});
$('#menu').onclick = () => document.body.classList.add('menu-open');
$('#scrim').onclick = () => document.body.classList.remove('menu-open');
$('#history-filter').addEventListener('input', renderHistory);
$('#theme-toggle').onclick = () => {
  const dark = matchMedia('(prefers-color-scheme: dark)').matches;
  const cur = document.documentElement.dataset.theme || (dark ? 'dark' : 'light');
  const next = cur === 'dark' ? 'light' : 'dark';
  document.documentElement.dataset.theme = next;
  store.set('theme', next);
};
setInterval(() => { if (app.route?.name !== 'run') renderHistory(); renderInbox(); }, 60_000);

await refresh();
connectGlobal();
render();
