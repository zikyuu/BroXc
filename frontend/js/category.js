'use strict';

/* The category drill-down (Food -> Cooking Ingredients -> Meat -> Chicken): semi-proportional tiles
   for the children, then the transactions underneath. Tiles are drop targets for long-press drag. */

const EMOJI_CHOICES = ['🍴', '🛒', '🚆', '🛏️', '🎟️', '🛍️', '🎁', '🏠', '💊', '☕', '🍜', '🎮', '📚', '💼', '✈️', '🐶', '🎬', '💇', '📱', '🧾'];

function replaceHash(hash) {
  history.replaceState(null, '', hash);
  renderRoute({ keepScroll: true });
}

function findNode(nodes, id) {
  for (const node of nodes) {
    if (node.id === id) return node;
    const hit = findNode(node.children, id);
    if (hit) return hit;
  }
  return null;
}

function tileHref(node, parent) {
  if (node.id != null) return `#/category/${node.id}${categoryQuerySuffix()}`;
  return `#/category/unsorted-${node.unsorted_of}${categoryQuerySuffix()}`;
}
let currentTripFilter = null;
const categoryQuerySuffix = () => (currentTripFilter ? `?trip=${currentTripFilter}` : '');

function tileView(nodes) {
  const rects = tileLayout(nodes);
  const rows = Math.max(2, Math.ceil(nodes.length / 2));
  const box = h('div', { class: 'tiles', style: { height: `${Math.min(420, 150 + rows * 62)}px` } });
  for (const { node, x, y, w, h: ht } of rects) {
    const color = categoryColor(node);
    const zero = node.total_sgd <= 0;
    const parentTarget = node.id != null ? node.id : node.unsorted_of;
    box.append(h('a', {
      class: `tile${zero ? ' zero' : ''}${node.kind === 'unsorted' ? ' unsorted' : ''}${node.kind === 'grocery' ? ' grocery' : ''}`,
      href: tileHref(node), 'data-drop-cat': parentTarget,
      style: { left: `${x * 100}%`, top: `${y * 100}%`, width: `${w * 100}%`, height: `${ht * 100}%`, '--c': color },
      'aria-label': `${node.name} ${money0(node.total_sgd)}`,
    },
      h('div', { class: 'tile-inner' },
        h('div', { class: 'tile-name' }, node.name),
        h('div', { class: 'tile-amount' }, money0(node.total_sgd)),
        node.kind === 'grocery' && h('div', { class: 'tile-note' }, icon('receipt', 14), ' no receipts'),
        node.icon && node.kind !== 'grocery' && node.kind !== 'misc' && node.kind !== 'unsorted' && h('span', { class: 'tile-icon' }, node.icon))));
  }
  return box;
}

async function categoryScreen([param], query) {
  const trip = query.get('trip');
  currentTripFilter = trip;
  const tab = query.get('tab') || 'breakdown';
  const month = state.month || currentMonth();
  const [start, end] = monthRange(month);
  const params = trip ? `trip_id=${trip}` : `start=${start}&end=${end}`;
  if (!state.categories.length) await loadCategories();
  const [tree, allItems, tripInfo] = await Promise.all([
    api(`/api/category-tree?${params}`), api(`/api/items?${params}`), trip ? api(`/api/trips/${trip}`) : null,
  ]);

  // which node is this?
  let node, keep, parentNode = null, crumbs = [];
  const unsortedOf = param.startsWith('unsorted-') ? Number(param.slice(9)) : null;
  if (param === 'unsorted') {
    node = { id: null, name: 'Unsorted', icon: '?', kind: 'unsorted', color: MISC_COLOR, total_sgd: tree.unsorted_sgd, children: [], count: tree.unsorted_count };
    keep = (i) => i.category_id == null;
  } else if (unsortedOf != null) {
    const owner = findNode(tree.roots, unsortedOf);
    node = { id: null, name: `Unsorted in ${owner ? owner.name : 'category'}`, icon: '?', kind: 'unsorted', color: owner ? owner.color : MISC_COLOR, total_sgd: owner ? owner.own_sgd : 0, children: [], count: owner ? owner.count : 0, unsorted_of: unsortedOf };
    keep = (i) => i.category_id === unsortedOf;
    parentNode = owner;
  } else {
    node = findNode(tree.roots, Number(param));
    if (!node) return emptyCard('That category is gone', 'It may have been deleted.', h('a', { class: 'btn', href: '#/' }, 'Back home'));
    const flat = categoryById(node.id);
    crumbs = flat ? flat.path.slice(0, -1) : [];
    parentNode = node.parent_id != null ? findNode(tree.roots, node.parent_id) : null;
    keep = (i) => i.category_path_ids.includes(node.id);
  }

  const items = allItems
    .filter((i) => !i.is_deposit && (i.personal_sgd == null || i.personal_sgd > 0) && keep(i))
    .sort((a, b) => (b.receipt.date || '').localeCompare(a.receipt.date || ''));
  const share = tree.total_sgd ? (node.total_sgd / tree.total_sgd) * 100 : 0;
  const color = categoryColor({ ...node, depth: node.parent_id == null && node.id != null ? 0 : 1 });
  const flat = node.id != null ? categoryById(node.id) : null;
  const title = node.name;
  const scopeLabel = trip ? (tripInfo ? tripInfo.trip.name : 'Trip') : new Date(`${month}-01T00:00:00`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric' });

  const header = h('div', { class: 'cat-hero', style: { '--c': color } },
    iconTile(node.icon || '•', color, 52),
    h('div', { class: 'grow' },
      h('div', { class: 'big' }, money0(node.total_sgd)),
      h('div', { class: 'muted small' }, node.kind === 'unsorted' ? 'real spending, not sorted yet' : `${share < 10 ? share.toFixed(1) : Math.round(share)}% of your spending`),
      h('div', { class: 'muted small' }, scopeLabel)),
    node.budget_sgd && !trip && h('div', { class: 'budget-meter' },
      h('div', { class: 'meter' }, h('i', { style: { width: `${Math.min(100, (node.total_sgd / node.budget_sgd) * 100)}%`, background: node.total_sgd > node.budget_sgd ? 'var(--bad)' : 'var(--good)' } })),
      h('span', { class: 'muted small' }, `of ${money0(node.budget_sgd)} budget`)));

  let body;
  if (tab === 'transactions') {
    body = items.length ? itemList(items) : emptyCard('Nothing in here yet', 'Drag things in from other categories, or they’ll land here as you add receipts.');
  } else {
    const tiles = node.children.filter((c) => !(c.total_sgd <= 0 && (c.kind === 'misc' || c.kind === 'unsorted')));
    const siblings = parentNode ? parentNode.children.filter((c) => c.id !== node.id && c.id != null) : [];
    body = h('div', { class: 'stack' },
      tiles.length
        ? tileView(tiles)
        : h('div', { class: 'card empty-state' },
            h('p', { class: 'muted small' }, node.kind === 'unsorted' ? 'These items are in the right area, but not placed any deeper yet. Long-press one to move it.' : 'This is the lowest level. Add sub-categories from the ⋯ menu if you want to split it further.')),
      !tiles.length && (siblings.length > 0 || parentNode) && h('div', { class: 'drop-tray' },
        h('span', { class: 'muted small' }, 'Long-press an item, then drop it on:'),
        h('div', { class: 'chips' },
          parentNode && h('span', { class: 'chip drop', 'data-drop-cat': parentNode.id }, `↑ ${parentNode.name}`),
          siblings.slice(0, 10).map((s) => h('span', { class: 'chip drop', 'data-drop-cat': s.id, style: { '--c': categoryColor(s) } }, s.name)))),
      sectionTitle(tiles.length ? 'Recent transactions' : 'Transactions', items.length > 6 && tiles.length > 0 ? h('button', { class: 'link small', onclick: () => replaceHash(`#/category/${param}?tab=transactions${trip ? `&trip=${trip}` : ''}`) }, 'See all') : null),
      items.length ? itemList(tiles.length ? items.slice(0, 6) : items) : h('p', { class: 'muted small' }, 'No transactions yet.'));
  }

  return h('div', { class: 'screen' },
    pageHeader(title, {
      subtitle: crumbs.length ? crumbs.join(' › ') : null,
      right: flat ? h('button', { class: 'icon-btn', 'aria-label': 'Edit category', onclick: () => categoryEditSheet(flat) }, icon('more')) : null,
    }),
    header,
    node.kind !== 'unsorted' && segmented([['breakdown', 'Breakdown'], ['transactions', 'Transactions']], tab,
      (key) => replaceHash(`#/category/${param}?tab=${key}${trip ? `&trip=${trip}` : ''}`)),
    node.kind === 'unsorted' ? h('div', { class: 'stack' }, body) : body);
}
route(/^\/category\/([\w-]+)$/, 'home', categoryScreen);

/* ---------- editing a category (also used by the Categories screen) ---------- */

function categoryEditSheet(cat, { parent = null, onDone } = {}) {
  const creating = !cat;
  const parentCat = parent || (cat && cat.parent_id != null ? categoryById(cat.parent_id) : null);
  const topLevel = creating ? !parent : cat.parent_id == null;
  const name = h('input', { type: 'text', value: creating ? '' : cat.name, placeholder: 'Category name', 'aria-label': 'Name' });
  const iconInput = h('input', { type: 'text', value: creating ? '' : (cat.icon || ''), placeholder: '🙂', maxlength: '4', 'aria-label': 'Icon', class: 'emoji-input' });
  const budget = h('input', { type: 'number', min: '0', step: '1', inputMode: 'decimal', value: !creating && cat.budget_sgd ? String(cat.budget_sgd) : '', placeholder: 'No budget', 'aria-label': 'Monthly budget' });
  let colorChoice = creating ? null : cat.own_color;
  const swatches = h('div', { class: 'swatches' });
  const drawSwatches = () => swatches.replaceChildren(...['#ff8a75', '#5d8df6', '#7c83f5', '#ffb066', '#b36cf0', '#f58bd0', '#a5d86e', '#4fd1a5', '#c9a877', '#f2c94c'].map((c) =>
    h('button', { class: `swatch${colorChoice === c ? ' on' : ''}`, style: { background: c }, 'aria-label': `Colour ${c}`, onclick: () => { colorChoice = c; drawSwatches(); } })));
  drawSwatches();

  openSheet(creating ? (parent ? `New inside ${parent.name}` : 'New category') : `Edit ${cat.name}`, (close) => {
    const finish = async () => { await loadCategories(); close(); if (onDone) onDone(); rerender(); };
    return h('div', { class: 'stack' },
      h('label', {}, 'Name', name),
      h('label', {}, 'Icon', iconInput,
        h('div', { class: 'chips' }, EMOJI_CHOICES.map((e) => h('button', { class: 'chip', onclick: () => { iconInput.value = e; } }, e)))),
      topLevel && h('label', {}, 'Colour', swatches, h('span', { class: 'muted small' }, 'Colour stays the same everywhere, so this category is always easy to spot.')),
      h('label', {}, 'Monthly budget (optional)', budget, h('span', { class: 'muted small' }, 'Sets the green line on the spending map. Without one, your usual spending is the line.')),
      h('div', { class: 'row-actions' },
        h('button', { class: 'btn primary grow', onclick: async () => {
          try {
            const budgetValue = budget.value === '' ? null : Number(budget.value);
            if (creating) await post('/api/categories', { name: name.value, parent_id: parentCat ? parentCat.id : null, icon: iconInput.value || null, color: colorChoice });
            else await patch(`/api/categories/${cat.id}`, { name: name.value, icon: iconInput.value || null, budget_sgd: budgetValue, ...(topLevel && colorChoice ? { color: colorChoice } : {}) });
            toast(creating ? 'Category added' : 'Saved');
            await finish();
          } catch (error) { fail(error); }
        } }, creating ? 'Add' : 'Save')),
      !creating && h('div', { class: 'list' },
        h('button', { class: 'list-row', onclick: () => { close(); categoryEditSheet(null, { parent: cat, onDone }); } }, icon('plus', 18), h('span', { class: 'grow' }, `Add a sub-category inside ${cat.name}`)),
        h('button', { class: 'list-row danger-text', onclick: async () => {
          if (!(await confirmSheet(`Delete “${cat.name}”? Anything inside it moves up to ${parentCat ? parentCat.name : 'Unsorted'}. Nothing is lost.`, 'Delete', true))) return;
          try { const r = await del(`/api/categories/${cat.id}`); toast(`Deleted. ${plural(r.moved_items, 'item')} moved up.`); close(); await loadCategories(); go(parentCat ? `#/category/${parentCat.id}` : '#/'); } catch (error) { fail(error); }
        } }, icon('close', 18), h('span', { class: 'grow' }, 'Delete this category'))));
  });
}
