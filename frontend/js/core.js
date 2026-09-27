'use strict';

/* Shared plumbing: DOM builders, the API client, formatting, toasts, bottom sheets and the router.
   Everything the screens need from the server goes through api()/post()/patch()/del(), so swapping
   the backend later (e.g. for a database that runs in the browser) only touches those functions. */

const $ = (selector, root = document) => root.querySelector(selector);

// Element builder. Text always goes in as text nodes, never HTML: receipt text comes from OCR and can't be trusted.
const PROPS = new Set(['value', 'checked', 'disabled', 'type', 'placeholder', 'htmlFor', 'hidden', 'selected', 'accept', 'required', 'name', 'id', 'min', 'max', 'step', 'inputMode']);
function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs || {})) {
    if (value === false || value == null) continue;
    if (key === 'class') el.className = value;
    else if (key === 'style' && typeof value === 'object') {
      for (const [prop, v] of Object.entries(value)) { // custom properties (--c) only work through setProperty
        if (prop.startsWith('--')) el.style.setProperty(prop, v); else el.style[prop] = v;
      }
    }
    else if (key.startsWith('on')) el.addEventListener(key.slice(2), value);
    else if (PROPS.has(key)) el[key] = value;
    else el.setAttribute(key, value === true ? '' : value);
  }
  for (const child of children.flat(Infinity)) {
    if (child == null || child === false || child === true) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return el;
}

/* replaceChildren, but skipping the false/null/true that conditional pieces (cond && h(...)) leave behind -
   the native version would print them as the text "false". */
function fill(el, ...children) {
  el.replaceChildren(...children.flat(Infinity).filter((child) => child != null && child !== false && child !== true));
  return el;
}

const SVG_NS = 'http://www.w3.org/2000/svg';
function svg(tag, attrs = {}, ...children) {
  const el = document.createElementNS(SVG_NS, tag);
  for (const [key, value] of Object.entries(attrs || {})) {
    if (value == null || value === false) continue;
    if (key.startsWith('on')) el.addEventListener(key.slice(2), value);
    else el.setAttribute(key, value);
  }
  for (const child of children.flat(Infinity)) {
    if (child == null || child === false) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return el;
}

const ICONS = {
  home: 'M3 11l9-8 9 8v9a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z',
  activity: 'M3 12h4l3-8 4 16 3-8h4',
  trip: 'M21 16v-2l-8-5V3.5a1.5 1.5 0 0 0-3 0V9l-8 5v2l8-2.5V19l-2 1.5V22l3.5-1 3.5 1v-1.5L13 19v-5.5z',
  reimburse: 'M4 7h16a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V8a1 1 0 0 1 1-1zM3 10h18M16 14.5h2',
  more: 'M5 12h.01M12 12h.01M19 12h.01',
  back: 'M15 18l-6-6 6-6',
  chevron: 'M9 6l6 6-6 6',
  search: 'M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14zM21 21l-4.5-4.5',
  plus: 'M12 5v14M5 12h14',
  check: 'M5 13l4 4L19 7',
  close: 'M6 6l12 12M18 6L6 18',
  edit: 'M4 20h4L19 9l-4-4L4 16zM13.5 6.5l4 4',
  tune: 'M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0M14 4v4M8 10v4M16 16v4',
  receipt: 'M6 3h12v18l-3-2-3 2-3-2-3 2zM9 8h6M9 12h6',
  chartline: 'M3 17l5-6 4 3 8-9',
  gear: 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19 12l2-1-2-4-2 1-2-1V5h-4v2l-2 1-2-1-2 4 2 1v2l-2 1 2 4 2-1 2 1v2h4v-2l2-1 2 1 2-4-2-1z',
};
function icon(name, size = 22, extra = {}) {
  return svg('svg', { viewBox: '0 0 24 24', width: size, height: size, fill: 'none', stroke: 'currentColor', 'stroke-width': 2, 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true', ...extra },
    svg('path', { d: ICONS[name] || ICONS.more }));
}

/* ---------- API ---------- */

async function api(path, options) {
  const response = await fetch(path, options);
  if (!response.ok) {
    let detail = response.statusText;
    try { detail = (await response.json()).detail || detail; } catch (_) { /* not JSON */ }
    throw new Error(typeof detail === 'string' ? detail : 'Something went wrong');
  }
  return response.json();
}
const send = (method) => (path, body) => api(path, { method, headers: { 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body) });
const post = send('POST');
const patch = send('PATCH');
const del = send('DELETE');

/* ---------- formatting ---------- */

const group = (n) => n.toLocaleString('en-US', { maximumFractionDigits: 0 });
// $1,234 for big round-figure summaries, $16.50 for individual amounts
function money0(value) { return `${value < 0 ? '−' : ''}$${group(Math.abs(Math.round(value)))}`; }
function money(value, { estimated = false, sign = false } = {}) {
  if (value == null || Number.isNaN(value)) return '—';
  const abs = Math.abs(value);
  const text = abs.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const prefix = value < 0 ? '−' : (sign && value > 0 ? '+' : '');
  return `${prefix}${estimated ? '~' : ''}$${text}`;
}
const plural = (n, one, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;
const ISO_DAY = /^\d{4}-\d{2}-\d{2}$/;
const parseDay = (value) => (ISO_DAY.test(value || '') ? new Date(`${value}T00:00:00`) : null);
function shortDate(value) {
  const d = parseDay(value);
  return d ? d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short' }) : (value || '');
}
function longDate(value) {
  const d = parseDay(value);
  return d ? d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) : (value || '');
}
function dayHeading(value) {
  const d = parseDay(value);
  if (!d) return 'No date';
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const diff = Math.round((today - d) / 86400000);
  if (diff === 0) return 'Today';
  if (diff === 1) return 'Yesterday';
  return d.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' });
}
const isoDay = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const currentMonth = () => isoDay(new Date()).slice(0, 7);
function monthRange(month) { // 'YYYY-MM' -> [first, last] ISO days
  const [y, m] = month.split('-').map(Number);
  return [isoDay(new Date(y, m - 1, 1)), isoDay(new Date(y, m, 0))];
}
const pathText = (path) => (path && path.length ? path.join(' › ') : 'Unsorted');

/* ---------- colour ---------- */

const PASTELS = ['#7fd6a4', '#ffb98a', '#c5a3ff', '#9ecbff', '#ffd76b', '#ff9fb2', '#b7e06a', '#8fe0e0'];
const MISC_COLOR = '#a9a39a';
// Top-level categories keep the colour they were given; deeper ones get a stable pastel from their
// id, so a category looks the same every time (colour is identity, never a judgement).
function categoryColor(cat) {
  if (!cat) return MISC_COLOR;
  if (cat.kind === 'misc' || cat.kind === 'unsorted') return MISC_COLOR;
  if (cat.kind === 'grocery') return '#8ab8ff';
  if (cat.depth === 0 || cat.parent_id == null) return cat.color || MISC_COLOR;
  return PASTELS[(cat.id ?? 0) % PASTELS.length];
}
const tint = (color, pct = 24) => `color-mix(in srgb, ${color} ${pct}%, var(--surface))`;

/* ---------- toasts, sheets ---------- */

let toastTimer;
function toast(message, isError = false) {
  const el = $('#toast');
  el.textContent = message;
  el.className = `toast${isError ? ' error' : ''}`;
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.hidden = true; }, isError ? 5000 : 2600);
}
const fail = (error) => toast(error.message || String(error), true);

/* A bottom sheet. content may be a node or a function (close) => node. onClose runs however it closes
   (button, escape, or tapping outside). Returns {close}. */
function openSheet(title, content, { tall = false, onClose } = {}) {
  const overlay = h('div', { class: 'overlay' });
  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    overlay.classList.add('closing');
    document.removeEventListener('keydown', onKey);
    setTimeout(() => overlay.remove(), 160);
    if (onClose) onClose();
  };
  const onKey = (e) => { if (e.key === 'Escape') close(); };
  const sheet = h('div', { class: `sheet${tall ? ' tall' : ''}`, role: 'dialog', 'aria-label': title },
    h('div', { class: 'sheet-grab' }),
    h('header', { class: 'sheet-head' }, h('h2', {}, title), h('button', { class: 'icon-btn', 'aria-label': 'Close', onclick: close }, icon('close', 18))),
    h('div', { class: 'sheet-body' }, typeof content === 'function' ? content(close) : content));
  overlay.append(sheet);
  overlay.addEventListener('pointerdown', (e) => { if (e.target === overlay) close(); });
  document.addEventListener('keydown', onKey);
  document.body.append(overlay);
  return { close, sheet };
}

function confirmSheet(message, confirmLabel = 'Confirm', danger = false) {
  return new Promise((resolve) => {
    let answered = false;
    const finish = (value) => { if (!answered) { answered = true; resolve(value); } };
    openSheet('Are you sure?', (close) => h('div', { class: 'stack' },
      h('p', {}, message),
      h('div', { class: 'row-actions' },
        h('button', { class: 'btn', onclick: () => { finish(false); close(); } }, 'Cancel'),
        h('button', { class: `btn ${danger ? 'danger' : 'primary'}`, onclick: () => { finish(true); close(); } }, confirmLabel))),
    { onClose: () => finish(false) });
  });
}

/* ---------- state + router ---------- */

const state = {
  month: null,           // 'YYYY-MM' shown on Home and category screens; null = this month
  categories: [],        // flat category list, in tree order
  activeTrip: null,
};
async function loadCategories() { state.categories = await api('/api/categories'); }
const categoryById = (id) => state.categories.find((c) => c.id === id);

const routes = [];
function route(pattern, tab, handler) { routes.push({ pattern, tab, handler }); }
let renderToken = 0;

function parseHash() {
  const raw = location.hash.replace(/^#/, '') || '/';
  const [path, query = ''] = raw.split('?');
  return { path, query: new URLSearchParams(query) };
}

async function renderRoute({ keepScroll = false } = {}) {
  const { path, query } = parseHash();
  const view = $('#view');
  const token = ++renderToken;
  const scrollY = keepScroll ? window.scrollY : 0;

  for (const r of routes) {
    const match = path.match(r.pattern);
    if (!match) continue;
    setNavTab(r.tab);
    if (!keepScroll) view.replaceChildren(h('div', { class: 'loading' }, 'Loading…'));
    try {
      const screen = await r.handler(match.slice(1), query);
      if (token !== renderToken) return; // navigated away while loading
      view.replaceChildren(screen);
      window.scrollTo(0, scrollY);
    } catch (error) {
      if (token !== renderToken) return;
      view.replaceChildren(h('div', { class: 'card empty-state' },
        h('p', {}, `Couldn’t load this screen: ${error.message}`),
        h('button', { class: 'btn', onclick: () => renderRoute() }, 'Try again')));
    }
    return;
  }
  view.replaceChildren(h('div', { class: 'card empty-state' }, h('p', {}, 'Nothing here.'), h('a', { class: 'btn', href: '#/' }, 'Go home')));
}
const rerender = () => renderRoute({ keepScroll: true });
const go = (hash) => { if (location.hash === hash) rerender(); else location.hash = hash; };
const goBack = (fallback = '#/') => { if (history.length > 1) history.back(); else location.hash = fallback; };

function setNavTab(tab) {
  for (const link of document.querySelectorAll('.bottom-nav a')) {
    link.setAttribute('aria-current', link.dataset.tab === tab ? 'page' : 'false');
  }
  $('#app').classList.toggle('no-nav', !tab);
}

/* Runs a write, toasts the result, and re-renders the current screen. */
async function act(promise, message) {
  try {
    const result = await promise;
    if (message) toast(message);
    await rerender();
    return result;
  } catch (error) {
    fail(error);
    return null;
  }
}
