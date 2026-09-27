'use strict';

/* Home: the radial spending map, then the four context cards (This Month, At This Pace,
   Needs a Look, Compared With Usual) and recent activity. */

function legend() {
  return h('div', { class: 'legend' },
    h('span', {}, h('i', { class: 'lg-actual' }), 'Actual'),
    h('span', {}, h('i', { class: 'lg-budget' }), 'Budget (target)'),
    h('span', {}, h('i', { class: 'lg-usual' }), 'Usual (average)'));
}

function monthSwitcher(home) {
  const step = (month) => { state.month = month; rerender(); };
  return h('div', { class: 'month-switch' },
    h('button', { class: 'icon-btn', 'aria-label': 'Previous month', disabled: !home.prev_month, onclick: () => step(home.prev_month) }, icon('back', 20)),
    h('span', { class: 'strong' }, home.label),
    h('button', { class: 'icon-btn', 'aria-label': 'Next month', disabled: !home.next_month, onclick: () => step(home.next_month) }, icon('chevron', 20)));
}

function thisMonthCard(home) {
  const t = home.this_month;
  return h('section', { class: 'card tile-card' },
    h('h3', {}, 'This month'),
    h('div', { class: 'big' }, money0(t.spent_sgd)),
    h('p', { class: 'muted small' }, 'spent by you'),
    h('a', { class: 'mini-stat blue', href: '#/balance' },
      h('strong', {}, t.balance ? money0(t.balance.implied_sgd) : 'Check'),
      h('span', {}, t.balance ? 'actual balance' : 'your balance')),
    h('a', { class: `mini-stat orange${t.owed_back_sgd > 0 ? '' : ' quiet'}`, href: '#/reimburse' },
      h('strong', {}, money0(t.owed_back_sgd)),
      h('span', {}, 'owed back to you')));
}

function paceCard(home) {
  const pace = home.pace;
  const days = pace.days_in_month;
  const today = home.elapsed_days;
  const actual = pace.actual.map((v) => v);
  const projection = Array.from({ length: days }, (_, i) => {
    if (i + 1 < today || !actual.length) return null;
    const last = actual[actual.length - 1];
    return last + ((pace.projected_sgd - last) * (i + 1 - today)) / Math.max(1, days - today);
  });
  const series = [];
  if (pace.usual.length) series.push({ points: pace.usual, color: 'var(--muted-line)', width: 2 });
  if (actual.length) series.push({ points: actual, color: 'var(--accent)', width: 3, area: true });
  if (home.elapsed_fraction < 1 && actual.length) series.push({ points: projection, color: 'var(--accent)', dashed: true, width: 2 });
  const top = Math.max(1, pace.projected_sgd, ...(pace.usual.length ? [pace.usual[pace.usual.length - 1]] : []), ...actual) * 1.05;

  return h('section', { class: 'card tile-card' },
    h('h3', {}, home.is_current ? 'At this pace' : 'Month total'),
    h('div', { class: 'big' }, money0(pace.projected_sgd)),
    h('p', { class: 'muted small' }, home.is_current ? 'projected spend' : 'spent'),
    series.length ? lineChart({ series, xCount: days, yMax: top, width: 200, height: 84, axes: false }) : h('p', { class: 'muted small' }, 'Builds up as you add spending.'),
    pace.balance_after_sgd != null && h('p', { class: 'muted small' }, `≈ ${money0(pace.balance_after_sgd)} left by month end`));
}

function needsLookCard(home) {
  const n = home.needs_look;
  const total = n.uncertain_sgd + n.confident_sgd;
  if (!total && !n.matches) {
    return h('section', { class: 'card tile-card' }, h('h3', {}, 'Needs a look'), h('p', { class: 'muted small' }, 'Nothing yet. Add a receipt or a YouTrip screenshot.'));
  }
  return h('a', { class: 'card tile-card link-card warm', href: '#/review' },
    h('h3', {}, 'Needs a look'),
    h('div', { class: 'big' }, money0(n.uncertain_sgd)),
    h('p', { class: 'muted small' }, 'could use a look'),
    h('p', { class: 'small' }, `${money0(n.confident_sgd)} confidently understood`),
    h('ul', { class: 'facts' },
      n.suggestions > 0 && h('li', {}, `${n.suggestions} suggestion${n.suggestions === 1 ? '' : 's'}`),
      n.unknown > 0 && h('li', {}, `${n.unknown} unknown`),
      n.matches > 0 && h('li', {}, `${n.matches} match${n.matches === 1 ? '' : 'es'} to check`)),
    h('span', { class: 'cta-link' }, 'Review ', icon('chevron', 14)));
}

function comparedCard(home) {
  return h('section', { class: 'card tile-card' },
    h('h3', {}, 'Compared with usual'),
    home.compared.length
      ? h('div', { class: 'compare' }, home.compared.map((c) => h('a', { class: 'compare-row', href: `#/category/${c.id}` },
          h('span', { class: 'dot', style: { background: c.color } }), h('span', { class: 'grow ellipsis' }, c.name),
          h('strong', { class: c.delta_sgd > 0 ? 'up' : 'down' }, `${c.delta_sgd > 0 ? '+' : '−'}${money0(Math.abs(c.delta_sgd))}`))))
      : h('p', { class: 'muted small' }, home.usual_months ? 'Right in line with usual.' : 'Needs a month or two of history to know what’s usual for you.'),
    h('a', { class: 'cta-link', href: '#/trends' }, 'See more ', icon('chevron', 14)));
}

async function homeScreen(_, query) {
  if (query.get('m')) state.month = query.get('m');
  const home = await api(`/api/home${state.month ? `?month=${state.month}` : ''}`);
  state.month = home.is_current ? null : home.month; // null means "this month", so it keeps following the calendar
  state.activeTrip = home.active_trip;

  if (!home.has_data) {
    return h('div', { class: 'screen' },
      h('div', { class: 'home-top' }, h('span', { class: 'icon-spacer' }), h('span', { class: 'strong' }, 'Welcome'), h('a', { class: 'icon-btn', href: '#/more', 'aria-label': 'More' }, icon('gear'))),
      h('div', { class: 'card empty-state hero-empty' },
        h('div', { class: 'big-emoji' }, '🌱'),
        h('p', { class: 'strong' }, 'Nothing tracked yet'),
        h('p', { class: 'muted small' }, 'Screenshot your YouTrip transactions and any receipts. The app pieces together your spending from that, and you only correct what matters.'),
        h('a', { class: 'btn primary', href: '#/add' }, 'Add your first screenshots')));
  }

  return h('div', { class: 'screen home' },
    h('div', { class: 'home-top' },
      h('a', { class: 'icon-btn', href: '#/search', 'aria-label': 'Search' }, icon('search')),
      monthSwitcher(home),
      h('a', { class: 'icon-btn', href: '#/more', 'aria-label': 'More' }, icon('gear'))),
    home.active_trip && h('a', { class: 'trip-banner', href: '#/trip-mode' }, h('span', {}, '🧳'), h('span', { class: 'grow' }, `Trip Mode is on · ${home.active_trip.name}`), icon('chevron', 16)),
    h('div', { class: 'radial-wrap' }, radialChart(home)),
    legend(),
    home.untracked_sgd > 0 && h('p', { class: 'muted small centered' }, `Includes ${money0(home.untracked_sgd)} of untracked money: the balance shows it left, but there’s no record of where.`),
    h('div', { class: 'card-grid' }, thisMonthCard(home), paceCard(home), needsLookCard(home), comparedCard(home)),
    sectionTitle('Recent transactions', h('a', { class: 'link small', href: '#/activity' }, 'See all')),
    home.recent.length ? h('div', { class: 'card flush' }, home.recent.map((e) => txnRow(e, { showDate: true }))) : h('p', { class: 'muted small' }, 'Nothing yet.'));
}

route(/^\/$/, 'home', homeScreen);
