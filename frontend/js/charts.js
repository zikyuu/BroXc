'use strict';

/* Hand-drawn SVG charts (no library): the radial spending map, line charts, and the
   semi-proportional tile layout. */

const TAU = Math.PI * 2;
const clamp = (value, lo, hi) => Math.min(hi, Math.max(lo, value));
const polar = (cx, cy, r, angle) => [cx + r * Math.cos(angle), cy + r * Math.sin(angle)];
const STATUS_COLOR = { good: '#34c38f', watch: '#f5a623', over: '#ef6b5b', neutral: '#8a8177' };

/* An annular sector from radius r0 to r1 between two angles (radians, clockwise from the +x axis). */
function sectorPath(cx, cy, r0, r1, a0, a1) {
  const large = a1 - a0 > Math.PI ? 1 : 0;
  const [x0, y0] = polar(cx, cy, r1, a0);
  const [x1, y1] = polar(cx, cy, r1, a1);
  const [x2, y2] = polar(cx, cy, r0, a1);
  const [x3, y3] = polar(cx, cy, r0, a0);
  return `M${x0.toFixed(2)} ${y0.toFixed(2)}A${r1} ${r1} 0 ${large} 1 ${x1.toFixed(2)} ${y1.toFixed(2)}`
    + `L${x2.toFixed(2)} ${y2.toFixed(2)}A${r0} ${r0} 0 ${large} 0 ${x3.toFixed(2)} ${y3.toFixed(2)}Z`;
}

/* ---------- radial spending map ----------
   angle  = how much was spent (approximately: every wedge gets a minimum so a small category stays tappable)
   radius = spend against the green reference (budget, else usual) - beyond the green line means over
   colour = which category, always the same one; the wedge is never recoloured to judge it */
function radialChart(home, { onSelect } = {}) {
  const SIZE = 360, C = SIZE / 2, R_IN = 74, R_REF = 122, GAP = 0.03;

  const wedges = home.categories.filter((c) => c.actual_sgd > 0).map((c) => ({ ...c, target: `#/category/${c.id}`, label: c.name }));
  if (home.unsorted_sgd > 0) wedges.push({ id: null, name: 'Unsorted', icon: '', color: '#e3d5b4', actual_sgd: home.unsorted_sgd, reference_sgd: null, kind: 'unsorted', target: '#/category/unsorted', label: 'Unsorted' });
  if (home.untracked_sgd > 0) wedges.push({ id: null, name: 'Untracked', icon: '?', color: '#d9d6d0', actual_sgd: home.untracked_sgd, reference_sgd: null, kind: 'untracked', target: '#/balance', label: 'Untracked' });

  const root = svg('svg', { class: 'radial', viewBox: '22 22 316 316', role: 'img', 'aria-label': `Spending map: ${money0(home.total_sgd)} this month` });
  const weightTotal = wedges.reduce((sum, w) => sum + w.actual_sgd, 0);

  if (weightTotal > 0) {
    const n = wedges.length;
    const minAngle = Math.min(0.46, (TAU * 0.5) / n);           // no wedge thinner than ~26 degrees (fewer if crowded)
    const spare = TAU - n * GAP - n * minAngle;                 // the rest is shared out by real amount
    let angle = -Math.PI / 2;
    wedges.forEach((w, i) => {
      const span = minAngle + spare * (w.actual_sgd / weightTotal);
      const a0 = angle + GAP / 2, a1 = angle + span - GAP / 2;
      angle += span + GAP;
      const mid = (a0 + a1) / 2;

      const ratio = w.reference_sgd ? w.actual_sgd / w.reference_sgd : 1;
      const outer = R_IN + (R_REF - R_IN) * clamp(ratio, 0.5, 1.55);
      const inset = 5; // the stroke below rounds the corners, so the fill is drawn this much smaller
      const fill = w.color || '#a9a39a';

      const wedge = svg('g', {
        class: 'wedge', tabindex: 0, role: 'link', style: `animation-delay:${i * 45}ms`,
        'aria-label': `${w.name} ${money0(w.actual_sgd)}${w.reference_sgd ? `, ${Math.round(ratio * 100)}% of ${w.reference_kind || 'usual'}` : ''}`,
        onclick: () => (onSelect ? onSelect(w) : go(w.target)),
        onkeydown: (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); go(w.target); } },
      },
        svg('path', {
          d: sectorPath(C, C, R_IN + inset, outer - inset, a0 + inset / R_IN * 0.6, a1 - inset / R_IN * 0.6),
          fill, stroke: fill, 'stroke-width': inset * 2, 'stroke-linejoin': 'round',
        }));

      // where usual sits, when the reference is a budget (otherwise usual *is* the green line)
      if (w.reference_kind === 'budget' && w.usual_sgd) {
        const ru = R_IN + (R_REF - R_IN) * clamp(w.usual_sgd / w.reference_sgd, 0.5, 1.55);
        const [ux0, uy0] = polar(C, C, ru, a0 + 0.06), [ux1, uy1] = polar(C, C, ru, a1 - 0.06);
        wedge.append(svg('path', { d: `M${ux0} ${uy0}A${ru} ${ru} 0 0 1 ${ux1} ${uy1}`, class: 'usual-mark', fill: 'none' }));
      }

      const labelR = (R_IN + outer) / 2 + 2;
      const [lx, ly] = polar(C, C, labelR, mid);
      const wide = (a1 - a0) > 0.5;
      if (w.icon && wide) wedge.append(svg('text', { x: lx, y: ly - 7, class: 'wedge-icon', 'text-anchor': 'middle' }, w.icon));
      wedge.append(svg('text', { x: lx, y: ly + (w.icon && wide ? 8 : 4), class: 'wedge-amount', 'text-anchor': 'middle' }, money0(w.actual_sgd)));
      if (w.kind === 'unsorted' && wide) wedge.append(svg('text', { x: lx, y: ly + 20, class: 'wedge-caption', 'text-anchor': 'middle' }, 'Unsorted'));
      root.append(wedge);
    });
  } else {
    root.append(svg('circle', { cx: C, cy: C, r: (R_IN + R_REF) / 2, fill: 'none', stroke: 'var(--line)', 'stroke-width': 22, 'stroke-dasharray': '3 9', 'stroke-linecap': 'round' }));
  }

  // the green line: where a category lands when it sits exactly on budget / usual - slightly wavy, hand-drawn feeling
  const points = [];
  for (let i = 0; i <= 180; i++) {
    const a = (i / 180) * TAU;
    const r = R_REF + 2.2 * Math.sin(a * 22);
    points.push(polar(C, C, r, a).map((v) => v.toFixed(1)).join(' '));
  }
  root.append(svg('path', { d: `M${points.join('L')}Z`, class: 'budget-ring', fill: 'none' }));

  // centre: month progress ring (colour = projected trajectory) around the total
  const RING = 56;
  root.append(svg('circle', { cx: C, cy: C, r: RING, fill: 'var(--surface)' }));
  root.append(svg('circle', { cx: C, cy: C, r: RING - 2, fill: 'none', stroke: 'var(--line)', 'stroke-width': 8 }));
  if (home.elapsed_fraction > 0) {
    root.append(svg('circle', {
      cx: C, cy: C, r: RING - 2, fill: 'none', stroke: STATUS_COLOR[home.status] || STATUS_COLOR.neutral, 'stroke-width': 8, 'stroke-linecap': 'round',
      'stroke-dasharray': `${(TAU * (RING - 2)) * Math.min(home.elapsed_fraction, 0.999)} ${TAU * (RING - 2)}`,
      transform: `rotate(-90 ${C} ${C})`, class: 'progress-ring',
    }));
  }
  root.append(svg('text', { x: C, y: C - 16, class: 'centre-date', 'text-anchor': 'middle' }, home.day_label));
  root.append(svg('text', { x: C, y: C + 6, class: 'centre-total', 'text-anchor': 'middle' }, money0(home.total_sgd)));
  root.append(svg('text', { x: C, y: C + 22, class: 'centre-caption', 'text-anchor': 'middle' }, 'your spending'));
  return root;
}

/* ---------- line chart ----------
   series: [{points: [number|null], color, dashed, width, area}] - index = x position (0..xCount-1)
   Draws a soft grid, optional axis labels, and a hover readout that snaps to the nearest x. */
function lineChart({ series, xCount, yMax, width = 320, height = 150, axes = true, xLabels = [], formatY = money0, hoverLabel, marker }) {
  const pad = axes ? { l: 40, r: 10, t: 12, b: 24 } : { l: 4, r: 4, t: 6, b: 6 };
  const w = width - pad.l - pad.r, ht = height - pad.t - pad.b;
  const top = yMax || Math.max(1, ...series.flatMap((s) => s.points.filter((p) => p != null)));
  const x = (i) => pad.l + (xCount <= 1 ? w / 2 : (i / (xCount - 1)) * w);
  const y = (v) => pad.t + ht - (clamp(v, 0, top) / top) * ht;

  const root = svg('svg', { class: 'line-chart', viewBox: `0 0 ${width} ${height}`, preserveAspectRatio: 'xMidYMid meet' });
  if (axes) {
    for (let t = 0; t <= 3; t++) {
      const value = (top / 3) * t;
      root.append(svg('line', { x1: pad.l, x2: width - pad.r, y1: y(value), y2: y(value), class: 'grid' }));
      root.append(svg('text', { x: pad.l - 6, y: y(value) + 4, class: 'axis', 'text-anchor': 'end' }, formatY(value)));
    }
    xLabels.forEach(({ index, text }) => root.append(svg('text', { x: x(index), y: height - 6, class: 'axis', 'text-anchor': 'middle' }, text)));
  }

  for (const s of series) {
    const pts = s.points.map((v, i) => (v == null ? null : [x(i), y(v)]));
    let d = '', pen = false;
    pts.forEach((p) => { if (!p) { pen = false; return; } d += `${pen ? 'L' : 'M'}${p[0].toFixed(1)} ${p[1].toFixed(1)}`; pen = true; });
    if (s.area && pts.some(Boolean)) {
      const known = pts.filter(Boolean);
      root.append(svg('path', { d: `${d}L${known[known.length - 1][0]} ${y(0)}L${known[0][0]} ${y(0)}Z`, fill: s.color, opacity: 0.12 }));
    }
    root.append(svg('path', { d, fill: 'none', stroke: s.color, 'stroke-width': s.width || 2.5, 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'stroke-dasharray': s.dashed ? '5 5' : null }));
    if (s.dots) pts.forEach((p) => p && root.append(svg('circle', { cx: p[0], cy: p[1], r: 3.2, fill: s.color })));
  }
  const markerSeries = series[series.length - 1]; // the last series is the one being tracked (this month), drawn over the reference lines
  if (marker != null && markerSeries.points[marker] != null) {
    root.append(svg('circle', { cx: x(marker), cy: y(markerSeries.points[marker]), r: 5, fill: 'var(--surface)', stroke: markerSeries.color, 'stroke-width': 2.5 }));
  }

  if (hoverLabel) { // tap or hover anywhere to read the value at the nearest x
    const cursor = svg('line', { class: 'cursor', y1: pad.t, y2: pad.t + ht, opacity: 0 });
    const tip = svg('text', { class: 'tip', 'text-anchor': 'middle', opacity: 0 });
    root.append(cursor, tip);
    const show = (event) => {
      const box = root.getBoundingClientRect();
      const px = ((event.clientX - box.left) / box.width) * width;
      const i = clamp(Math.round(((px - pad.l) / w) * (xCount - 1)), 0, xCount - 1);
      cursor.setAttribute('x1', x(i)); cursor.setAttribute('x2', x(i)); cursor.setAttribute('opacity', 1);
      tip.textContent = hoverLabel(i); tip.setAttribute('x', clamp(x(i), 60, width - 60)); tip.setAttribute('y', pad.t + 10); tip.setAttribute('opacity', 1);
    };
    root.addEventListener('pointermove', show);
    root.addEventListener('pointerdown', show);
    root.addEventListener('pointerleave', () => { cursor.setAttribute('opacity', 0); tip.setAttribute('opacity', 0); });
  }
  return root;
}

/* ---------- semi-proportional tiles ----------
   A pure treemap would make a $2 category a sliver nobody can tap. Each tile's weight is floored
   at a share of the total, so size still reflects importance but never drops below a usable minimum. */
function tileLayout(nodes, { minShare = 0.09 } = {}) {
  const total = nodes.reduce((sum, n) => sum + Math.max(n.total_sgd, 0), 0) || 1;
  const weighted = nodes.map((n) => ({ node: n, weight: Math.max(n.total_sgd, total * (n.total_sgd > 0 ? minShare : minShare * 0.75)) }));
  const rects = [];
  (function split(list, x, y, w, ht) {
    if (!list.length) return;
    if (list.length === 1) { rects.push({ node: list[0].node, x, y, w, h: ht }); return; }
    const sum = list.reduce((s, item) => s + item.weight, 0);
    let acc = 0, cut = 1;
    for (let i = 0; i < list.length - 1; i++) { acc += list[i].weight; cut = i + 1; if (acc >= sum / 2) break; }
    const left = list.slice(0, cut), right = list.slice(cut);
    const share = left.reduce((s, item) => s + item.weight, 0) / sum;
    if (w >= ht) { split(left, x, y, w * share, ht); split(right, x + w * share, y, w * (1 - share), ht); }
    else { split(left, x, y, w, ht * share); split(right, x, y + ht * share, w, ht * (1 - share)); }
  })(weighted, 0, 0, 1, 1);
  return rects;
}

/* Small bar list used for weekday patterns. */
function miniBars(values, { color = 'var(--accent)', height = 56 } = {}) {
  const max = Math.max(1, ...values.map((v) => v.value));
  return h('div', { class: 'mini-bars', style: { height: `${height + 22}px` } }, values.map((v) =>
    h('div', { class: 'mini-bar' },
      h('div', { class: 'bar-track', style: { height: `${height}px` } }, h('div', { class: 'bar-fill', style: { height: `${(v.value / max) * 100}%`, background: v.color || color } })),
      h('span', {}, v.label))));
}
