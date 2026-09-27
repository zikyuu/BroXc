'use strict';

/* Start-up: build the bottom navigation, load the category tree, and hand over to the router. */

const NAV = [
  ['home', '#/', 'home', 'Home'],
  ['activity', '#/activity', 'activity', 'Activity'],
  ['trip', '#/trips', 'trip', 'Trip'],
  ['reimburse', '#/reimburse', 'reimburse', 'Reimburse'],
  ['more', '#/more', 'more', 'More'],
];

async function init() {
  $('.bottom-nav').append(...NAV.map(([tab, href, iconName, label]) =>
    h('a', { href, 'data-tab': tab, 'aria-current': 'false' }, icon(iconName, 24), h('span', {}, label))));
  window.addEventListener('hashchange', () => renderRoute());
  try { await loadCategories(); } catch (error) { /* screens retry when they need it */ }
  await renderRoute();
}

init();
