'use strict';

/* Travel (by trip / by spending), trip detail, and Trip Mode. A trip is a context tag: the same
   transaction is "Food > Eat Out" and "Tallinn trip" at once, never counted twice. */

const TRIP_EMOJI = ['🏰', '🗼', '🏔️', '🏖️', '🌆', '🚂', '🎌', '🌲', '🛳️', '🎡'];
const TRIP_COLORS = ['#5d8df6', '#ff8a75', '#4fd1a5', '#b36cf0', '#ffb066', '#f58bd0'];
const tripColor = (trip) => trip.color || TRIP_COLORS[(trip.id || 0) % TRIP_COLORS.length];
const tripBanner = (trip) => `linear-gradient(135deg, ${tripColor(trip)}, color-mix(in srgb, ${tripColor(trip)} 45%, #ffffff))`;
const tripDates = (trip) => [trip.start_date, trip.end_date].filter(Boolean).map(shortDate).join(' – ') || 'No dates yet';

/* Create or edit a trip. */
function tripEditSheet(trip, { onDone } = {}) {
  const creating = !trip;
  const name = h('input', { type: 'text', value: creating ? '' : trip.name, placeholder: 'e.g. Tallinn trip', 'aria-label': 'Trip name' });
  const start = h('input', { type: 'date', value: creating ? '' : (trip.start_date || ''), 'aria-label': 'Start date' });
  const end = h('input', { type: 'date', value: creating ? '' : (trip.end_date || ''), 'aria-label': 'End date' });
  const activate = h('input', { type: 'checkbox', checked: true });
  let emoji = creating ? '🧳' : (trip.emoji || '🧳'), color = creating ? TRIP_COLORS[0] : tripColor(trip);
  const emojiRow = h('div', { class: 'chips' }), colorRow = h('div', { class: 'swatches' });
  const draw = () => {
    emojiRow.replaceChildren(...TRIP_EMOJI.map((e) => h('button', { class: 'chip', 'aria-pressed': String(e === emoji), onclick: () => { emoji = e; draw(); } }, e)));
    colorRow.replaceChildren(...TRIP_COLORS.map((c) => h('button', { class: `swatch${c === color ? ' on' : ''}`, style: { background: c }, 'aria-label': `Colour ${c}`, onclick: () => { color = c; draw(); } })));
  };
  draw();
  openSheet(creating ? 'New trip' : 'Trip settings', (close) => h('div', { class: 'stack' },
    h('label', {}, 'Name', name),
    h('div', { class: 'date-row' }, h('label', {}, 'Starts', start), h('label', {}, 'Ends', end)),
    h('label', {}, 'Icon', emojiRow),
    h('label', {}, 'Colour', colorRow),
    creating && h('label', { class: 'check-row' }, activate, h('span', {}, 'Turn on Trip Mode now (new transactions tag themselves)')),
    h('button', { class: 'btn primary wide', onclick: async () => {
      try {
        if (!name.value.trim()) throw new Error('Give the trip a name.');
        if (creating) await post('/api/trips', { name: name.value, start_date: start.value || null, end_date: end.value || null, activate: activate.checked, color, emoji });
        else await patch(`/api/trips/${trip.id}`, { name: name.value, start_date: start.value || null, end_date: end.value || null, color, emoji });
        toast(creating ? 'Trip created' : 'Saved');
        close();
        if (onDone) onDone(); else rerender();
      } catch (error) { fail(error); }
    } }, creating ? 'Create trip' : 'Save')));
}

/* ---------- Travel ---------- */

async function travelScreen(_, query) {
  const view = query.get('v') || 'trip';
  const data = await api('/api/travel');
  const max = Math.max(1, ...data.categories.map((c) => c.spend_sgd));
  const active = data.trips.find((t) => t.is_active);

  return h('div', { class: 'screen' },
    pageHeader('Travel', { back: false, right: h('button', { class: 'icon-btn', 'aria-label': 'New trip', onclick: () => tripEditSheet(null) }, icon('plus')) }),
    h('div', { class: 'cat-hero', style: { '--c': '#5d8df6' } },
      iconTile('✈️', '#5d8df6', 52),
      h('div', { class: 'grow' }, h('div', { class: 'big' }, money0(data.travel_total_sgd)), h('div', { class: 'muted small' }, `${data.share_of_spending}% of your spending`))),
    h('a', { class: `trip-banner${active ? '' : ' off'}`, href: '#/trip-mode' }, h('span', {}, '🧳'), h('span', { class: 'grow' }, active ? `Trip Mode is on · ${active.name}` : 'Trip Mode is off'), h('span', { class: 'cta-link' }, active ? 'Manage' : 'Turn on', icon('chevron', 14))),
    segmented([['trip', 'By trip'], ['spending', 'By spending']], view, (key) => replaceHash(`#/trips?v=${key}`)),
    view === 'trip'
      ? (data.trips.length
          ? h('div', { class: 'stack' }, data.trips.map((trip) => h('a', { class: 'trip-card', href: `#/trip/${trip.id}` },
              h('div', { class: 'trip-thumb', style: { background: tripBanner(trip) } }, trip.emoji || '🧳'),
              h('div', { class: 'grow' }, h('div', { class: 'strong' }, trip.name, trip.is_active && h('span', { class: 'chip mini good' }, 'on')), h('div', { class: 'muted small' }, tripDates(trip)), h('div', { class: 'strong' }, money0(trip.spend_sgd))),
              icon('chevron', 18))))
          : emptyCard('No trips yet', 'Create one, turn on Trip Mode, and new charges tag themselves.', h('button', { class: 'btn primary', onclick: () => tripEditSheet(null) }, 'Create a trip')))
      : (data.categories.length
          ? h('div', { class: 'card stack tight' }, data.categories.map((c) => h('div', { class: 'bar-row' },
              iconTile(c.icon, c.color, 34),
              h('div', { class: 'grow' }, h('div', { class: 'row-between' }, h('span', { class: 'strong' }, c.name), h('span', { class: 'strong' }, money0(c.spend_sgd))),
                h('div', { class: 'meter' }, h('i', { style: { width: `${(c.spend_sgd / max) * 100}%`, background: c.color || MISC_COLOR } }))))))
          : emptyCard('Nothing to group yet', 'Once trips have spending, it’s grouped by category here.')),
    h('p', { class: 'muted small centered' }, 'Same expenses, two ways of grouping them. Nothing is counted twice.'));
}
route(/^\/trips$/, 'trip', travelScreen);

/* ---------- Trip detail ---------- */

async function tripDetailScreen([id], query) {
  const tab = query.get('tab') || 'overview';
  if (!state.categories.length) await loadCategories();
  const d = await api(`/api/trips/${id}`);
  const trip = d.trip;
  const max = Math.max(1, ...d.categories.map((c) => c.total_sgd));

  return h('div', { class: 'screen' },
    pageHeader(trip.name, { right: h('button', { class: 'icon-btn', 'aria-label': 'Trip settings', onclick: () => tripEditSheet(trip) }, icon('edit')) }),
    h('div', { class: 'trip-hero', style: { background: tripBanner(trip) } },
      h('div', { class: 'big-emoji' }, trip.emoji || '🧳'),
      h('div', {}, h('div', { class: 'strong big-title' }, trip.name), h('div', { class: 'small' }, tripDates(trip)))),
    segmented([['overview', 'Overview'], ['transactions', 'Transactions']], tab, (key) => replaceHash(`#/trip/${id}?tab=${key}`)),
    tab === 'overview'
      ? h('div', { class: 'stack' },
          h('div', { class: 'two-up' },
            h('div', { class: 'card stat blue' }, h('div', { class: 'big' }, money(d.spend_sgd)), h('span', { class: 'muted small' }, 'Your spending')),
            h('div', { class: 'card stat orange' }, h('div', { class: 'big' }, money(d.fronted_sgd)), h('span', { class: 'muted small' }, 'You fronted for others'))),
          d.categories.length
            ? h('div', { class: 'card flush list' }, d.categories.map((c) => h('a', { class: 'list-row', href: `#/category/${c.id}?trip=${id}` },
                iconTile(c.icon, c.color, 34),
                h('div', { class: 'grow' }, h('div', { class: 'row-between' }, h('span', { class: 'strong' }, c.name), h('span', { class: 'strong' }, money0(c.total_sgd))),
                  h('div', { class: 'meter' }, h('i', { style: { width: `${(c.total_sgd / max) * 100}%`, background: c.color } }))),
                icon('chevron', 16))),
              d.unsorted_sgd > 0 && h('a', { class: 'list-row', href: `#/category/unsorted?trip=${id}` }, iconTile('?', MISC_COLOR, 34), h('span', { class: 'grow strong' }, 'Unsorted'), h('span', { class: 'strong' }, money0(d.unsorted_sgd)), icon('chevron', 16)))
            : emptyCard('No spending on this trip yet', trip.is_active ? 'Trip Mode is on, so new charges will land here.' : 'Turn on Trip Mode and new charges land here automatically.'),
          h('p', { class: 'muted small centered' }, 'Who owes what is tracked on the Reimburse tab, not per trip.'),
          h('a', { class: 'btn wide', href: '#/trip-mode' }, trip.is_active ? 'Manage Trip Mode' : 'Turn on Trip Mode for this trip'))
      : (d.transactions.length ? groupedFeed(d.transactions) : emptyCard('No transactions on this trip yet')));
}
route(/^\/trip\/(\d+)$/, 'trip', tripDetailScreen);

/* ---------- Trip Mode ---------- */

async function tripModeScreen(_, query) {
  if (!state.categories.length) await loadCategories();
  const trips = await api('/api/trips');
  const active = trips.find((t) => t.is_active);
  const chosen = trips.find((t) => String(t.id) === query.get('trip')) || active || trips[0] || null;

  const setOn = async (on) => {
    try {
      if (on) await post(`/api/trips/${chosen.id}/activate`, {});
      else await post('/api/trips/deactivate', {});
      toast(on ? `Trip Mode is on for ${chosen.name}` : 'Trip Mode is off');
      await rerender();
    } catch (error) { fail(error); }
  };
  const suggested = ['Food', 'Transport', 'Accommodation', 'Activities', 'Shopping', 'Souvenirs']
    .map((name) => state.categories.find((c) => c.name === name && c.parent_id == null)).filter(Boolean);

  if (!chosen) {
    return h('div', { class: 'screen' }, pageHeader('Trip Mode'),
      h('div', { class: 'card empty-state hero-empty' },
        h('div', { class: 'big-emoji' }, '🧳'),
        h('p', { class: 'strong' }, 'Set up before a trip'),
        h('p', { class: 'muted small' }, 'Create a trip and turn on Trip Mode. Every new transaction is tagged with it automatically, and you can untag anything unrelated, like rent.'),
        h('button', { class: 'btn primary', onclick: () => tripEditSheet(null) }, 'Create a trip')));
  }

  const isOn = !!(active && active.id === chosen.id);
  return h('div', { class: 'screen' },
    pageHeader('Trip Mode', { right: h('button', { class: 'icon-btn', 'aria-label': 'New trip', onclick: () => tripEditSheet(null) }, icon('plus')) }),
    h('div', { class: 'card toggle-card' },
      h('span', { class: 'small grow' }, 'Automatically tag new transactions with this trip'),
      h('button', { class: 'switch', role: 'switch', 'aria-checked': String(isOn), 'aria-label': 'Trip Mode', onclick: () => setOn(!isOn) }, h('i', {}))),
    h('a', { class: 'trip-hero', href: `#/trip/${chosen.id}`, style: { background: tripBanner(chosen) } },
      h('div', { class: 'big-emoji' }, chosen.emoji || '🧳'),
      h('div', {}, h('div', { class: 'strong big-title' }, chosen.name), h('div', { class: 'small' }, tripDates(chosen)))),
    trips.length > 1 && h('div', { class: 'chips scroll-x' }, trips.map((t) => h('button', { class: 'chip', 'aria-pressed': String(t.id === chosen.id), onclick: () => replaceHash(`#/trip-mode?trip=${t.id}`) }, `${t.emoji || '🧳'} ${t.name}`))),
    h('div', { class: `card status-card ${isOn ? 'on' : 'off'}` },
      h('p', { class: 'strong' }, isOn ? '✅ Trip Mode is ON' : 'Trip Mode is OFF'),
      h('p', { class: 'small' }, isOn ? `New transactions will be tagged with “${chosen.name}”. You can uncheck ones that don’t belong, like rent.` : active ? `Trip Mode is on for “${active.name}”. Turning it on here switches it over.` : 'Turn it on and new transactions tag themselves with this trip.')),
    h('div', { class: 'card flush list' },
      h('button', { class: 'list-row', onclick: () => tripEditSheet(chosen) }, icon('tune', 18), h('span', { class: 'grow' }, 'Trip settings'), icon('chevron', 16))),
    suggested.length > 0 && h('div', { class: 'card' },
      h('h3', {}, 'Suggested categories'),
      h('div', { class: 'cat-grid' }, suggested.map((c) => h('a', { class: 'cat-cell', href: `#/category/${c.id}?trip=${chosen.id}` }, iconTile(c.icon, c.color, 44), h('span', { class: 'small' }, c.name)))),
      h('p', { class: 'muted small' }, 'Tap one to see what this trip spent there. Your own categories work as usual.')),
    h('div', { class: 'card flush list' },
      h('a', { class: 'list-row', href: '#/categories' }, icon('edit', 18), h('span', { class: 'grow' }, 'Customise categories'), icon('chevron', 16))));
}
route(/^\/trip-mode$/, 'trip', tripModeScreen);
