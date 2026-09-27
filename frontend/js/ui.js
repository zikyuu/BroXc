'use strict';

/* Reusable pieces: headers, segmented controls, the category picker, item cards (with long-press
   editing and drag-to-recategorise), transaction rows. */

function pageHeader(title, { back = true, right = null, backTo = null, subtitle = null } = {}) {
  return h('header', { class: 'page-header' },
    back ? h('button', { class: 'icon-btn', 'aria-label': 'Back', onclick: () => (backTo ? go(backTo) : goBack()) }, icon('back')) : h('span', { class: 'icon-spacer' }),
    h('div', { class: 'page-title' }, h('h1', {}, title), subtitle && h('span', { class: 'muted small' }, subtitle)),
    right || h('span', { class: 'icon-spacer' }));
}

function segmented(options, active, onChange) {
  return h('div', { class: 'segmented', role: 'tablist' }, options.map(([key, label]) =>
    h('button', { role: 'tab', 'aria-selected': String(key === active), onclick: () => onChange(key) }, label)));
}

function sectionTitle(text, action) {
  return h('div', { class: 'section-title' }, h('h2', {}, text), action || null);
}

function emptyCard(title, body, action) {
  return h('div', { class: 'card empty-state' }, h('p', { class: 'strong' }, title), body && h('p', { class: 'muted small' }, body), action || null);
}

/* A little rounded icon tile, tinted with a category colour. */
function iconTile(symbol, color, size = 40) {
  return h('span', { class: 'icon-tile', style: { width: `${size}px`, height: `${size}px`, background: tint(color || MISC_COLOR, 28), fontSize: `${Math.round(size * 0.5)}px` } }, symbol || '•');
}

/* ---------- trips picker ---------- */

async function pickTrip(currentId, onPick) {
  const trips = await api('/api/trips');
  openSheet('Which trip?', (close) => h('div', { class: 'list' },
    h('button', { class: 'list-row', onclick: () => { close(); onPick(null); } },
      h('span', { class: 'grow' }, 'No trip'), currentId == null && icon('check', 18)),
    trips.map((trip) => h('button', { class: 'list-row', onclick: () => { close(); onPick(trip.id); } },
      h('span', { class: 'grow' }, `${trip.emoji || '🧳'} ${trip.name}`), trip.id === currentId && icon('check', 18))),
    !trips.length && h('p', { class: 'muted small pad' }, 'No trips yet. Create one from the Trip tab.')));
}

/* ---------- category picker ---------- */

/* Opens a searchable, collapsible tree of the user's categories. onPick(category, {learn, alsoSimilar}).
   When teach is on, the caller may also start future receipts' matching items in this category. */
function pickCategory({ title = 'Choose a category', selectedId = null, allowClear = false, teach = false, onPick }) {
  const byParent = new Map();
  for (const cat of state.categories) {
    const key = cat.parent_id ?? 'root';
    if (!byParent.has(key)) byParent.set(key, []);
    byParent.get(key).push(cat);
  }
  const selected = categoryById(selectedId);
  const expanded = new Set(selected ? selected.path_ids.slice(0, -1) : []);
  let query = '';
  const learn = h('input', { type: 'checkbox', checked: true });
  const similar = h('input', { type: 'checkbox' });

  openSheet(title, (close) => {
    const list = h('div', { class: 'tree-list' });
    const choose = (cat) => { close(); onPick(cat, { learn: learn.checked, alsoSimilar: similar.checked }); };

    const row = (cat, depth, showPath) => {
      const kids = byParent.get(cat.id) || [];
      return h('div', { class: `tree-row${cat.id === selectedId ? ' current' : ''}`, style: { paddingLeft: `${8 + depth * 18}px` } },
        kids.length && !query
          ? h('button', { class: 'twisty', 'aria-label': expanded.has(cat.id) ? 'Collapse' : 'Expand', onclick: () => { expanded.has(cat.id) ? expanded.delete(cat.id) : expanded.add(cat.id); draw(); } },
              icon('chevron', 16, { style: `transform:rotate(${expanded.has(cat.id) ? 90 : 0}deg)` }))
          : h('span', { class: 'twisty-space' }),
        h('button', { class: 'tree-pick', onclick: () => choose(cat) },
          iconTile(cat.icon, categoryColor(cat), 28),
          h('span', { class: 'grow' }, cat.name, showPath && h('small', { class: 'muted' }, ` · ${cat.path.slice(0, -1).join(' › ')}`)),
          cat.id === selectedId && icon('check', 18)));
    };
    const walk = (parentKey, depth, out) => {
      for (const cat of byParent.get(parentKey) || []) {
        out.push(row(cat, depth, false));
        if (expanded.has(cat.id)) walk(cat.id, depth + 1, out);
      }
    };
    const draw = () => {
      const out = [];
      if (query) {
        const q = query.toLowerCase();
        for (const cat of state.categories) if (cat.name.toLowerCase().includes(q) || cat.path.join(' ').toLowerCase().includes(q)) out.push(row(cat, 0, true));
        if (!out.length) out.push(h('p', { class: 'muted small pad' }, 'No category matches that.'));
      } else walk('root', 0, out);
      list.replaceChildren(...out);
    };
    draw();

    return h('div', { class: 'stack' },
      h('input', { type: 'text', placeholder: 'Search categories', 'aria-label': 'Search categories', oninput: (e) => { query = e.target.value.trim(); draw(); } }),
      list,
      teach && h('div', { class: 'stack tight' },
        h('label', { class: 'check-row' }, learn, h('span', {}, 'Remember this for next time')),
        h('label', { class: 'check-row' }, similar, h('span', {}, 'Also fix past items with the same name that I haven’t sorted'))),
      allowClear && h('button', { class: 'btn', onclick: () => { close(); onPick(null, {}); } }, 'Clear (let the app guess)'),
      h('a', { class: 'link small', href: '#/categories', onclick: close }, 'Edit my categories'));
  }, { tall: true });
}

/* ---------- item cards ---------- */

const editor = { active: false, selected: new Set(), items: new Map(), afterMove: null };

function itemAmount(item) {
  if (item.personal_sgd != null) return { text: money(item.personal_sgd, { estimated: item.sgd_source === 'estimated' }), estimated: item.sgd_source === 'estimated' };
  return { text: `${item.currency || ''} ${item.price.toFixed(2)}`.trim(), estimated: true };
}

function categoryChip(item, { full = false } = {}) {
  const path = item.category_path;
  const label = path.length ? (full ? path.join(' › ') : path[path.length - 1]) : 'Unsorted';
  const color = item.category_color || MISC_COLOR;
  return h('span', { class: `chip cat${item.category_confidence === 'suggested' ? ' suggested' : ''}${!path.length ? ' unsorted' : ''}`, style: { '--c': color } },
    h('i', { class: 'dot' }), label, item.category_confidence === 'suggested' && h('b', { title: 'A guess, not confirmed yet' }, ' ?'));
}

function itemCard(item) {
  const amount = itemAmount(item);
  const noReceipt = item.receipt.id == null;
  const selected = editor.selected.has(item.id);
  return h('div', { class: `item-card${selected ? ' selected' : ''}${item.category_confidence === 'suggested' ? ' suggested' : ''}`, 'data-item-id': item.id, tabindex: 0, role: 'button', 'aria-label': `${item.name}, ${amount.text}` },
    h('div', { class: 'ic-date' }, shortDate(item.receipt.date)),
    h('div', { class: 'ic-main' },
      h('div', { class: 'ic-name' }, item.name, item.quantity && item.quantity !== 1 ? ` ×${item.quantity}` : ''),
      h('div', { class: 'ic-meta' }, noReceipt ? 'no receipt' : (item.receipt.merchant || 'Unknown store'),
        item.split_mode !== 'mine' && h('span', { class: 'chip mini paid' }, item.others_sgd ? `paid ${money0(item.others_sgd)} for others` : 'paid for others'),
        item.trip && h('span', { class: 'chip mini trip' }, item.trip.name))),
    h('div', { class: 'ic-right' },
      h('div', { class: `ic-amount${amount.estimated ? ' estimated' : ''}` }, amount.text),
      categoryChip(item)));
}

function itemList(items, { onChange } = {}) {
  const container = h('div', { class: 'item-list', 'data-gesture-root': true }, items.map(itemCard));
  for (const item of items) editor.items.set(item.id, item);
  enableGestures(container, onChange);
  return container;
}

function itemSheet(item, onChange) {
  const amount = itemAmount(item);
  const tid = item.receipt.transaction_id;
  const noReceipt = item.receipt.id == null;
  const refresh = async () => { await rerender(); if (onChange) onChange(); };
  const setCategory = async (cat, opts = {}) => {
    try {
      await post('/api/items/category', { item_ids: [item.id], category_id: cat ? cat.id : null, learn: !!opts.learn, also_similar: !!opts.alsoSimilar });
      toast(cat ? `Moved to ${cat.name}` : 'Cleared');
      await refresh();
    } catch (error) { fail(error); }
  };

  openSheet(item.name, (close) => h('div', { class: 'stack' },
    h('div', { class: 'sheet-amount' }, amount.text, item.personal_sgd != null && item.price_sgd != null && Math.abs(item.price_sgd - item.personal_sgd) > 0.005 && h('small', { class: 'muted' }, `  of ${money(item.price_sgd)}`)),
    h('p', { class: 'muted small' }, [noReceipt ? 'No receipt yet' : item.receipt.merchant, longDate(item.receipt.date), item.currency && item.currency !== 'SGD' && `${item.currency} ${item.price.toFixed(2)}`].filter(Boolean).join(' · ')),
    h('div', { class: 'list' },
      h('button', { class: 'list-row', onclick: () => { close(); pickCategory({ title: 'Move to…', selectedId: item.category_id, allowClear: true, teach: true, onPick: setCategory }); } },
        h('span', { class: 'muted' }, 'Category'), h('span', { class: 'grow right' }, categoryChip(item, { full: true })), icon('chevron', 16)),
      item.category_confidence === 'suggested' && h('button', { class: 'list-row accent', onclick: async () => { close(); try { await post('/api/review/accept', { item_ids: [item.id] }); toast('Confirmed'); await refresh(); } catch (e) { fail(e); } } },
        icon('check', 18), h('span', { class: 'grow' }, `Yes, it’s ${item.category_path[item.category_path.length - 1]}`)),
      h('button', { class: 'list-row', onclick: async () => {
        close();
        pickTrip(item.trip ? item.trip.id : null, (tripId) => act(
          tid != null ? post(`/api/transactions/${tid}/trip`, { trip_id: tripId }) : post(`/api/receipts/${item.receipt.id}/trip`, { trip_id: tripId }), 'Trip updated'));
      } }, h('span', { class: 'muted' }, 'Trip'), h('span', { class: 'grow right' }, item.trip ? item.trip.name : 'None'), icon('chevron', 16)),
      tid != null && h('button', { class: 'list-row', onclick: () => { close(); go(`#/split/${tid}`); } },
        h('span', { class: 'grow' }, 'Split / paid for others'), h('span', { class: 'muted small' }, item.split_mode === 'mine' ? '' : 'set'), icon('chevron', 16)),
      tid != null && h('button', { class: 'list-row', onclick: () => { close(); go(`#/txn/${tid}`); } }, h('span', { class: 'grow' }, 'Open transaction'), icon('chevron', 16)),
      tid == null && item.receipt.id != null && h('button', { class: 'list-row', onclick: () => { close(); go(`#/receipt/${item.receipt.id}`); } }, h('span', { class: 'grow' }, 'Open receipt'), icon('chevron', 16)),
      noReceipt && h('button', { class: 'list-row', onclick: () => { close(); go('#/add'); } }, h('span', { class: 'grow' }, 'Add the receipt'), icon('chevron', 16)))));
}

/* ---------- long-press editing, multi-select, drag-and-drop ----------
   Long-press a card to start editing (it becomes selected). Drag it onto any element carrying
   data-drop-cat="<category id>" (or "none") to move every selected item there; or tap "Move to…"
   in the bar that appears. A quick tap opens the item. */

const LONG_PRESS_MS = 420;
let gesture = null;

function editBar() { return $('#editbar'); }

function updateEditBar() {
  const bar = editBar();
  bar.hidden = !editor.active;
  if (!editor.active) return;
  bar.replaceChildren(
    h('span', { class: 'strong' }, plural(editor.selected.size, 'item'), ' selected'),
    h('span', { class: 'grow' }),
    h('button', { class: 'btn primary', disabled: editor.selected.size === 0, onclick: () => pickCategory({ title: 'Move to…', teach: true, onPick: (cat, opts) => moveItems([...editor.selected], cat ? cat.id : null, opts) }) }, 'Move to…'),
    h('button', { class: 'btn', onclick: exitEditing }, 'Done'));
}

function exitEditing() {
  editor.active = false;
  editor.selected.clear();
  document.body.classList.remove('editing');
  for (const el of document.querySelectorAll('.item-card.selected')) el.classList.remove('selected');
  updateEditBar();
}

function toggleSelected(id, card) {
  if (editor.selected.has(id)) editor.selected.delete(id); else editor.selected.add(id);
  card.classList.toggle('selected', editor.selected.has(id));
  if (editor.selected.size === 0) exitEditing(); else updateEditBar();
}

async function moveItems(ids, categoryId, { learn = true, alsoSimilar = false } = {}) {
  try {
    const result = await post('/api/items/category', { item_ids: ids, category_id: categoryId, learn, also_similar: alsoSimilar });
    const name = categoryId != null ? (categoryById(categoryId) || {}).name : 'Unsorted';
    toast(`Moved ${plural(result.updated, 'item')} to ${name}`);
    exitEditing();
    await rerender();
  } catch (error) { fail(error); }
}

function enableGestures(container, onChange) {
  container.addEventListener('pointerdown', (event) => {
    const card = event.target.closest('.item-card');
    if (!card || (event.pointerType === 'mouse' && event.button !== 0)) return;
    const id = Number(card.dataset.itemId);
    gesture = { card, id, startX: event.clientX, startY: event.clientY, x: event.clientX, y: event.clientY, longPressed: false, dragging: false, ghost: null, target: null, onChange };
    gesture.timer = setTimeout(() => {
      if (!gesture || gesture.card !== card) return;
      gesture.longPressed = true;
      if (!editor.active) { editor.active = true; document.body.classList.add('editing'); }
      if (!editor.selected.has(id)) { editor.selected.add(id); card.classList.add('selected'); }
      card.classList.add('lifted');
      if (navigator.vibrate) navigator.vibrate(12);
      updateEditBar();
    }, LONG_PRESS_MS);
  });
  container.addEventListener('keydown', (event) => {
    const card = event.target.closest('.item-card');
    if (card && (event.key === 'Enter' || event.key === ' ')) { event.preventDefault(); activateCard(card, onChange); }
  });
}

function activateCard(card, onChange) {
  const id = Number(card.dataset.itemId);
  if (editor.active) toggleSelected(id, card);
  else if (editor.items.has(id)) itemSheet(editor.items.get(id), onChange);
}

function endGesture() {
  if (!gesture) return;
  clearTimeout(gesture.timer);
  gesture.card.classList.remove('lifted');
  if (gesture.ghost) gesture.ghost.remove();
  for (const el of document.querySelectorAll('.drop-hover')) el.classList.remove('drop-hover');
  document.body.classList.remove('dragging');
  gesture = null;
}

document.addEventListener('pointermove', (event) => {
  if (!gesture) return;
  gesture.x = event.clientX; gesture.y = event.clientY;
  const moved = Math.hypot(event.clientX - gesture.startX, event.clientY - gesture.startY);
  if (!gesture.longPressed) {
    if (moved > 10) { clearTimeout(gesture.timer); gesture.cancelled = true; } // it's a scroll, not a press
    return;
  }
  if (!gesture.dragging && moved > 6) {
    gesture.dragging = true;
    document.body.classList.add('dragging');
    const count = editor.selected.size;
    const ghost = gesture.card.cloneNode(true);
    ghost.classList.add('ghost');
    ghost.style.width = `${gesture.card.offsetWidth}px`;
    if (count > 1) ghost.append(h('span', { class: 'ghost-count' }, count));
    document.body.append(ghost);
    gesture.ghost = ghost;
  }
  if (gesture.dragging) {
    gesture.ghost.style.transform = `translate(${event.clientX - gesture.card.offsetWidth / 2}px, ${event.clientY - 28}px)`;
    const under = document.elementsFromPoint(event.clientX, event.clientY).find((el) => el.closest && el.closest('[data-drop-cat]'));
    const target = under ? under.closest('[data-drop-cat]') : null;
    if (target !== gesture.target) {
      if (gesture.target) gesture.target.classList.remove('drop-hover');
      if (target) target.classList.add('drop-hover');
      gesture.target = target;
    }
    // nudge the page when dragging near the top or bottom edge, so far-away tiles are reachable
    if (event.clientY < 90) window.scrollBy(0, -12); else if (event.clientY > window.innerHeight - 110) window.scrollBy(0, 12);
  }
});

document.addEventListener('pointerup', () => {
  if (!gesture) return;
  const g = gesture;
  const wasTap = !g.longPressed && !g.cancelled;
  if (g.dragging && g.target) {
    const value = g.target.dataset.dropCat;
    const ids = editor.selected.size ? [...editor.selected] : [g.id];
    endGesture();
    moveItems(ids, value === 'none' ? null : Number(value));
    return;
  }
  endGesture();
  if (wasTap) activateCard(g.card, g.onChange);
});
document.addEventListener('pointercancel', () => endGesture());
// once a press has turned into a drag, the page must not scroll under the finger
document.addEventListener('touchmove', (event) => { if (gesture && (gesture.dragging || gesture.longPressed)) event.preventDefault(); }, { passive: false });
window.addEventListener('hashchange', () => { if (editor.active) exitEditing(); });

/* ---------- transaction rows ---------- */

const TYPE_LABEL = { reimbursement: 'Reimbursement', income: 'Income', refund: 'Refund', transfer_own_account: 'Own account transfer', other: 'Money in' };
const TYPE_ICON = { reimbursement: '🤝', income: '💰', refund: '↩️', transfer_own_account: '🔁', other: '⬇️' };

function txnRow(entry, { showDate = false } = {}) {
  const incoming = entry.type !== 'expense';
  const cat = entry.category;
  const color = cat && cat.color ? cat.color : MISC_COLOR;
  const target = entry.kind === 'receipt' ? `#/receipt/${entry.id}` : `#/txn/${entry.id}`;
  const split = entry.others_sgd > 0.005;
  const amountText = incoming ? money(entry.amount_sgd, { sign: true }) : money(split ? entry.personal_sgd : entry.amount_sgd);

  let sub;
  if (incoming) sub = TYPE_LABEL[entry.type] || 'Money in';
  else if (entry.status === 'receipt_only') sub = 'Receipt · no charge linked yet';
  else if (cat && cat.mixed) sub = `${cat.distinct} categories`;
  else if (cat && cat.path && cat.path.length) sub = cat.path.slice(-2).join(' › ');
  else sub = 'Unsorted';

  return h('a', { class: 'txn-row', href: target },
    incoming ? iconTile(TYPE_ICON[entry.type] || '⬇️', '#34c38f') : iconTile(cat && cat.icon ? cat.icon : (entry.kind === 'receipt' ? '🧾' : '•'), color),
    h('div', { class: 'grow' },
      h('div', { class: 'strong ellipsis' }, entry.title),
      h('div', { class: 'muted small txn-sub' }, h('span', { class: 'ellipsis' }, [showDate && shortDate(entry.date), sub].filter(Boolean).join(' · ')),
        entry.trip && h('span', { class: 'chip mini trip' }, entry.trip.name),
        entry.status === 'needs_review' && h('span', { class: 'chip mini warn' }, 'check match'),
        entry.status === 'unmatched' && h('span', { class: 'chip mini quiet' }, 'no receipt'))),
    h('div', { class: 'right' },
      h('div', { class: `strong${incoming ? ' in' : ''}` }, amountText),
      split && h('div', { class: 'muted small' }, `of ${money(entry.amount_sgd)}`)));
}

function groupedFeed(entries, { limit } = {}) {
  const shown = limit ? entries.slice(0, limit) : entries;
  const days = [];
  for (const entry of shown) {
    const last = days[days.length - 1];
    if (last && last.date === entry.date) last.rows.push(entry); else days.push({ date: entry.date, rows: [entry] });
  }
  return h('div', { class: 'feed' }, days.map((day) => h('section', {},
    h('h3', { class: 'day-heading' }, dayHeading(day.date)),
    h('div', { class: 'card flush' }, day.rows.map((entry) => txnRow(entry))))));
}
