'use strict';

/* Activity feed, transaction detail, and the screens reached from it: Split / Paid for Others,
   incoming-money classification, manual breakdown, and receipt-only view. */

/* ---------- activity feed ---------- */

async function activityScreen(_, query) {
  const filter = query.get('f') || 'all';
  const data = await api('/api/activity');
  const entries = data.entries;
  const tests = {
    all: () => true,
    review: (e) => e.status === 'needs_review',
    receipt: (e) => e.status === 'unmatched' || e.status === 'receipt_only',
    in: (e) => e.type !== 'expense',
  };
  const counts = Object.fromEntries(Object.keys(tests).map((k) => [k, entries.filter(tests[k]).length]));
  const chip = (key, label) => h('button', { class: 'chip', 'aria-pressed': String(filter === key), onclick: () => replaceHash(`#/activity?f=${key}`) }, label, counts[key] > 0 && key !== 'all' ? ` ${counts[key]}` : '');

  const shown = entries.filter(tests[filter]);
  return h('div', { class: 'screen' },
    pageHeader('Activity', { back: false, right: h('a', { class: 'icon-btn', href: '#/search', 'aria-label': 'Search' }, icon('search')) }),
    h('div', { class: 'chips scroll-x' }, chip('all', 'All'), chip('review', 'Check match'), chip('receipt', 'No receipt'), chip('in', 'Money in')),
    shown.length ? groupedFeed(shown)
      : emptyCard(entries.length ? 'Nothing matches that filter' : 'No transactions yet',
          entries.length ? null : 'Upload a YouTrip screenshot and your charges will show up here.',
          entries.length ? null : h('a', { class: 'btn primary', href: '#/add' }, 'Add screenshots')),
    h('a', { class: 'fab', href: '#/add', 'aria-label': 'Add screenshots' }, icon('plus', 26)));
}
route(/^\/activity$/, 'activity', activityScreen);

/* ---------- transaction detail ---------- */

const TYPE_TITLE = { expense: 'Purchase', reimbursement: 'Reimbursement', income: 'Income / allowance', refund: 'Refund', transfer_own_account: 'Transfer between my accounts', other: 'Other money in' };

function menuRow(label, { value, onclick, href, danger = false, hint } = {}) {
  const tag = href ? 'a' : 'button';
  return h(tag, { class: `list-row${danger ? ' danger-text' : ''}`, href, onclick },
    h('span', { class: 'grow' }, label, hint && h('small', { class: 'muted block' }, hint)),
    value && h('span', { class: 'muted small right' }, value),
    !danger && icon('chevron', 16));
}

async function txnScreen([id]) {
  if (!state.categories.length) await loadCategories();
  const d = await api(`/api/transactions/${id}`);
  const t = d.transaction;
  const incoming = t.type !== 'expense';
  const items = d.items;
  const local = t.local_amount != null ? `${t.local_currency || ''} ${t.local_amount.toFixed(2)}`.trim() : null;
  const split = d.others_sgd > 0.005;
  const singleItem = items.length === 1 ? items[0] : null;
  const isRealReceipt = t.receipt && !d.can_break_down && t.type === 'expense';
  const partial = t.type === 'reimbursement' && t.reimbursement_amount != null && t.reimbursement_amount < (t.amount_sgd || 0) - 0.005;

  const noteBox = h('textarea', { class: 'note-box', rows: '2', placeholder: 'Add a note', 'aria-label': 'Note' }, t.user_note || '');
  noteBox.addEventListener('blur', async () => {
    if ((noteBox.value.trim() || null) === (t.user_note || null)) return;
    try { await post(`/api/transactions/${id}/note`, { note: noteBox.value }); t.user_note = noteBox.value.trim() || null; toast('Note saved'); } catch (e) { fail(e); }
  });

  const linkReceipt = async () => {
    const { unmatched_receipts: receipts } = await api('/api/activity');
    openSheet('Link a receipt', (close) => receipts.length
      ? h('div', { class: 'list' }, receipts.map((r) => h('button', { class: 'list-row', onclick: async () => { close(); await act(post(`/api/transactions/${id}/link`, { receipt_id: r.id }), 'Linked'); } },
          h('span', { class: 'grow' }, r.merchant || 'Unknown store', h('small', { class: 'muted block' }, [shortDate(r.date), r.total != null && `${r.currency || ''} ${r.total.toFixed(2)}`].filter(Boolean).join(' · '))))))
      : h('div', { class: 'stack' }, h('p', { class: 'muted' }, 'No unmatched receipts right now.'), h('a', { class: 'btn primary', href: '#/add', onclick: close }, 'Upload a receipt')));
  };

  return h('div', { class: 'screen' },
    pageHeader('Transaction', { right: h('button', { class: 'icon-btn', 'aria-label': 'More', onclick: () => openSheet('Transaction', (close) => h('div', { class: 'list' },
      h('button', { class: 'list-row danger-text', onclick: async () => {
        close();
        if (!(await confirmSheet('Delete this transaction? This removes it from your history and your totals.', 'Delete', true))) return;
        try { await del(`/api/transactions/${id}`); toast('Deleted'); goBack('#/activity'); } catch (e) { fail(e); }
      } }, icon('close', 18), h('span', { class: 'grow' }, 'Delete transaction'))))}, icon('more')) }),

    h('div', { class: 'txn-hero' },
      incoming ? iconTile(TYPE_ICON[t.type] || '⬇️', '#34c38f', 56) : iconTile(singleItem && singleItem.category_icon ? singleItem.category_icon : '🧾', singleItem && singleItem.category_color ? singleItem.category_color : MISC_COLOR, 56),
      h('div', { class: 'strong big-title' }, t.description || 'Unknown charge'),
      h('div', { class: 'muted small' }, [t.date, t.trip && t.trip.name].filter(Boolean).join(' · ')),
      h('div', { class: `hero-amount${incoming ? ' in' : ''}` }, incoming ? money(t.amount_sgd, { sign: true }) : money(-(t.amount_sgd || 0))),
      h('div', { class: 'muted small' }, ['YouTrip · SGD', local && `charged ${local}`].filter(Boolean).join(' · ')),
      h('div', { class: 'chips center' },
        !incoming && h('button', { class: `chip trip-chip${t.trip ? ' on' : ''}`, onclick: () => pickTrip(t.trip ? t.trip.id : null, (tripId) => act(post(`/api/transactions/${id}/trip`, { trip_id: tripId }), 'Trip updated')) }, t.trip ? `🧳 ${t.trip.name}` : '+ Trip'),
        singleItem && h('button', { class: 'chip-btn', onclick: () => pickCategory({ title: 'Category', selectedId: singleItem.category_id, allowClear: true, teach: true, onPick: (cat, o) => act(post('/api/items/category', { item_ids: [singleItem.id], category_id: cat ? cat.id : null, learn: !!o.learn, also_similar: !!o.alsoSimilar }), cat ? `Moved to ${cat.name}` : 'Cleared') }) }, categoryChip(singleItem, { full: true })),
        !singleItem && items.length > 1 && h('span', { class: 'chip quiet' }, `${items.length} items`))),

    t.status === 'needs_review' && h('div', { class: 'card notice' },
      h('p', { class: 'strong' }, 'Worth a look'),
      h('p', { class: 'small' }, t.note || 'This charge was linked to a receipt, but the match isn’t certain.'),
      h('div', { class: 'row-actions' },
        h('button', { class: 'btn primary', onclick: () => act(post(`/api/transactions/${id}/approve`, {}), 'Approved') }, 'Looks right'),
        h('button', { class: 'btn', onclick: () => act(post(`/api/transactions/${id}/unlink`, {}), 'Unlinked') }, 'Unlink'))),

    !incoming && h('div', { class: 'card flush list' },
      menuRow('Split / Paid for others', { href: `#/split/${id}`, value: split ? `you ${money(d.personal_sgd)} · others ${money(d.others_sgd)}` : null }),
      t.receipt
        ? menuRow(t.receipt.merchant ? `Receipt · ${t.receipt.merchant}` : 'Receipt', { onclick: () => (isRealReceipt || t.receipt) && go(`#/receipt/${t.receipt.id}`), value: t.status === 'auto' ? 'matched' : t.status === 'approved' ? 'confirmed' : null })
        : menuRow('Add receipt', { onclick: linkReceipt, hint: 'Link one you’ve uploaded, or upload it now' }),
      d.can_break_down && menuRow('Break down into categories', { href: `#/breakdown/${id}`, hint: 'e.g. a Splitwise settlement made of food, transport and souvenirs' }),
      menuRow('Not a purchase?', { href: `#/classify/${id}`, hint: 'Mark it as money in, a refund, or a transfer' })),

    incoming && h('div', { class: 'card flush list' },
      menuRow(TYPE_TITLE[t.type] || 'Money in', { href: `#/classify/${id}`, value: 'change', hint: partial ? `${money(t.reimbursement_amount)} counted as reimbursement, the rest as income` : null })),

    items.length > 1 || (items.length === 1 && isRealReceipt)
      ? h('div', { class: 'stack' }, sectionTitle('Items'), itemList(items)) : null,

    h('div', { class: 'card' }, h('h3', {}, 'Notes'), noteBox));
}
route(/^\/txn\/(\d+)$/, 'activity', txnScreen);

/* ---------- receipt-only ---------- */

async function receiptScreen([id]) {
  if (!state.categories.length) await loadCategories();
  const [allItems, activity] = await Promise.all([api('/api/items'), api('/api/activity')]);
  const items = allItems.filter((i) => i.receipt.id === Number(id));
  if (!items.length) return emptyCard('Receipt not found', null, h('a', { class: 'btn', href: '#/activity' }, 'Back'));
  const first = items[0];
  const tid = first.receipt.transaction_id;
  const candidates = activity.entries.filter((e) => e.kind === 'transaction' && e.status === 'unmatched');
  const total = items.filter((i) => !i.is_deposit).reduce((sum, i) => sum + (i.price_sgd || 0), 0);

  return h('div', { class: 'screen' },
    pageHeader(first.receipt.merchant || 'Receipt'),
    h('div', { class: 'card' },
      h('div', { class: 'muted small' }, longDate(first.receipt.date)),
      h('div', { class: 'big' }, money(total)),
      first.currency && first.currency !== 'SGD' && h('div', { class: 'muted small' }, `printed in ${first.currency}`),
      h('button', { class: `chip trip-chip${first.trip ? ' on' : ''}`, onclick: () => pickTrip(first.trip ? first.trip.id : null, (tripId) => act(post(`/api/receipts/${id}/trip`, { trip_id: tripId }), 'Trip updated')) }, first.trip ? `🧳 ${first.trip.name}` : '+ Trip')),
    tid == null && h('div', { class: 'card' },
      h('h3', {}, 'No charge linked yet'),
      h('p', { class: 'muted small' }, 'It still counts in your spending. Link the matching YouTrip charge once you’ve uploaded it.'),
      candidates.length
        ? h('div', { class: 'list' }, candidates.slice(0, 8).map((c) => h('button', { class: 'list-row', onclick: () => act(post(`/api/transactions/${c.id}/link`, { receipt_id: Number(id) }), 'Linked') },
            h('span', { class: 'grow' }, c.title, h('small', { class: 'muted block' }, shortDate(c.date))), h('span', { class: 'strong' }, money(c.amount_sgd)))))
        : h('p', { class: 'muted small' }, 'No unlinked charges to pair it with.')),
    tid != null && h('a', { class: 'btn', href: `#/txn/${tid}` }, 'Open the linked transaction'),
    sectionTitle('Items'), itemList(items));
}
route(/^\/receipt\/(\d+)$/, 'activity', receiptScreen);

/* ---------- split / paid for others ---------- */

async function splitScreen([id]) {
  if (!state.categories.length) await loadCategories();
  const d = await api(`/api/transactions/${id}`);
  const t = d.transaction;
  const total = t.amount_sgd || 0;
  const existing = d.others_sgd > 0.005;
  const singleItem = d.items.length === 1 ? d.items[0] : null;
  const where = singleItem && singleItem.category_path.length ? singleItem.category_path.slice(-2).join(' › ') : (d.items.length > 1 ? 'your categories' : 'Unsorted');

  const form = { mode: existing ? 'custom' : 'equal', people: 2, share: existing ? d.personal_sgd : total };
  const mine = () => (form.mode === 'equal' ? Math.round((total / form.people) * 100) / 100 : Math.min(total, Math.max(0, Number(form.share) || 0)));

  const out = h('div', { class: 'stack' });
  const shareInput = h('input', { type: 'number', min: '0', step: '0.01', inputMode: 'decimal', value: String(form.share.toFixed ? form.share.toFixed(2) : form.share), 'aria-label': 'Your share', oninput: (e) => { form.share = e.target.value; draw(false); } });
  const stepper = (delta) => { form.people = Math.min(30, Math.max(2, form.people + delta)); draw(); };

  const draw = (rebuildInput = true) => {
    const my = mine(), others = Math.round((total - my) * 100) / 100;
    const valid = my >= 0 && my <= total + 0.005;
    if (rebuildInput && form.mode === 'custom') shareInput.value = String(my.toFixed(2));
    fill(out, 
      segmented([['equal', 'Split equally'], ['custom', 'Custom']], form.mode, (m) => { if (m === 'custom' && form.mode === 'equal') form.share = mine(); form.mode = m; draw(); }),
      h('div', { class: 'card list' },
        h('div', { class: 'list-row static' }, h('span', { class: 'grow' }, 'Total amount'), h('strong', {}, money(total))),
        form.mode === 'equal' && h('div', { class: 'list-row static' }, h('span', { class: 'grow' }, 'Number of people (including you)'),
          h('div', { class: 'stepper' }, h('button', { class: 'icon-btn', 'aria-label': 'Fewer people', onclick: () => stepper(-1) }, '−'), h('strong', {}, form.people), h('button', { class: 'icon-btn', 'aria-label': 'More people', onclick: () => stepper(1) }, '+'))),
        h('div', { class: 'list-row static' }, h('span', { class: 'grow' }, 'Your share'), form.mode === 'custom' ? h('span', { class: 'money-input' }, '$', shareInput) : h('strong', {}, money(my))),
        h('div', { class: 'list-row static accent-row' }, h('span', { class: 'grow' }, 'Paid for others'), h('strong', {}, money(others)))),
      h('div', { class: 'card soft' },
        h('p', { class: 'small strong' }, 'This will be recorded as:'),
        h('ul', { class: 'facts' },
          h('li', {}, `${money(my)} in ${where}`),
          h('li', {}, `${money(others)} in Paid for others (not in spending)`)),
        h('p', { class: 'muted small' }, `The transaction stays ${money(total)} in your cash history.`)),
      !valid && h('p', { class: 'error-text small' }, `Your share has to be between $0 and ${money(total)}.`),
      h('button', { class: 'btn primary wide', disabled: !valid, onclick: async () => {
        try { await post(`/api/transactions/${id}/split`, { my_share_sgd: my }); toast(others > 0.005 ? `${money(others)} recorded as paid for others` : 'Split cleared'); go(`#/txn/${id}`); } catch (e) { fail(e); }
      } }, 'Confirm'),
      existing && h('button', { class: 'btn quiet wide', onclick: async () => { try { await post(`/api/transactions/${id}/split`, { my_share_sgd: total }); toast('Split cleared'); go(`#/txn/${id}`); } catch (e) { fail(e); } } }, 'Remove split (all mine)'));
  };
  draw();

  return h('div', { class: 'screen' }, pageHeader('Split / Paid for others'),
    h('div', { class: 'muted small centered' }, t.description || 'Transaction'),
    out);
}
route(/^\/split\/(\d+)$/, 'activity', splitScreen);

/* ---------- classify incoming money ---------- */

async function classifyScreen([id]) {
  const [d, activity] = await Promise.all([api(`/api/transactions/${id}`), api('/api/activity')]);
  const t = d.transaction;
  const amount = t.amount_sgd || 0;
  const outstanding = d.outstanding_excluding_sgd;
  const looksPersonToPerson = /^(from|paynow|transfer|received|pay ?lah|venmo)/i.test(t.description || '');
  const OPTIONS = [
    ['reimbursement', '🤝', 'Reimbursement', 'Reduces your “owed back” balance'],
    ['income', '💰', 'Allowance / Income', 'Adds to your funds, not a reimbursement'],
    ['transfer_own_account', '🔁', 'Transfer (my own account)', 'Neither spending nor income'],
    ['refund', '↩️', 'Refund', 'For a previous purchase'],
    ['other', '•', 'Other', 'Something else'],
  ];
  const form = { type: t.type !== 'expense' ? t.type : (looksPersonToPerson ? 'reimbursement' : 'reimbursement'), excess: 'income', refundOf: t.type === 'refund' && t.receipt ? String(t.receipt.id) : '' };
  const refundable = activity.entries.filter((e) => e.type === 'expense' && e.receipt && e.id !== Number(id));

  const out = h('div', { class: 'stack' });
  const draw = () => {
    const excess = form.type === 'reimbursement' && amount > Math.max(outstanding, 0) + 0.005;
    const owed = Math.max(outstanding, 0);
    fill(out, 
      h('div', { class: 'card list flush' }, OPTIONS.map(([key, emoji, label, hint]) =>
        h('button', { class: `list-row option${form.type === key ? ' selected' : ''}`, role: 'radio', 'aria-checked': String(form.type === key), onclick: () => { form.type = key; draw(); } },
          iconTile(emoji, '#34c38f', 36),
          h('span', { class: 'grow' }, label, key === 'reimbursement' && looksPersonToPerson && t.type === 'expense' && h('em', { class: 'suggest' }, ' suggested'), h('small', { class: 'muted block' }, hint)),
          form.type === key && icon('check', 20)))),
      excess && h('div', { class: 'card notice' },
        h('p', { class: 'strong' }, owed > 0 ? `Only ${money(owed)} is currently owed back` : 'Nothing is currently owed back'),
        h('p', { class: 'small' }, 'A reimbursement can’t push what you’re owed below zero. What about the extra?'),
        h('label', { class: 'check-row' }, h('input', { type: 'radio', name: 'excess', checked: form.excess === 'income', onchange: () => { form.excess = 'income'; } }),
          h('span', {}, owed > 0 ? `Count the extra ${money(amount - owed)} as income` : 'Count all of it as income')),
        h('label', { class: 'check-row' }, h('input', { type: 'radio', name: 'excess', checked: form.excess === 'all', onchange: () => { form.excess = 'all'; } }),
          h('span', {}, 'It’s all reimbursement: my earlier records were incomplete'))),
      form.type === 'refund' && h('div', { class: 'card' },
        h('label', {}, 'Which purchase is this refunding?',
          h('select', { onchange: (e) => { form.refundOf = e.target.value; } },
            h('option', { value: '' }, 'I’m not sure'),
            refundable.map((e) => h('option', { value: String(e.receipt.id), selected: form.refundOf === String(e.receipt.id) }, `${shortDate(e.date)} · ${e.title} · ${money(e.amount_sgd)}`)))),
        h('p', { class: 'muted small' }, 'Linking it keeps the record straight. Category totals aren’t netted automatically yet.')),
      h('button', { class: 'btn primary wide', onclick: save }, 'Save'),
      t.type !== 'expense' && h('button', { class: 'btn quiet wide', onclick: async () => { try { await post(`/api/transactions/${id}/classify`, { type: 'expense' }); toast('Back to a normal purchase'); go(`#/txn/${id}`); } catch (e) { fail(e); } } }, 'Actually, this was a purchase'));
  };
  const save = async () => {
    let type = form.type, body = {};
    if (type === 'reimbursement' && amount > Math.max(outstanding, 0) + 0.005 && form.excess === 'income') {
      if (outstanding <= 0.005) type = 'income'; else body.reimbursement_amount = outstanding;
    }
    if (type === 'refund' && form.refundOf) body.refunds_receipt_id = Number(form.refundOf);
    try { await post(`/api/transactions/${id}/classify`, { type, ...body }); toast('Saved'); go(`#/txn/${id}`); } catch (e) { fail(e); }
  };
  draw();

  return h('div', { class: 'screen' }, pageHeader('Incoming transaction'),
    h('div', { class: 'txn-hero' },
      iconTile('⬇️', '#34c38f', 52),
      h('div', { class: 'hero-amount in' }, money(amount, { sign: true })),
      h('div', { class: 'strong' }, t.description || 'Unknown'),
      h('div', { class: 'muted small' }, t.date || '')),
    h('h3', { class: 'section-h' }, 'What is this?'), out);
}
route(/^\/classify\/(\d+)$/, 'activity', classifyScreen);

/* ---------- manual breakdown ---------- */

async function breakdownScreen([id]) {
  if (!state.categories.length) await loadCategories();
  const d = await api(`/api/transactions/${id}`);
  const t = d.transaction;
  const total = t.amount_sgd || 0;
  if (!d.can_break_down) {
    return h('div', { class: 'screen' }, pageHeader('Break down'), emptyCard('This one’s already itemised', 'A receipt read from a photo already splits it into items.', h('a', { class: 'btn', href: `#/txn/${id}` }, 'Back')));
  }
  const rows = d.items.filter((i) => i.name !== 'Unsorted remainder' && i.category_id != null).map((i) => ({ category: categoryById(i.category_id), amount: String((i.price_sgd || i.price).toFixed(2)) }));
  if (!rows.length) rows.push({ category: null, amount: '' });

  const out = h('div', { class: 'stack' });
  const draw = () => {
    const assigned = rows.reduce((sum, r) => sum + (Number(r.amount) || 0), 0);
    const remaining = Math.round((total - assigned) * 100) / 100;
    const over = remaining < -0.005;
    fill(out, 
      h('div', { class: 'card stack tight' }, rows.map((row, i) => h('div', { class: 'break-row' },
        h('button', { class: 'chip-btn grow', onclick: () => pickCategory({ title: 'Category', selectedId: row.category && row.category.id, onPick: (cat) => { row.category = cat; draw(); } }) },
          row.category ? h('span', { class: 'chip cat', style: { '--c': categoryColor(row.category) } }, h('i', { class: 'dot' }), row.category.path.slice(-2).join(' › ')) : h('span', { class: 'muted' }, 'Choose category')),
        h('span', { class: 'money-input' }, '$', h('input', { type: 'number', min: '0', step: '0.01', inputMode: 'decimal', value: row.amount, placeholder: '0.00', 'aria-label': 'Amount', oninput: (e) => { row.amount = e.target.value; refreshSummary(); } })),
        h('button', { class: 'icon-btn', 'aria-label': 'Remove row', onclick: () => { rows.splice(i, 1); if (!rows.length) rows.push({ category: null, amount: '' }); draw(); } }, icon('close', 18)))),
        h('button', { class: 'btn', onclick: () => { rows.push({ category: null, amount: '' }); draw(); } }, '+ Add another')),
      h('div', { class: 'card soft', id: 'break-summary' }),
      h('button', { class: 'btn primary wide', id: 'break-save', onclick: save }, 'Save breakdown'));
    refreshSummary();
    void over;
  };
  const refreshSummary = () => {
    const assigned = rows.reduce((sum, r) => sum + (Number(r.amount) || 0), 0);
    const remaining = Math.round((total - assigned) * 100) / 100;
    const box = $('#break-summary');
    if (!box) return;
    box.replaceChildren(
      h('div', { class: 'list-row static' }, h('span', { class: 'grow' }, 'Charged'), h('strong', {}, money(total))),
      h('div', { class: 'list-row static' }, h('span', { class: 'grow' }, 'Assigned'), h('strong', {}, money(assigned))),
      h('div', { class: 'list-row static' }, h('span', { class: 'grow' }, remaining < -0.005 ? 'Over by' : 'Left as Unsorted'), h('strong', { class: remaining < -0.005 ? 'error-text' : '' }, money(Math.abs(remaining)))));
    const button = $('#break-save');
    if (button) button.disabled = assigned <= 0 || remaining < -0.005;
  };
  const save = async () => {
    const parts = rows.filter((r) => Number(r.amount) > 0).map((r) => ({ category_id: r.category ? r.category.id : null, amount_sgd: Number(r.amount), name: r.category ? r.category.name : null }));
    try { await post(`/api/transactions/${id}/breakdown`, { parts }); toast('Broken down'); go(`#/txn/${id}`); } catch (e) { fail(e); }
  };
  draw();

  return h('div', { class: 'screen' }, pageHeader('Break down'),
    h('div', { class: 'card soft' },
      h('p', { class: 'strong' }, `${t.description || 'Transaction'} · ${money(total)}`),
      h('p', { class: 'small muted' }, 'Say what this payment was made of, for example a Splitwise settlement covering food, transport and souvenirs. These amounts are the same money, not extra, so your total doesn’t change. Anything you leave out stays Unsorted.')),
    out);
}
route(/^\/breakdown\/(\d+)$/, 'activity', breakdownScreen);
