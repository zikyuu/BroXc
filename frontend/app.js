'use strict';

/* Talks to the local API in receipt_pipeline/api/app.py. Everything the page needs from the
   server goes through api()/post() below, so swapping the backend later (e.g. for a database
   that runs in the browser) only touches those two functions. */

const UNTAGGED = 'Untagged';
const $ = (selector, root = document) => root.querySelector(selector);

// Element builder. Text always goes in as text nodes, never HTML: receipt text comes from OCR and can't be trusted.
const PROPS = new Set(['value', 'checked', 'disabled', 'type', 'placeholder', 'htmlFor', 'hidden', 'selected', 'accept', 'required', 'name', 'id']);
function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs || {})) {
    if (value === false || value == null) continue;
    if (key === 'class') el.className = value;
    else if (key.startsWith('on')) el.addEventListener(key.slice(2), value);
    else if (PROPS.has(key)) el[key] = value;
    else el.setAttribute(key, value === true ? '' : value);
  }
  for (const child of children.flat(Infinity)) {
    if (child == null || child === false) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return el;
}

async function api(path, options) {
  const response = await fetch(path, options);
  if (!response.ok) {
    let detail = response.statusText;
    try { detail = (await response.json()).detail || detail; } catch (_) { /* not JSON */ }
    throw new Error(typeof detail === 'string' ? detail : 'Something went wrong');
  }
  return response.json();
}
const post = (path, body) => api(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });

/* ---------- formatting ---------- */

function money(value, estimated = false) {
  const sign = value < 0 ? '−' : '';
  return `${sign}${estimated ? '~' : ''}S$${Math.abs(value).toFixed(2)}`;
}
const plural = (n, one, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;
function shortDate(value) {
  if (!value) return '';
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return value;
  return new Date(`${value}T00:00:00`).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}
function priceLabel(item) {
  const original = `${item.currency || ''} ${item.price.toFixed(2)}`.trim();
  if (item.price_sgd == null || state.showOriginal.has(item.id)) return original;
  return money(item.price_sgd, item.sgd_source === 'estimated');
}

let toastTimer;
function toast(message, isError = false) {
  const el = $('#toast');
  el.textContent = message;
  el.className = `toast${isError ? ' error' : ''}`;
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.hidden = true; }, isError ? 5000 : 2800);
}

/* ---------- state ---------- */

const state = {
  tab: 'spending',
  range: 'all', start: '', end: '',
  tag: null,
  selected: new Set(),
  showOriginal: new Set(),
  overview: null, items: [], allTags: [], transactions: { transactions: [], unmatched_receipts: [] },
};

const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
function rangeBounds() {
  const today = new Date();
  if (state.range === 'week') {
    const monday = new Date(today);
    monday.setDate(today.getDate() - ((today.getDay() + 6) % 7));
    return [iso(monday), iso(today)];
  }
  if (state.range === 'month') return [iso(new Date(today.getFullYear(), today.getMonth(), 1)), iso(today)];
  if (state.range === 'custom') return [state.start, state.end];
  return ['', ''];
}

async function refresh() {
  const [start, end] = rangeBounds();
  const query = new URLSearchParams();
  if (start) query.set('start', start);
  if (end) query.set('end', end);

  const [overview, items, allTags, transactions] = await Promise.all([
    api(`/api/overview?${query}`), api(`/api/items?${query}`), api('/api/tags'), api('/api/transactions'),
  ]);
  Object.assign(state, { overview, items, allTags, transactions });

  // keep only selections you can still see: after tagging inside a filter (say "Untagged"),
  // the items you just tagged drop out of view, and a hidden selection is a trap
  const visible = new Set(visibleItems().map((i) => i.id));
  state.selected = new Set([...state.selected].filter((id) => visible.has(id)));
  render();
}

function render() {
  renderStatus();
  renderSpending();
  renderReconcile();
  updateBulkBar();
}

function setTab(name) {
  state.tab = name;
  for (const button of document.querySelectorAll('.tabs button')) {
    button.setAttribute('aria-selected', String(button.dataset.tab === name));
  }
  for (const section of document.querySelectorAll('.tab')) section.hidden = section.id !== `tab-${name}`;
  updateBulkBar();
}

/* ---------- status line ---------- */

function renderStatus() {
  const el = $('#status');
  const s = state.overview.status;
  if (!s.has_data) { el.hidden = true; return; }

  const parts = [];
  if (s.needs_review) parts.push(`${plural(s.needs_review, 'match', 'matches')} to review`);
  if (s.unmatched_transactions) parts.push(`${plural(s.unmatched_transactions, 'charge')} without a receipt`);
  if (s.unreconciled_sgd) parts.push(`${money(s.unreconciled_sgd)} not yet reconciled`);
  if (s.unmatched_receipts) parts.push(`${plural(s.unmatched_receipts, 'receipt')} without a charge`);

  el.hidden = false;
  el.classList.toggle('attention', parts.length > 0);
  el.textContent = parts.length ? parts.join(' · ') : 'Everything is reconciled';
}

/* ---------- spending tab ---------- */

const RANGES = [['all', 'All time'], ['month', 'This month'], ['week', 'This week'], ['custom', 'Custom']];

function setRange(key) {
  state.range = key;
  if (key !== 'custom') refresh().catch((e) => toast(e.message, true));
  else renderSpending();
}

function dateInput(label, key) {
  return h('label', {}, label, h('input', {
    type: 'date', value: state[key],
    onchange: (e) => { state[key] = e.target.value; refresh().catch((err) => toast(err.message, true)); },
  }));
}

function rangeControls() {
  return h('div', { class: 'stack' },
    h('div', { class: 'chips' }, RANGES.map(([key, label]) =>
      h('button', { class: 'chip', 'aria-pressed': String(state.range === key), onclick: () => setRange(key) }, label))),
    state.range === 'custom' && h('div', { class: 'date-row' }, dateInput('From', 'start'), dateInput('To', 'end')));
}

function totalCard(summary) {
  const notes = [];
  if (summary.estimated_sgd) {
    notes.push(`${money(summary.estimated_sgd)} of this is estimated from the usual exchange rate. It firms up once the receipt is matched to its charge.`);
  }
  for (const [currency, amount] of Object.entries(summary.unconverted)) {
    notes.push(`Plus ${currency} ${amount.toFixed(2)} that can't be converted yet: no exchange rate known for ${currency}.`);
  }
  if (summary.undated_excluded) {
    notes.push(`${plural(summary.undated_excluded, 'item')} on receipts with no readable date ${summary.undated_excluded === 1 ? 'is' : 'are'} left out of this range.`);
  }
  return h('div', { class: 'card' },
    h('h2', {}, 'Total spend'),
    h('div', { class: 'total' }, money(summary.total_sgd)),
    h('p', { class: 'muted small' }, plural(summary.item_count, 'item')),
    notes.map((note) => h('p', { class: 'muted small' }, note)));
}

function tagCard(summary) {
  const rows = summary.by_tag;
  const widest = Math.max(1, ...rows.map((row) => Math.abs(row.sgd)));
  return h('div', { class: 'card' },
    h('header', {}, h('h2', {}, 'By tag'), h('span', { class: 'muted small' }, 'Tap a tag to filter')),
    h('div', { class: 'tag-rows' }, rows.map((row) =>
      h('button', {
        class: `tag-row${row.tag === UNTAGGED ? ' untagged' : ''}`,
        'aria-pressed': String(state.tag === row.tag),
        onclick: () => { state.tag = state.tag === row.tag ? null : row.tag; renderSpending(); },
      },
        h('span', { class: 'name' }, row.tag, ' ', h('small', {}, `(${row.count})`)),
        h('span', { class: 'track' }, h('span', { class: 'fill', style: `width:${(Math.abs(row.sgd) / widest) * 100}%` })),
        h('span', { class: 'amount' }, money(row.sgd, row.estimated_sgd > 0))))),
    h('p', { class: 'muted small' }, 'An item can have several tags, so these overlap and won’t add up to the total.'));
}

function visibleItems() {
  if (!state.tag) return state.items;
  if (state.tag === UNTAGGED) return state.items.filter((item) => item.tags.length === 0);
  return state.items.filter((item) => item.tags.includes(state.tag));
}

function itemRow(item) {
  const selected = state.selected.has(item.id);
  const meta = [item.receipt.merchant, shortDate(item.receipt.date), item.is_deposit && 'deposit, not counted'].filter(Boolean).join(' · ');
  return h('div', { class: `item${selected ? ' selected' : ''}`, 'data-id': item.id },
    h('input', { type: 'checkbox', checked: selected, 'aria-label': `Select ${item.name}`, onchange: (e) => toggleSelected(item.id, e.target.checked) }),
    h('div', { class: 'name' }, item.name, item.quantity && item.quantity !== 1 ? ` ×${item.quantity}` : ''),
    h('button', {
      class: `price${item.sgd_source === 'estimated' ? ' estimated' : ''}`,
      title: 'Tap to switch between SGD and the original currency',
      onclick: () => {
        if (state.showOriginal.has(item.id)) state.showOriginal.delete(item.id); else state.showOriginal.add(item.id);
        renderSpending();
      },
    }, priceLabel(item)),
    h('div', { class: 'meta' }, meta),
    h('div', { class: 'tags' }, item.tags.length
      ? item.tags.map((tag) => h('button', {
          class: `chip tag${tag === 'mystery' ? ' mystery' : ''}`, title: `Show only “${tag}”`,
          onclick: () => { state.tag = tag; renderSpending(); },
        }, tag))
      : h('span', { class: 'muted small' }, 'No tags yet')));
}

function itemsCard() {
  const items = visibleItems();
  const allSelected = items.length > 0 && items.every((item) => state.selected.has(item.id));
  return h('div', { class: 'card' },
    h('header', {},
      h('h2', {}, state.tag ? `Items · ${state.tag}` : 'Items'),
      h('span', { class: 'chips' },
        state.tag && h('button', { class: 'chip', onclick: () => { state.tag = null; renderSpending(); } }, 'Clear filter ×'),
        items.length > 0 && h('button', { class: 'chip', onclick: () => selectAll(items, !allSelected) }, allSelected ? 'Deselect all' : 'Select all'))),
    items.length
      ? h('div', { class: 'items' }, items.map(itemRow))
      : h('p', { class: 'empty' }, 'No items here.'));
}

function renderSpending() {
  const root = $('#tab-spending');
  root.replaceChildren();
  if (!state.overview) return;

  const summary = state.overview.summary;
  if (!state.items.length && !state.overview.status.has_data) {
    root.append(h('div', { class: 'card empty' },
      h('p', {}, 'Nothing tracked yet.'),
      h('p', { class: 'small' }, 'Head to the Add tab to upload a receipt or a YouTrip screenshot.')));
    return;
  }
  root.append(h('div', { class: 'stack' }, rangeControls(), totalCard(summary), tagCard(summary), itemsCard()));
  updateBulkBar();
}

/* ---------- selecting and tagging ---------- */

function toggleSelected(id, on) {
  if (on) state.selected.add(id); else state.selected.delete(id);
  const row = document.querySelector(`.item[data-id="${id}"]`);
  if (row) row.classList.toggle('selected', on);
  updateBulkBar();
}

function selectAll(items, on) {
  for (const item of items) { if (on) state.selected.add(item.id); else state.selected.delete(item.id); }
  renderSpending();
}

function clearSelection() {
  state.selected.clear();
  renderSpending();
}

const bulk = {};
function buildBulkBar() {
  bulk.count = h('span', { class: 'count' });
  bulk.input = h('input', { type: 'text', placeholder: 'Tag name, e.g. groceries', 'aria-label': 'Tag name', list: 'tag-options' });
  bulk.options = h('datalist', { id: 'tag-options' });
  bulk.chips = h('div', { class: 'chips' });
  $('#bulkbar').append(
    h('div', { class: 'row' }, bulk.count, h('button', { class: 'btn quiet', onclick: clearSelection }, 'Clear')),
    h('div', { class: 'row' },
      bulk.input, bulk.options,
      h('button', { class: 'btn primary', onclick: () => applyTag('add') }, 'Add tag'),
      h('button', { class: 'btn', onclick: () => applyTag('remove') }, 'Remove tag')),
    bulk.chips);
}

let suggestionRun = 0;
async function updateBulkBar() {
  const count = state.selected.size;
  $('#bulkbar').hidden = count === 0 || state.tab !== 'spending';
  if (count === 0) return;

  bulk.count.textContent = `${plural(count, 'item')} selected`;
  bulk.options.replaceChildren(...state.allTags.map((tag) => h('option', { value: tag.name })));

  const current = [...new Set(state.items.filter((i) => state.selected.has(i.id)).flatMap((i) => i.tags))];
  const run = ++suggestionRun;
  let related = [];
  if (current.length) {
    try { related = await api(`/api/tags/related?${current.map((t) => `tags=${encodeURIComponent(t)}`).join('&')}`); } catch (_) { /* suggestions are optional */ }
  }
  if (run !== suggestionRun) return;

  const popular = state.allTags.slice(0, 6).map((tag) => tag.name);
  const suggestions = [...new Set([...related, ...popular])].filter((tag) => !current.includes(tag)).slice(0, 8);
  bulk.chips.replaceChildren(
    ...(suggestions.length ? [h('span', { class: 'muted small' }, 'Suggestions')] : []),
    ...suggestions.map((tag) => h('button', { class: 'chip tag', onclick: () => { bulk.input.value = tag; bulk.input.focus(); } }, tag)));
}

async function applyTag(mode) {
  const tag = bulk.input.value.trim();
  if (!tag) { toast('Type a tag name first', true); bulk.input.focus(); return; }
  try {
    const result = await post('/api/items/tags', {
      item_ids: [...state.selected],
      add: mode === 'add' ? [tag] : [],
      remove: mode === 'remove' ? [tag] : [],
    });
    toast(`${mode === 'add' ? 'Added' : 'Removed'} “${tag.toLowerCase()}” on ${plural(result.updated, 'item')}`);
    bulk.input.value = '';
    await refresh();
  } catch (error) {
    toast(error.message, true);
  }
}

/* ---------- reconcile tab ---------- */

async function act(path, body, message) {
  try {
    await post(path, body || {});
    toast(message);
    await refresh();
  } catch (error) {
    toast(error.message, true);
  }
}

function txnCard(txn, unmatchedReceipts) {
  const local = txn.local_amount != null ? `${txn.local_currency || ''} ${txn.local_amount.toFixed(2)}`.trim() : '';
  const picker = h('select', { 'aria-label': 'Receipt to link' },
    unmatchedReceipts.map((r) => h('option', { value: r.id },
      [r.merchant || 'Unknown store', shortDate(r.date), r.total != null && `${r.currency || ''} ${r.total.toFixed(2)}`].filter(Boolean).join(' · '))));

  let actions = null;
  if (txn.status === 'unmatched') {
    actions = unmatchedReceipts.length
      ? h('div', { class: 'link-picker' }, picker,
          h('button', { class: 'btn', onclick: () => act(`/api/transactions/${txn.id}/link`, { receipt_id: Number(picker.value) }, 'Linked') }, 'Link'))
      : h('p', { class: 'muted small' }, 'No unmatched receipts to link yet.');
  } else {
    actions = h('div', { class: 'actions' },
      txn.status === 'needs_review' && h('button', { class: 'btn primary', onclick: () => act(`/api/transactions/${txn.id}/approve`, null, 'Approved') }, 'Looks right'),
      h('button', { class: 'btn', onclick: () => act(`/api/transactions/${txn.id}/unlink`, null, 'Unlinked') }, 'Unlink'),
      txn.status === 'approved' && h('span', { class: 'muted small' }, 'Approved'));
  }

  return h('div', { class: 'txn' },
    h('div', { class: 'top' }, h('span', {}, txn.description || 'Unknown charge'), h('span', { class: 'amount' }, money(txn.amount_sgd ?? 0))),
    h('div', { class: 'muted small' }, [txn.date, local && `charged ${local}`].filter(Boolean).join(' · ')),
    txn.receipt && h('div', { class: 'link' },
      h('strong', {}, txn.receipt.merchant || 'Unknown store'),
      h('span', { class: 'muted' }, [shortDate(txn.receipt.date), txn.receipt.total != null && `${txn.receipt.currency || ''} ${txn.receipt.total.toFixed(2)}`].filter(Boolean).join(' · '))),
    txn.note && h('div', { class: 'note' }, txn.note),
    actions);
}

function renderReconcile() {
  const root = $('#tab-reconcile');
  root.replaceChildren();
  const { transactions, unmatched_receipts: unmatchedReceipts } = state.transactions;

  if (!transactions.length) {
    root.append(h('div', { class: 'card empty' },
      h('p', {}, 'No YouTrip charges yet.'),
      h('p', { class: 'small' }, 'Upload a YouTrip screenshot on the Add tab and they’ll appear here, linked to receipts.')));
    return;
  }

  const groups = [
    ['Needs review', 'Linked, but worth a look. Counted in your spending either way.', (t) => t.status === 'needs_review'],
    ['No receipt yet', 'Add the receipt whenever you find it and it will link itself.', (t) => t.status === 'unmatched'],
    ['Matched', null, (t) => t.status === 'auto' || t.status === 'approved'],
  ];
  const cards = groups.map(([title, hint, test]) => {
    const rows = transactions.filter(test);
    if (!rows.length) return null;
    return h('div', { class: 'card' },
      h('header', {}, h('h2', {}, `${title} · ${rows.length}`)),
      hint && h('p', { class: 'muted small' }, hint),
      h('div', {}, rows.map((txn) => txnCard(txn, unmatchedReceipts))));
  });
  root.append(h('div', { class: 'stack' }, cards));
}

/* ---------- add tab ---------- */

async function submitUpload(event, url, resultEl, describe) {
  event.preventDefault();
  const form = event.currentTarget;
  const data = new FormData(form);
  for (const [key, value] of [...data.entries()]) {
    if (value instanceof File && !value.name) data.delete(key); // an optional file input left empty
  }
  const button = $('button[type=submit]', form);
  button.disabled = true;
  resultEl.textContent = 'Reading the image… the first run can take a minute.';
  try {
    const result = await api(url, { method: 'POST', body: data });
    resultEl.textContent = describe(result);
    form.reset();
    await refresh();
  } catch (error) {
    resultEl.textContent = '';
    toast(error.message, true);
  } finally {
    button.disabled = false;
  }
}

function renderAdd() {
  const receiptResult = h('p', { class: 'muted small', 'aria-live': 'polite' });
  const youtripResult = h('p', { class: 'muted small', 'aria-live': 'polite' });

  $('#tab-add').append(h('div', { class: 'stack' },
    h('form', {
      class: 'card',
      onsubmit: (e) => submitUpload(e, '/api/upload/receipt', receiptResult, (r) =>
        `Read “${r.merchant || 'unknown store'}”: ${plural(r.items, 'item')}, total ${r.currency || ''} ${r.total ?? '?'}. ` +
        (r.matched ? `Linked to a YouTrip charge${r.needs_review ? ' (worth a look)' : ''}.` : 'No matching YouTrip charge yet.')),
    },
      h('header', {}, h('h2', {}, 'Add a receipt')),
      h('p', { class: 'muted small' }, 'Upload a Google Translate screenshot of the receipt (Swedish to English). Add the original photo too if you can: its store name helps match the YouTrip charge.'),
      h('label', {}, 'Translated screenshot', h('input', { type: 'file', name: 'translated', accept: 'image/*', required: true })),
      h('label', {}, 'Original photo (optional)', h('input', { type: 'file', name: 'original', accept: 'image/*' })),
      h('button', { class: 'btn primary', type: 'submit' }, 'Read receipt'),
      receiptResult),
    h('form', {
      class: 'card',
      onsubmit: (e) => submitUpload(e, '/api/upload/youtrip', youtripResult, (r) =>
        `Found ${plural(r.found, 'charge')}: ${r.added} new, ${r.already_had} already saved. ${plural(r.matched, 'receipt')} linked.`),
    },
      h('header', {}, h('h2', {}, 'Add YouTrip charges')),
      h('p', { class: 'muted small' }, 'Screenshot your YouTrip transaction list. Overlapping screenshots are fine: charges you’ve already saved are skipped.'),
      h('label', {}, 'YouTrip screenshot', h('input', { type: 'file', name: 'screenshot', accept: 'image/*', required: true })),
      h('button', { class: 'btn primary', type: 'submit' }, 'Read charges'),
      youtripResult)));
}

/* ---------- start ---------- */

async function init() {
  buildBulkBar();
  renderAdd();
  for (const button of document.querySelectorAll('.tabs button')) {
    button.addEventListener('click', () => setTab(button.dataset.tab));
  }
  $('#status').addEventListener('click', () => setTab('reconcile'));
  try {
    await refresh();
  } catch (error) {
    $('#tab-spending').append(h('div', { class: 'card' }, h('p', {}, `Couldn’t reach the server: ${error.message}`)));
  }
}

init();
