'use strict';

/* Search, Trends, Review (needs a look), Balance check, Categories, Add (uploads) and the More menu. */

/* ---------- search ---------- */

function searchScreen(_, query) {
  let q = query.get('q') || '';
  let tab = 'all';
  let data = null, timer = null, token = 0;
  const results = h('div', { class: 'stack' });
  const tabs = h('div');

  const input = h('input', { type: 'search', class: 'search-input', placeholder: 'Search items, merchants, categories, trips', value: q, 'aria-label': 'Search',
    oninput: (e) => { q = e.target.value; clearTimeout(timer); timer = setTimeout(run, 220); } });

  const draw = () => {
    if (!q.trim()) { results.replaceChildren(h('p', { class: 'muted small centered pad' }, 'Try “salmon”, a shop name, a category, or a trip.')); tabs.replaceChildren(); return; }
    if (!data) return;
    const itemIds = new Set(data.items.map((i) => i.receipt.transaction_id).filter((x) => x != null));
    const extraTxns = data.transactions.filter((t) => !itemIds.has(t.id));
    tabs.replaceChildren(segmented([['all', 'All'], ['transactions', 'Transactions'], ['receipts', 'Receipts'], ['trips', 'Trips']], tab, (k) => { tab = k; draw(); }));

    const sections = [];
    if ((tab === 'all' || tab === 'transactions') && (data.items.length || extraTxns.length)) {
      sections.push(sectionTitle('Transactions'));
      if (data.items.length) sections.push(itemList(data.items.slice(0, tab === 'all' ? 8 : 40)));
      if (extraTxns.length) sections.push(h('div', { class: 'card flush' }, extraTxns.slice(0, tab === 'all' ? 5 : 40).map((t) => txnRow(t, { showDate: true }))));
    }
    if ((tab === 'all' || tab === 'receipts') && data.receipts.length) {
      sections.push(sectionTitle('Receipts'));
      sections.push(h('div', { class: 'card flush' }, data.receipts.map((r) => h('a', { class: 'txn-row', href: r.transaction_id != null ? `#/txn/${r.transaction_id}` : `#/receipt/${r.id}` },
        iconTile('🧾', '#a9a39a'), h('div', { class: 'grow' }, h('div', { class: 'strong' }, r.merchant || 'Receipt'), h('div', { class: 'muted small' }, `${shortDate(r.date)} · ${plural(r.matched_items, 'item')} matched`)), icon('chevron', 16)))));
    }
    if ((tab === 'all' || tab === 'trips') && data.trips.length) {
      sections.push(sectionTitle('Trips'));
      sections.push(h('div', { class: 'card flush' }, data.trips.map((t) => h('a', { class: 'txn-row', href: `#/trip/${t.id}` },
        iconTile(t.emoji || '🧳', tripColor(t)), h('div', { class: 'grow' }, h('div', { class: 'strong' }, t.name), h('div', { class: 'muted small' }, tripDates(t))), h('span', { class: 'strong' }, money0(t.spend_sgd))))));
    }
    results.replaceChildren(...(sections.length ? sections : [h('p', { class: 'muted small centered pad' }, `Nothing found for “${q}”.`)]));
  };
  async function run() {
    const mine = ++token;
    history.replaceState(null, '', q.trim() ? `#/search?q=${encodeURIComponent(q)}` : '#/search');
    if (!q.trim()) { data = null; draw(); return; }
    try { const result = await api(`/api/search?q=${encodeURIComponent(q)}`); if (mine === token) { data = result; draw(); } } catch (e) { fail(e); }
  }
  loadCategories().then(() => run());
  draw();
  setTimeout(() => input.focus(), 60);

  return h('div', { class: 'screen' },
    h('div', { class: 'search-bar' }, h('span', { class: 'search-field' }, icon('search', 18), input), h('button', { class: 'link', onclick: () => goBack() }, 'Cancel')),
    tabs, results);
}
route(/^\/search$/, 'home', async (a, q) => searchScreen(a, q));

/* ---------- trends ---------- */

async function trendsScreen(_, query) {
  const range = query.get('r') || '1M';
  const d = await api(`/api/trends?range=${range}`);
  const monthly = range !== '1M';

  let chart;
  if (!monthly) {
    const days = d.daily.days_in_month;
    const series = [];
    if (d.daily.usual.length) series.push({ points: d.daily.usual, color: 'var(--muted-line)', width: 2.2 });
    series.push({ points: d.daily.actual, color: 'var(--accent)', width: 3, area: true });
    const top = Math.max(1, ...d.daily.usual, ...d.daily.actual) * 1.08;
    chart = lineChart({ series, xCount: days, yMax: top, height: 190, xLabels: [1, 8, 15, 22, days].filter((n) => n <= days).map((n) => ({ index: n - 1, text: String(n) })), marker: d.daily.today_day ? d.daily.today_day - 1 : null,
      hoverLabel: (i) => `Day ${i + 1}: ${money0(d.daily.actual[i] ?? d.daily.usual[i] ?? 0)}${d.daily.usual[i] != null ? ` · usual ${money0(d.daily.usual[i])}` : ''}` });
  } else {
    const points = d.months.map((m) => m.total_sgd);
    const series = [{ points, color: 'var(--accent)', width: 3, dots: true, area: true }];
    if (d.usual_monthly_sgd) series.unshift({ points: points.map(() => d.usual_monthly_sgd), color: 'var(--muted-line)', dashed: true, width: 2 });
    chart = lineChart({ series, xCount: points.length, yMax: Math.max(1, ...points, d.usual_monthly_sgd || 0) * 1.12, height: 190,
      xLabels: d.months.map((m, i) => ({ index: i, text: m.label })).filter((_, i, all) => all.length <= 8 || i % Math.ceil(all.length / 6) === 0),
      hoverLabel: (i) => `${d.months[i].label}: ${money0(d.months[i].total_sgd)}` });
  }
  const maxDelta = Math.max(1, ...d.category_changes.map((c) => Math.abs(c.delta_sgd ?? c.actual_sgd)));

  return h('div', { class: 'screen' },
    pageHeader('Trends'),
    h('div', { class: 'chips scroll-x' }, ['1M', '3M', '6M', '1Y', 'All'].map((r) => h('button', { class: 'chip', 'aria-pressed': String(range === r), onclick: () => replaceHash(`#/trends?r=${r}`) }, r))),
    h('div', { class: 'card' },
      h('div', { class: 'legend' }, h('span', {}, h('i', { class: 'lg-actual' }), monthly ? 'Monthly spending' : 'This month'), d.usual_monthly_sgd && h('span', {}, h('i', { class: 'lg-usual2' }), 'Usual')),
      chart,
      h('div', { class: 'stat-row' },
        h('div', {}, h('strong', {}, money0(d.this_month_sgd)), h('span', { class: 'muted small' }, 'this month')),
        h('div', {}, h('strong', {}, money(d.avg_daily_sgd)), h('span', { class: 'muted small' }, 'avg per day')),
        h('div', {}, h('strong', {}, d.usual_monthly_sgd ? money0(d.usual_monthly_sgd) : '—'), h('span', { class: 'muted small' }, 'usual month')))),

    sectionTitle('Spending by category'),
    d.category_changes.length
      ? h('div', { class: 'card flush list' }, d.category_changes.map((c) => h('a', { class: 'list-row', href: `#/category/${c.id}` },
          iconTile(c.icon, c.color, 34),
          h('div', { class: 'grow' }, h('div', { class: 'row-between' }, h('span', { class: 'strong' }, c.name), h('span', { class: 'strong' }, money0(c.actual_sgd))),
            h('div', { class: 'meter' }, h('i', { style: { width: `${(Math.abs(c.delta_sgd ?? c.actual_sgd) / maxDelta) * 100}%`, background: c.delta_sgd == null ? c.color : (c.delta_sgd > 0 ? 'var(--bad)' : 'var(--good)') } }))),
          c.delta_sgd != null && h('strong', { class: c.delta_sgd > 0 ? 'up' : 'down' }, `${c.delta_sgd > 0 ? '+' : '−'}${money0(Math.abs(c.delta_sgd))}`))))
      : emptyCard('No spending this month yet'),
    d.usual_monthly_sgd && h('p', { class: 'muted small' }, 'Changes are against your usual, scaled to how much of the month has passed.'),

    sectionTitle('Which days you spend'),
    h('div', { class: 'card' }, miniBars(d.weekdays.map((w) => ({ label: w.label, value: w.avg_sgd })), { color: 'var(--accent)' }), h('p', { class: 'muted small' }, 'Average per day, over the chosen range.')),

    d.recurring.length > 0 && sectionTitle('Looks recurring'),
    d.recurring.length > 0 && h('div', { class: 'card flush list' }, d.recurring.map((r) => h('div', { class: 'list-row static' },
      h('span', { class: 'grow' }, r.name, h('small', { class: 'muted block' }, `${r.months} months · ${r.count} times`)), h('strong', {}, `~${money0(r.typical_sgd)}`)))),

    d.trips.length > 0 && sectionTitle('Trips over time'),
    d.trips.length > 0 && h('div', { class: 'card flush list' }, d.trips.map((t) => h('a', { class: 'list-row', href: `#/trip/${t.id}` },
      iconTile(t.emoji || '🧳', tripColor(t), 34), h('span', { class: 'grow' }, t.name, h('small', { class: 'muted block' }, t.start_date ? longDate(t.start_date) : '')), h('strong', {}, money0(t.spend_sgd)), icon('chevron', 16)))));
}
route(/^\/trends$/, 'home', trendsScreen);

/* ---------- review: what the app isn't sure about ---------- */

async function reviewScreen(_, query) {
  if (!state.categories.length) await loadCategories();
  const scope = query.get('s') === 'all' ? 'all' : 'month';
  const month = state.month || currentMonth();
  const d = await api(`/api/review${scope === 'month' ? `?month=${month}` : ''}`);
  const suggestions = d.items.filter((i) => i.category_confidence === 'suggested');

  const acceptAll = async () => {
    if (!(await confirmSheet(`Confirm all ${suggestions.length} suggested categories? Only do this if the guesses look right to you.`, 'Confirm all'))) return;
    await act(post('/api/review/accept', { item_ids: suggestions.map((i) => i.id) }), `Confirmed ${suggestions.length}`);
  };
  const reviewCard = (item) => {
    const suggested = item.category_confidence === 'suggested';
    return h('div', { class: 'review-card' },
      h('div', { class: 'row-between' }, h('div', { class: 'grow' }, h('div', { class: 'strong' }, item.name), h('div', { class: 'muted small' }, `${item.receipt.merchant || ''} · ${shortDate(item.receipt.date)}`)), h('strong', {}, money(item.personal_sgd))),
      h('div', { class: 'row-between wrap' }, categoryChip(item, { full: true }),
        h('div', { class: 'row-actions' },
          suggested && h('button', { class: 'btn small primary', onclick: () => act(post('/api/review/accept', { item_ids: [item.id] }), 'Confirmed') }, 'Yes'),
          h('button', { class: 'btn small', onclick: () => pickCategory({ title: 'Move to…', selectedId: item.category_id, teach: true, onPick: (cat, o) => cat && act(post('/api/items/category', { item_ids: [item.id], category_id: cat.id, learn: !!o.learn, also_similar: !!o.alsoSimilar }), `Moved to ${cat.name}`) }) }, suggested ? 'Change' : 'Choose'))));
  };

  return h('div', { class: 'screen' },
    pageHeader('Needs a look'),
    segmented([['month', new Date(`${month}-01T00:00:00`).toLocaleDateString('en-GB', { month: 'long' })], ['all', 'All time']], scope, (key) => replaceHash(`#/review?s=${key}`)),
    h('div', { class: 'card warm' },
      h('div', { class: 'big' }, money0(d.uncertain_sgd)), h('div', { class: 'muted' }, 'could use a look'),
      h('p', { class: 'small' }, `${money0(d.confident_sgd)} is confidently understood. This is optional: your totals already include everything below.`),
      suggestions.length > 1 && h('button', { class: 'btn primary', onclick: acceptAll }, `Confirm all ${suggestions.length} suggestions`)),
    d.matches.length > 0 && sectionTitle(`${plural(d.matches.length, 'match', 'matches')} to check`),
    d.matches.length > 0 && h('div', { class: 'card flush' }, d.matches.map((t) => h('a', { class: 'txn-row', href: `#/txn/${t.id}` },
      iconTile('🔗', '#f5a623'), h('div', { class: 'grow' }, h('div', { class: 'strong' }, t.description), h('div', { class: 'muted small ellipsis' }, t.note || 'Linked to a receipt, not certain')), h('span', { class: 'strong' }, money(t.amount_sgd))))),
    d.items.length ? sectionTitle('Biggest first') : null,
    d.items.length ? h('div', { class: 'stack' }, d.items.slice(0, 40).map(reviewCard)) : (d.matches.length ? null : emptyCard('All clear', 'Nothing needs a look right now.')),
    d.items.length > 40 && h('p', { class: 'muted small centered' }, `${d.items.length - 40} smaller ones not shown. They’re fine to leave.`));
}
route(/^\/review$/, 'home', reviewScreen);

/* ---------- balance check ---------- */

async function balanceScreen() {
  const d = await api('/api/balance');
  const cur = d.current;
  const amount = h('input', { type: 'number', step: '0.01', inputMode: 'decimal', placeholder: cur ? cur.implied_sgd.toFixed(2) : '0.00', 'aria-label': 'Actual balance' });
  const date = h('input', { type: 'date', value: isoDay(new Date()), 'aria-label': 'Date' });

  return h('div', { class: 'screen' },
    pageHeader('Balance check'),
    h('div', { class: 'card' },
      cur ? [h('div', { class: 'muted small' }, 'Balance implied by your records'), h('div', { class: 'big' }, money(cur.implied_sgd)),
             h('p', { class: 'muted small' }, `Last checked ${longDate(cur.reconciled_on)} at ${money(cur.reconciled_sgd)}, then moved by everything recorded since.`)]
          : [h('p', { class: 'strong' }, 'Check your real balance now and then'), h('p', { class: 'muted small' }, 'Enter what your card actually shows. The first check is a starting point; later ones reveal money the records can’t explain.')]),
    h('div', { class: 'card stack' },
      h('label', {}, 'What does your card show right now?', h('span', { class: 'money-input' }, '$', amount)),
      h('label', {}, 'As of', date),
      h('button', { class: 'btn primary wide', onclick: async () => {
        if (amount.value === '') { toast('Enter your balance first', true); return; }
        try {
          const r = await post('/api/balance', { actual_sgd: Number(amount.value), date: date.value || null });
          toast(r.first ? 'Saved as your starting point' : r.untracked_sgd > 0.005 ? `${money(r.untracked_sgd)} untracked` : r.untracked_sgd < -0.005 ? `${money(-r.untracked_sgd)} more than expected` : 'Everything adds up');
          await rerender();
        } catch (e) { fail(e); }
      } }, 'Save balance')),
    h('div', { class: 'card soft' }, h('p', { class: 'small' }, h('strong', {}, '? Untracked'), ' is money that left with no record at all: no merchant, no date, no category. The app won’t invent any. It shows as a grey ? on your spending map so the totals still add up.')),
    d.history.length > 0 && sectionTitle('Past checks'),
    d.history.length > 0 && h('div', { class: 'card flush list' }, d.history.map((r) => h('div', { class: 'list-row static' },
      h('span', { class: 'grow' }, longDate(r.reconciled_on), h('small', { class: 'muted block' }, r.implied_sgd == null ? 'starting point' : `expected ${money(r.implied_sgd)}`)),
      h('div', { class: 'right' }, h('strong', {}, money(r.actual_sgd)), r.untracked_sgd > 0.005 && h('div', { class: 'small error-text' }, `? ${money(r.untracked_sgd)} untracked`),
        r.untracked_sgd < -0.005 && h('div', { class: 'small muted' }, `${money(-r.untracked_sgd)} extra`))))));
}
route(/^\/balance$/, 'home', balanceScreen);

/* ---------- categories ---------- */

async function categoriesScreen() {
  await loadCategories();
  const rows = state.categories.map((c) => h('div', { class: 'tree-row static', style: { paddingLeft: `${10 + c.depth * 20}px` } },
    iconTile(c.icon, categoryColor(c), 30),
    h('span', { class: 'grow' }, c.name, c.kind === 'misc' && h('small', { class: 'muted' }, ' · deliberate catch-all'), c.kind === 'grocery' && h('small', { class: 'muted' }, ' · no-receipt groceries'),
      c.budget_sgd && h('small', { class: 'muted block' }, `budget ${money0(c.budget_sgd)} / month`)),
    h('button', { class: 'icon-btn', 'aria-label': `Edit ${c.name}`, onclick: () => categoryEditSheet(c) }, icon('edit', 18))));

  return h('div', { class: 'screen' },
    pageHeader('Categories', { right: h('button', { class: 'icon-btn', 'aria-label': 'New category', onclick: () => categoryEditSheet(null) }, icon('plus')) }),
    h('p', { class: 'muted small' }, 'Organise spending your way. Categories nest as deep as you like. A budget sets the green line on your spending map.'),
    h('div', { class: 'card flush' }, rows));
}
route(/^\/categories$/, 'more', categoriesScreen);

/* ---------- add: uploads ---------- */

async function submitUpload(event, url, resultEl, describe) {
  event.preventDefault();
  const form = event.currentTarget;
  const data = new FormData(form);
  for (const [key, value] of [...data.entries()]) if (value instanceof File && !value.name) data.delete(key); // an optional file left empty
  const button = $('button[type=submit]', form);
  button.disabled = true;
  resultEl.textContent = 'Reading the image… the first run can take a minute.';
  try {
    const result = await api(url, { method: 'POST', body: data });
    resultEl.textContent = describe(result);
    form.reset();
  } catch (error) {
    resultEl.textContent = '';
    fail(error);
  } finally { button.disabled = false; }
}

async function addScreen() {
  const home = await api('/api/home');
  const receiptResult = h('p', { class: 'muted small', 'aria-live': 'polite' });
  const youtripResult = h('p', { class: 'muted small', 'aria-live': 'polite' });
  return h('div', { class: 'screen' },
    pageHeader('Add', { back: true }),
    home.active_trip && h('a', { class: 'trip-banner', href: '#/trip-mode' }, h('span', {}, '🧳'), h('span', { class: 'grow' }, `New items will join ${home.active_trip.name}`), icon('chevron', 16)),
    h('form', { class: 'card stack', onsubmit: (e) => submitUpload(e, '/api/upload/youtrip', youtripResult, (r) => `Found ${plural(r.found, 'charge')}: ${r.added} new, ${r.already_had} already saved. ${plural(r.matched, 'receipt')} linked.`) },
      h('h3', {}, 'YouTrip charges'),
      h('p', { class: 'muted small' }, 'Screenshot your YouTrip transaction list. Overlapping screenshots are fine: charges you’ve already saved are skipped.'),
      h('label', {}, 'Screenshot', h('input', { type: 'file', name: 'screenshot', accept: 'image/*', required: true })),
      h('button', { class: 'btn primary', type: 'submit' }, 'Read charges'), youtripResult),
    h('form', { class: 'card stack', onsubmit: (e) => submitUpload(e, '/api/upload/receipt', receiptResult, (r) =>
      `Read “${r.merchant || 'unknown store'}”: ${plural(r.items, 'item')}, total ${r.currency || ''} ${r.total ?? '?'}. ` + (r.matched ? `Linked to a YouTrip charge${r.needs_review ? ' (worth a look)' : ''}.` : 'No matching YouTrip charge yet.')) },
      h('h3', {}, 'Receipt'),
      h('p', { class: 'muted small' }, 'A Google Translate screenshot of the receipt (Swedish to English). Add the original photo too if you can: its store name helps match the charge.'),
      h('label', {}, 'Translated screenshot', h('input', { type: 'file', name: 'translated', accept: 'image/*', required: true })),
      h('label', {}, 'Original photo (optional)', h('input', { type: 'file', name: 'original', accept: 'image/*' })),
      h('button', { class: 'btn primary', type: 'submit' }, 'Read receipt'), receiptResult),
    h('a', { class: 'btn wide', href: '#/review' }, 'See what needs a look'));
}
route(/^\/add$/, 'more', addScreen);

/* ---------- more ---------- */

async function moreScreen() {
  const link = (href, symbol, label, hint) => h('a', { class: 'list-row', href }, iconTile(symbol, '#a9a39a', 36), h('span', { class: 'grow' }, label, hint && h('small', { class: 'muted block' }, hint)), icon('chevron', 16));
  return h('div', { class: 'screen' },
    pageHeader('More', { back: false }),
    h('div', { class: 'card flush list' },
      link('#/add', '📥', 'Add screenshots', 'YouTrip charges and receipts'),
      link('#/review', '👀', 'Needs a look', 'Optional: confirm the app’s guesses'),
      link('#/search', '🔎', 'Search', 'Items, merchants, categories, trips')),
    h('div', { class: 'card flush list' },
      link('#/trends', '📈', 'Trends', 'Monthly patterns, usual vs now'),
      link('#/balance', '⚖️', 'Balance check', 'Find money the records can’t explain'),
      link('#/categories', '🗂️', 'Categories', 'Your own hierarchy and budgets')),
    h('p', { class: 'muted small centered' }, 'Everything stays on this device’s database. No account, no cloud.'));
}
route(/^\/more$/, 'more', moreScreen);
