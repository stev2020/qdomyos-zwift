// FunRun routes: everything needed to offer new routes in the "Entdecken" tab and to estimate ride times.
//  - signposted cycle routes of OpenStreetMap around a place (Waymarked Trails), long ones as stages
//  - the climbs catalog (katalog.json), routed with BRouter
//  - heights from the Terrarium terrain tiles (AWS open data), smoothed for the bike's resistance
//  - GPX writer, outline and profile as the app computes them for its own routes
//  - ride time estimate: speed on the flat and climbing rate (fixed or learned from the last 10 rides)
// No dependency on the app: works in any browser (tests). Plain string handling, no regular expressions.
(function () {
  'use strict';
  const RT = (window.FRR = {});
  const R = 6371008.8, DEG = Math.PI / 180, MR = 6378137;

  // ------------------------------------------------------------------ geometry ([lat, lon] points)
  RT.dist = (a, b) => {
    const dLat = (b[0] - a[0]) * DEG, dLon = (b[1] - a[1]) * DEG;
    const x = Math.sin(dLat / 2) ** 2 + Math.cos(a[0] * DEG) * Math.cos(b[0] * DEG) * Math.sin(dLon / 2) ** 2;
    return 2 * R * Math.asin(Math.min(1, Math.sqrt(x)));
  };
  // Web Mercator (EPSG:3857, as Waymarked Trails sends it) <-> [lat, lon]
  RT.fromMerc = (x, y) => [(2 * Math.atan(Math.exp(y / MR)) - Math.PI / 2) / DEG, x / MR / DEG];
  RT.toMerc = (lat, lon) => [lon * DEG * MR, Math.log(Math.tan(Math.PI / 4 + lat * DEG / 2)) * MR];
  // distance from the start for every point
  RT.cum = pts => {
    const s = new Float64Array(pts.length);
    for (let i = 1; i < pts.length; i++) s[i] = s[i - 1] + RT.dist(pts[i - 1], pts[i]);
    return s;
  };
  // index of the segment that holds distance d (s ascending)
  function seg(s, d) {
    let lo = 0, hi = s.length - 1;
    if (d <= s[0]) return 0;
    if (d >= s[hi]) return Math.max(0, hi - 1);
    while (hi - lo > 1) { const m = (lo + hi) >> 1; if (s[m] <= d) lo = m; else hi = m; }
    return lo;
  }
  // point at distance d along pts (with heights if they have one)
  RT.at = (pts, s, d) => {
    const i = seg(s, d), j = Math.min(i + 1, pts.length - 1), l = s[j] - s[i];
    const u = l > 0 ? Math.max(0, Math.min(1, (d - s[i]) / l)) : 0, a = pts[i], b = pts[j];
    const p = [a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u];
    if (a.length > 2) p.push(a[2] + (b[2] - a[2]) * u);
    return p;
  };
  // points every `step` metres from 0 to the end (the last one exactly at the end)
  RT.resample = (pts, s, step) => {
    const total = s[s.length - 1], n = Math.max(1, Math.round(total / step)), st = total / n, out = [];
    for (let k = 0; k <= n; k++) out.push(RT.at(pts, s, k * st));
    return { pts: out, step: st };
  };
  // part of a line between two distances (a > b: driven the other way round)
  RT.cut = (pts, s, a, b) => {
    const lo = Math.min(a, b), hi = Math.max(a, b), out = [RT.at(pts, s, lo)];
    for (let i = 0; i < pts.length; i++) if (s[i] > lo && s[i] < hi) out.push(pts[i]);
    out.push(RT.at(pts, s, hi));
    return a <= b ? out : out.reverse();
  };
  // nearest point of the line to p: { d (along the line), off (metres away) }
  RT.nearest = (pts, s, p) => {
    const ky = R * DEG, kx = R * DEG * Math.cos(p[0] * DEG);
    let best = 1e18, bestD = 0;
    for (let i = 0; i + 1 < pts.length; i++) {
      const ax = (pts[i][1] - p[1]) * kx, ay = (pts[i][0] - p[0]) * ky;
      const dx = (pts[i + 1][1] - pts[i][1]) * kx, dy = (pts[i + 1][0] - pts[i][0]) * ky, l2 = dx * dx + dy * dy;
      const t = l2 > 0 ? Math.max(0, Math.min(1, -(ax * dx + ay * dy) / l2)) : 0;
      const qx = ax + t * dx, qy = ay + t * dy, d2 = qx * qx + qy * qy;
      if (d2 < best) { best = d2; bestD = s[i] + t * (s[i + 1] - s[i]); }
    }
    return { d: bestD, off: Math.sqrt(best) };
  };

  // ------------------------------------------------------------------ heights
  // gaussian smoothing; odd reflection at both ends keeps the end heights and the slope there
  RT.gauss = (v, sig) => {
    if (!(sig > 0.3)) return Array.from(v);
    const r = Math.ceil(3 * sig), n = v.length, w = [];
    for (let j = -r; j <= r; j++) w.push(Math.exp(-0.5 * (j / sig) ** 2));
    const val = k => (k < 0 ? 2 * v[0] - v[Math.min(n - 1, -k)] : k >= n ? 2 * v[n - 1] - v[Math.max(0, 2 * (n - 1) - k)] : v[k]);
    const out = new Array(n);
    for (let i = 0; i < n; i++) {
      let acc = 0, ws = 0;
      for (let j = -r; j <= r; j++) { acc += w[j + r] * val(i + j); ws += w[j + r]; }
      out[i] = acc / ws;
    }
    return out;
  };
  // closest never-falling sequence (pool adjacent violators): a pure climb without the dips of noisy heights
  RT.isotonic = v => {
    const blocks = [];
    for (const x of v) {
      blocks.push([x, 1]);
      while (blocks.length > 1 && blocks[blocks.length - 2][0] / blocks[blocks.length - 2][1] > blocks[blocks.length - 1][0] / blocks[blocks.length - 1][1]) {
        const b = blocks.pop();
        blocks[blocks.length - 1][0] += b[0]; blocks[blocks.length - 1][1] += b[1];
      }
    }
    const out = [];
    for (const [sm, c] of blocks) for (let k = 0; k < c; k++) out.push(sm / c);
    return out;
  };
  // running median (odd window in points): removes single wrong heights before the smoothing
  RT.median = (v, w) => {
    const h = Math.floor(w / 2), n = v.length, out = new Array(n);
    for (let i = 0; i < n; i++) {
      const win = [];
      for (let k = Math.max(0, i - h); k <= Math.min(n - 1, i + h); k++) win.push(v[k]);
      win.sort((a, b) => a - b);
      out[i] = win[win.length >> 1];
    }
    return out;
  };
  // tunnels and bridges: the terrain data has the mountain above or the valley below; the road runs straight from end to end.
  // spans: [[from, to], ...] in metres along the line
  RT.bridgeSpans = (ele, step, spans) => {
    const e = Array.from(ele), n = e.length;
    for (const [a, b] of spans || []) {
      const i0 = Math.max(0, Math.floor(Math.min(a, b) / step) - 1), i1 = Math.min(n - 1, Math.ceil(Math.max(a, b) / step) + 1);
      if (i1 - i0 < 2) continue;
      for (let i = i0 + 1; i < i1; i++) e[i] = e[i0] + (e[i1] - e[i0]) * (i - i0) / (i1 - i0);
    }
    return e;
  };
  // heights far off their surroundings (tunnels: the mountain above; deep valleys under bridges; cliffs at the coast):
  // more than 25 m away from the median of the 500 m around them, together with their slopes (more than 8 m away),
  // they are replaced by a straight line
  RT.despike = (ele, step) => {
    const n = ele.length, med = RT.median(ele, Math.max(3, 2 * Math.round(250 / step) + 1)), e = Array.from(ele);
    const off = i => Math.abs(ele[i] - med[i]);
    const flag = new Uint8Array(n);
    for (let i = 0; i < n; i++) {
      if (off(i) <= 25 || flag[i]) continue;
      let a = i, b = i;
      while (a > 0 && off(a - 1) > 8) a--;
      while (b < n - 1 && off(b + 1) > 8) b++;
      for (let k = a; k <= b; k++) flag[k] = 1;
    }
    const bad = i => flag[i] === 1;
    for (let i = 0; i < n; i++) {
      if (!bad(i)) continue;
      let j = i;
      while (j < n && bad(j)) j++;
      const a = i - 1, b = j; // good neighbours (or the ends)
      for (let k = i; k < j; k++) {
        if (a < 0 && b >= n) e[k] = med[k];
        else if (a < 0) e[k] = ele[b];
        else if (b >= n) e[k] = ele[a];
        else e[k] = ele[a] + (ele[b] - ele[a]) * (k - a) / (b - a);
      }
      i = j;
    }
    return e;
  };
  // climbs: no step steeper than `cap` (e.g. 0.2 = 20 %); the height above it goes to the next steps (the climb keeps its metres)
  RT.capGrade = (e, step, cap) => {
    const n = e.length, m = cap * step, d = [];
    for (let i = 0; i + 1 < n; i++) d.push(e[i + 1] - e[i]);
    let carry = 0;
    for (let i = 0; i < d.length; i++) {
      let x = d[i] + carry;
      carry = x > m ? x - m : 0;
      d[i] = Math.min(x, m);
    }
    for (let i = d.length - 1; i >= 0 && carry > 1e-9; i--) { const add = Math.min(m - d[i], carry); d[i] += add; carry -= add; }
    const out = [e[0]];
    for (const x of d) out.push(out[out.length - 1] + x);
    return out;
  };
  // heights on a uniform grid (step metres) smoothed for riding: sigma in metres; mono: a climb that only goes up
  RT.smoothHeights = (ele, step, sigma, mono, spans) => {
    let e = RT.bridgeSpans(RT.despike(ele, step), step, spans);
    e = RT.median(e, Math.max(3, 2 * Math.round(25 / step) + 1));
    e = RT.gauss(e, sigma / step);
    if (mono) e = RT.gauss(RT.capGrade(RT.isotonic(e), step, 0.2), 30 / step);
    return e;
  };
  // the part of spans inside [a, b] of a line, measured from a (b < a: the other way round)
  RT.cutSpans = (spans, a, b) => {
    const lo = Math.min(a, b), hi = Math.max(a, b), out = [];
    for (const [x, y] of spans || []) {
      const p = Math.max(lo, Math.min(x, y)), q = Math.min(hi, Math.max(x, y));
      if (q > p) out.push(a <= b ? [p - lo, q - lo] : [hi - q, hi - p]);
    }
    return out;
  };
  // heights for a line: smoothed profile on a 10 m grid, read back at every point (points at most 10 m apart)
  RT.withHeights = (pts, s, gridEle, gridStep) => {
    const out = [];
    const eAt = d => {
      const k = Math.max(0, Math.min(gridEle.length - 1.0001, d / gridStep)), i = Math.floor(k), u = k - i;
      return gridEle[i] + (gridEle[Math.min(i + 1, gridEle.length - 1)] - gridEle[i]) * u;
    };
    for (let i = 0; i < pts.length; i++) {
      if (i) {
        const l = s[i] - s[i - 1], n = Math.ceil(l / 10);
        for (let k = 1; k < n; k++) {
          const u = k / n, a = pts[i - 1], b = pts[i];
          out.push([a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u, eAt(s[i - 1] + l * u)]);
        }
      }
      out.push([pts[i][0], pts[i][1], eAt(s[i])]);
    }
    return out;
  };

  // ------------------------------------------------------------------ description (as the app does it for its routes)
  // pts with heights: length, ascent, lowest/highest point, steepest 200 m, outline (48 points) and profile (60 heights)
  RT.describe = pts => {
    const s = RT.cum(pts), len = s[s.length - 1];
    const n = Math.max(2, Math.floor(len / 20) + 1), ev = [];
    for (let i = 0; i < n; i++) ev.push(RT.at(pts, s, len * i / (n - 1))[2]);
    let ascent = 0, lo = 1e9, hi = -1e9, prev = 0;
    for (let i = 0; i < n; i++) {
      let sum = 0, cnt = 0;
      for (let k = Math.max(0, i - 2); k <= Math.min(n - 1, i + 2); k++) { sum += ev[k]; cnt++; }
      const v = sum / cnt;
      if (i && v > prev) ascent += v - prev;
      prev = v; lo = Math.min(lo, ev[i]); hi = Math.max(hi, ev[i]);
    }
    let gmax = 0;
    const w = Math.max(1, Math.round(200 / (len / (n - 1))));
    for (let i = 0; i + w < n; i++) gmax = Math.max(gmax, (ev[i + w] - ev[i]) / (w * len / (n - 1)) * 100);
    // outline: north up, in a square 0..1
    const lat0 = pts[0][0], kx = Math.cos(lat0 * DEG);
    let minX = 1e18, maxX = -1e18, minY = 1e18, maxY = -1e18;
    const xy = pts.map(p => [p[1] * kx, p[0]]);
    for (const [x, y] of xy) { minX = Math.min(minX, x); maxX = Math.max(maxX, x); minY = Math.min(minY, y); maxY = Math.max(maxY, y); }
    const span = Math.max(1e-9, maxX - minX, maxY - minY), offX = (span - (maxX - minX)) / 2, offY = (span - (maxY - minY)) / 2;
    const shape = [], profile = [];
    for (let k = 0; k < 48; k++) {
      const p = RT.at(xy, s, len * k / 47);
      shape.push([Math.round((p[0] - minX + offX) / span * 1000) / 1000, Math.round((1 - (p[1] - minY + offY) / span) * 1000) / 1000]);
    }
    for (let k = 0; k < 60; k++) profile.push(Math.round(RT.at(pts, s, len * k / 59)[2]));
    return { length: Math.round(len), ascent: Math.round(ascent), eleMin: Math.round(lo), eleMax: Math.round(hi),
      gmax: Math.round(gmax * 10) / 10, shape, profile };
  };

  // ------------------------------------------------------------------ GPX
  const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' };
  const esc = t => Array.from(String(t == null ? '' : t), c => ESC[c] || c).join('');
  RT.gpx = (name, desc, pts) => {
    const out = ['<?xml version="1.0" encoding="UTF-8"?>',
      '<gpx version="1.1" creator="FunRun (QZ)" xmlns="http://www.topografix.com/GPX/1/1">',
      '  <metadata>', '    <name>' + esc(name) + '</name>', '    <desc>' + esc(desc) + '</desc>', '  </metadata>',
      '  <trk>', '    <name>' + esc(name) + '</name>', '    <trkseg>'];
    for (const p of pts) out.push('      <trkpt lat="' + p[0].toFixed(6) + '" lon="' + p[1].toFixed(6) + '"><ele>' + p[2].toFixed(2) + '</ele></trkpt>');
    out.push('    </trkseg>', '  </trk>', '</gpx>', '');
    return out.join('\n');
  };
  // file name for the app's gpx folder (no characters that file systems refuse)
  RT.fileName = name => {
    const bad = '/\\:*?"<>|';
    let t = Array.from(String(name), c => (bad.indexOf(c) >= 0 || c < ' ' ? ' ' : c)).join('').trim();
    while (t.indexOf('  ') >= 0) t = t.split('  ').join(' ');
    return (t || 'Strecke').slice(0, 80);
  };

  // ------------------------------------------------------------------ network
  async function getJson(url, tries) {
    let last;
    for (let k = 0; k < (tries || 2); k++) {
      try {
        const r = await fetch(url);
        if (r.ok) return await r.json();
        last = new Error('HTTP ' + r.status);
        if (r.status < 500 && r.status !== 429) break;
      } catch (e) { last = e; }
      await new Promise(res => setTimeout(res, 800 * (k + 1)));
    }
    throw last || new Error('keine Antwort');
  }
  // run jobs with at most `n` at a time, results in order
  RT.pool = async (items, n, job) => {
    const out = new Array(items.length);
    let next = 0;
    const worker = async () => { while (next < items.length) { const i = next++; out[i] = await job(items[i], i); } };
    await Promise.all(Array.from({ length: Math.min(n, items.length) }, worker));
    return out;
  };

  // places: [{ name, label, lat, lon }] (Photon, OpenStreetMap data)
  RT.geocode = async q => {
    const j = await getJson('https://photon.komoot.io/api/?q=' + encodeURIComponent(q) + '&limit=6&lang=de');
    return (j.features || []).map(f => {
      const p = f.properties || {}, c = f.geometry.coordinates;
      const label = [p.name, p.city && p.city !== p.name ? p.city : '', p.state, p.country].filter(Boolean).join(', ');
      return { name: p.name || q, label, lat: c[1], lon: c[0] };
    });
  };
  // nearest town for a point (stage names)
  RT.placeName = async p => {
    try {
      const j = await getJson('https://photon.komoot.io/reverse?lat=' + p[0] + '&lon=' + p[1] + '&lang=de&limit=1');
      const q = (j.features && j.features[0] && j.features[0].properties) || {};
      return q.city || q.town || q.village || q.district || q.name || '';
    } catch (e) { return ''; }
  };

  // heights from the free terrain tiles (Tilezen/Mapzen on AWS Open Data: SRTM, EU-DEM and others), read in a canvas.
  // Terrarium PNG: height = R * 256 + G + B / 256 - 32768. No key, no request limit; zoom 13 is about 10 m per pixel here.
  const TILES = 'https://s3.amazonaws.com/elevation-tiles-prod/terrarium/';
  const tileCache = new Map();
  function tileData(z, x, y) {
    const key = z + '/' + x + '/' + y;
    let t = tileCache.get(key);
    if (!t) {
      if (tileCache.size > 160) tileCache.clear();
      t = (async () => {
        let last;
        for (let k = 0; k < 3; k++) {
          try {
            const r = await fetch(TILES + key + '.png');
            if (!r.ok) throw new Error('Höhendaten: HTTP ' + r.status);
            const bmp = await createImageBitmap(await r.blob());
            const c = document.createElement('canvas');
            c.width = bmp.width; c.height = bmp.height;
            const ctx = c.getContext('2d');
            ctx.drawImage(bmp, 0, 0);
            return { w: c.width, h: c.height, d: ctx.getImageData(0, 0, c.width, c.height).data };
          } catch (e) { last = e; await new Promise(res => setTimeout(res, 700 * (k + 1))); }
        }
        throw last;
      })();
      t.catch(() => tileCache.delete(key));
      tileCache.set(key, t);
    }
    return t;
  }
  RT.heights = async (pts, zoom) => {
    const z = zoom || 13, n = 2 ** z;
    const pos = pts.map(p => [(p[1] + 180) / 360 * n, (1 - Math.log(Math.tan(p[0] * DEG) + 1 / Math.cos(p[0] * DEG)) / Math.PI) / 2 * n]);
    const keys = Array.from(new Set(pos.map(([xf, yf]) => Math.floor(xf) + '/' + Math.floor(yf))));
    await RT.pool(keys, 4, k => { const xy = k.split('/'); return tileData(z, +xy[0], +xy[1]); });
    const out = [];
    for (const [xf, yf] of pos) {
      const x = Math.floor(xf), y = Math.floor(yf), t = await tileData(z, x, y), d = t.d;
      const px = Math.max(0, Math.min(t.w - 1.001, (xf - x) * t.w - 0.5)), py = Math.max(0, Math.min(t.h - 1.001, (yf - y) * t.h - 0.5));
      const i0 = Math.floor(px), j0 = Math.floor(py), u = px - i0, v = py - j0;
      const val = (i, j) => { const k = (j * t.w + i) * 4; return d[k] * 256 + d[k + 1] + d[k + 2] / 256 - 32768; };
      out.push((val(i0, j0) * (1 - u) + val(i0 + 1, j0) * u) * (1 - v) + (val(i0, j0 + 1) * (1 - u) + val(i0 + 1, j0 + 1) * u) * v);
    }
    return out;
  };

  // does an OpenStreetMap way run in a tunnel or on a bridge (its heights must not follow the terrain)?
  const isStructure = (tunnel, bridge) => (!!tunnel && tunnel !== 'no') || (!!bridge && bridge !== 'no');
  // BRouter (OpenStreetMap roads, SRTM heights): { pts: [[lat, lon, ele], ...], spans: tunnels and bridges [[from, to], ...] }
  // via: [[lat, lon], ...]
  RT.brouter = async (via, profile) => {
    const url = 'https://brouter.de/brouter?lonlats=' + via.map(p => p[1].toFixed(6) + ',' + p[0].toFixed(6)).join('|') +
                '&profile=' + (profile || 'fastbike') + '&alternativeidx=0&format=geojson';
    const j = await getJson(url, 3);
    const f = j.features && j.features[0];
    if (!f) throw new Error('BRouter fand keinen Weg');
    const pts = f.geometry.coordinates.map(c => [c[1], c[0], c[2] == null ? 0 : c[2]]);
    // the messages describe the route way by way (a header row, then length and tags of each part)
    const msgs = (f.properties && f.properties.messages) || [], head = msgs[0] || [];
    const iD = head.indexOf('Distance'), iT = head.indexOf('WayTags'), spans = [];
    if (iD >= 0 && iT >= 0) {
      let d = 0;
      for (let k = 1; k < msgs.length; k++) {
        const len = +msgs[k][iD] || 0, tags = String(msgs[k][iT] || '').split(' ');
        const tag = key => { const t = tags.find(x => x.indexOf(key + '=') === 0); return t ? t.slice(key.length + 1) : ''; };
        if (isStructure(tag('tunnel'), tag('bridge'))) spans.push([d, d + len]);
        d += len;
      }
      // the messages count their own metres: scale them to this line
      const s = RT.cum(pts), k = d > 0 ? s[s.length - 1] / d : 1;
      for (const sp of spans) { sp[0] *= k; sp[1] *= k; }
    }
    return { pts, spans };
  };

  // ------------------------------------------------------------------ OpenStreetMap cycle routes (Waymarked Trails)
  const WMT = 'https://cycling.waymarkedtrails.org/api/v1/';
  // routes crossing the square around a place (radius km): [{ id, name, ref, group, linear, itinerary }]
  RT.osmList = async (lat, lon, radiusKm) => {
    const dLat = radiusKm / 111.2, dLon = radiusKm / (111.2 * Math.cos(lat * DEG));
    const a = RT.toMerc(lat - dLat, lon - dLon), b = RT.toMerc(lat + dLat, lon + dLon);
    const j = await getJson(WMT + 'list/by_area?bbox=' + [a[0], a[1], b[0], b[1]].map(Math.round).join(',') + '&limit=100');
    return (j.results || []).filter(r => r.type === 'relation' && (r.name || r.ref));
  };
  // a route as connected pieces of [lat, lon] in driving order (main route; forward way where it splits)
  // pieces: { pts: [[lat, lon], ...], spans: tunnels and bridges [[from, to], ...] in metres along the piece }
  RT.osmRoute = async id => {
    const j = await getJson(WMT + 'details/relation/' + id);
    const pieces = [];
    let cur = null;
    const add = w => {
      const coords = (w.geometry && w.geometry.coordinates) || [], tags = w.tags || {};
      const structure = isStructure(tags.tunnel, tags.bridge);
      for (let k = 0; k < coords.length; k++) {
        const p = RT.fromMerc(coords[k][0], coords[k][1]);
        if (cur && cur.pts.length) {
          const g = RT.dist(cur.pts[cur.pts.length - 1], p);
          if (g < 0.5) continue;
          if (k === 0 && g > 150) { pieces.push(cur); cur = null; } // the next way does not join on: a gap in the route
        }
        if (!cur) cur = { pts: [], spans: [], len: 0 };
        if (cur.pts.length) {
          const g = RT.dist(cur.pts[cur.pts.length - 1], p);
          if (structure && k > 0) cur.spans.push([cur.len, cur.len + g]);
          cur.len += g;
        }
        cur.pts.push(p);
      }
    };
    const walk = node => {
      if (!node) return;
      if (node.route_type === 'linear') for (const w of node.ways || []) add(w);
      else if (node.route_type === 'split') for (const m of node.forward || []) walk(m);
      else for (const m of node.main || []) walk(m); // 'route' (also stages of long routes)
    };
    walk(j.route);
    if (cur && cur.pts.length > 1) pieces.push(cur);
    // neighbouring structure bits become one span
    for (const pc of pieces) {
      const merged = [];
      for (const sp of pc.spans) {
        if (merged.length && sp[0] - merged[merged.length - 1][1] < 1) merged[merged.length - 1][1] = sp[1];
        else merged.push(sp.slice());
      }
      pc.spans = merged;
    }
    const t = j.tags || {};
    return { id, name: j.name || j.ref || 'Radroute', ref: j.ref || '', group: j.group || '', linear: j.linear || '',
      itinerary: j.itinerary || [], roundtrip: t.roundtrip === 'yes', official: j.official_length || 0,
      operator: j.operator || '', url: j.url || t.website || '', pieces: pieces.filter(p => p.pts.length > 1) };
  };
  // the whole route (its longest piece), or for long routes a stage of about stageLen metres from the point nearest
  // to `near`: [{ pts, spans, from, to, dir, whole, off }]; dir 1 = with the route, -1 = against it
  RT.osmStages = (route, near, stageLen) => {
    const cand = route.pieces.map(pc => {
      const s = RT.cum(pc.pts);
      return { pc, s, len: s[s.length - 1], nr: near ? RT.nearest(pc.pts, s, near) : { d: 0, off: 0 } };
    });
    if (!cand.length) return [];
    // pieces worth riding (not the short bits of a route with gaps), the one closest to the place first
    const maxLen = Math.max(...cand.map(c => c.len));
    const useful = cand.filter(c => c.len >= Math.min(3000, maxLen * 0.5));
    useful.sort((a, b) => (near ? a.nr.off - b.nr.off : 0) || b.len - a.len);
    const best = useful[0], total = best.len;
    const part = (a, b, dir) => ({ pts: RT.cut(best.pc.pts, best.s, a, b), spans: RT.cutSpans(best.pc.spans, a, b), from: a, to: b, dir, off: best.nr.off });
    if (!near || total <= stageLen * 1.6) return [Object.assign(part(0, total, 1), { whole: true })];
    const out = [], d0 = best.nr.d;
    if (total - d0 >= stageLen * 0.6) out.push(part(d0, Math.min(total, d0 + stageLen), 1));
    if (d0 >= stageLen * 0.6) out.push(part(d0, Math.max(0, d0 - stageLen), -1));
    if (!out.length) out.push(part(Math.max(0, total - stageLen), total, 1));
    return out;
  };
  // heights for a line: every 20 m from the terrain tiles, smoothed over about 120 m (trees and houses in the
  // terrain data make small false bumps); returns pts with heights, at most 10 m apart
  RT.addHeights = async (pts, opts) => {
    const o = opts || {}, s = RT.cum(pts);
    const grid = RT.resample(pts, s, o.sample || 20);
    const raw = await RT.heights(grid.pts, o.zoom || 13);
    const ele = RT.smoothHeights(raw, grid.step, o.sigma || 120, !!o.mono, o.spans);
    return RT.withHeights(pts, s, ele, grid.step);
  };
  // quick heights for the list (coarser tiles, a point every 150 m or more): length, climbing, outline, profile
  RT.quickProfile = async pts => {
    const s = RT.cum(pts), grid = RT.resample(pts, s, Math.max(150, s[s.length - 1] / 400));
    const raw = await RT.heights(grid.pts, 12);
    const ele = RT.gauss(raw, 150 / grid.step);
    return RT.describe(grid.pts.map((p, i) => [p[0], p[1], ele[i]]));
  };

  // ------------------------------------------------------------------ climbs catalog (BRouter)
  // a catalog route with heights ready for riding: BRouter heights on a 10 m grid, tunnels and bridges bridged, smoothed.
  // Climbs (mono) never fall and run from their lowest point near the start to their highest point near the end.
  RT.catalogTrack = async entry => {
    const br = await RT.brouter(entry.via, entry.profile || 'fastbike');
    let pts = br.pts, spans = br.spans, s = RT.cum(pts);
    let grid = RT.resample(pts, s, 10);
    let ele = RT.smoothHeights(grid.pts.map(p => p[2]), grid.step, entry.mono ? 60 : 40, false, spans);
    if (entry.mono) {
      const n = ele.length, cutN = Math.floor(n * 0.4);
      let lo = 0, hi = n - 1;
      for (let i = 0; i < cutN; i++) if (ele[i] < ele[lo]) lo = i;
      for (let i = n - 1; i > n - 1 - cutN; i--) if (ele[i] > ele[hi]) hi = i;
      if (lo > 0 || hi < n - 1) {
        const a = lo * grid.step, b = hi * grid.step;
        pts = RT.cut(pts, s, a, b); spans = RT.cutSpans(spans, a, b); s = RT.cum(pts);
        grid = RT.resample(pts, s, 10);
      }
      ele = RT.smoothHeights(grid.pts.map(p => p[2]), grid.step, 60, true, spans);
    }
    return RT.withHeights(pts.map(p => [p[0], p[1]]), s, ele, grid.step);
  };

  // ------------------------------------------------------------------ long routes in stages (ultra races)
  // a public route of RideWithGPS (as the organisers of many races publish them): { name, pts: [[lat, lon, ele]], ... }
  RT.rwgpsRoute = async id => {
    const j = await getJson('https://ridewithgps.com/routes/' + encodeURIComponent(id) + '.json', 2);
    const pts = (j.track_points || []).filter(p => p.x != null && p.y != null).map(p => [p.y, p.x, p.e == null ? NaN : p.e]);
    if (pts.length < 2) throw new Error('Die Route hat keine Punkte');
    return { name: j.name || 'Route', pts, length: j.distance || 0, ascent: j.elevation_gain || 0, unpaved: j.unpaved_pct, country: j.country_code || '' };
  };
  // GPX text -> { name, pts: [[lat, lon, ele]] } (track points, else route points); the track's name first, as the app does
  RT.parseGpx = text => {
    const doc = new DOMParser().parseFromString(text, 'application/xml');
    let nodes = doc.getElementsByTagName('trkpt');
    if (!nodes.length) nodes = doc.getElementsByTagName('rtept');
    const pts = [];
    for (let i = 0; i < nodes.length; i++) {
      const nd = nodes[i], lat = parseFloat(nd.getAttribute('lat')), lon = parseFloat(nd.getAttribute('lon'));
      if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue;
      const el = nd.getElementsByTagName('ele')[0];
      pts.push([lat, lon, el ? parseFloat(el.textContent) : NaN]);
    }
    const first = tag => { const t = doc.getElementsByTagName(tag)[0]; const nm = t && Array.from(t.childNodes).find(c => c.nodeName === 'name'); return nm ? nm.textContent.trim() : ''; };
    return { name: first('trk') || first('metadata') || first('rte'), pts };
  };

  // compact text for long lists of whole numbers (as in Google's polyline format)
  RT.encodeInts = nums => {
    const out = [];
    for (let v of nums) {
      v = v < 0 ? ~(v << 1) : v << 1;
      while (v >= 0x20) { out.push(String.fromCharCode((0x20 | (v & 0x1f)) + 63)); v >>>= 5; }
      out.push(String.fromCharCode(v + 63));
    }
    return out.join('');
  };
  RT.decodeInts = str => {
    const out = [];
    let i = 0;
    while (i < str.length) {
      let b, shift = 0, result = 0;
      do { b = str.charCodeAt(i++) - 63; result |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20 && i < str.length);
      out.push(result & 1 ? ~(result >> 1) : result >> 1);
    }
    return out;
  };
  // a track as text: latitude and longitude to 1 m, heights to 10 cm (or none)
  RT.encodeTrack = pts => {
    const d = (k, f) => { let prev = 0; return pts.map(p => { const v = Math.round(p[k] * f); const x = v - prev; prev = v; return x; }); };
    const hasEle = pts.every(p => Number.isFinite(p[2]));
    return { lat: RT.encodeInts(d(0, 1e5)), lon: RT.encodeInts(d(1, 1e5)), ele: hasEle ? RT.encodeInts(d(2, 10)) : '' };
  };
  RT.decodeTrack = t => {
    const sum = (arr, f) => { let v = 0; return arr.map(x => (v += x) / f); };
    const lat = sum(RT.decodeInts(t.lat), 1e5), lon = sum(RT.decodeInts(t.lon), 1e5), ele = t.ele ? sum(RT.decodeInts(t.ele), 10) : null;
    return lat.map((y, i) => [y, lon[i], ele ? ele[i] : NaN]);
  };
  // fewer points where the line runs straight (keeps every bend within `tol` metres)
  RT.simplify = (pts, tol) => {
    const n = pts.length;
    if (n < 3) return pts.slice();
    const lat0 = pts[0][0] * DEG, kx = R * DEG * Math.cos(lat0), ky = R * DEG;
    const keep = new Uint8Array(n);
    keep[0] = keep[n - 1] = 1;
    const stack = [[0, n - 1]];
    while (stack.length) {
      const [a, b] = stack.pop();
      const ax = pts[a][1] * kx, ay = pts[a][0] * ky, bx = pts[b][1] * kx, by = pts[b][0] * ky;
      const dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy;
      let best = -1, bi = -1;
      for (let i = a + 1; i < b; i++) {
        const px = pts[i][1] * kx - ax, py = pts[i][0] * ky - ay;
        const t = l2 > 0 ? Math.max(0, Math.min(1, (px * dx + py * dy) / l2)) : 0;
        const qx = px - t * dx, qy = py - t * dy, d2 = qx * qx + qy * qy;
        if (d2 > best) { best = d2; bi = i; }
      }
      if (bi >= 0 && best > tol * tol) { keep[bi] = 1; stack.push([a, bi], [bi, b]); }
    }
    return pts.filter((p, i) => keep[i]);
  };
  // project id from a name: "silk-road-mountain-race-2026-k3x9"
  RT.projectId = name => {
    const map = { 'ä': 'ae', 'ö': 'oe', 'ü': 'ue', 'ß': 'ss', 'é': 'e', 'è': 'e', 'à': 'a', 'ç': 'c' };
    let s = '';
    for (const ch of String(name).toLowerCase()) {
      const c = map[ch] || ch;
      s += (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ? c : '-';
    }
    while (s.indexOf('--') >= 0) s = s.split('--').join('-');
    s = s.split('-').filter(Boolean).join('-').slice(0, 44) || 'strecke';
    return s + '-' + Date.now().toString(36).slice(-5);
  };
  // stage borders: about stageLen metres each, a short rest joins the last stage
  RT.stageBorders = (total, stageLen) => {
    const n = Math.max(1, Math.round(total / stageLen)), out = [];
    for (let k = 0; k < n; k++) out.push([total * k / n, total * (k + 1) / n]);
    return out;
  };
  // a long route as a project of stages: { id, name, length, ascent, stageLen, track, stages: [{ n, from, to, length, ascent }] }
  RT.makeProject = (meta, ptsIn, stageLen) => {
    // points closer than 2 m to each other add nothing; bends are kept to 3 m
    const pts = RT.simplify(ptsIn.filter((p, i) => i === 0 || RT.dist(ptsIn[i - 1], p) > 2), 3);
    const s = RT.cum(pts), total = s[s.length - 1];
    const hasEle = pts.every(p => Number.isFinite(p[2]));
    // climbing per stage from the heights smoothed over 100 m (when there are heights)
    let ele = null, step = 50;
    if (hasEle) {
      const grid = RT.resample(pts, s, step);
      step = grid.step;
      ele = RT.gauss(RT.despike(grid.pts.map(p => p[2]), step), 100 / step);
    }
    const climb = (a, b) => {
      if (!ele) return 0;
      let up = 0;
      for (let i = Math.max(1, Math.ceil(a / step)); i <= Math.min(ele.length - 1, Math.floor(b / step)); i++) up += Math.max(0, ele[i] - ele[i - 1]);
      return Math.round(up);
    };
    const stages = RT.stageBorders(total, stageLen).map(([a, b], k) => ({ n: k + 1, from: Math.round(a), to: Math.round(b), length: Math.round(b - a), ascent: climb(a, b) }));
    return Object.assign({ v: 1, created: new Date().toISOString(), stageLen, length: Math.round(total),
      ascent: stages.reduce((x, st) => x + st.ascent, 0), heights: hasEle ? 'route' : 'terrain', track: RT.encodeTrack(pts), stages }, meta);
  };
  // the GPX points of stage n (1..): heights of the route smoothed (or from the terrain tiles), 1 km more on both sides
  // for the smoothing, then cut
  RT.stageTrack = async (project, n) => {
    const st = project.stages[n - 1], pts = RT.decodeTrack(project.track), s = RT.cum(pts), total = s[s.length - 1];
    const pad = 1000, a = Math.max(0, st.from - pad), b = Math.min(total, st.to + pad);
    const part = RT.cut(pts, s, a, b), ps = RT.cum(part);
    let withEle;
    if (project.heights === 'route' && part.every(p => Number.isFinite(p[2]))) {
      const grid = RT.resample(part, ps, 10);
      const e = RT.smoothHeights(grid.pts.map(p => p[2]), grid.step, 80, false, null);
      withEle = RT.withHeights(part.map(p => [p[0], p[1]]), ps, e, grid.step);
    } else {
      withEle = await RT.addHeights(part.map(p => [p[0], p[1]]), { zoom: 13, sample: 20, sigma: 120 });
    }
    const ws = RT.cum(withEle);
    return RT.cut(withEle, ws, st.from - a, Math.min(ws[ws.length - 1], st.to - a));
  };
  // route key of a file as the app makes it (file name without folder and extension, lower case)
  RT.routeKey = file => {
    let f = String(file || '');
    f = f.slice(Math.max(f.lastIndexOf('/'), f.lastIndexOf('\\')) + 1);
    const dot = f.lastIndexOf('.');
    return (dot > 0 ? f.slice(0, dot) : f).toLowerCase();
  };
  // stages ridden to the end (from the rides): { done: Set of stage numbers, km }
  RT.projectProgress = (project, rides) => {
    const done = new Set();
    const keys = new Map(project.stages.filter(st => st.file).map(st => [RT.routeKey(st.file), st.n]));
    for (const r of rides || []) if (r.route && r.route.finished && keys.has(r.route.key)) done.add(keys.get(r.route.key));
    const km = project.stages.filter(st => done.has(st.n)).reduce((x, st) => x + st.length, 0) / 1000;
    const next = project.stages.find(st => !done.has(st.n)) || null;
    return { done, km, next };
  };

  // ------------------------------------------------------------------ ride time estimate
  // params: { flat: km/h on the flat, climb: metres up per hour on climbs }
  // each part of the profile takes as long as the slower of: its length at the flat speed, its climb at the climbing rate
  RT.estimate = (length, profile, params) => {
    const v = Math.max(5, params.flat) / 3.6, c = Math.max(100, params.climb) / 3600;
    if (!profile || profile.length < 2) return length / v;
    const n = profile.length - 1, dl = length / n;
    let t = 0;
    for (let i = 0; i < n; i++) t += Math.max(dl / v, Math.max(0, profile[i + 1] - profile[i]) / c);
    return t;
  };
  // without a profile (stages of long routes): the climbing taken as spread over climbs of 5 %, the rest at the flat speed
  RT.estimateAscent = (length, ascent, params) => {
    const v = Math.max(5, params.flat) / 3.6, c = Math.max(100, params.climb) / 3600;
    const climbLen = Math.min(length, Math.max(0, ascent) / 0.05);
    return Math.max(length / v, (length - climbLen) / v + Math.max(0, ascent) / c);
  };
  // fixed values from the settings, or learned from the last 10 rides that have them (time-weighted)
  RT.speedParams = (settings, rides) => {
    const fixed = { flat: +settings.flat > 0 ? +settings.flat : 25, climb: +settings.climb > 0 ? +settings.climb : 700, learned: false, rides: 0 };
    if (!settings.adaptive) return fixed;
    const recent = (rides || []).filter(r => r.flatTime > 0 || r.climbTime > 0).slice(0, 10);
    let fT = 0, fS = 0, cT = 0, cS = 0;
    for (const r of recent) {
      if (r.flatTime >= 120 && r.flatSpeed > 0) { fT += r.flatTime; fS += r.flatSpeed * r.flatTime; }
      if (r.climbTime >= 120 && r.vam > 0) { cT += r.climbTime; cS += r.vam * r.climbTime; }
    }
    return { flat: fT ? fS / fT : fixed.flat, climb: cT ? cS / cT : fixed.climb, learned: !!(fT || cT), flatLearned: !!fT,
      climbLearned: !!cT, rides: recent.length };
  };
  // "ca. 1:45 h" / "ca. 50 min"
  RT.duration = sec => {
    const m = Math.max(5, Math.round(sec / 300) * 5);
    return m < 60 ? 'ca. ' + m + ' min' : 'ca. ' + Math.floor(m / 60) + ':' + String(m % 60).padStart(2, '0') + ' h';
  };
})();
