'use strict';
// Agent HQ: reads claude -p stream-json logs (logs/*.jsonl) and draws the agent organization.
// One Run per log file; events are applied in order by apply(), both for live tailing and replay.

const AGENTS = {
  'architecture-reviewer': { label: '아키텍처', role: '헥사고날·도메인 경계', model: 'opus', dept: 'review' },
  'security-auditor':      { label: '보안', role: '인가·인젝션·XSS', model: 'opus', dept: 'review' },
  'java-backend-reviewer': { label: '백엔드', role: 'Java 동작 버그', model: 'sonnet', dept: 'review' },
  'frontend-reviewer':     { label: '프론트엔드', role: 'Thymeleaf·정적 JS', model: 'sonnet', dept: 'review' },
  'sql-reviewer':          { label: 'DB', role: 'JPA·Querydsl·DDL', model: 'sonnet', dept: 'review' },
  'refactor-scout':        { label: '리팩토링', role: '중복·과설계·죽은 코드', model: 'sonnet', dept: 'review' },
  'issue-clerk':           { label: '이슈 관리', role: '중복 확인·이슈 등록', model: 'haiku', dept: 'review' },
  'issue-fixer':           { label: '이슈 해결', role: '브랜치에서 수정', model: 'sonnet', dept: 'resolve' },
  'build-runner':          { label: '테스트 실행', role: 'Gradle 빌드·테스트', model: 'haiku', dept: 'resolve' },
  'fix-verifier':          { label: '수정 검증', role: 'APPROVE / REJECT', model: 'opus', dept: 'resolve' },
  'general-purpose':       { label: '범용', role: 'general-purpose', model: '', dept: 'other' },
  'Explore':               { label: '탐색', role: '코드 탐색 (읽기 전용)', model: '', dept: 'other' },
  'Plan':                  { label: '설계', role: '구현 계획', model: '', dept: 'other' },
};
const DEPTS = [
  { id: 'review', name: '리뷰 본부', en: 'PATROL', members: ['architecture-reviewer', 'security-auditor', 'java-backend-reviewer', 'frontend-reviewer', 'sql-reviewer', 'refactor-scout', 'issue-clerk'] },
  { id: 'resolve', name: '해결 본부', en: 'RESOLVE', members: ['issue-fixer', 'build-runner', 'fix-verifier'] },
];
const STATUS_LABEL = { running: '작업 중', done: '완료', failed: '실패', stopped: '중단', idle: '대기' };
const LIVE_MTIME_MS = 45000;
const AUTOLOAD_MS = 3 * 864e5;

const S = {
  files: new Map(),      // name -> { name, size, mtime, offset, events, run, loaded }
  procs: [], lanes: [], queues: [], gitea: null, state: null,
  selected: 'live',      // 'live' or a file name
  replay: null,
  ok: false,
};

// ---------- helpers ----------
const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const pad = (n) => String(n).padStart(2, '0');
const hms = (t) => { const d = new Date(t); return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`; };
const hm = (t) => { const d = new Date(t); return `${pad(d.getHours())}:${pad(d.getMinutes())}`; };
const md = (t) => { const d = new Date(t); return `${d.getMonth() + 1}/${d.getDate()}`; };
function dur(ms) {
  if (ms == null || !isFinite(ms) || ms < 0) return '-';
  const s = Math.round(ms / 1000);
  if (s < 60) return `${s}초`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}분 ${pad(s % 60)}초`;
  return `${Math.floor(m / 60)}시간 ${pad(m % 60)}분`;
}
function ago(ms) {
  if (ms < 60e3) return '방금';
  if (ms < 3600e3) return `${Math.round(ms / 60e3)}분 전`;
  if (ms < 864e5) return `${Math.round(ms / 3600e3)}시간 전`;
  return `${Math.round(ms / 864e5)}일 전`;
}
const tok = (n) => (n >= 1e6 ? (n / 1e6).toFixed(1) + 'M' : n >= 1e3 ? (n / 1e3).toFixed(1) + 'k' : String(n | 0));
const usd = (n) => '$' + (n || 0).toFixed(2);
const tier = (m) => (/opus/.test(m || '') ? 'opus' : /sonnet/.test(m || '') ? 'sonnet' : /haiku/.test(m || '') ? 'haiku' : m || '');
const isToday = (t) => t && new Date(t).toDateString() === new Date().toDateString();
const base = (p) => String(p || '').split(/[\\/]/).pop();
const clip = (s, n) => { s = String(s ?? '').replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
const agentLabel = (type) => (type === 'main' ? '총괄' : AGENTS[type]?.label || type || '에이전트');
const modelVar = (m) => ({ opus: 'var(--opus)', sonnet: 'var(--sonnet)', haiku: 'var(--haiku)' }[m] || 'var(--muted)');
const stMark = (st) => `<span class="st s-${st}"><i class="dot"></i>${STATUS_LABEL[st] || st}</span>`;
const clockFor = (r) => (S.replay && r === S.replay.run ? S.replay.t : Date.now());

// ---------- run model ----------
function newRun(name) {
  const m = name.match(/^resolve-(\d+)(?:\.attempt(\d+))?\.jsonl$/);
  const r = {
    name, kind: m ? 'resolve' : name.startsWith('patrol') ? 'patrol' : 'other',
    issue: m ? +m[1] : null, attempt: m && m[2] ? +m[2] : null,
    startTs: null, lastTs: null, endTs: null, live: false,
    agents: new Map(), tools: new Map(), tasks: new Map(), msgSeen: new Set(),
    feed: [], blocks: [], phases: [], cost: 0, result: null, rate: null,
  };
  r.agents.set('main', mkAgent('main', 'main', '', 'opus', null, null));
  return r;
}
function mkAgent(id, type, desc, model, parent, ts) {
  return { id, type, desc, model, parent, startTs: ts, endTs: null, status: 'running', activity: '', said: '',
    tokens: 0, outTokens: 0, calls: 0, ticks: [], blocks: 0, errors: 0, summary: '', lastTs: ts, bg: false };
}
function runLabel(r) {
  if (r.kind === 'resolve') return `#${r.issue} 이슈 해결${r.attempt ? ` · 재시도 전 ${r.attempt}차` : ''}`;
  if (r.kind === 'patrol') return `순찰 ${r.name.replace(/^patrol-?|\.jsonl$/g, '')}`.trim();
  return r.name.replace(/\.jsonl$/, '');
}
function feed(r, item) {
  r.feed.push(item);
  if (r.feed.length > 4000) r.feed.splice(0, 1000);
}
function toolText(c) {
  const i = c.input || {};
  switch (c.name) {
    case 'Bash': case 'PowerShell': return i.description || clip(i.command, 90);
    case 'Read': return `읽기 ${base(i.file_path)}`;
    case 'Edit': return `수정 ${base(i.file_path)}`;
    case 'Write': return `작성 ${base(i.file_path)}`;
    case 'Grep': return `검색 "${clip(i.pattern, 40)}"`;
    case 'Glob': return `파일 찾기 ${clip(i.pattern, 50)}`;
    case 'Skill': return `스킬 /${i.skill}${i.args ? ' ' + i.args : ''}`;
    case 'Agent': case 'Task': return `${agentLabel(i.subagent_type)} 투입: ${i.description || ''}`;
    case 'TaskOutput': return '백그라운드 작업 결과 확인';
    case 'ToolSearch': return '도구 불러오기';
    default: return c.name;
  }
}
function resultText(c) {
  const v = c.content;
  if (typeof v === 'string') return v;
  if (Array.isArray(v)) return v.map((x) => x.text || '').join(' ');
  return '';
}
function normStatus(s) {
  return s === 'completed' ? 'done' : s === 'failed' ? 'failed' : s === 'running' ? 'running' : 'stopped';
}
function finish(r, a, status, ts, summary) {
  a.status = normStatus(status);
  a.endTs = ts;
  if (summary) a.summary = summary;
  if (!a.doneFed) {
    a.doneFed = true;
    feed(r, { ts, a, kind: 'done', text: `${STATUS_LABEL[a.status]} · ${dur(ts - a.startTs)}${summary ? ' · ' + clip(summary, 140) : ''}` });
  }
}
function spawn(r, id, input, parent, ts) {
  let a = r.agents.get(id);
  if (!a) {
    const type = input.subagent_type || 'general-purpose';
    a = mkAgent(id, type, input.description || '', tier(input.model) || AGENTS[type]?.model || '', parent.id, ts);
    r.agents.set(id, a);
  }
  return a;
}

function apply(r, e) {
  const ts = e._ts;
  if (ts) { if (!r.startTs) r.startTs = ts; r.lastTs = ts; }
  const main = r.agents.get('main');
  if (!main.startTs && ts) main.startTs = ts;
  const who = (pid) => (pid && r.agents.get(pid)) || main;

  if (e.type === 'system') {
    switch (e.subtype) {
      case 'init': if (e.model) main.model = tier(e.model); break;
      case 'task_started': {
        if (e.task_type !== 'local_agent' && !e.subagent_type) break;   // local_bash etc. are not agents
        const a = spawn(r, e.tool_use_id, { subagent_type: e.subagent_type, description: e.description }, main, ts);
        a.bg = !!e.is_backgrounded;
        if (e.task_id) r.tasks.set(e.task_id, a);
        break;
      }
      case 'task_progress': {
        const a = r.agents.get(e.tool_use_id);
        if (a) {
          if (e.description) a.activity = e.description;
          if (e.usage) { a.tokens = Math.max(a.tokens, e.usage.total_tokens || 0); a.calls = Math.max(a.calls, e.usage.tool_uses || 0); }
          a.lastTs = ts;
        }
        break;
      }
      case 'task_notification': {
        const a = r.agents.get(e.tool_use_id) || r.tasks.get(e.task_id);
        if (a) finish(r, a, e.status, ts, e.summary);
        break;
      }
      case 'task_updated': {
        const a = r.tasks.get(e.task_id);
        const p = e.patch || {};
        if (a && p.status && p.status !== 'running') finish(r, a, p.status, p.end_time || ts);
        if (a && p.end_time) a.endTs = p.end_time;
        break;
      }
      case 'post_turn_summary': if (e.status_detail) main.activity = e.status_detail; break;
      case 'task_summary': if (e.detail) main.activity = e.detail; break;
      case 'hook_response':
        if (e.outcome && e.outcome !== 'success') feed(r, { ts, a: main, kind: 'error', text: `${e.hook_name} 훅 오류 (exit ${e.exit_code}) ${clip(e.stderr || e.output, 100)}` });
        break;
    }
    return;
  }
  if (e.type === 'assistant') {
    const a = who(e.parent_tool_use_id);
    const msg = e.message || {};
    if (msg.model) a.model = tier(msg.model);
    if (msg.id && !r.msgSeen.has(msg.id)) { r.msgSeen.add(msg.id); a.outTokens += msg.usage?.output_tokens || 0; }
    a.lastTs = ts;
    for (const c of msg.content || []) {
      if (c.type === 'tool_use') {
        r.tools.set(c.id, { a, name: c.name, ts });
        if (a !== main && a.calls < a.ticks.length + 1) a.calls = a.ticks.length + 1;
        if (a === main) a.calls++;
        a.ticks.push(ts);
        const text = toolText(c);
        a.activity = text;
        if (c.name === 'Agent' || c.name === 'Task') {
          const sub = spawn(r, c.id, c.input || {}, a, ts);
          feed(r, { ts, a, kind: 'spawn', text, sub });
        } else {
          if (c.name === 'Skill' && c.input?.skill !== 'gitea') r.phases.push({ ts, name: c.input?.skill });
          feed(r, { ts, a, kind: 'tool', tool: c.name, text });
        }
      } else if (c.type === 'text' && c.text && c.text.trim()) {
        a.said = c.text;
        feed(r, { ts, a, kind: 'say', text: clip(c.text, 260) });
      }
    }
    return;
  }
  if (e.type === 'user') {
    const a = who(e.parent_tool_use_id);
    const tur = typeof e.tool_use_result === 'string' ? e.tool_use_result : '';
    for (const c of e.message?.content || []) {
      if (c.type !== 'tool_result') continue;
      const t = r.tools.get(c.tool_use_id);
      const owner = t?.a || a;
      const text = resultText(c);
      if (tur.includes('BLOCKED by unit-project-ops guard') || text.includes('BLOCKED by unit-project-ops guard')) {
        const why = (tur || text).split('guard:')[1]?.trim() || '가드 차단';
        r.blocks.push({ ts, a: owner, why });
        owner.blocks++;
        feed(r, { ts, a: owner, kind: 'block', text: `가드 차단: ${clip(why, 160)}` });
      } else if (c.is_error) {
        owner.errors++;
        feed(r, { ts, a: owner, kind: 'error', tool: t?.name, text: clip(text, 160) });
      }
      const sub = r.agents.get(c.tool_use_id);
      if (sub && sub !== main && !/^Async agent launched/.test(text) && sub.status === 'running') {
        finish(r, sub, c.is_error ? 'failed' : 'completed', ts, clip(text, 400));
      }
    }
    return;
  }
  if (e.type === 'result') {
    r.result = { isError: !!e.is_error || (e.subtype && e.subtype !== 'success'), text: e.result, ts };
    r.cost = Math.max(r.cost, e.total_cost_usd || 0);
    r.endTs = ts;
    return;
  }
  if (e.type === 'rate_limit_event') { r.rate = { ...(e.rate_limit_info || {}), ts }; }
}

function parseChunk(f, text) {
  const out = [];
  let pending = [];
  for (let line of text.split('\n')) {
    if (!line.trim()) continue;
    if (line.charCodeAt(0) === 0xfeff) line = line.slice(1);
    let e;
    try { e = JSON.parse(line); } catch { continue; }
    let ts = e.timestamp ? Date.parse(e.timestamp) : null;
    if (!ts && e.subtype === 'task_updated' && e.patch?.end_time) ts = e.patch.end_time;
    if (ts) { f.lastTs = ts; for (const p of pending) p._ts = ts; pending = []; }
    e._ts = ts || f.lastTs || null;
    if (!e._ts) pending.push(e);
    out.push(e);
  }
  for (const p of pending) p._ts = f.lastTs || Date.now();
  return out;
}

// ---------- data loading ----------
async function getJSON(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${url}: ${r.status}`);
  return r.json();
}
async function pullLog(f) {
  const res = await fetch(`/api/log?name=${encodeURIComponent(f.name)}&from=${f.offset}`);
  if (!res.ok) return;
  if (res.headers.get('X-Reset') === '1') { f.offset = 0; f.events = []; f.run = newRun(f.name); f.lastTs = null; }
  const text = await res.text();
  f.offset = +res.headers.get('X-Next-Offset') || f.offset;
  if (!f.run) f.run = newRun(f.name);
  for (const e of parseChunk(f, text)) { f.events.push(e); apply(f.run, e); }
  f.loaded = true;
}
function latestPatrol() {
  let best = null;
  for (const f of S.files.values()) if (/^patrol/.test(f.name) && (!best || f.mtime > best.mtime)) best = f;
  return best;
}
function markLive() {
  const lp = latestPatrol();
  const now = Date.now();
  for (const f of S.files.values()) {
    const proc = S.procs.find((p) => (p.kind === 'resolve' ? f.name === `resolve-${p.issue}.jsonl` : p.kind === 'patrol' && f === lp));
    // A session that just started has an empty log; show it as live from its process start.
    if (!f.run && proc) { f.run = newRun(f.name); f.loaded = true; }
    if (!f.run) continue;
    if (proc && !f.run.startTs) { f.run.startTs = f.run.lastTs = proc.started; f.run.agents.get('main').activity = '세션 시작 중 · 첫 로그 대기'; }
    f.run.live = !!proc || (now - f.mtime < LIVE_MTIME_MS && !f.run.result);
  }
}
let loading = false;
async function tick() {
  if (loading) return;
  loading = true;
  try {
    const d = await getJSON('/api/runs');
    S.ok = true;
    S.procs = d.procs || []; S.lanes = d.lanes || [];
    S.queues = (d.queues || []).map((q) => ({ ...q, items: [q.items].flat(3).filter(Boolean) }));
    const seen = new Set();
    for (const x of d.files || []) {
      seen.add(x.name);
      let f = S.files.get(x.name);
      if (!f) { f = { name: x.name, offset: 0, events: [], run: null, loaded: false, lastTs: null }; S.files.set(x.name, f); }
      f.size = x.size; f.mtime = x.mtime;
    }
    for (const n of [...S.files.keys()]) if (!seen.has(n)) S.files.delete(n);
    const now = Date.now();
    for (const f of [...S.files.values()].sort((a, b) => b.mtime - a.mtime)) {
      const want = f.loaded || now - f.mtime < AUTOLOAD_MS || f.name === S.selected;
      if (want && f.size !== f.offset) await pullLog(f);
    }
    markLive();
  } catch (err) {
    S.ok = false;
    console.error(err);
  } finally {
    loading = false;
  }
  render();
}
async function slowTick() {
  try { S.gitea = await getJSON('/api/gitea'); } catch (e) { S.gitea = { error: String(e) }; }
  try { S.state = await getJSON('/api/state'); } catch {}
  render();
}

// ---------- scope ----------
const loadedRuns = () => [...S.files.values()].filter((f) => f.run).map((f) => f.run);
const liveRuns = () => loadedRuns().filter((r) => r.live).sort((a, b) => b.startTs - a.startTs);
function scopeRuns() {
  if (S.replay) return [S.replay.run];
  if (S.selected === 'live') return liveRuns();
  const f = S.files.get(S.selected);
  return f?.run ? [f.run] : [];
}
function agentStatus(r, a) {
  if (a.id === 'main') return r.live ? 'running' : r.result?.isError ? 'failed' : r.result ? 'done' : 'stopped';
  if (a.status === 'running' && !r.live) return 'stopped';
  return a.status;
}
function issueOf(n) { return (S.gitea?.issues || []).find((i) => i.number === n); }
function runOutcome(r) {
  if (r.live) return null;
  if (r.kind === 'resolve') {
    const labels = issueOf(r.issue)?.labels || [];
    if (!r.attempt) {
      if (labels.includes('agent:pr-open')) return { cls: 'ok', text: 'PR 생성' };
      if (labels.includes('agent:blocked')) return { cls: 'bad', text: '보류' };
    }
    if (r.attempt) return { cls: 'warn', text: 'API 오류 재시도' };
  }
  if (r.result?.isError) return { cls: 'bad', text: '오류 종료' };
  if (r.result) return { cls: 'ok', text: '완료' };
  return { cls: 'warn', text: '중단' };
}

// ---------- render ----------
function render() {
  $('#conn').className = 'conn ' + (S.ok ? 'ok' : 'bad');
  $('#conn').textContent = S.ok ? '실시간 연결' : '서버 연결 끊김';
  $('#clock').textContent = new Date().toLocaleString('ko-KR', { hour12: false });
  renderKpis();
  renderRuns();
  renderLanes();
  renderReplayBar();
  const runs = scopeRuns();
  renderOrg(runs);
  renderTimeline(runs);
  renderIssues();
  renderFeed(runs);
}

function renderKpis() {
  const all = loadedRuns();
  const live = all.filter((r) => r.live);
  let working = 0, today = 0, cost = 0, blocks = 0, rate = null;
  for (const r of all) {
    if (r.live) working += 1 + [...r.agents.values()].filter((a) => a.id !== 'main' && agentStatus(r, a) === 'running').length;
    if (isToday(r.startTs)) { cost += r.cost; today += r.agents.size - 1; }
    blocks += r.blocks.filter((b) => isToday(b.ts)).length;
    if (r.rate?.unifiedWindows && (!rate || r.rate.ts > rate.ts)) rate = r.rate;
  }
  const iss = (S.gitea?.issues || []).filter((i) => i.state === 'open');
  const openPr = (S.gitea?.pulls || []).filter((p) => p.state === 'open').length;
  const blocked = iss.filter((i) => i.labels.includes('agent:blocked')).length;
  const five = rate?.unifiedWindows?.five_hour?.utilization;
  const k = (label, v, sub = '') => `<div class="kpi"><div class="k">${label}</div><div class="v">${v}${sub ? `<small>${sub}</small>` : ''}</div></div>`;
  $('#kpis').innerHTML =
    k('가동 세션', live.length, `/ 레인 ${S.procs.length}`) +
    k('작업 중 에이전트', working) +
    k('오늘 투입', today, '회') +
    k('오늘 비용', usd(cost)) +
    k('PR 대기', S.gitea ? openPr : '-', '사람 리뷰') +
    k('사람 판단 필요', S.gitea ? blocked : '-', '보류 이슈') +
    k('가드 차단', blocks, '오늘') +
    k('5시간 한도', five != null ? Math.round(five * 100) + '%' : '-');
}

function renderRuns() {
  const files = [...S.files.values()].sort((a, b) => b.mtime - a.mtime);
  const row = (f) => {
    const r = f.run;
    const sel = !S.replay && S.selected === f.name ? ' sel' : '';
    if (!r) {
      return `<div class="run${sel}" data-run="${esc(f.name)}"><span class="st s-idle"><i class="dot"></i></span><span class="nm">${esc(f.name.replace(/\.jsonl$/, ''))}</span><span class="cost"></span>
        <span class="meta">${md(f.mtime)} ${hm(f.mtime)} · 클릭하면 불러옵니다</span></div>`;
    }
    const st = r.live ? 'running' : 'done';
    const out = runOutcome(r);
    const title = r.kind === 'resolve' ? issueOf(r.issue)?.title : '';
    const n = r.agents.size - 1;
    return `<div class="run${sel}" data-run="${esc(f.name)}" title="${esc(title || '')}">
      <span class="st s-${st}"><i class="dot"></i></span>
      <span class="nm">${esc(runLabel(r))}</span>
      <span class="cost">${r.cost ? usd(r.cost) : ''}</span>
      <span class="meta">${r.startTs ? md(r.startTs) + ' ' + hm(r.startTs) : ''} · ${dur((r.live ? Date.now() : r.lastTs) - r.startTs)} · 에이전트 ${n}
        ${r.live ? '<span class="badge ok">실행 중</span>' : out ? `<span class="badge ${out.cls}">${out.text}</span>` : ''}
        ${title ? '<br>' + esc(clip(title, 44)) : ''}</span>
    </div>`;
  };
  const live = files.filter((f) => f.run?.live);
  const today = files.filter((f) => !f.run?.live && isToday(f.mtime));
  const older = files.filter((f) => !f.run?.live && !isToday(f.mtime));
  const allSel = !S.replay && S.selected === 'live' ? ' sel' : '';
  $('#runs').innerHTML =
    `<div class="run${allSel}" data-run="live"><span class="st s-${live.length ? 'running' : 'idle'}"><i class="dot"></i></span><span class="nm">실시간 전체 보기</span><span class="cost"></span>
      <span class="meta">실행 중인 세션 ${live.length}개를 합쳐서 봅니다</span></div>` +
    (live.length ? `<div class="grp">실행 중</div>${live.map(row).join('')}` : '') +
    (today.length ? `<div class="grp">오늘</div>${today.map(row).join('')}` : '') +
    (older.length ? `<div class="grp">이전</div>${older.map(row).join('')}` : '');
}

function renderLanes() {
  const lanes = S.lanes.filter((l) => l.lines?.length);
  $('#lanes').innerHTML = lanes.length
    ? lanes.slice(0, 5).map((l) => `<div class="ln"><b>${esc(l.name)}</b> <span style="color:var(--muted)">${ago(Date.now() - l.mtime)}</span>
        ${[l.lines].flat().slice(-3).map((x) => `<div title="${esc(x)}">${esc(x)}</div>`).join('')}</div>`).join('')
    : '<div class="empty">레인 로그가 없습니다</div>';
}

function renderOrg(runs) {
  const scopeAll = S.replay ? runs : loadedRuns();
  const todays = S.replay ? runs : scopeAll.filter((r) => isToday(r.startTs));
  const inst = (list) => {
    const m = new Map();
    for (const r of list) for (const a of r.agents.values()) if (a.id !== 'main') {
      if (!m.has(a.type)) m.set(a.type, []);
      m.get(a.type).push({ r, a, st: agentStatus(r, a) });
    }
    return m;
  };
  const cur = inst(runs), day = inst(todays), ever = inst(scopeAll);
  const title = S.replay ? `리플레이 · ${runLabel(S.replay.run)}` : S.selected === 'live' ? '조직 현황 · 실시간' : `조직 현황 · ${runLabel(runs[0] || { name: S.selected, kind: 'other' })}`;
  $('#orgTitle').textContent = title;

  // command card: one row per session in scope
  const hqRows = runs.length
    ? runs.map((r) => {
        const main = r.agents.get('main');
        const st = agentStatus(r, main);
        const now = clockFor(r);
        return `<div class="mem s-${st}">
          <div class="who"><b>${esc(runLabel(r))}</b><span class="badge m m-${main.model}">${main.model || ''}</span>${stMark(st)}</div>
          <div class="num">${dur((r.live ? now : r.lastTs) - r.startTs)} · ${r.cost || !r.live ? usd(r.cost) : '비용은 종료 시 집계'}</div>
          <div class="act">${esc(clip(main.activity || main.said || '-', 140))}</div></div>`;
      }).join('')
    : `<div class="mem s-idle"><div class="who"><b>대기 중</b>${stMark('idle')}</div><div class="num"></div><div class="act">실행 중인 세션이 없습니다. 왼쪽에서 지난 세션을 고르거나 리플레이하세요.</div></div>`;
  const liveN = runs.filter((r) => r.live).length;
  const hq = `<div class="dept${liveN ? ' active' : ''}">
    <div class="hd"><span class="nm">총괄</span><span class="en">COMMAND</span><span class="cnt">${liveN}<small> 세션 가동</small></span></div>
    <div class="trio"><div><div class="k">오늘 세션</div><div class="v">${todays.length}</div></div>
      <div><div class="k">오늘 비용</div><div class="v">${usd(todays.reduce((s, r) => s + r.cost, 0))}</div></div>
      <div><div class="k">가드 차단</div><div class="v">${todays.reduce((s, r) => s + r.blocks.length, 0)}</div></div></div>
    <div class="members">${hqRows}</div></div>`;

  const extraTypes = [...ever.keys()].filter((t) => !AGENTS[t] || AGENTS[t].dept === 'other');
  const depts = [...DEPTS, ...(extraTypes.length ? [{ id: 'other', name: '기타', en: 'SUPPORT', members: extraTypes }] : [])];
  const cards = depts.map((d) => {
    let working = 0, dayCalls = 0, dayFail = 0, done = 0, total = 0;
    const rows = d.members.map((type) => {
      const now = cur.get(type) || [];
      const running = now.filter((x) => x.st === 'running');
      const dayList = day.get(type) || [];
      const last = [...(ever.get(type) || [])].sort((x, y) => (y.a.lastTs || 0) - (x.a.lastTs || 0))[0];
      dayCalls += dayList.length;
      dayFail += dayList.filter((x) => x.st === 'failed').length;
      total += now.length; done += now.filter((x) => x.st === 'done').length;
      if (running.length) working++;
      const meta = AGENTS[type] || { label: type, role: '', model: '' };
      const model = (running[0] || last)?.a.model || meta.model;
      let st = 'idle', act = '대기';
      let num = `오늘 ${dayList.length}회`;
      if (running.length) {
        st = 'running';
        const x = running[0];
        act = `${runs.length > 1 ? runLabel(x.r).split(' ')[0] + ' · ' : ''}${x.a.activity || x.a.desc}`;
        num = `${running.length > 1 ? '×' + running.length + ' · ' : ''}${dur(clockFor(x.r) - x.a.startTs)} · 도구 ${x.a.calls}`;
      } else if (now.length) {
        const x = now[now.length - 1];
        st = x.st;
        act = `${x.a.desc || ''} · ${STATUS_LABEL[x.st]} (${dur((x.a.endTs || x.r.lastTs) - x.a.startTs)})`;
        num = `도구 ${x.a.calls} · ${tok(x.a.tokens || x.a.outTokens)}`;
      } else if (last) {
        act = `최근 ${ago(Date.now() - (last.a.endTs || last.a.lastTs))} · ${runLabel(last.r)} · ${last.a.desc || ''}`;
      }
      return `<div class="mem s-${st}"><div class="who"><b>${esc(meta.label)}</b><span class="badge m m-${model}">${model}</span><span class="role">${esc(meta.role)}</span></div>
        <div class="num">${stMark(st)} ${esc(num)}</div><div class="act" title="${esc(act)}">${esc(act)}</div></div>`;
    }).join('');
    const pct = total ? (done / total) * 100 : 0;
    return `<div class="dept${working ? ' active' : ''}">
      <div class="hd"><span class="nm">${d.name}</span><span class="en">${d.en}</span><span class="cnt">${working}<small> / ${d.members.length} 작업 중</small></span></div>
      <div class="trio"><div><div class="k">오늘 투입</div><div class="v">${dayCalls}</div></div>
        <div><div class="k">현재 범위</div><div class="v">${total}</div></div>
        <div><div class="k">오늘 실패</div><div class="v">${dayFail}</div></div></div>
      <div class="bar" title="현재 범위 완료 ${done}/${total}"><i style="width:${pct}%;background:var(--good)"></i></div>
      <div class="bar-cap"><span>현재 범위 완료</span><span>${done} / ${total}</span></div>
      <div class="members">${rows}</div></div>`;
  }).join('');
  $('#org').innerHTML = hq + cards;
}

// timeline
let tips = [];
function niceStep(span) {
  const mins = [1, 2, 5, 10, 15, 30, 60, 120, 240].map((m) => m * 60e3);
  return mins.find((s) => span / s <= 8) || mins[mins.length - 1];
}
function renderTimeline(runs) {
  const box = $('#timeline');
  tips = [];
  if (!runs.length) { box.innerHTML = '<div class="empty">표시할 세션이 없습니다</div>'; return; }
  const W = Math.max(box.clientWidth, 480);
  box.innerHTML = runs.slice(0, 4).map((r) => timelineSvg(r, W)).join('');
}
function timelineSvg(r, W) {
  if (!r.startTs) return '';
  const rp = S.replay && r === S.replay.run ? S.replay : null;
  const now = clockFor(r);
  const t0 = rp ? rp.start : r.startTs;
  let t1 = rp ? rp.end : r.live ? now : r.endTs && r.endTs > r.lastTs ? r.endTs : r.lastTs;
  if (t1 - t0 < 60e3) t1 = t0 + 60e3;
  const rows = [...r.agents.values()].sort((a, b) => (a.id === 'main' ? -1 : b.id === 'main' ? 1 : (a.startTs || 0) - (b.startTs || 0)));
  const L = 190, R = 14, RH = 26, top = 24;
  const H = top + rows.length * RH + 6;
  const x = (t) => L + ((Math.min(Math.max(t, t0), t1) - t0) / (t1 - t0)) * (W - L - R);
  const step = niceStep(t1 - t0);
  let g = '';
  for (let t = Math.ceil(t0 / step) * step; t <= t1; t += step) {
    g += `<line x1="${x(t)}" x2="${x(t)}" y1="${top - 6}" y2="${H - 4}" stroke="var(--grid)"/><text class="ax" x="${x(t)}" y="12" text-anchor="middle">${hm(t)}</text>`;
  }
  for (const p of r.phases) {
    g += `<line x1="${x(p.ts)}" x2="${x(p.ts)}" y1="${top - 4}" y2="${H - 4}" stroke="var(--ink-2)" stroke-dasharray="2 3" opacity=".5"/>`;
  }
  rows.forEach((a, i) => {
    const y = top + i * RH;
    const st = agentStatus(r, a);
    const s = a.startTs || r.startTs;
    const e = st === 'running' ? now : a.endTs || (a.id === 'main' ? r.lastTs : a.lastTs) || now;
    const xs = x(s), xe = Math.max(x(e), xs + 3);
    const tipIdx = tips.push({ r, a }) - 1;
    const color = modelVar(a.model);
    const label = a.id === 'main' ? '총괄' : agentLabel(a.type);
    g += `<rect class="hit" data-tip="${tipIdx}" x="0" y="${y}" width="${W}" height="${RH}"/>`;
    g += `<text x="6" y="${y + 12}" data-tip="${tipIdx}">${esc(label)}${st === 'running' ? ' ●' : st === 'failed' ? ' ✕' : ''}</text>`;
    g += `<text class="sub" x="6" y="${y + 23}">${esc(clip(a.id === 'main' ? runLabel(r) : a.desc, 26))}</text>`;
    g += `<rect x="${xs}" y="${y + 5}" width="${xe - xs}" height="${RH - 10}" rx="4" fill="${color}" opacity="${a.id === 'main' ? 0.35 : 0.9}" pointer-events="none"/>`;
    if (st === 'running') g += `<rect x="${xe - 2}" y="${y + 3}" width="2" height="${RH - 6}" fill="var(--good)" pointer-events="none"><animate attributeName="opacity" values="1;.2;1" dur="1.4s" repeatCount="indefinite"/></rect>`;
    const ticks = a.ticks.length > 600 ? a.ticks.filter((_, k) => k % Math.ceil(a.ticks.length / 600) === 0) : a.ticks;
    let d = '';
    for (const t of ticks) { const tx = x(t).toFixed(1); d += `M${tx} ${y + 8}V${y + RH - 8}`; }
    if (d) g += `<path d="${d}" stroke="rgba(255,255,255,.65)" stroke-width="1" pointer-events="none"/>`;
    for (const b of r.blocks.filter((b) => b.a === a)) {
      const bx = x(b.ts);
      g += `<path d="M${bx} ${y + 3}l5 5-5 5-5-5z" fill="var(--critical)" stroke="var(--surface)" stroke-width="1.5" pointer-events="none"/>`;
    }
  });
  if (rp) g += `<line x1="${x(rp.t)}" x2="${x(rp.t)}" y1="${top - 8}" y2="${H}" stroke="var(--warning)" stroke-width="2"/>`;
  const st = agentStatus(r, r.agents.get('main'));
  const subs = rows.length - 1;
  return `<div><div class="tl-hd"><b>${esc(runLabel(r))}</b>${stMark(st)}
      <span>${md(r.startTs)} ${hms(r.startTs)} 시작 · ${dur((r.live ? now : r.lastTs) - r.startTs)} · 서브에이전트 ${subs} · ${usd(r.cost)}${r.blocks.length ? ` · 가드 차단 ${r.blocks.length}` : ''}</span>
      ${!r.live && !rp ? `<button class="primary" data-replay="${esc(r.name)}">▶ 리플레이</button>` : ''}</div>
    <svg viewBox="0 0 ${W} ${H}" height="${H}" data-t0="${t0}" data-t1="${t1}" data-l="${L}" data-w="${W - L - R}" ${rp ? 'style="cursor:pointer"' : ''}>${g}</svg></div>`;
}
function tipHtml({ r, a }) {
  const st = agentStatus(r, a);
  const end = st === 'running' ? clockFor(r) : a.endTs || a.lastTs;
  const row = (k, v) => `<div class="r"><span>${k}</span><span>${esc(v)}</span></div>`;
  return `<b>${esc(a.id === 'main' ? '총괄 · ' + runLabel(r) : agentLabel(a.type))}</b>
    ${a.desc ? `<div class="d">${esc(a.desc)}</div>` : ''}
    ${row('상태', STATUS_LABEL[st])}${row('모델', a.model || '-')}
    ${row('시간', `${hms(a.startTs || r.startTs)} → ${st === 'running' ? '진행 중' : hms(end)}`)}
    ${row('소요', dur(end - (a.startTs || r.startTs)))}${row('도구 호출', a.id === 'main' ? a.calls : a.calls || a.ticks.length)}
    ${a.tokens || a.outTokens ? row('토큰', tok(a.tokens || a.outTokens)) : ''}
    ${a.blocks ? row('가드 차단', a.blocks) : ''}${a.errors ? row('도구 오류', a.errors) : ''}
    ${a.activity ? `<div class="d">마지막: ${esc(clip(a.activity, 120))}</div>` : ''}
    ${a.summary ? `<div class="d">${esc(clip(a.summary, 220))}</div>` : ''}`;
}

function renderIssues() {
  const g = S.gitea;
  if (g?.webUrl) $('#giteaLink').href = g.webUrl;
  if (!g) { $('#issues').innerHTML = '<div class="empty">불러오는 중…</div>'; return; }
  if (g.error) { $('#issues').innerHTML = `<div class="empty">Gitea 조회 실패: ${esc(g.error)}</div>`; return; }
  const open = g.issues.filter((i) => i.state === 'open');
  const has = (l) => open.filter((i) => i.labels.includes(l)).length;
  const tile = (k, v, st) => `<div class="itile"><div class="k"><i class="dot s-${st}"></i>${k}</div><div class="v">${v}</div></div>`;
  const agentState = (i) => {
    if (i.labels.includes('agent:pr-open')) return '<span class="badge ok">PR 대기</span>';
    if (i.labels.includes('agent:blocked')) return '<span class="badge bad">보류</span>';
    if (i.labels.includes('agent:in-progress')) return '<span class="badge warn">처리 중</span>';
    if (i.labels.includes('agent:found')) return '<span class="badge">발견</span>';
    return '';
  };
  const sev = (i) => (i.labels.find((l) => l.startsWith('severity/')) || '').replace('severity/', '');
  const sevRank = { critical: 0, high: 1, medium: 2, low: 3, '': 4 };
  const list = [...open].sort((a, b) => sevRank[sev(a)] - sevRank[sev(b)] || b.number - a.number).slice(0, 14);
  const prs = g.pulls.filter((p) => p.state === 'open').slice(0, 6);
  $('#issues').innerHTML = `<div class="itiles">${tile('발견', has('agent:found'), 'idle')}${tile('처리 중', has('agent:in-progress'), 'running')}${tile('PR 대기', has('agent:pr-open'), 'done')}${tile('보류', has('agent:blocked'), 'failed')}</div>
    <div class="sect">열린 이슈 ${open.length} (심각도 순)</div>
    <div class="ilist">${list.map((i) => `<a class="irow" href="${esc(i.url)}" target="_blank" rel="noopener"><span class="n">#${i.number}</span><span class="t" title="${esc(i.title)}">${esc(i.title)}</span><span>${sev(i) ? `<span class="badge">${sev(i)}</span> ` : ''}${agentState(i)}</span></a>`).join('') || '<div class="empty">열린 이슈 없음</div>'}</div>
    <div class="sect">열린 PR ${prs.length}</div>
    <div class="ilist">${prs.map((p) => `<a class="irow" href="${esc(p.url)}" target="_blank" rel="noopener"><span class="n">!${p.number}</span><span class="t" title="${esc(p.title)}">${esc(p.title)}</span><span class="badge">${esc(p.head)}</span></a>`).join('') || '<div class="empty">열린 PR 없음</div>'}</div>`;
}

function renderFeed(runs) {
  const multi = runs.length > 1;
  const items = [];
  for (const r of runs) for (const it of r.feed.slice(-250)) items.push([r, it]);
  items.sort((a, b) => b[1].ts - a[1].ts);
  $('#feed').innerHTML = items.slice(0, 180).map(([r, it]) => {
    const a = it.a;
    const who = a.id === 'main' ? '총괄' : agentLabel(a.type);
    return `<div class="fi k-${it.kind}"><span class="ts">${hms(it.ts)}</span><span>
      ${multi ? `<span class="rt">${esc(runLabel(r).split(' ')[0])}</span>` : ''}<span class="who"><i class="sw" style="background:${modelVar(a.model)}"></i>${esc(who)}</span>
      ${it.tool ? `<span class="tool">${esc(it.tool)}</span>` : ''}<span class="tx">${it.kind === 'spawn' ? '→ ' : it.kind === 'block' ? '◆ ' : ''}${esc(it.text)}</span></span></div>`;
  }).join('') || '<div class="empty">활동 없음</div>';
}

// ---------- replay ----------
function startReplay(name) {
  const f = S.files.get(name);
  if (!f?.events.length) return;
  const ts = f.events.map((e) => e._ts).filter(Boolean);
  S.replay = { name, events: f.events, idx: 0, start: Math.min(...ts), end: Math.max(...ts), t: 0, speed: 60, playing: true, run: newRun(name) };
  S.replay.t = S.replay.start;
  S.replay.run.live = true;
  render();
}
function seekReplay(t) {
  const R = S.replay;
  R.run = newRun(R.name); R.idx = 0; R.t = t; R.run.live = true;
  advance(0);
}
function advance(dtMs) {
  const R = S.replay;
  R.t = Math.min(R.end, R.t + dtMs * R.speed);
  while (R.idx < R.events.length && (R.events[R.idx]._ts || 0) <= R.t) apply(R.run, R.events[R.idx++]);
  if (R.idx >= R.events.length) { R.playing = false; R.run.live = false; }
}
function renderReplayBar() {
  const bar = $('#replaybar');
  const R = S.replay;
  if (!R) { bar.hidden = true; return; }
  bar.hidden = false;
  const pct = ((R.t - R.start) / (R.end - R.start || 1)) * 1000;
  if (!bar.dataset.built) {
    bar.innerHTML = `<span class="tag">REPLAY</span><button id="rpPlay"></button>
      <select id="rpSpeed">${[10, 30, 60, 120, 300, 600].map((s) => `<option value="${s}">${s}배속</option>`).join('')}</select>
      <input id="rpPos" type="range" min="0" max="1000"><span id="rpTime" style="font-family:var(--mono)"></span><button id="rpExit">리플레이 종료</button>`;
    bar.dataset.built = '1';
    $('#rpPlay').onclick = () => { if (R.idx >= R.events.length) seekReplay(R.start); S.replay.playing = !S.replay.playing; if (S.replay.idx < S.replay.events.length) S.replay.run.live = true; render(); };
    $('#rpSpeed').onchange = (e) => { S.replay.speed = +e.target.value; };
    $('#rpPos').oninput = (e) => { const Q = S.replay; seekReplay(Q.start + (e.target.value / 1000) * (Q.end - Q.start)); render(); };
    $('#rpExit').onclick = () => { S.replay = null; bar.dataset.built = ''; render(); };
  }
  $('#rpSpeed').value = String(R.speed);
  $('#rpPlay').textContent = R.playing ? '❚❚ 일시정지' : '▶ 재생';
  if (document.activeElement !== $('#rpPos')) $('#rpPos').value = String(Math.round(pct));
  $('#rpTime').textContent = `${hms(R.t)} / ${hms(R.end)} (${dur(R.t - R.start)} 경과)`;
}
let lastFrame = 0, lastRender = 0;
function frame(t) {
  if (S.replay?.playing) {
    advance(lastFrame ? t - lastFrame : 0);
    if (t - lastRender > 250) { lastRender = t; render(); }
  }
  lastFrame = t;
  requestAnimationFrame(frame);
}

// ---------- events ----------
document.addEventListener('click', async (ev) => {
  const rp = ev.target.closest('[data-replay]');
  if (rp) { startReplay(rp.dataset.replay); return; }
  const run = ev.target.closest('[data-run]');
  if (run) {
    S.replay = null; $('#replaybar').dataset.built = '';
    S.selected = run.dataset.run;
    const f = S.files.get(S.selected);
    if (f && !f.loaded) { $('#timeline').innerHTML = '<div class="empty">불러오는 중…</div>'; await pullLog(f); markLive(); }
    render();
    return;
  }
  const svg = ev.target.closest('.timeline svg');
  if (svg && S.replay) {
    const b = svg.getBoundingClientRect();
    const px = ((ev.clientX - b.left) / b.width) * svg.viewBox.baseVal.width;
    const t0 = +svg.dataset.t0, t1 = +svg.dataset.t1, L = +svg.dataset.l, w = +svg.dataset.w;
    if (px >= L) { seekReplay(t0 + ((px - L) / w) * (t1 - t0)); render(); }
  }
});
document.addEventListener('mousemove', (ev) => {
  const tip = $('#tip');
  const el = ev.target.closest('[data-tip]');
  if (!el || !tips[+el.dataset.tip]) { tip.hidden = true; return; }
  tip.innerHTML = tipHtml(tips[+el.dataset.tip]);
  tip.hidden = false;
  const w = tip.offsetWidth, h = tip.offsetHeight;
  tip.style.left = Math.min(ev.clientX + 14, innerWidth - w - 8) + 'px';
  tip.style.top = Math.min(ev.clientY + 14, innerHeight - h - 8) + 'px';
});
let resizeT;
addEventListener('resize', () => { clearTimeout(resizeT); resizeT = setTimeout(render, 150); });

tick();
slowTick();
setInterval(tick, 2000);
setInterval(slowTick, 30000);
requestAnimationFrame(frame);
