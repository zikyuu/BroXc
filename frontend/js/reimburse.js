'use strict';

/* Reimbursements: one pooled "owed back" balance, not per-person debts. Paid-for-others entries raise
   it, reimbursements lower it. When it hits $0 that's a settled checkpoint; after that only newer
   paid-for-others entries are shown, which is enough to jog your memory about who hasn't paid. */

function activityRow(entry, kind) {
  const paid = kind === 'paid';
  const target = paid ? (entry.transaction_id != null ? `#/txn/${entry.transaction_id}` : null) : `#/txn/${entry.id}`;
  const body = [
    h('span', { class: `pill-amount ${paid ? 'out' : 'in'}` }, paid ? `−${money0(entry.others_sgd)}` : money(entry.amount_sgd, { sign: true }).replace(/\.00$/, '')),
    h('div', { class: 'grow' },
      h('div', { class: 'strong ellipsis' }, paid ? [entry.merchant && entry.merchant !== 'No receipt yet' ? entry.merchant : entry.name, entry.trip && ` · ${entry.trip}`].filter(Boolean).join('') : (entry.description || 'Payment received')),
      h('div', { class: 'muted small' }, paid ? 'Paid for others' : 'Reimbursement')),
    h('span', { class: 'muted small' }, shortDate(entry.date)),
    target && icon('chevron', 16)];
  return target ? h('a', { class: 'activity-line', href: target }, body) : h('div', { class: 'activity-line' }, body);
}

async function reimburseScreen(_, query) {
  const tab = query.get('t') || 'owed';
  const all = query.get('all') === '1';
  const data = await api('/api/reimbursements');
  const since = data.since_checkpoint;
  const recent = [
    ...since.paid_items.map((e) => ({ kind: 'paid', date: e.date || '', entry: e })),
    ...since.reimbursements.map((e) => ({ kind: 'in', date: e.date || '', entry: e })),
  ].sort((a, b) => b.date.localeCompare(a.date));
  const owed = data.outstanding_sgd;

  const card = data.over_reimbursed
    ? h('div', { class: 'card owed-card over' }, h('div', { class: 'big' }, money0(-owed)), h('div', { class: 'muted' }, 'received beyond what you were owed'),
        h('p', { class: 'small' }, 'Open the reimbursement that pushed it over and tell the app how to treat the extra, or that earlier records were incomplete.'))
    : data.settled || owed <= 0.005
      ? h('div', { class: 'card owed-card settled' }, h('div', { class: 'big-emoji' }, '🎉'), h('div', { class: 'big' }, 'All settled'), h('div', { class: 'muted' }, nothingOwedText(data)))
      : h('div', { class: 'card owed-card' },
          h('div', { class: 'big' }, money0(owed)), h('div', { class: 'muted' }, 'owed back to you'),
          since.paid_items.length > 0 && h('p', { class: 'small muted' }, data.last_checkpoint ? `Since everything was last settled on ${longDate(data.last_checkpoint)}` : 'Across everything you’ve fronted so far'),
          h('a', { class: 'btn primary wide', href: '#/activity?f=in' }, 'View money in'));

  const shown = all ? recent : recent.slice(0, 5);
  let body;
  if (tab === 'history') {
    const earlier = [
      ...data.earlier.paid_items.map((e) => ({ kind: 'paid', date: e.date || '', entry: e })),
      ...data.earlier.reimbursements.map((e) => ({ kind: 'in', date: e.date || '', entry: e })),
    ].sort((a, b) => b.date.localeCompare(a.date));
    body = h('div', { class: 'stack' },
      data.checkpoints.length
        ? h('div', { class: 'card flush list' }, data.checkpoints.map((c) => h('div', { class: 'list-row static' },
            h('span', { class: 'good-dot' }), h('span', { class: 'grow' }, `Settled ${longDate(c.reached_at)}`, h('small', { class: 'muted block' }, `${money0(c.paid_total)} fronted · ${money0(c.received_total)} received`)))))
        : emptyCard('No settled periods yet', 'Each time your balance returns to $0, it’s recorded here.'),
      earlier.length > 0 && sectionTitle('Earlier activity'),
      earlier.length > 0 && h('div', { class: 'card flush' }, earlier.map((r) => activityRow(r.entry, r.kind))));
  } else {
    body = h('div', { class: 'stack' },
      card,
      sectionTitle('Recent activity', recent.length > 5 ? h('a', { class: 'link small', href: `#/reimburse?all=${all ? 0 : 1}` }, all ? 'Show fewer' : 'See all') : null),
      shown.length
        ? h('div', { class: 'card flush' }, shown.map((r) => activityRow(r.entry, r.kind)))
        : h('p', { class: 'muted small' }, 'Nothing paid for others yet. Open a transaction and use “Split / Paid for others”.'),
      h('div', { class: 'card tip' }, h('span', {}, '💡'), h('div', {}, h('strong', {}, 'Tip'), h('p', { class: 'small' }, 'When money arrives from a friend, open it and mark it as a reimbursement. That lowers what you’re owed without touching your spending.'))));
  }

  return h('div', { class: 'screen' },
    pageHeader('Reimbursement', { back: false }),
    segmented([['owed', 'Owed back to you'], ['history', 'History']], tab, (key) => replaceHash(`#/reimburse?t=${key}`)),
    body);
}
const nothingOwedText = (data) => (data.received_sgd > 0 ? `${money0(data.received_sgd)} paid back so far` : 'Nobody owes you anything');
route(/^\/reimburse$/, 'reimburse', reimburseScreen);
