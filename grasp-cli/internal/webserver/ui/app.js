'use strict';
/* grasp canvas: a whiteboard of function cards. Cards stay where you put
   them; a new card opens beside the card it was opened from. Drag headers to
   move cards, the background to pan, ⌘+wheel to zoom. Sessions persist the
   whole arrangement server-side. */

const $ = s => document.querySelector(s);
const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const CARD_W = 620, GAP_X = 70, GAP_Y = 30, EST_H = 320;

let IDX = null, byId = new Map(), callersOf = new Map(), COMMENTS = { threads: [] }, CFG = {};
let S = null;                 // session: {name, cards: Map, edges: [], focus, pan, zoom}
let heights = new Map();      // card id -> measured px height
let widths = new Map();       // card id -> measured px width (cards size to their code)
const W = id => widths.get(id) || CARD_W;
let undoStack = [];           // canvas snapshots, session-local
let sigMode = false;
let composing = null;         // {fnId, file, line, endLine, side}
let allModulesShown = false;
let zTop = 10;
let spaceHeld = false;

function emptySession(name) {
  return { name, cards: new Map(), edges: [], groups: [], focus: null, pan: { x: 0, y: 0 }, zoom: 1 };
}

// ---------- groups ----------
// A group of cards is drawn as a frame around the cards themselves, wherever
// they sit, so two flows on one canvas read apart. The frame follows its
// cards; a card belongs to at most one group.
function groupOf(id) {
  return S.groups.find(g => g.cards.includes(id)) || null;
}

function pruneGroups() {
  S.groups = S.groups.filter(g => {
    g.cards = g.cards.filter(c => S.cards.has(c));
    return g.cards.length > 0;
  });
}

function groupSelection() {
  const ids = selected.size ? [...selected] : (S.focus ? [S.focus] : []);
  const members = ids.filter(id => S.cards.has(id));
  if (!members.length) return;
  pushHistory();
  for (const g of S.groups) g.cards = g.cards.filter(c => !members.includes(c));
  S.groups.push({ id: 'g_' + Math.random().toString(36).slice(2, 8), title: '', cards: members });
  pruneGroups();
  renderCanvas(); scheduleSave();
}

function ungroupSelection() {
  const ids = selected.size ? [...selected] : (S.focus ? [S.focus] : []);
  if (!ids.length) return;
  pushHistory();
  for (const g of S.groups) g.cards = g.cards.filter(c => !ids.includes(c));
  pruneGroups();
  renderCanvas(); scheduleSave();
}

// ---------- data ----------
async function loadAll(keep) {
  const [ir, cr, gr] = await Promise.all([fetch('/api/index'), fetch('/api/comments'), fetch('/api/config')]);
  if (!ir.ok) { $('#hint').innerHTML = esc(await ir.text()); return false; }
  IDX = await ir.json();
  COMMENTS = cr.ok ? await cr.json() : { threads: [] };
  CFG = gr.ok ? await gr.json() : {};
  byId = new Map(IDX.functions.map(f => [f.id, f]));
  callersOf = new Map();
  for (const f of IDX.functions)
    for (const c of f.calls) {
      if (!callersOf.has(c.target)) callersOf.set(c.target, []);
      callersOf.get(c.target).push({ from: f.id, call: c });
    }
  if (keep && S) {
    for (const id of [...S.cards.keys()]) if (!byId.has(id)) S.cards.delete(id);
    S.edges = S.edges.filter(e => S.cards.has(e.from) && S.cards.has(e.to));
  }
  renderHeader(); renderSidebar();
  return true;
}

function changedFns() { return IDX.functions.filter(f => f.change !== 'unchanged'); }

// ---------- sessions ----------
function defaultSessionName() {
  const q = new URLSearchParams(location.search).get('s');
  if (q) return q;
  if (IDX.review && IDX.review.pr) return 'pr-' + IDX.review.pr;
  return 'default';
}

async function loadSession(name) {
  S = emptySession(name);
  try {
    const r = await fetch('/api/sessions/' + encodeURIComponent(name));
    if (r.ok) {
      const doc = await r.json();
      for (const c of doc.cards || []) if (byId.has(c.id)) S.cards.set(c.id, { x: c.x, y: c.y, view: c.view || 'source', fold: !!c.fold, collapsed: !!c.collapsed, root: !!c.root, expanded: new Set() });
      S.edges = (doc.edges || []).filter(e => S.cards.has(e.from) && S.cards.has(e.to));
      S.groups = (doc.groups || []).map(g => ({ id: g.id, title: g.title || '', cards: (g.cards || []).filter(c => S.cards.has(c)) })).filter(g => g.cards.length);
      S.focus = doc.focus && S.cards.has(doc.focus) ? doc.focus : null;
      if (doc.pan) S.pan = doc.pan;
      if (doc.zoom) S.zoom = doc.zoom;
    }
  } catch { /* fresh session */ }
  const url = new URL(location);
  if (name === 'default') url.searchParams.delete('s'); else url.searchParams.set('s', name);
  history.replaceState(null, '', url);
  if (S.cards.size === 0) autoOpenChanges();
  renderCanvas();
  applyTransform();
  await refreshSessionList();
}

let saveTimer = null;
function scheduleSave() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(saveSession, 700);
}
async function saveSession() {
  if (!S) return;
  const doc = {
    cards: [...S.cards.entries()].map(([id, c]) => ({ id, x: Math.round(c.x), y: Math.round(c.y), view: c.view, fold: c.fold, collapsed: c.collapsed, root: c.root })),
    edges: S.edges, groups: S.groups, focus: S.focus, pan: { x: Math.round(S.pan.x), y: Math.round(S.pan.y) }, zoom: S.zoom,
  };
  await fetch('/api/sessions/' + encodeURIComponent(S.name), { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(doc) }).catch(() => {});
}

async function refreshSessionList() {
  let names = [];
  try { names = (await (await fetch('/api/sessions')).json()).sessions || []; } catch { /* none */ }
  if (!names.includes(S.name)) names.unshift(S.name);
  const sel = $('#sessionSel');
  sel.innerHTML = names.map(n => '<option' + (n === S.name ? ' selected' : '') + '>' + esc(n) + '</option>').join('') +
    '<option value="__new">new session…</option><option value="__del">delete this session</option>';
}

$('#sessionSel').addEventListener('change', async () => {
  const v = $('#sessionSel').value;
  if (v === '__new') {
    const name = prompt('session name (letters, digits, - and _):');
    await refreshSessionList();
    if (name && /^[A-Za-z0-9_-]{1,40}$/.test(name)) { await saveSession(); await loadSession(name); }
    return;
  }
  if (v === '__del') {
    await fetch('/api/sessions/' + encodeURIComponent(S.name), { method: 'DELETE' });
    await loadSession('default');
    return;
  }
  if (v !== S.name) { await saveSession(); await loadSession(v); }
});

// Open every changed function as a card, one column per module, modified
// cards showing their diff — the canvas a review starts from.
function autoOpenChanges() {
  const ch = changedFns().slice(0, 24);
  if (ch.length === 0) return;
  const mods = new Map();
  for (const f of ch) { if (!mods.has(f.module)) mods.set(f.module, []); mods.get(f.module).push(f); }
  let col = 0;
  for (const [, fns] of mods) {
    let y = 40;
    for (const f of fns) {
      S.cards.set(f.id, { x: 40 + col * (CARD_W + GAP_X), y, view: f.base_source != null ? 'diff' : 'source', fold: false, collapsed: false, root: true, expanded: new Set() });
      y += EST_H + GAP_Y;
    }
    col++;
  }
  for (const f of ch)
    for (const c of f.calls)
      if (S.cards.has(c.target) && c.target !== f.id && !S.edges.some(e => e.from === f.id && e.to === c.target))
        S.edges.push({ from: f.id, to: c.target, key: c.target + '@' + c.range.start[0] + ':' + c.range.start[1] });
  S.focus = ch[0].id;
  // lay out with real heights once rendered
  requestAnimationFrame(() => requestAnimationFrame(() => { layoutCanvas(); renderCanvas(); scheduleSave(); }));
}

// ---------- header ----------
function renderHeader() {
  $('#project').textContent = IDX.project.app;
  const g = IDX.git || {};
  const base = (g.base_ref || '').replace(/^origin\//, '');
  $('#reviewline').textContent = base ? base + '…' + (g.branch === 'HEAD' ? (g.head || '').slice(0, 8) : g.branch) : '';
  const pr = IDX.review;
  const a = $('#prlink');
  if (pr && pr.pr) { a.textContent = '#' + pr.pr + ' ' + (pr.title || ''); a.href = pr.url || '#'; } else { a.textContent = ''; }
  $('#counts').textContent = changedFns().length + ' changed · ' + IDX.functions.length + ' functions';
}

// ---------- sidebar ----------
function renderSidebar() {
  const ch = changedFns();
  const chGroups = groupBy(ch, f => f.module);
  $('#changes').innerHTML = ch.length === 0 ? '<div class="side-empty">no changes against the base</div>'
    : [...chGroups.entries()].map(([mod, fns]) =>
        '<div class="side-mod"><div class="side-modlabel">' + esc(mod) + '</div>' + fns.map(sideFn).join('') + '</div>').join('');

  const sideCmt = t => {
    const first = (t.comments[0] && t.comments[0].body || '').slice(0, 48);
    const mark = t.status ? ' <span class="chip">' + esc(t.status) + '</span>' : '';
    const cls = t.status === 'orphan' ? 'side-cmt orphan' : 'side-cmt';
    return '<div class="' + cls + '" data-fn="' + esc(t.function) + '"' + (t.status === 'orphan' ? '' : ' data-click="1"') + '>' +
      '<span class="loc">' + esc(t.file.split('/').pop() + ':' + t.line) + '</span> ' + esc(first) + mark + '</div>';
  };
  const openThreads = COMMENTS.threads.filter(t => !t.resolved && !threadForeign(t));
  const foreign = COMMENTS.threads.filter(t => !t.resolved && threadForeign(t));
  $('#commentsList').innerHTML =
    (openThreads.length === 0 ? '<div class="side-empty">none open</div>' : openThreads.map(sideCmt).join('')) +
    (foreign.length ? '<details class="side-mod"><summary>other reviews (' + foreign.length + ')</summary>' +
      foreign.map(t => sideCmt(t).replace('data-click="1"', '') + '').join('') + '</details>' : '');

  // Related: modules the change touches one hop away — callers into and
  // callees out of the changed functions. A widely-used component drags in
  // dozens of callers, so modules rank by how many edges tie them to the
  // change and only the strongest few show; the rest sit behind "show more".
  const changedIds = new Set(ch.map(f => f.id));
  const changedMods = new Set(ch.map(f => f.module));
  const related = new Map(); // module -> {weight, fns: Map(id -> {f, dirs})}
  const addRel = (f, dir) => {
    if (!f || changedIds.has(f.id) || changedMods.has(f.module)) return;
    if (!related.has(f.module)) related.set(f.module, { weight: 0, fns: new Map() });
    const m = related.get(f.module);
    m.weight++;
    if (!m.fns.has(f.id)) m.fns.set(f.id, { f, dirs: new Set() });
    m.fns.get(f.id).dirs.add(dir);
  };
  for (const f of ch) for (const c of f.calls) addRel(byId.get(c.target), 'out');
  for (const id of changedIds) for (const caller of (callersOf.get(id) || [])) addRel(byId.get(caller.from), 'in');

  const relRows = [...related.entries()].sort((a, b) => b[1].weight - a[1].weight);
  const REL_CAP = 8;
  const relHTML = list => list.map(([mod, m]) =>
    '<details class="side-mod"><summary>' + esc(mod) + ' <span style="color:var(--dim)">(' + m.fns.size + ')</span></summary>' +
    [...m.fns.values()].map(({ f, dirs }) => sideFn(f, dirs.has('in') && dirs.has('out') ? '↔' : dirs.has('in') ? '←' : '→')).join('') +
    '</details>').join('');
  $('#related').innerHTML = related.size === 0 ? '<div class="side-empty">nothing adjacent</div>'
    : relHTML(relRows.slice(0, REL_CAP)) +
      (relRows.length > REL_CAP
        ? '<div id="relMore" hidden>' + relHTML(relRows.slice(REL_CAP)) + '</div>' +
          '<button id="relMoreBtn" style="margin:4px">show ' + (relRows.length - REL_CAP) + ' more related modules</button>'
        : '');
  const relBtn = $('#relMoreBtn');
  if (relBtn) relBtn.addEventListener('click', () => { $('#relMore').hidden = false; relBtn.remove(); });

  const modsEl = $('#modules');
  if (allModulesShown) {
    const mods = groupBy(IDX.functions, f => f.module);
    modsEl.innerHTML = [...mods.entries()].map(([mod, fns]) =>
      '<details class="side-mod"><summary>' + esc(mod) + ' <span style="color:var(--dim)">(' + fns.length + ')</span></summary>' +
      fns.map(sideFn).join('') + '</details>').join('');
    $('#allModulesBtn').textContent = 'hide the full module list';
  } else {
    modsEl.innerHTML = '';
    $('#allModulesBtn').textContent = 'show all modules (' + new Set(IDX.functions.map(f => f.module)).size + ')';
  }

  document.querySelectorAll('.side-fn').forEach(el => el.addEventListener('click', () => openCard(el.dataset.id, {})));
  document.querySelectorAll('.side-cmt[data-click]').forEach(el => el.addEventListener('click', () => openCard(el.dataset.fn, {})));
  applyFilter();
}

function sideFn(f, dir) {
  return '<div class="side-fn" data-id="' + esc(f.id) + '"><span class="badge ' + f.change + '">' +
    f.change[0].toUpperCase() + '</span>' +
    (dir ? '<span style="color:var(--dim)" title="← calls the change · → called by it">' + dir + '</span>' : '') +
    '<span>' + esc(f.name) + '<span style="color:var(--dim)">/' + f.arity + '</span></span></div>';
}

function groupBy(list, key) {
  const m = new Map();
  for (const it of list) { const k = key(it); if (!m.has(k)) m.set(k, []); m.get(k).push(it); }
  return m;
}

$('#filter').addEventListener('input', applyFilter);
function applyFilter() {
  const q = $('#filter').value.toLowerCase();
  document.querySelectorAll('.side-fn').forEach(el => { el.hidden = q !== '' && !el.dataset.id.toLowerCase().includes(q); });
  document.querySelectorAll('#sidebar details, #changes .side-mod').forEach(d => {
    const any = [...d.querySelectorAll('.side-fn')].some(el => !el.hidden);
    d.style.display = any ? '' : 'none';
    if (q !== '' && d.tagName === 'DETAILS') d.open = true;
  });
}
$('#allModulesBtn').addEventListener('click', () => { allModulesShown = !allModulesShown; renderSidebar(); });

// ---------- canvas ----------
function applyTransform() {
  $('#world').style.transform = 'translate(' + S.pan.x + 'px,' + S.pan.y + 'px) scale(' + S.zoom + ')';
  $('#zoomLabel').textContent = Math.round(S.zoom * 100) + '%';
}

function openCard(id, { fromId, key, side }) {
  if (!byId.has(id)) return;
  if (fromId && !S.cards.has(fromId)) fromId = undefined;
  setFocus(id);
  if (S.cards.has(id)) {
    if (fromId && !S.edges.some(e => e.from === fromId && e.to === id)) { pushHistory(); S.edges.push({ from: fromId, to: id, key }); }
    renderCanvas();
    const el = cardEl(id); if (el) el.classList.add('flash');
    ensureVisible(id);
    scheduleSave();
    return;
  }
  pushHistory();
  const pos = place(fromId, side);
  S.cards.set(id, { x: pos.x, y: pos.y, view: 'source', fold: false, collapsed: false, root: !fromId, expanded: new Set() });
  if (fromId) {
    S.edges.push({ from: side === 'left' ? id : fromId, to: side === 'left' ? fromId : id, key });
    // a card opened from another joins the group of the card it came from
    const g = groupOf(fromId);
    if (g && !g.cards.includes(id)) g.cards.push(id);
  }
  renderCanvas();
  ensureVisible(id);
  scheduleSave();
}

// place beside the opener, in the first clear space there.
function place(fromId, side) {
  if (!fromId || !S.cards.has(fromId)) {
    let y = 40;
    for (const [id, c] of S.cards) if (c.x < 40 + CARD_W) y = Math.max(y, c.y + (heights.get(id) || EST_H) + GAP_Y);
    return { x: 40, y };
  }
  const from = S.cards.get(fromId);
  const x = side === 'left' ? from.x - CARD_W - GAP_X : from.x + W(fromId) + GAP_X;
  let y = from.y;
  const collides = yy => [...S.cards.entries()].some(([id, c]) =>
    x < c.x + W(id) + 10 && x + CARD_W > c.x - 10 &&
    yy < c.y + (heights.get(id) || EST_H) + 10 && yy + EST_H > c.y - 10);
  let guard = 0;
  while (collides(y) && guard++ < 200) y += 60;
  return { x, y };
}

function closeCard(id, subtree) {
  pushHistory();
  selected.delete(id);
  S.cards.delete(id);
  S.edges = S.edges.filter(e => e.from !== id && e.to !== id);
  if (subtree) {
    // keep what a root still reaches; everything else had no other way in.
    const reach = new Set();
    const walk = i => { if (reach.has(i)) return; reach.add(i); for (const e of S.edges) if (e.from === i) walk(e.to); };
    for (const [i, c] of S.cards) if (c.root) walk(i);
    for (const i of [...S.cards.keys()]) if (!reach.has(i)) { S.cards.delete(i); }
    S.edges = S.edges.filter(e => S.cards.has(e.from) && S.cards.has(e.to));
  }
  if (S.focus === id) S.focus = [...S.cards.keys()].pop() || null;
  pruneGroups();
  renderCanvas();
  scheduleSave();
}

function setFocus(id) {
  S.focus = id;
  document.querySelectorAll('.card.focused').forEach(c => c.classList.remove('focused'));
  const el = cardEl(id);
  if (el) { el.classList.add('focused'); el.style.zIndex = ++zTop; }
}

function cardEl(id) { return document.querySelector('.card[data-id="' + CSS.escape(id) + '"]'); }

function renderCanvas() {
  const world = $('#world');
  world.querySelectorAll('.card').forEach(el => el.remove());
  $('#hint').style.display = S.cards.size === 0 ? '' : 'none';
  for (const [id] of S.cards) world.appendChild(buildCard(byId.get(id)));
  requestAnimationFrame(() => {
    for (const [id] of S.cards) {
      const el = cardEl(id);
      if (el) { heights.set(id, el.offsetHeight); widths.set(id, el.offsetWidth); }
    }
    drawEdges();
  });
}

// ---------- undo ----------
function snapshot() {
  return JSON.stringify({
    cards: [...S.cards.entries()].map(([id, c]) => ({ id, x: c.x, y: c.y, view: c.view, fold: c.fold, collapsed: c.collapsed, root: c.root })),
    edges: S.edges, groups: S.groups, focus: S.focus, pan: S.pan, zoom: S.zoom,
  });
}

function pushHistory() {
  undoStack.push(snapshot());
  if (undoStack.length > 30) undoStack.shift();
  $('#undoBtn').disabled = false;
}

function undo() {
  const snap = undoStack.pop();
  if (!snap) return;
  const doc = JSON.parse(snap);
  S.cards = new Map(doc.cards.filter(c => byId.has(c.id))
    .map(c => [c.id, { x: c.x, y: c.y, view: c.view, fold: c.fold, collapsed: c.collapsed, root: c.root, expanded: new Set() }]));
  S.edges = doc.edges.filter(e => S.cards.has(e.from) && S.cards.has(e.to));
  S.groups = (doc.groups || []).map(g => ({ id: g.id, title: g.title, cards: g.cards.filter(c => S.cards.has(c)) })).filter(g => g.cards.length);
  S.focus = doc.focus && S.cards.has(doc.focus) ? doc.focus : null;
  S.pan = doc.pan; S.zoom = doc.zoom;
  renderCanvas(); applyTransform(); scheduleSave();
  $('#undoBtn').disabled = undoStack.length === 0;
}
$('#undoBtn').addEventListener('click', undo);

function ensureVisible(id) {
  const c = S.cards.get(id);
  if (!c) return;
  const vp = $('#viewport'), vw = vp.clientWidth, vh = vp.clientHeight;
  const sx = c.x * S.zoom + S.pan.x, sy = c.y * S.zoom + S.pan.y;
  const w = W(id) * S.zoom, h = Math.min(heights.get(id) || EST_H, 500) * S.zoom;
  if (sx < 0) S.pan.x -= sx - 30;
  if (sy < 40) S.pan.y -= sy - 70;
  if (sx + w > vw) S.pan.x -= sx + w - vw + 30;
  if (sy + h > vh) S.pan.y -= sy + h - vh + 30;
  applyTransform();
  requestAnimationFrame(drawEdges);
}

// ---------- pan / zoom / drag ----------
const viewport = $('#viewport');
viewport.addEventListener('wheel', e => {
  e.preventDefault();
  if (e.metaKey || e.ctrlKey) {
    const z2 = Math.min(2.5, Math.max(0.12, S.zoom * Math.exp(-e.deltaY * 0.0022)));
    const r = viewport.getBoundingClientRect();
    const cx = e.clientX - r.left, cy = e.clientY - r.top;
    S.pan.x = cx - (cx - S.pan.x) * (z2 / S.zoom);
    S.pan.y = cy - (cy - S.pan.y) * (z2 / S.zoom);
    S.zoom = z2;
  } else {
    S.pan.x -= e.deltaX; S.pan.y -= e.deltaY;
  }
  applyTransform();
  scheduleSave();
}, { passive: false });

// ---------- selection ----------
// ⌘/Ctrl+click toggles a card in the selection; Shift+drag on the background
// draws a box; dragging any selected card moves the whole selection. The
// selection is this tab's own — it is not saved with the session.
let selected = new Set();

function paintSelected() {
  document.querySelectorAll('.card').forEach(el => el.classList.toggle('selected', selected.has(el.dataset.id)));
}

function clearSelection() {
  if (selected.size === 0) return;
  selected.clear();
  paintSelected();
}

function toggleSelected(id) {
  if (selected.has(id)) selected.delete(id); else selected.add(id);
  paintSelected();
}

// dragging: {kind:'pan'|'cards'|'box', …}. A ⌘/Ctrl press on a card is
// ambiguous until the mouse moves: past 4px it drags, released in place it
// toggles the selection.
let dragging = null;
viewport.addEventListener('mousedown', e => {
  const cardHead = e.target.closest('.card-head');
  const card = e.target.closest('.card');
  if (e.target.closest('button, a, select, textarea, input, .callers-menu')) return;

  // Drag a frame's title to move the whole group; a click with no drag
  // renames it in place.
  const ftitle = e.target.closest('.frame-title');
  if (ftitle) {
    const gid = ftitle.closest('.frame').dataset.gid;
    const g = S.groups.find(x => x.id === gid);
    if (g) {
      const positions = new Map(g.cards.filter(m => S.cards.has(m)).map(m => [m, { x: S.cards.get(m).x, y: S.cards.get(m).y }]));
      dragging = { kind: 'cards', id: g.cards[0], positions, sx: e.clientX, sy: e.clientY, moved: false, renameGroup: gid };
      e.preventDefault();
    }
    return;
  }

  if (!card && e.shiftKey && !spaceHeld) {
    const box = document.createElement('div');
    box.id = 'selbox';
    viewport.appendChild(box);
    dragging = { kind: 'box', sx: e.clientX, sy: e.clientY, el: box };
    e.preventDefault();
    return;
  }
  if (spaceHeld || !card) {
    dragging = { kind: 'pan', sx: e.clientX, sy: e.clientY, ox: S.pan.x, oy: S.pan.y, clearOnClick: !card && !e.metaKey && !e.ctrlKey };
    viewport.classList.add('panning');
    e.preventDefault();
    return;
  }
  const id = card.dataset.id;
  const modifier = e.metaKey || e.ctrlKey;
  const inSelection = selected.has(id);
  // A selected card drags from anywhere on it — that is what the selection is
  // for. Otherwise the header (or a modifier press) is the drag handle.
  if (cardHead || modifier || inSelection) {
    setFocus(id);
    const moving = inSelection ? [...selected] : [id];
    const positions = new Map(moving.filter(m => S.cards.has(m)).map(m => [m, { x: S.cards.get(m).x, y: S.cards.get(m).y }]));
    dragging = {
      kind: 'cards', id, positions, sx: e.clientX, sy: e.clientY, moved: false,
      toggleOnClick: modifier,
      releaseOnClick: inSelection && !modifier, // a plain click lets the selection go
    };
    e.preventDefault();
  } else {
    setFocus(id);
  }
});

window.addEventListener('mousemove', e => {
  if (!dragging) return;
  const dx = e.clientX - dragging.sx, dy = e.clientY - dragging.sy;
  switch (dragging.kind) {
    case 'pan':
      S.pan.x = dragging.ox + dx;
      S.pan.y = dragging.oy + dy;
      if (Math.abs(dx) + Math.abs(dy) > 3) dragging.clearOnClick = false;
      applyTransform();
      break;
    case 'cards': {
      if (!dragging.moved && Math.abs(dx) + Math.abs(dy) <= 4) return;
      dragging.moved = true;
      for (const [id, p] of dragging.positions) {
        const c = S.cards.get(id);
        if (!c) continue;
        c.x = p.x + dx / S.zoom;
        c.y = p.y + dy / S.zoom;
        const el = cardEl(id);
        if (el) { el.style.left = c.x + 'px'; el.style.top = c.y + 'px'; }
      }
      drawEdges();
      break;
    }
    case 'box': {
      const vr = viewport.getBoundingClientRect();
      const x = Math.min(e.clientX, dragging.sx) - vr.left, y = Math.min(e.clientY, dragging.sy) - vr.top;
      Object.assign(dragging.el.style, {
        left: x + 'px', top: y + 'px',
        width: Math.abs(dx) + 'px', height: Math.abs(dy) + 'px',
      });
      break;
    }
  }
});

window.addEventListener('mouseup', e => {
  if (!dragging) return;
  const d = dragging;
  dragging = null;
  viewport.classList.remove('panning');
  switch (d.kind) {
    case 'pan':
      if (d.clearOnClick) clearSelection();
      scheduleSave();
      break;
    case 'cards':
      if (!d.moved && d.renameGroup) startGroupRename(d.renameGroup);
      else if (!d.moved && d.toggleOnClick) toggleSelected(d.id);
      else if (!d.moved && d.releaseOnClick) clearSelection();
      else if (d.moved) {
        if (!d.renameGroup) maybeDropIntoFrame(d);
        scheduleSave();
      }
      break;
    case 'box': {
      d.el.remove();
      const vr = viewport.getBoundingClientRect();
      const bx1 = Math.min(e.clientX, d.sx) - vr.left, by1 = Math.min(e.clientY, d.sy) - vr.top;
      const bx2 = Math.max(e.clientX, d.sx) - vr.left, by2 = Math.max(e.clientY, d.sy) - vr.top;
      const next = new Set();
      for (const [id, c] of S.cards) {
        const sx = c.x * S.zoom + S.pan.x, sy = c.y * S.zoom + S.pan.y;
        const w = W(id) * S.zoom, h = (heights.get(id) || EST_H) * S.zoom;
        if (sx < bx2 && sx + w > bx1 && sy < by2 && sy + h > by1) next.add(id);
      }
      selected = next;
      paintSelected();
      break;
    }
  }
});

$('#resetBtn').addEventListener('click', resetLayout);
function resetLayout() {
  pushHistory();
  layoutCanvas();
  S.pan = { x: 0, y: 0 };
  renderCanvas(); applyTransform(); scheduleSave();
}

const FLOW_GAP = 110;

// Layered flow layout: callers on the left, callees to the right, one
// connected component per horizontal band so two flows read apart. Within a
// column, cards order by the barycenter of their neighbors — the sweep that
// untangles crossing edges. Cards with no edge at all sit in a grid section
// of their own under the flows.
function layoutCanvas() {
  const ids = [...S.cards.keys()];
  if (ids.length === 0) return;
  const H = id => heights.get(id) || EST_H;
  const out = new Map(ids.map(i => [i, new Set()]));
  const inn = new Map(ids.map(i => [i, new Set()]));
  for (const e of S.edges) {
    if (out.has(e.from) && inn.has(e.to) && e.from !== e.to) { out.get(e.from).add(e.to); inn.get(e.to).add(e.from); }
  }

  // connected components (undirected)
  const seen = new Set();
  const comps = [];
  for (const id of ids) {
    if (seen.has(id)) continue;
    const comp = [], stack = [id];
    while (stack.length) {
      const n = stack.pop();
      if (seen.has(n)) continue;
      seen.add(n); comp.push(n);
      for (const m of out.get(n)) stack.push(m);
      for (const m of inn.get(n)) stack.push(m);
    }
    comps.push(comp);
  }
  const isolated = [];
  const flows = [];
  for (const comp of comps) {
    if (comp.length === 1 && out.get(comp[0]).size === 0 && inn.get(comp[0]).size === 0) isolated.push(comp[0]);
    else flows.push(comp);
  }
  flows.sort((a, b) => b.length - a.length);

  let yBase = 40;
  for (const flow of flows) yBase = layoutFlow(flow, out, inn, H, yBase) + FLOW_GAP;

  // the unconnected section: a compact grid under the flows
  if (isolated.length) {
    isolated.sort((a, b) => (byId.get(a).module + a).localeCompare(byId.get(b).module + b));
    const perRow = 3;
    let x = 40, y = yBase, rowH = 0;
    isolated.forEach((id, i) => {
      if (i > 0 && i % perRow === 0) { y += rowH + GAP_Y; x = 40; rowH = 0; }
      const c = S.cards.get(id);
      c.x = x; c.y = y;
      x += W(id) + GAP_X;
      rowH = Math.max(rowH, H(id));
    });
  }
}

function layoutFlow(nodes, out, inn, H, yStart) {
  const nodeSet = new Set(nodes);
  const layer = new Map();
  // longest path from the flow's entry points, so a card sits to the right
  // of everything that calls it
  const visiting = new Set();
  const depth = n => {
    if (layer.has(n)) return layer.get(n);
    if (visiting.has(n)) return 0; // cycle: break it here
    visiting.add(n);
    let d = 0;
    for (const p of inn.get(n)) if (nodeSet.has(p)) d = Math.max(d, depth(p) + 1);
    visiting.delete(n);
    layer.set(n, d);
    return d;
  };
  for (const n of nodes) depth(n);

  const cols = [];
  for (const n of nodes) { const d = layer.get(n) || 0; (cols[d] || (cols[d] = [])).push(n); }
  for (let d = 0; d < cols.length; d++) if (!cols[d]) cols[d] = [];

  // barycenter sweeps: order each column by the mean position of its
  // neighbors in the adjacent column, a few passes each way
  const pos = new Map();
  cols.forEach(col => col.forEach((n, i) => pos.set(n, i)));
  const bary = (n, neigh) => {
    const ns = [...neigh].filter(m => nodeSet.has(m));
    if (!ns.length) return pos.get(n);
    return ns.reduce((s, m) => s + pos.get(m), 0) / ns.length;
  };
  for (let it = 0; it < 3; it++) {
    for (let d = 1; d < cols.length; d++) {
      cols[d].sort((a, b) => bary(a, inn.get(a)) - bary(b, inn.get(b)));
      cols[d].forEach((n, i) => pos.set(n, i));
    }
    for (let d = cols.length - 2; d >= 0; d--) {
      cols[d].sort((a, b) => bary(a, out.get(a)) - bary(b, out.get(b)));
      cols[d].forEach((n, i) => pos.set(n, i));
    }
  }

  // coordinates: x cumulative by each layer's widest card; y stacked, nudged
  // toward the mean of the neighbors already placed so edges run
  // near-horizontal
  const colX = [];
  let xCursor = 40;
  cols.forEach((col, d) => {
    colX[d] = xCursor;
    let widest = CARD_W;
    for (const n of col) widest = Math.max(widest, W(n));
    xCursor += widest + GAP_X;
  });

  const yOf = new Map();
  let maxBottom = yStart;
  cols.forEach((col, d) => {
    let cursor = yStart;
    for (const n of col) {
      let want = cursor;
      const placed = [...inn.get(n)].filter(m => nodeSet.has(m) && yOf.has(m));
      if (placed.length) {
        const mean = placed.reduce((s, m) => s + yOf.get(m), 0) / placed.length;
        want = Math.max(cursor, mean);
      }
      yOf.set(n, want);
      const c = S.cards.get(n);
      c.x = colX[d];
      c.y = want;
      cursor = want + H(n) + GAP_Y;
      maxBottom = Math.max(maxBottom, cursor);
    }
  });
  return maxBottom;
}

$('#sigBtn').addEventListener('click', toggleSig);
function toggleSig() {
  sigMode = !sigMode;
  $('#world').classList.toggle('sig', sigMode);
  $('#sigBtn').classList.toggle('on', sigMode);
  requestAnimationFrame(() => { for (const [id] of S.cards) { const el = cardEl(id); if (el) heights.set(id, el.offsetHeight); } drawEdges(); });
}

// ---------- cards ----------
function buildCard(fn) {
  const st = S.cards.get(fn.id);
  const card = document.createElement('div');
  card.className = 'card' + (fn.removed ? ' removed-card' : '') + (fn.id === S.focus ? ' focused' : '') +
    (st.collapsed ? ' collapsed' : '') + (selected.has(fn.id) ? ' selected' : '');
  card.dataset.id = fn.id;
  card.style.left = st.x + 'px';
  card.style.top = st.y + 'px';
  if (fn.id === S.focus) card.style.zIndex = ++zTop;

  const showDiff = st.view === 'diff' && fn.base_source != null;
  let dstat = '';
  if (fn.base_source != null) {
    const d = diffLines(fn.base_source.split('\n'), fn.source.split('\n'));
    dstat = '<span class="dstat"><span class="plus">+' + d.filter(r => r.t === 'add').length + '</span> <span class="minus">−' + d.filter(r => r.t === 'del').length + '</span></span>';
  }
  const nCallers = (callersOf.get(fn.id) || []).length;
  const fileLine = fn.file + ':' + fn.span.start_line;
  const link = editorLink(fn);
  // no caller anywhere in the index: the flow starts here
  const entryChip = nCallers === 0 && !fn.removed && fn.kind !== 'file' && fn.kind !== 'attr'
    ? '<span class="chip" style="border-color:var(--accent);color:var(--accent)" title="nothing in the project calls this">entry</span>' : '';

  card.innerHTML =
    '<div class="card-head">' +
      '<span class="badge ' + fn.change + '">' + fn.change[0].toUpperCase() + '</span>' +
      '<span class="card-title">' + esc(fn.name) + '<span class="arity">/' + fn.arity + '</span></span>' +
      '<span class="chip">' + esc(fn.kind) + '</span>' + entryChip + dstat +
      '<span class="card-actions">' +
        (nCallers ? '<span class="callers-wrap"><button class="callersBtn">callers ' + nCallers + '</button></span>' : '') +
        (fn.base_source != null ? '<button class="toggleView">' + (showDiff ? 'source' : 'diff') + '</button>' : '') +
        (showDiff ? '<button class="toggleFold">' + (st.fold ? 'all lines' : 'changes only') + '</button>' : '') +
        '<button class="collapseBtn" title="collapse (c)">' + (st.collapsed ? '▸' : '▾') + '</button>' +
        '<button class="closeCard" title="close (x) · shift closes the subtree">×</button>' +
      '</span>' +
    '</div>' +
    '<div class="card-sub"><span>' + esc(fn.module) + '</span>' +
      (link && !fn.removed ? '<a href="' + link + '">' + esc(fileLine) + '</a>'
                           : '<span>' + esc(fileLine) + (fn.removed ? ' (base)' : '') + '</span>') +
    '</div>' +
    '<div class="card-body"></div>';

  const body = card.querySelector('.card-body');
  if (!st.collapsed) {
    body.appendChild(showDiff ? diffTable(fn, st) : sourceTable(fn));
    // Outdated threads — their line was edited away — sit in the footer.
    const stale = COMMENTS.threads.filter(t => t.function === fn.id && t.status === 'outdated' && !threadForeign(t));
    if (stale.length) {
      const foot = document.createElement('div');
      foot.className = 'card-foot';
      for (const t of stale) {
        const note = document.createElement('div');
        note.className = 'stale-note';
        note.textContent = '⚠ outdated — was ' + t.file + ':' + t.line + (t.side === 'base' ? ' (base)' : '');
        foot.appendChild(note);
        foot.appendChild(threadBox(t));
      }
      body.appendChild(foot);
    }
  }

  card.addEventListener('mousedown', () => { if (S.focus !== fn.id) setFocus(fn.id); });
  const tv = card.querySelector('.toggleView');
  if (tv) tv.addEventListener('click', () => {
    st.view = showDiff ? 'source' : 'diff';
    if (st.view === 'diff' && fn.base_source != null) {
      const rows = diffLines(fn.base_source.split('\n'), fn.source.split('\n'));
      if (rows.length > 100 && st.fold === false && !st.foldTouched) st.fold = true;
    }
    renderCanvas(); scheduleSave();
  });
  const tf = card.querySelector('.toggleFold');
  if (tf) tf.addEventListener('click', () => { st.fold = !st.fold; st.foldTouched = true; renderCanvas(); scheduleSave(); });
  card.querySelector('.collapseBtn').addEventListener('click', () => { st.collapsed = !st.collapsed; renderCanvas(); scheduleSave(); });
  card.querySelector('.closeCard').addEventListener('click', e => closeCard(fn.id, e.shiftKey));
  const cb = card.querySelector('.callersBtn');
  if (cb) cb.addEventListener('click', () => callersMenu(card, fn));
  return card;
}

function callersMenu(card, fn) {
  const old = card.querySelector('.callers-menu');
  if (old) { old.remove(); return; }
  const wrap = card.querySelector('.callers-wrap');
  const menu = document.createElement('div');
  menu.className = 'callers-menu';
  const seen = new Set();
  for (const { from } of callersOf.get(fn.id) || []) {
    if (seen.has(from)) continue;
    seen.add(from);
    const row = document.createElement('div');
    row.textContent = from;
    row.addEventListener('click', () => {
      const caller = byId.get(from);
      const call = caller && caller.calls.find(c => c.target === fn.id);
      const key = call ? fn.id + '@' + call.range.start[0] + ':' + call.range.start[1] : undefined;
      openCard(from, { fromId: fn.id, key, side: 'left' });
      menu.remove();
    });
    menu.appendChild(row);
  }
  wrap.appendChild(menu);
}

function editorLink(fn) {
  const root = IDX.project.root;
  if (!CFG.editor || !root) return null;
  const abs = root + '/' + fn.file, line = fn.span.start_line;
  switch (CFG.editor) {
    case 'vscode': return 'vscode://file/' + abs + ':' + line;
    case 'cursor': return 'cursor://file/' + abs + ':' + line;
    case 'zed': return 'zed://file/' + abs + ':' + line;
    case 'idea': return 'idea://open?file=' + encodeURIComponent(abs) + '&line=' + line;
  }
  return null;
}

// ---------- syntax highlighting ----------
const KW = {
  js: 'const let var function return if else for while do switch case break continue new class extends import export from default async await try catch finally throw typeof instanceof of in yield static get set delete void this super null undefined true false',
  elixir: 'def defp defmodule defmacro defmacrop defguard defstruct defprotocol defimpl defdelegate do end fn when case cond if else unless for with try rescue catch after raise receive quote unquote alias import require use true false nil and or not in',
  go: 'func return if else for range switch case break continue type struct interface map chan go defer select package import var const nil true false new make len cap append copy delete panic recover error string int int64 uint byte rune bool float64 any',
};
const kwSets = {};
for (const k in KW) kwSets[k] = new Set(KW[k].split(' '));

function langOf(file) {
  if (/\.(ex|exs)$/.test(file)) return 'elixir';
  if (/\.go$/.test(file)) return 'go';
  return 'js';
}

const tokRe = {
  js: /(\/\/.*$|\/\*.*?\*\/)|("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`?)|(\b\d[\d_.]*\b)|(\b[A-Z][A-Za-z0-9_]*\b)|(\b[a-z_$][A-Za-z0-9_$]*\b)/gm,
  elixir: /(#.*$)|("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')|(\b\d[\d_.]*\b)|(:[a-zA-Z_][A-Za-z0-9_?!]*|@[a-z_]+)|(\b[A-Z][A-Za-z0-9_.]*\b)|(\b[a-z_][A-Za-z0-9_?!]*\b)/gm,
  go: /(\/\/.*$|\/\*.*?\*\/)|("(?:[^"\\]|\\.)*"|`[^`]*`?|'(?:[^'\\]|\\.)*')|(\b\d[\d_.]*\b)|(\b[A-Z][A-Za-z0-9_]*\b)|(\b[a-z_][A-Za-z0-9_]*\b)/gm,
};

// tokenize one line into [{s, e, cls}] spans (not covering everything).
function tokenize(text, lang) {
  const re = tokRe[lang] || tokRe.js;
  re.lastIndex = 0;
  const out = [];
  let m;
  while ((m = re.exec(text))) {
    let cls = '';
    if (m[1] != null) cls = 'tok-com';
    else if (m[2] != null) cls = 'tok-str';
    else if (m[3] != null) cls = 'tok-num';
    else if (lang === 'elixir' && m[4] != null) cls = 'tok-atom';
    else {
      const word = m[0];
      const kwIdx = lang === 'elixir' ? 6 : 5;
      if (m[kwIdx] != null) cls = kwSets[lang].has(word) ? 'tok-kw' : '';
      else cls = kwSets[lang].has(word) ? 'tok-kw' : 'tok-mod';
    }
    if (cls) out.push({ s: m.index, e: m.index + m[0].length, cls });
    if (m.index === re.lastIndex) re.lastIndex++;
  }
  return out;
}

function highlightRange(text, from, to, tokens) {
  let out = '', pos = from;
  for (const t of tokens) {
    if (t.e <= from || t.s >= to) continue;
    const s = Math.max(t.s, from), e = Math.min(t.e, to);
    if (s > pos) out += esc(text.slice(pos, s));
    out += '<span class="' + t.cls + '">' + esc(text.slice(s, e)) + '</span>';
    pos = e;
  }
  return out + esc(text.slice(pos, to));
}

// ---------- source view ----------
function sourceTable(fn) {
  const lines = fn.source.split('\n');
  const start = fn.span.start_line;
  const side = fn.removed ? 'base' : 'new';
  const lang = langOf(fn.file);
  const callsByLine = new Map();
  for (const c of fn.calls) {
    if (c.range.start[0] !== c.range.end[0]) continue;
    const l = c.range.start[0];
    if (!callsByLine.has(l)) callsByLine.set(l, []);
    callsByLine.get(l).push(c);
  }
  const table = mkCodeTable();
  const tbody = table.tBodies[0];
  lines.forEach((text, i) => {
    const abs = start + i;
    const tr = document.createElement('tr');
    if (inThreadRange(fn, abs, side)) tr.classList.add('inrange');
    tr.innerHTML = '<td class="ln" data-line="' + abs + '" data-side="' + side + '" title="comment · drag or shift+click for a range">' + abs + '</td><td class="codecell">' +
      lineHTML(text, callsByLine.get(abs) || [], lang) + '</td>';
    tbody.appendChild(tr);
    appendThreadRows(tbody, fn, abs, side, 2);
  });
  wireCalls(table, fn.id);
  return table;
}

function lineHTML(text, calls, lang) {
  const tokens = tokenize(text, lang);
  if (calls.length === 0) return highlightRange(text, 0, text.length, tokens);
  calls.sort((a, b) => a.range.start[1] - b.range.start[1]);
  let out = '', pos = 0;
  for (const c of calls) {
    const s = c.range.start[1] - 1, e = Math.min(c.range.end[1] - 1, text.length);
    if (s < pos || s >= text.length) continue;
    out += highlightRange(text, pos, s, tokens);
    const key = c.target + '@' + c.range.start[0] + ':' + c.range.start[1];
    out += byId.has(c.target)
      ? '<a class="call" data-target="' + esc(c.target) + '" data-key="' + esc(key) + '" title="' + esc(c.target) + '">' + esc(text.slice(s, e)) + '</a>'
      : highlightRange(text, s, e, tokens);
    pos = e;
  }
  return out + highlightRange(text, pos, text.length, tokens);
}

function wireCalls(scope, fromId) {
  scope.querySelectorAll('a.call').forEach(a =>
    a.addEventListener('click', () => openCard(a.dataset.target, { fromId, key: a.dataset.key })));
}

// ---------- diff view ----------
function diffLines(a, b) {
  const n = a.length, m = b.length;
  const dp = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1));
  for (let i = n - 1; i >= 0; i--)
    for (let j = m - 1; j >= 0; j--)
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
  const rows = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) { rows.push({ t: 'ctx', text: a[i], o: i + 1, n: j + 1 }); i++; j++; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) { rows.push({ t: 'del', text: a[i], o: i + 1, n: null }); i++; }
    else { rows.push({ t: 'add', text: b[j], o: null, n: j + 1 }); j++; }
  }
  while (i < n) { rows.push({ t: 'del', text: a[i], o: i + 1, n: null }); i++; }
  while (j < m) { rows.push({ t: 'add', text: b[j], o: null, n: j + 1 }); j++; }
  return rows;
}

function diffTable(fn, st) {
  const rows = diffLines(fn.base_source.split('\n'), fn.source.split('\n'));
  const start = fn.span.start_line;
  const lang = langOf(fn.file);
  const table = mkCodeTable();
  const tbody = table.tBodies[0];

  // The new side's lines are the current source, so its calls are clickable
  // here too — an added call opens its callee straight from the diff. Base
  // (deleted) lines have no call info in the index and stay plain.
  const callsByLine = new Map();
  for (const c of fn.calls) {
    if (c.range.start[0] !== c.range.end[0]) continue;
    const l = c.range.start[0];
    if (!callsByLine.has(l)) callsByLine.set(l, []);
    callsByLine.get(l).push(c);
  }

  const visible = new Array(rows.length).fill(true);
  if (st.fold) {
    rows.forEach((r, k) => { visible[k] = r.t !== 'ctx'; });
    rows.forEach((r, k) => {
      if (r.t !== 'ctx') for (let d = -3; d <= 3; d++) if (rows[k + d]) visible[k + d] = true;
    });
    // every line a comment sits on stays drawn
    rows.forEach((r, k) => {
      const absNew = r.n != null ? start + r.n - 1 : null;
      if ((r.o != null && threadsAt(fn, r.o, 'base').length) || (absNew != null && threadsAt(fn, absNew, 'new').length)) visible[k] = true;
    });
  }

  let k = 0, runIdx = 0;
  while (k < rows.length) {
    if (!visible[k] && !st.expanded.has(runIdx)) {
      let e = k;
      while (e < rows.length && !visible[e]) e++;
      const count = e - k, thisRun = runIdx;
      const tr = document.createElement('tr');
      tr.className = 'fold';
      tr.innerHTML = '<td colspan="4">⋯ ' + count + ' unchanged line' + (count > 1 ? 's' : '') + '</td>';
      tr.addEventListener('click', () => { st.expanded.add(thisRun); renderCanvas(); });
      tbody.appendChild(tr);
      k = e; runIdx++;
      continue;
    }
    const r = rows[k];
    const absNew = r.n != null ? start + r.n - 1 : null;
    const tr = document.createElement('tr');
    tr.className = r.t === 'ctx' ? '' : r.t;
    if ((r.o != null && inThreadRange(fn, r.o, 'base')) || (absNew != null && inThreadRange(fn, absNew, 'new'))) tr.classList.add('inrange');
    const sign = r.t === 'add' ? '+' : r.t === 'del' ? '−' : '';
    const code = absNew != null
      ? lineHTML(r.text, callsByLine.get(absNew) || [], lang)
      : highlightRange(r.text, 0, r.text.length, tokenize(r.text, lang));
    tr.innerHTML = '<td class="ln old"' + (r.o != null ? ' data-line="' + r.o + '" data-side="base"' : '') + ' title="comment on the base side · drag for a range">' + (r.o != null ? r.o : '') + '</td>' +
      '<td class="ln"' + (absNew != null ? ' data-line="' + absNew + '" data-side="new"' : '') + ' title="comment · drag for a range">' + (absNew != null ? absNew : '') + '</td>' +
      '<td class="sign">' + sign + '</td><td class="codecell">' + code + '</td>';
    tbody.appendChild(tr);
    if (r.o != null) appendThreadRows(tbody, fn, r.o, 'base', 4);
    if (absNew != null) appendThreadRows(tbody, fn, absNew, 'new', 4);
    k++;
    if (k < rows.length && !visible[k - 1] && visible[k]) runIdx++;
  }
  wireCalls(table, fn.id);
  return table;
}

function mkCodeTable() {
  const t = document.createElement('table');
  t.className = 'code';
  t.appendChild(document.createElement('tbody'));
  return t;
}

// ---------- comments ----------
// Drag down or up the line numbers to comment on a range, GitHub-style: the
// selection tints as you drag and the composer opens on release, covering
// line..end_line. A drag stays on the side it started (new or base); a plain
// click is a one-line thread; Shift+click stretches an open composer.
let lineSel = null; // {fnId, file, side, anchor, cur}

document.addEventListener('mousedown', e => {
  const td = e.target.closest('td.ln');
  if (!td || !td.dataset.line) return;
  const card = td.closest('.card');
  if (!card) return;
  const fn = byId.get(card.dataset.id);
  if (!fn) return;
  const line = +td.dataset.line, side = td.dataset.side;
  e.preventDefault();
  e.stopPropagation();
  if (e.shiftKey && composing && composing.fnId === fn.id && composing.side === side) {
    if (line >= composing.line) composing.endLine = line;
    else { composing.endLine = composing.endLine || composing.line; composing.line = line; }
    renderCanvas();
    return;
  }
  lineSel = { fnId: fn.id, file: fn.file, side, anchor: line, cur: line };
  paintLineSelection(card);
}, true);

document.addEventListener('mouseover', e => {
  if (!lineSel) return;
  const td = e.target.closest('td.ln');
  if (!td || !td.dataset.line || td.dataset.side !== lineSel.side) return;
  const card = td.closest('.card');
  if (!card || card.dataset.id !== lineSel.fnId) return;
  lineSel.cur = +td.dataset.line;
  paintLineSelection(card);
});

document.addEventListener('mouseup', () => {
  if (!lineSel) return;
  const { fnId, file, side, anchor, cur } = lineSel;
  lineSel = null;
  const lo = Math.min(anchor, cur), hi = Math.max(anchor, cur);
  composing = { fnId, file, line: lo, endLine: hi > lo ? hi : null, side };
  renderCanvas();
});

function paintLineSelection(card) {
  const lo = Math.min(lineSel.anchor, lineSel.cur), hi = Math.max(lineSel.anchor, lineSel.cur);
  card.querySelectorAll('td.ln[data-side="' + lineSel.side + '"]').forEach(td => {
    const n = +td.dataset.line;
    td.parentElement.classList.toggle('inrange', n >= lo && n <= hi);
  });
}

// A thread belongs to the review it was written on: one from another PR's
// review is foreign here — listed under the sidebar's "other reviews", drawn
// on no card. Untagged threads (branch reviews, older files) show everywhere.
function threadForeign(t) {
  if (!t.review_pr) return false;
  const cur = IDX.review && IDX.review.pr;
  return t.review_pr !== cur;
}

function threadsAt(fn, line, side) {
  // Only anchored threads sit on lines; outdated ones live in the card's
  // footer, orphans only in the sidebar.
  return COMMENTS.threads.filter(t => !t.status && !threadForeign(t) && t.function === fn.id && t.side === side &&
    (t.end_line ? t.end_line === line : t.line === line));
}

function inThreadRange(fn, line, side) {
  if (composing && composing.fnId === fn.id && composing.side === side && composing.endLine &&
      line >= composing.line && line <= composing.endLine) return true;
  return COMMENTS.threads.some(t => !threadForeign(t) && t.file === fn.file && t.side === side && t.end_line &&
    line >= t.line && line <= t.end_line);
}

function appendThreadRows(tbody, fn, line, side, colspan) {
  for (const t of threadsAt(fn, line, side)) tbody.appendChild(threadRow(t, colspan));
  if (composing && composing.fnId === fn.id && composing.side === side &&
      (composing.endLine ? composing.endLine === line : composing.line === line))
    tbody.appendChild(composerRow(colspan));
}

function threadRow(t, colspan) {
  const tr = document.createElement('tr');
  const td = document.createElement('td');
  td.colSpan = colspan;
  td.appendChild(threadBox(t));
  tr.appendChild(td);
  return tr;
}

function threadBox(t) {
  const box = document.createElement('div');
  box.className = 'thread' + (t.resolved ? ' resolved' : '');
  const range = t.end_line ? t.line + '–' + t.end_line : '' + t.line;
  box.innerHTML = '<div class="who" style="margin-bottom:6px"><span style="font-family:var(--mono)">' + esc(range) + (t.side === 'base' ? ' (base)' : '') + '</span>' +
    (t.resolved ? '<span class="chip">resolved</span>' : '') + '</div>' +
    t.comments.map(c =>
      '<div class="cmt"><div class="who"><span class="avatar">' + esc(initials(c.author)) + '</span>' +
      esc(c.author) + ' · ' + esc((c.at || '').slice(0, 16).replace('T', ' ')) + '</div>' +
      '<div class="body">' + esc(c.body) + '</div></div>').join('') +
    (t.published_url ? '<div class="pub">published: ' + esc(t.published_url) + '</div>' : '') +
    '<textarea placeholder="reply…"></textarea>' +
    '<div class="thread-actions">' +
      '<button class="reply">reply</button>' +
      '<button class="resolve">' + (t.resolved ? 'reopen' : 'resolve') + '</button>' +
      '<button class="del">delete</button>' +
      (t.published_url ? '' : '<button class="sendgh" title="post this thread to the PR now">send to GitHub</button>') +
    '</div>';
  if (t.resolved) box.addEventListener('click', e => { if (!e.target.closest('button, textarea')) box.classList.toggle('expanded'); });
  const ta = box.querySelector('textarea');
  box.querySelector('.reply').addEventListener('click', () => { if (ta.value.trim()) api({ action: 'reply', thread: t.id, body: ta.value }); });
  ta.addEventListener('keydown', e => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter' && ta.value.trim()) api({ action: 'reply', thread: t.id, body: ta.value });
  });
  box.querySelector('.resolve').addEventListener('click', () => api({ action: t.resolved ? 'unresolve' : 'resolve', thread: t.id }));
  box.querySelector('.del').addEventListener('click', () => api({ action: 'delete', thread: t.id }));
  const sendgh = box.querySelector('.sendgh');
  if (sendgh) sendgh.addEventListener('click', () => publishThread(t.id, sendgh));
  return box;
}

async function publishThread(threadID, btn) {
  if (btn) { btn.disabled = true; btn.textContent = 'sending…'; }
  const r = await fetch('/api/publish', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ thread: threadID }) });
  if (!r.ok) { alert(await r.text()); if (btn) { btn.disabled = false; btn.textContent = 'send to GitHub'; } return; }
  const out = await r.json();
  COMMENTS = out.comments;
  renderCanvas(); renderSidebar();
}

function composerRow(colspan) {
  const tr = document.createElement('tr');
  const td = document.createElement('td');
  td.colSpan = colspan;
  const box = document.createElement('div');
  box.className = 'composer';
  const range = composing.endLine ? composing.line + '–' + composing.endLine : '' + composing.line;
  box.innerHTML = '<textarea placeholder="comment on line ' + esc(range) + '…"></textarea>' +
    '<div class="row"><button class="send">comment</button>' +
    '<button class="sendGh" title="save the thread and post it to the PR right away">comment &amp; send to GitHub</button>' +
    '<button class="cancel">cancel</button>' +
    '<span class="hint">⌘⏎ comments · shift+click a line number extends the range</span></div>';
  const ta = box.querySelector('textarea');
  const send = async (alsoPublish) => {
    if (!ta.value.trim()) return;
    const payload = { action: 'add', function: composing.fnId, file: composing.file, line: composing.line, end_line: composing.endLine || 0, side: composing.side, body: ta.value };
    composing = null;
    const doc = await apiRaw(payload);
    if (doc && alsoPublish && doc.threads.length) await publishThread(doc.threads[doc.threads.length - 1].id, null);
  };
  box.querySelector('.send').addEventListener('click', () => send(false));
  box.querySelector('.sendGh').addEventListener('click', () => send(true));
  box.querySelector('.cancel').addEventListener('click', () => { composing = null; renderCanvas(); });
  ta.addEventListener('keydown', e => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') send(false);
    if (e.key === 'Escape') { composing = null; renderCanvas(); e.stopPropagation(); }
  });
  td.appendChild(box); tr.appendChild(td);
  setTimeout(() => ta.focus(), 0);
  return tr;
}

async function apiRaw(payload) {
  const r = await fetch('/api/comments', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
  if (!r.ok) { alert(await r.text()); return null; }
  COMMENTS = await r.json();
  renderCanvas(); renderSidebar();
  return COMMENTS;
}

async function api(payload) { await apiRaw(payload); }

// ---------- send review (all threads + final considerations) ----------
$('#sendReviewBtn').addEventListener('click', () => {
  const unpublished = COMMENTS.threads.filter(t => !t.published_url).length;
  $('#reviewInfo').textContent = unpublished + ' unpublished thread' + (unpublished === 1 ? '' : 's') +
    ' will be posted as review comments. Nothing syncs without this button.';
  $('#reviewStatus').textContent = '';
  $('#reviewBody').value = '';
  $('#reviewModal').hidden = false;
  $('#reviewBody').focus();
});
$('#reviewCancel').addEventListener('click', () => { $('#reviewModal').hidden = true; });
$('#reviewModal').addEventListener('mousedown', e => { if (e.target === $('#reviewModal')) $('#reviewModal').hidden = true; });
$('#reviewSend').addEventListener('click', async () => {
  const btn = $('#reviewSend');
  btn.disabled = true;
  $('#reviewStatus').textContent = 'sending…';
  const r = await fetch('/api/review', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ body: $('#reviewBody').value.trim() }) });
  btn.disabled = false;
  if (!r.ok) { $('#reviewStatus').textContent = await r.text(); return; }
  const out = await r.json();
  COMMENTS = out.comments;
  renderCanvas(); renderSidebar();
  $('#reviewStatus').textContent = out.log[out.log.length - 1] || 'done';
  setTimeout(() => { $('#reviewModal').hidden = true; }, 1600);
});

function initials(name) {
  return (name || '?').split(/\s+/).map(w => w[0] || '').join('').slice(0, 2).toUpperCase();
}

// ---------- edges ----------
function edgeColor(key) {
  let h = 0;
  for (const ch of key || '') h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return 'hsl(' + (h % 360) + ' 65% 62%)';
}

function drawEdges() {
  const svg = $('#edgesvg');
  const world = $('#world');
  const wr = world.getBoundingClientRect();
  let html = '';
  S.edges.forEach((e, idx) => {
    const fromCard = cardEl(e.from), toCard = cardEl(e.to);
    if (!fromCard || !toCard) return;
    const to = S.cards.get(e.to), from = S.cards.get(e.from);
    let x1, y1;
    const srcEl = e.key ? fromCard.querySelector('a.call[data-key="' + CSS.escape(e.key) + '"]') : null;
    if (srcEl) {
      const r = srcEl.getBoundingClientRect();
      x1 = (r.right - wr.left) / S.zoom;
      y1 = (r.top + r.height / 2 - wr.top) / S.zoom;
    } else {
      x1 = from.x + W(e.from);
      y1 = from.y + 20;
    }
    const rightward = to.x >= from.x + W(e.from) / 2;
    const x2 = rightward ? to.x : to.x + W(e.to);
    const y2 = to.y + 22;
    if (!rightward && srcEl == null) x1 = from.x;
    const mx = (x1 + x2) / 2;
    const color = edgeColor(e.key || e.from + e.to);
    const tip = rightward ? x2 - 7 : x2 + 7;
    html += '<path data-i="' + idx + '" d="M' + x1 + ' ' + y1 + ' C' + mx + ' ' + y1 + ', ' + mx + ' ' + y2 + ', ' + x2 + ' ' + y2 +
      '" fill="none" stroke="' + color + '" stroke-opacity=".55" stroke-width="1.6"/>' +
      '<polygon points="' + x2 + ',' + y2 + ' ' + tip + ',' + (y2 - 4) + ' ' + tip + ',' + (y2 + 4) + '" fill="' + color + '" fill-opacity=".8"/>';
  });
  svg.innerHTML = html;
  drawFrames();
  svg.querySelectorAll('path').forEach(p => p.addEventListener('dblclick', () => {
    const e = S.edges[+p.dataset.i];
    if (!e) return;
    // jump to whichever end is farther out of sight
    const vp = $('#viewport');
    const center = { x: vp.clientWidth / 2, y: vp.clientHeight / 2 };
    const dist = id => {
      const c = S.cards.get(id);
      const sx = (c.x + W(id) / 2) * S.zoom + S.pan.x, sy = c.y * S.zoom + S.pan.y;
      return Math.hypot(sx - center.x, sy - center.y);
    };
    const far = dist(e.from) > dist(e.to) ? e.from : e.to;
    setFocus(far); ensureVisible(far);
  }));
}

// startGroupRename swaps the frame's title for an input in place: Enter (or
// clicking away) saves, a blank name leaves the frame with none, Escape
// leaves it as it was.
function startGroupRename(gid) {
  const g = S.groups.find(x => x.id === gid);
  const el = document.querySelector('.frame[data-gid="' + CSS.escape(gid) + '"] .ftext');
  if (!g || !el) return;
  const input = document.createElement('input');
  input.value = g.title;
  input.placeholder = 'group title';
  el.replaceWith(input);
  input.focus();
  input.select();
  let done = false;
  const commit = save => {
    if (done) return;
    done = true;
    if (save && input.value.trim() !== g.title) {
      pushHistory();
      g.title = input.value.trim();
      scheduleSave();
    }
    renderCanvas();
  };
  input.addEventListener('keydown', ev => {
    ev.stopPropagation();
    if (ev.key === 'Enter') commit(true);
    else if (ev.key === 'Escape') commit(false);
  });
  input.addEventListener('blur', () => commit(true));
  input.addEventListener('mousedown', ev => ev.stopPropagation());
}

// Dropping a card inside another group's frame moves it (and the selection
// dragged with it) to that group. Dropped anywhere else, a card keeps the
// group it had — the frame just stretches to follow it.
function maybeDropIntoFrame(d) {
  const primary = S.cards.get(d.id);
  if (!primary) return;
  const cx = primary.x + W(d.id) / 2, cy = primary.y + 20;
  const current = groupOf(d.id);
  for (const g of S.groups) {
    if (current && g.id === current.id) continue;
    const r = frameRect(g);
    if (!r || cx < r.x || cx > r.x + r.w || cy < r.y || cy > r.y + r.h) continue;
    pushHistory();
    const moving = [...d.positions.keys()];
    for (const og of S.groups) og.cards = og.cards.filter(c => !moving.includes(c));
    for (const m of moving) if (!g.cards.includes(m) && S.cards.has(m)) g.cards.push(m);
    pruneGroups();
    renderCanvas();
    return;
  }
}

// frameRect computes a group's frame in world coordinates: the members'
// bounding box plus padding, with headroom for the title inside the top edge.
const FRAME_PAD = 20, FRAME_TOP = 46;
function frameRect(g) {
  let x1 = Infinity, y1 = Infinity, x2 = -Infinity, y2 = -Infinity;
  for (const id of g.cards) {
    const c = S.cards.get(id);
    if (!c) continue;
    x1 = Math.min(x1, c.x); y1 = Math.min(y1, c.y);
    x2 = Math.max(x2, c.x + W(id)); y2 = Math.max(y2, c.y + (heights.get(id) || EST_H));
  }
  if (x1 === Infinity) return null;
  return { x: x1 - FRAME_PAD, y: y1 - FRAME_TOP, w: x2 - x1 + 2 * FRAME_PAD, h: y2 - y1 + FRAME_TOP + FRAME_PAD };
}

function drawFrames() {
  const world = $('#world');
  world.querySelectorAll('.frame').forEach(el => el.remove());
  const svg = $('#edgesvg');
  for (const g of S.groups) {
    const r = frameRect(g);
    if (!r) continue;
    const el = document.createElement('div');
    el.className = 'frame';
    el.dataset.gid = g.id;
    Object.assign(el.style, { left: r.x + 'px', top: r.y + 'px', width: r.w + 'px', height: r.h + 'px' });
    el.innerHTML = '<div class="frame-title">' +
      '<b class="ftext">' + esc(g.title || 'Untitled group') + '</b>' +
      '<span>' + g.cards.length + ' card' + (g.cards.length === 1 ? '' : 's') + '</span>' +
      '<button class="fungroup" title="take the frame away, leave the cards">ungroup</button></div>';
    // the title stays readable however far out the zoom is
    el.querySelector('.frame-title').style.transform = 'scale(' + Math.min(3, 1 / S.zoom) + ')';
    el.querySelector('.fungroup').addEventListener('click', e => {
      e.stopPropagation();
      pushHistory();
      S.groups = S.groups.filter(x => x.id !== g.id);
      renderCanvas(); scheduleSave();
    });
    world.insertBefore(el, svg);
  }
}

// ---------- palette ----------
let palSel = 0, palItems = [];
function openPalette() { $('#palette').hidden = false; $('#palInput').value = ''; palRender(''); $('#palInput').focus(); }
function closePalette() { $('#palette').hidden = true; }
$('#paletteBtn').addEventListener('click', openPalette);
$('#palette').addEventListener('mousedown', e => { if (e.target === $('#palette')) closePalette(); });
$('#palInput').addEventListener('input', () => palRender($('#palInput').value));
$('#palInput').addEventListener('keydown', e => {
  if (e.key === 'ArrowDown') { palSel = Math.min(palSel + 1, palItems.length - 1); palPaint(); e.preventDefault(); }
  else if (e.key === 'ArrowUp') { palSel = Math.max(palSel - 1, 0); palPaint(); e.preventDefault(); }
  else if (e.key === 'Enter') { if (palItems[palSel]) { openCard(palItems[palSel].id, {}); closePalette(); } }
  else if (e.key === 'Escape') closePalette();
});

function fuzzyScore(needle, hay) {
  needle = needle.toLowerCase(); hay = hay.toLowerCase();
  if (needle === '') return 1;
  let score = 0, j = 0, streak = 0;
  for (let i = 0; i < hay.length && j < needle.length; i++) {
    if (hay[i] === needle[j]) { streak++; score += 1 + streak * 2 + (i === 0 || './_-'.includes(hay[i - 1]) ? 8 : 0); j++; }
    else streak = 0;
  }
  return j === needle.length ? score : -1;
}

function palRender(q) {
  const scored = [];
  for (const f of IDX.functions) {
    const s = fuzzyScore(q, f.id);
    if (s >= 0) scored.push([s + (f.change !== 'unchanged' ? 5 : 0), f]);
  }
  scored.sort((a, b) => b[0] - a[0]);
  palItems = scored.slice(0, 60).map(x => x[1]);
  palSel = 0;
  palPaint();
}

function palPaint() {
  $('#palList').innerHTML = palItems.map((f, i) =>
    '<li data-i="' + i + '" class="' + (i === palSel ? 'sel' : '') + '"><span class="badge ' + f.change + '">' +
    f.change[0].toUpperCase() + '</span><span>' + esc(f.id) + '</span><span class="file">' + esc(f.file) + '</span></li>').join('');
  document.querySelectorAll('#palList li').forEach(li =>
    li.addEventListener('click', () => { openCard(palItems[+li.dataset.i].id, {}); closePalette(); }));
  const sel = document.querySelector('#palList li.sel');
  if (sel) sel.scrollIntoView({ block: 'nearest' });
}

// ---------- chat ----------
let chatRunning = false;
$('#askBtn').addEventListener('click', toggleChat);
$('#chatClose').addEventListener('click', toggleChat);
function toggleChat() {
  const p = $('#chat');
  p.hidden = !p.hidden;
  if (!p.hidden) $('#chatText').focus();
}

$('#chatNew').addEventListener('click', () => {
  $('#transcript').innerHTML = '';
  chatMsg('meta', 'new conversation');
  fetch('/api/chat/reset', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ session: S.name }) }).catch(() => {});
});
$('#chatStop').addEventListener('click', () => fetch('/api/chat/stop', { method: 'POST' }));

$('#chatText').addEventListener('keydown', e => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendChat(); }
});

function chatMsg(cls, text) {
  const div = document.createElement('div');
  div.className = 'msg ' + cls;
  div.textContent = text;
  $('#transcript').appendChild(div);
  $('#transcript').scrollTop = $('#transcript').scrollHeight;
  return div;
}

async function sendChat() {
  const ta = $('#chatText');
  const message = ta.value.trim();
  if (!message || chatRunning) return;
  ta.value = '';
  chatMsg('user', message);
  chatRunning = true;
  $('#chatStop').disabled = false;
  ta.disabled = true;
  try {
    const r = await fetch('/api/chat', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ message, mode: $('#chatMode').value, model: $('#chatModel').value, session: S.name }),
    });
    if (!r.ok) { chatMsg('err', await r.text()); return; }
    const reader = r.body.getReader();
    const dec = new TextDecoder();
    let buf = '';
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let nl;
      while ((nl = buf.indexOf('\n\n')) >= 0) {
        const chunk = buf.slice(0, nl);
        buf = buf.slice(nl + 2);
        for (const line of chunk.split('\n')) {
          if (line.startsWith('data: ')) handleChatEvent(line.slice(6));
        }
      }
    }
  } catch (err) {
    chatMsg('err', String(err));
  } finally {
    chatRunning = false;
    $('#chatStop').disabled = true;
    ta.disabled = false;
    ta.focus();
  }
}

function handleChatEvent(raw) {
  let ev;
  try { ev = JSON.parse(raw); } catch { return; }
  switch (ev.type) {
    case 'assistant':
      for (const block of (ev.message && ev.message.content) || []) {
        if (block.type === 'text' && block.text.trim()) chatMsg('assistant', block.text);
        else if (block.type === 'tool_use') {
          const input = JSON.stringify(block.input || {});
          chatMsg('tool', '⏺ ' + block.name + ' ' + (input.length > 90 ? input.slice(0, 90) + '…' : input));
        }
      }
      break;
    case 'result':
      chatMsg('meta', (ev.subtype === 'success' ? 'done' : ev.subtype) +
        (ev.num_turns ? ' · ' + ev.num_turns + ' turns' : '') +
        (ev.total_cost_usd ? ' · $' + ev.total_cost_usd.toFixed(4) : ''));
      COMMENTS_refresh();
      break;
    case 'stderr':
      chatMsg('err', ev.text);
      break;
  }
}

async function COMMENTS_refresh() {
  const r = await fetch('/api/comments');
  if (r.ok) { COMMENTS = await r.json(); renderCanvas(); renderSidebar(); }
}

// ---------- keyboard ----------
document.addEventListener('keydown', e => {
  if (e.code === 'Space' && !(e.target.tagName === 'TEXTAREA' || e.target.tagName === 'INPUT')) { spaceHeld = true; }
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); openPalette(); return; }
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'i') { e.preventDefault(); toggleChat(); return; }
  if (e.target.tagName === 'TEXTAREA' || e.target.tagName === 'INPUT') return;
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'z') { e.preventDefault(); undo(); return; }
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'a') {
    e.preventDefault();
    selected = new Set(S.cards.keys());
    paintSelected();
    return;
  }
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'g') {
    e.preventDefault();
    if (e.shiftKey) ungroupSelection(); else groupSelection();
    return;
  }
  if (e.key === 'Escape') {
    if (!$('#palette').hidden) closePalette();
    else if (!$('#reviewModal').hidden) $('#reviewModal').hidden = true;
    else if (composing) { composing = null; renderCanvas(); }
    else clearSelection();
    return;
  }
  const st = S.focus && S.cards.get(S.focus);
  const fn = S.focus && byId.get(S.focus);
  switch (e.key) {
    case 'd':
      if (st && fn && fn.base_source != null) { st.view = st.view === 'diff' ? 'source' : 'diff'; renderCanvas(); scheduleSave(); }
      break;
    case 'h':
      if (st) { st.fold = !st.fold; st.foldTouched = true; renderCanvas(); scheduleSave(); }
      break;
    case 'c':
      if (st) { st.collapsed = !st.collapsed; renderCanvas(); scheduleSave(); }
      break;
    case 'x':
      if (S.focus) closeCard(S.focus, e.shiftKey);
      break;
    case 's':
      toggleSig();
      break;
    case 'ArrowRight': walkEdge(true); e.preventDefault(); break;
    case 'ArrowLeft': walkEdge(false); e.preventDefault(); break;
    case 'ArrowDown': walkColumn(1); e.preventDefault(); break;
    case 'ArrowUp': walkColumn(-1); e.preventDefault(); break;
  }
});
document.addEventListener('keyup', e => { if (e.code === 'Space') spaceHeld = false; });

function walkEdge(out) {
  if (!S.focus) return;
  const e = out ? S.edges.find(e => e.from === S.focus) : S.edges.find(e => e.to === S.focus);
  if (!e) return;
  const next = out ? e.to : e.from;
  setFocus(next); ensureVisible(next);
}

function walkColumn(dir) {
  if (!S.focus) return;
  const cur = S.cards.get(S.focus);
  const same = [...S.cards.entries()].filter(([, c]) => Math.abs(c.x - cur.x) < CARD_W / 2).sort((a, b) => a[1].y - b[1].y);
  const idx = same.findIndex(([id]) => id === S.focus);
  const next = same[idx + dir];
  if (next) { setFocus(next[0]); ensureVisible(next[0]); }
}

// ---------- agent-driven canvas (MCP) ----------
function applyCanvasCommand(cmd) {
  if (cmd.op === 'comments_changed') { COMMENTS_refresh(); renderSidebar(); return; }
  if (cmd.session && cmd.session !== S.name) return;
  switch (cmd.op) {
    case 'open_card':
      openCard(cmd.function_id, cmd.called_by ? { fromId: cmd.called_by, key: callKey(cmd.called_by, cmd.function_id) } : {});
      break;
    case 'close_card':
      if (S.cards.has(cmd.function_id)) closeCard(cmd.function_id, false);
      break;
    case 'focus_card':
      if (!S.cards.has(cmd.function_id)) openCard(cmd.function_id, {});
      else { setFocus(cmd.function_id); ensureVisible(cmd.function_id); }
      break;
    case 'set_view': {
      const st = S.cards.get(cmd.function_id);
      if (st) { st.view = cmd.view; renderCanvas(); scheduleSave(); }
      break;
    }
    case 'set_cards':
      applySetCards(cmd);
      break;
    case 'highlight_card':
      applyHighlight(cmd);
      break;
    case 'group_cards': {
      const ids = (cmd.function_ids || []).filter(id => S.cards.has(id));
      if (!ids.length) break;
      pushHistory();
      for (const g of S.groups) g.cards = g.cards.filter(c => !ids.includes(c));
      let g = cmd.title ? S.groups.find(x => x.title === cmd.title) : null;
      if (!g) {
        g = { id: 'g_' + Math.random().toString(36).slice(2, 8), title: cmd.title || '', cards: [] };
        S.groups.push(g);
      }
      for (const id of ids) if (!g.cards.includes(id)) g.cards.push(id);
      pruneGroups(); renderCanvas(); scheduleSave();
      break;
    }
    case 'ungroup_cards': {
      const ids = cmd.function_ids || [];
      pushHistory();
      for (const g of S.groups) g.cards = g.cards.filter(c => !ids.includes(c));
      pruneGroups(); renderCanvas(); scheduleSave();
      break;
    }
    case 'rename_group': {
      const g = S.groups.find(x => x.title === cmd.group || x.id === cmd.group);
      if (!g) break;
      pushHistory();
      g.title = cmd.title || '';
      renderCanvas(); scheduleSave();
      break;
    }
  }
}

function callKey(fromId, toId) {
  const from = byId.get(fromId);
  const c = from && from.calls.find(c => c.target === toId);
  return c ? toId + '@' + c.range.start[0] + ':' + c.range.start[1] : undefined;
}

// Replace the whole canvas with the agent's graph and lay it out afresh.
// One undo (⌘Z) brings the reviewer's own arrangement back.
function applySetCards(cmd) {
  pushHistory();
  S.cards = new Map();
  S.edges = [];
  S.groups = [];
  const byKey = new Map();
  const titleByKey = new Map(); // a card with no group takes its parent's
  const groupCards = new Map(); // title -> ids
  for (const c of cmd.cards || []) {
    const id = c.function_id;
    if (!byId.has(id)) continue;
    if (!S.cards.has(id)) {
      const fn = byId.get(id);
      S.cards.set(id, { x: 0, y: 0, view: fn.base_source != null ? 'diff' : 'source', fold: false, collapsed: false, root: !c.parent_key, expanded: new Set() });
    }
    byKey.set(c.key, id);
    const title = c.group || (c.parent_key ? titleByKey.get(c.parent_key) : undefined);
    titleByKey.set(c.key, title);
    if (title) {
      if (!groupCards.has(title)) groupCards.set(title, []);
      if (!groupCards.get(title).includes(id)) groupCards.get(title).push(id);
    }
    if (c.parent_key && byKey.has(c.parent_key)) {
      const from = byKey.get(c.parent_key);
      if (from !== id && !S.edges.some(e => e.from === from && e.to === id))
        S.edges.push({ from, to: id, key: callKey(from, id) });
    }
  }
  for (const [title, ids] of groupCards)
    S.groups.push({ id: 'g_' + Math.random().toString(36).slice(2, 8), title, cards: ids });
  S.focus = byKey.size ? byKey.values().next().value : null;
  renderCanvas();
  requestAnimationFrame(() => requestAnimationFrame(() => {
    for (const [id] of S.cards) { const el = cardEl(id); if (el) heights.set(id, el.offsetHeight); }
    layoutCanvas(); renderCanvas();
    S.pan = { x: 0, y: 0 };
    applyTransform(); scheduleSave();
  }));
}

function applyHighlight(cmd) {
  if (!S.cards.has(cmd.function_id)) openCard(cmd.function_id, {});
  setFocus(cmd.function_id);
  requestAnimationFrame(() => {
    const el = cardEl(cmd.function_id);
    if (!el) return;
    const rows = [...el.querySelectorAll('td.ln:not(.old)')]
      .filter(td => {
        const n = parseInt(td.textContent, 10);
        return n >= cmd.line && n <= (cmd.end_line || cmd.line);
      })
      .map(td => td.parentElement);
    rows.forEach(r => r.classList.add('inrange'));
    setTimeout(() => { rows.forEach(r => r.classList.remove('inrange')); }, 4000);
    const target = rows[0] || el;
    const wr = $('#world').getBoundingClientRect();
    const rr = target.getBoundingClientRect();
    panTo((rr.left - wr.left) / S.zoom, (rr.top - wr.top) / S.zoom);
  });
}

function panTo(wx, wy) {
  const vp = $('#viewport');
  S.pan.x = vp.clientWidth * 0.25 - wx * S.zoom;
  S.pan.y = vp.clientHeight * 0.35 - wy * S.zoom;
  applyTransform();
  requestAnimationFrame(drawEdges);
  scheduleSave();
}

// ---------- boot ----------
(async function boot() {
  if (!(await loadAll(false))) return;
  await loadSession(defaultSessionName());
  if (!new URLSearchParams(location.search).has('static')) {
    const es = new EventSource('/events');
    es.addEventListener('reload', async () => {
      const name = S.name;
      if (await loadAll(true)) {
        // a new PR index renames the session it belongs to
        const want = defaultSessionName();
        if (want !== name && IDX.review) await loadSession(want);
        else { renderCanvas(); applyTransform(); }
      }
    });
    es.addEventListener('canvas', e => {
      try { applyCanvasCommand(JSON.parse(e.data)); } catch { /* malformed command */ }
    });
  }
})();
