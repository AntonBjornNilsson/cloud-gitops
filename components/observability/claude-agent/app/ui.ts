// Server-rendered shell pages; the run list and transcripts render client-side from the JSON API + SSE.
import type { Run } from './store.ts';

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

const CSS = `
:root{--bg:#f6f7f9;--panel:#fff;--text:#1d2129;--muted:#667085;--border:#e3e6eb;--accent:#4f46e5;--ok:#16794c;--okbg:#e5f5ec;
--warn:#a15c07;--warnbg:#fdf3e1;--bad:#b42318;--badbg:#fdecea;--code:#f1f3f6;--think:#f4f2fb;--add:#e6f6ea;--del:#fbe9e9;color-scheme:light}
@media (prefers-color-scheme:dark){:root{--bg:#0f1115;--panel:#171a21;--text:#e6e8ec;--muted:#98a2b3;--border:#2a2f3a;--accent:#8b85ff;
--ok:#4cc38a;--okbg:#12291e;--warn:#f0b35a;--warnbg:#2e2412;--bad:#ff7b72;--badbg:#341716;--code:#11141a;--think:#1c1a2b;--add:#132a1b;--del:#2e1517;color-scheme:dark}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 system-ui,-apple-system,Segoe UI,sans-serif}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
main{max-width:980px;margin:0 auto;padding:20px 16px 60px}
header{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:18px}h1{font-size:20px;margin:0}h2{font-size:16px;margin:24px 0 10px}
.muted{color:var(--muted)}.small{font-size:13px}
.panel{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:14px 16px;margin:10px 0}
button{font:inherit;border:1px solid var(--border);background:var(--panel);color:var(--text);border-radius:8px;padding:6px 14px;cursor:pointer}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff}button.yes{background:var(--ok);border-color:var(--ok);color:#fff}
button.no{background:var(--bad);border-color:var(--bad);color:#fff}button:disabled{opacity:.5;cursor:default}
textarea{width:100%;min-height:80px;font:inherit;background:var(--bg);color:var(--text);border:1px solid var(--border);border-radius:8px;padding:8px}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
table{width:100%;border-collapse:collapse}td,th{text-align:left;padding:8px 6px;border-bottom:1px solid var(--border);vertical-align:top}
th{font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);font-weight:600}
.badge{display:inline-block;font-size:12px;padding:1px 8px;border-radius:999px;background:var(--code);color:var(--muted);white-space:nowrap}
.b-running,.b-queued{background:var(--think);color:var(--accent)}.b-waiting{background:var(--warnbg);color:var(--warn)}
.b-done{background:var(--okbg);color:var(--ok)}.b-failed,.b-interrupted{background:var(--badbg);color:var(--bad)}
pre,code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px}
pre{background:var(--code);border-radius:8px;padding:10px;overflow-x:auto;white-space:pre-wrap;word-break:break-word;margin:6px 0}
p code,li code{background:var(--code);padding:1px 5px;border-radius:4px}
.ev{margin:8px 0}.ev.sub{margin-left:22px;border-left:2px solid var(--border);padding-left:10px}
.status{color:var(--muted);font-size:13px}
.think{background:var(--think);border-radius:8px;padding:8px 12px;font-style:italic;color:var(--muted)}
.think summary{cursor:pointer;font-style:normal;font-weight:600;font-size:13px}
.tool{border:1px solid var(--border);border-radius:8px;background:var(--panel)}
.tool>.head{padding:6px 10px;font-size:13px;display:flex;gap:8px;align-items:baseline}
.tool>.head b{font-family:ui-monospace,monospace}.tool .body{padding:0 10px 6px}
.tool details summary{cursor:pointer;font-size:12px;color:var(--muted);padding:2px 10px 6px}.tool.err{border-color:var(--bad)}
.q{border:2px solid var(--warn);background:var(--warnbg);border-radius:10px;padding:10px 14px}.q.answered{border-width:1px;opacity:.9}
.q h3{margin:0 0 6px;font-size:15px}
.report{border-left:4px solid var(--accent)}
.diff .add{background:var(--add)}.diff .del{background:var(--del)}.diff .hunk{color:var(--accent)}
.md h1,.md h2,.md h3{font-size:15px;margin:10px 0 4px}.md p{margin:6px 0}.md ul{margin:6px 0;padding-left:22px}
@media (max-width:640px){td:nth-child(2),th:nth-child(2){display:none}}
`;

// Small, safe markdown subset: fenced code, inline code, bold, headings, bullet lists, links
const MD = `
function md(src){
  const e=s=>s.replace(/[&<>"']/g,c=>'&#'+c.charCodeAt(0)+';');
  const inline=s=>e(s).replace(/\`([^\`]+)\`/g,'<code>$1</code>').replace(/\\*\\*([^*]+)\\*\\*/g,'<b>$1</b>')
    .replace(/\\[([^\\]]+)\\]\\((https?:[^)\\s]+)\\)/g,'<a href="$2" target="_blank" rel="noopener">$1</a>');
  const out=[];let list=false;const lines=String(src||'').split('\\n');
  for(let i=0;i<lines.length;i++){let l=lines[i];
    if(l.startsWith('\`\`\`')){const buf=[];i++;while(i<lines.length&&!lines[i].startsWith('\`\`\`'))buf.push(lines[i++]);
      if(list){out.push('</ul>');list=false}out.push('<pre>'+e(buf.join('\\n'))+'</pre>');continue}
    const li=l.match(/^\\s*[-*] (.*)/);
    if(li){if(!list){out.push('<ul>');list=true}out.push('<li>'+inline(li[1])+'</li>');continue}
    if(list){out.push('</ul>');list=false}
    const h=l.match(/^(#{1,4}) (.*)/);if(h){out.push('<h3>'+inline(h[2])+'</h3>');continue}
    if(l.trim())out.push('<p>'+inline(l)+'</p>');
  }
  if(list)out.push('</ul>');return out.join('');
}
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>'&#'+c.charCodeAt(0)+';');
const fmtTime=t=>t?new Date(t).toLocaleString([], {month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}):'';
async function post(url,body){const r=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body||{})});
  const j=await r.json().catch(()=>({}));if(!r.ok)throw new Error(j.error||r.statusText);return j}
`;

function shell(title: string, body: string, script: string): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title><style>${CSS}</style></head><body><main>${body}</main><script>${MD}${script}</script></body></html>`;
}

export function indexPage(schedules: { name: string; cron: string }[]): string {
  const sched = schedules.map((s) => `${esc(s.name)} <code>${esc(s.cron)}</code>`).join(', ');
  return shell('Claude Agent', `
<header><h1>Claude Agent</h1><span class="muted small">Schedules (UTC): ${sched}</span></header>
<div class="panel">
  <div class="row" style="justify-content:space-between"><b>New run</b>
    <button id="health">Run a health review now</button></div>
  <p class="small muted">Or give Claude a task. Read-only commands run straight away; cluster writes and repo changes are asked on ntfy (and here).</p>
  <textarea id="prompt" placeholder="e.g. Why does jellyfin restart every night? Fix it if it's a manifest problem."></textarea>
  <div class="row" style="margin-top:8px"><button class="primary" id="start">Start task</button><span id="err" class="small" style="color:var(--bad)"></span></div>
</div>
<h2>Runs</h2>
<div class="panel" style="padding:4px 10px"><table><thead><tr><th>Started</th><th>Trigger</th><th>Status</th><th>Run</th></tr></thead><tbody id="runs"></tbody></table></div>`, `
const tbody=document.getElementById('runs');
function label(r){return r.report?.title||(r.prompt||'').split('\\n')[0].slice(0,120)||(r.kind==='health'?'Health review':'Task')}
async function load(){const runs=await (await fetch('api/runs')).json();
  tbody.innerHTML=runs.map(r=>'<tr><td class="small">'+fmtTime(r.startedAt||r.createdAt)+'</td><td class="small muted">'+esc(r.trigger)+(r.continueFrom?' ↩':'')+'</td>'+
  '<td><span class="badge b-'+r.status+'">'+r.status+'</span></td><td><a href="runs/'+r.id+'">'+esc(label(r))+'</a>'+
  (r.outcome?'<div class="small muted">'+esc(r.outcome)+'</div>':'')+'</td></tr>').join('')||'<tr><td colspan="4" class="muted">No runs yet</td></tr>'}
load();new EventSource('api/stream').addEventListener('run',()=>load());
const err=document.getElementById('err');
document.getElementById('health').onclick=async()=>{try{const r=await post('api/runs',{kind:'health'});location.href='runs/'+r.id}catch(e){err.textContent=e.message}};
document.getElementById('start').onclick=async()=>{try{const r=await post('api/runs',{prompt:document.getElementById('prompt').value});location.href='runs/'+r.id}catch(e){err.textContent=e.message}};
`);
}

export function runPage(run: Run): string {
  return shell(`Claude Agent · ${run.id}`, `
<header><a href="../">← Runs</a><h1 id="title"></h1><span id="badge" class="badge"></span>
  <button id="stop" style="display:none;margin-left:auto">Stop</button></header>
<div id="meta" class="muted small"></div>
<div id="events"></div>
<div id="cont" class="panel" style="display:none"><b>Continue this session</b>
  <p class="small muted">Claude keeps the context and the repo clone of this run.</p>
  <textarea id="prompt" placeholder="Follow-up instruction or question"></textarea>
  <div class="row" style="margin-top:8px"><button class="primary" id="send">Continue</button><span id="err" class="small" style="color:var(--bad)"></span></div></div>`, `
const ID=${JSON.stringify(run.id)};let RUN=null;const box=document.getElementById('events');const tools={};const answered={};
function toolSummary(name,i){i=i||{};
  if(name==='Bash')return '<pre>'+esc(i.command)+'</pre>'+(i.description?'<div class="small muted">'+esc(i.description)+'</div>':'');
  if(name==='Edit'||name==='MultiEdit'){const edits=i.edits||[{old_string:i.old_string,new_string:i.new_string}];
    return '<div class="small">'+esc(i.file_path)+'</div>'+edits.map(x=>'<pre class="diff">'+String(x.old_string||'').split('\\n').map(l=>'<span class="del">- '+esc(l)+'</span>').join('\\n')+'\\n'+
      String(x.new_string||'').split('\\n').map(l=>'<span class="add">+ '+esc(l)+'</span>').join('\\n')+'</pre>').join('')}
  if(name==='Write')return '<div class="small">'+esc(i.file_path)+'</div><details><summary>content</summary><pre>'+esc(i.content)+'</pre></details>';
  if(i.file_path||i.path||i.pattern)return '<div class="small"><code>'+esc(i.file_path||i.path||'')+'</code> '+esc(i.pattern||'')+'</div>';
  return '<pre>'+esc(JSON.stringify(i,null,2))+'</pre>'}
function diffHtml(p){return String(p||'').split('\\n').map(l=>{const c=l.startsWith('+')&&!l.startsWith('+++')?'add':l.startsWith('-')&&!l.startsWith('---')?'del':l.startsWith('@@')?'hunk':'';
  return c?'<span class="'+c+'">'+esc(l)+'</span>':esc(l)}).join('\\n')}
function add(ev){const d=document.createElement('div');d.className='ev'+(ev.sub?' sub':'');
  switch(ev.type){
  case 'status':d.className+=' status';d.innerHTML=fmtTime(ev.t)+' · '+esc(ev.text)+(ev.prUrl?' · <a href="'+esc(ev.prUrl)+'" target="_blank">PR</a>':'');break;
  case 'thinking':d.innerHTML='<details class="think" open><summary>Reasoning</summary><div class="md">'+md(ev.text)+'</div></details>';break;
  case 'text':d.innerHTML='<div class="md">'+md(ev.text)+'</div>';break;
  case 'tool_use':{const n=String(ev.name).replace(/^mcp__agent__/,'');d.innerHTML='<div class="tool"><div class="head"><b>'+esc(n)+'</b><span class="muted small">'+fmtTime(ev.t)+'</span></div><div class="body">'+toolSummary(ev.name,ev.input)+'</div><div class="out"></div></div>';tools[ev.id]=d;break}
  case 'tool_result':{const t=tools[ev.id];if(t){const lines=String(ev.output||'').split('\\n').length;
    t.querySelector('.out').innerHTML='<details'+(ev.isError?' open':'')+'><summary>'+(ev.isError?'error':'output')+' · '+lines+' lines</summary><pre>'+esc(ev.output)+'</pre></details>';
    if(ev.isError)t.firstChild.classList.add('err')}return}
  case 'question':d.innerHTML='<div class="q" id="q-'+ev.qid+'"><h3>❓ '+esc(ev.title)+'</h3><div class="md">'+md(ev.detail)+'</div><div class="row ans">'+
    '<button class="yes" data-a="yes">Yes</button><button class="no" data-a="no">No</button><span class="small muted">also sent to ntfy</span></div></div>';
    d.querySelectorAll('button').forEach(b=>b.onclick=async()=>{b.disabled=true;try{await post('../api/questions/'+ev.qid+'/'+b.dataset.a)}catch(e){alert(e.message)}});break;
  case 'answer':{const q=document.getElementById('q-'+ev.qid);if(q){q.classList.add('answered');q.querySelector('.ans').innerHTML='<b>'+(ev.answer==='yes'?'✅ Yes':'❌ No')+'</b><span class="small muted">via '+esc(ev.by)+' · '+fmtTime(ev.t)+'</span>'}return}
  case 'diff':d.innerHTML='<details class="panel" open><summary><b>Proposed change</b></summary><pre>'+esc(ev.stat)+'</pre><pre class="diff">'+diffHtml(ev.patch)+'</pre></details>';break;
  case 'report':d.innerHTML='<div class="panel report"><div class="row"><span class="badge">'+esc(ev.report.status)+'</span><b>'+esc(ev.report.title)+'</b></div><div class="md">'+md(ev.report.summary)+'</div></div>';break;
  case 'result':d.className+=' status';d.textContent=(ev.turns||0)+' turns · '+Math.round((ev.durationMs||0)/1000)+'s'+(ev.costUsd!=null?' · est. $'+Number(ev.costUsd).toFixed(2):'')+(ev.subtype!=='success'?' · '+ev.subtype:'');break;
  default:return}
  const atBottom=innerHeight+scrollY>=document.body.scrollHeight-80;box.appendChild(d);if(atBottom)scrollTo(0,document.body.scrollHeight)}
function setRun(r){RUN=r;const t=r.report?.title||(r.prompt||'').split('\\n')[0].slice(0,100)||(r.kind==='health'?'Health review':'Task');
  document.getElementById('title').textContent=t;document.title='Claude Agent · '+t;
  const b=document.getElementById('badge');b.textContent=r.status;b.className='badge b-'+r.status;
  const live=['queued','running','waiting'].includes(r.status);document.getElementById('stop').style.display=live?'':'none';
  document.getElementById('cont').style.display=!live&&r.sessionId?'':'none';
  document.getElementById('meta').innerHTML=esc(r.trigger)+' · '+fmtTime(r.startedAt||r.createdAt)+(r.endedAt?' → '+fmtTime(r.endedAt):'')+
    (r.continueFrom?' · continues <a href="'+r.continueFrom+'">'+r.continueFrom+'</a>':'')+(r.outcome?' · '+esc(r.outcome):'')+(r.error?' · <span style="color:var(--bad)">'+esc(r.error)+'</span>':'');
  if(r.prompt&&!document.getElementById('ask')){const p=document.createElement('div');p.id='ask';p.className='panel';p.innerHTML='<div class="small muted">Task</div><div class="md">'+md(r.prompt)+'</div>';box.before(p)}}
(async()=>{
  // Subscribe first and buffer, so nothing between the history fetch and the stream is lost
  let buf=[];const es=new EventSource('../api/runs/'+ID+'/stream');
  es.onmessage=e=>{const ev=JSON.parse(e.data);buf?buf.push(ev):add(ev)};es.addEventListener('run',e=>setRun(JSON.parse(e.data)));
  const{run,events}=await (await fetch('../api/runs/'+ID)).json();setRun(run);events.forEach(add);
  const last=events.length?events[events.length-1].t:'';buf.filter(ev=>ev.t>last).forEach(add);buf=null})();
document.getElementById('stop').onclick=async()=>{if(confirm('Stop this run?'))await post('../api/runs/'+ID+'/stop').catch(e=>alert(e.message))};
document.getElementById('send').onclick=async()=>{try{const r=await post('../api/runs',{prompt:document.getElementById('prompt').value,continueFrom:ID});location.href=r.id}
  catch(e){document.getElementById('err').textContent=e.message}};
`);
}
