// FunRun routes: everything needed to offer new routes in the "Entdecken" tab and to estimate ride times.
//  - signposted cycle routes of OpenStreetMap around a place (Waymarked Trails), long ones as stages
//  - the climbs catalog (katalog.json), routed with BRouter
//  - heights from the Terrarium terrain tiles (AWS open data), smoothed for the bike's resistance
//  - GPX writer, outline and profile as the app computes them for its own routes
//  - ride time estimate: speed on the flat and climbing rate (fixed or learned from the last 10 rides)
//  - ultra races of DotWatcher with their routes from the trackers (Trackleaders, FollowMyChallenge, Madcap)
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
  // nearest point of the line to p: { d (along the line), off (metres away) }; from: only the line from there on
  RT.nearest = (pts, s, p, from) => {
    const ky = R * DEG, kx = R * DEG * Math.cos(p[0] * DEG);
    let best = 1e18, bestD = 0;
    for (let i = 0; i + 1 < pts.length; i++) {
      if (from > 0 && s[i + 1] < from) continue;
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
  // opts (routes without heights): profile { step, ele } heights along the route for the climbing of the stages,
  // ascentTotal the organiser's figure for the whole route (sets the scale of coarse heights); cps: [{ name, at }]
  RT.makeProject = (meta, ptsIn, stageLen, opts) => {
    const o = opts || {};
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
    } else if (o.profile && o.profile.ele && o.profile.ele.length > 1) {
      ele = o.profile.ele; step = o.profile.step;
    }
    const climb = (a, b) => {
      if (!ele) return 0;
      let up = 0;
      for (let i = Math.max(1, Math.ceil(a / step)); i <= Math.min(ele.length - 1, Math.floor(b / step)); i++) up += Math.max(0, ele[i] - ele[i - 1]);
      return Math.round(up);
    };
    const stages = RT.stageBorders(total, stageLen).map(([a, b], k) => ({ n: k + 1, from: Math.round(a), to: Math.round(b), length: Math.round(b - a), ascent: climb(a, b) }));
    // coarse terrain heights miss the small ups and downs: the organiser's figure for the whole route sets the scale (when it fits)
    if (!hasEle && ele && o.ascentTotal > 0) {
      const sum = stages.reduce((x, st) => x + st.ascent, 0), f = sum > 0 ? o.ascentTotal / sum : 0;
      if (f >= 0.4 && f <= 3) for (const st of stages) st.ascent = Math.round(st.ascent * f);
    }
    const project = Object.assign({ v: 1, created: new Date().toISOString(), stageLen, length: Math.round(total),
      ascent: stages.reduce((x, st) => x + st.ascent, 0), heights: hasEle ? 'route' : 'terrain', track: RT.encodeTrack(pts), stages }, meta);
    if (o.cps && o.cps.length) project.cps = o.cps;
    return project;
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

  // ------------------------------------------------------------------ ultra races of DotWatcher and the trackers it shows
  // There is no official interface: these are the data the sites' own pages load (a site that changes its pages needs an
  // update here). The FunRun page may not load these sites itself: the page sets RT.fetchText (the app loads them).
  RT.fetchText = async (url, opts) => {
    const o = opts || {};
    const r = await fetch(url, o.method === 'POST' ? { method: 'POST', headers: { 'Content-Type': o.type || 'application/json' }, body: o.body || '' } : undefined);
    if (!r.ok) throw new Error('HTTP ' + r.status);
    return r.text();
  };
  // the first number of a text, thousands marks taken out: "1,050km" 1050, "~9,000m" 9000, "1.100 km" 1100, "553.3 mi" 553.3
  RT.firstNumber = text => {
    const s = String(text == null ? '' : text), digit = c => c >= '0' && c <= '9';
    let i = 0;
    while (i < s.length && !digit(s[i])) i++;
    let j = i;
    while (j < s.length && (digit(s[j]) || ((s[j] === ',' || s[j] === '.') && digit(s[j + 1] || '')))) j++;
    const parts = [];
    let cur = '';
    for (const ch of s.slice(i, j)) { if (ch === ',' || ch === '.') { parts.push(cur); cur = ''; } else cur += ch; }
    parts.push(cur);
    if (!parts[0]) return NaN;
    if (parts.length === 1) return +parts[0];
    // groups of three after the first: thousands marks; otherwise the last mark is the decimal point
    if (parts.slice(1).every(x => x.length === 3)) return +parts.join('');
    return +(parts.slice(0, -1).join('') + '.' + parts[parts.length - 1]);
  };
  // length and climbing as DotWatcher and the trackers write them ("1,050km", "320km / 410km", "553.3 mi"; "36,000m") in km
  // and m; missing or 0: NaN
  RT.textKm = text => {
    const t = String(text || '').toLowerCase(), n = RT.firstNumber(t);
    const v = t.indexOf('mi') >= 0 && t.indexOf('km') < 0 ? n * 1.609344 : n;
    return v > 0 ? v : NaN;
  };
  RT.textMetres = text => {
    const t = String(text || '').toLowerCase(), n = RT.firstNumber(t);
    const v = t.indexOf('ft') >= 0 ? n * 0.3048 : n;
    return v > 0 ? v : NaN;
  };
  // DotWatcher's terrain: 'road', 'gravel' (also all-road, mixed), 'off' (off-road, MTB) or ''
  RT.terrainKind = text => {
    const t = String(text || '').toLowerCase();
    if (t.indexOf('off') >= 0 || t.indexOf('mtb') >= 0 || t.indexOf('trail') >= 0 || t.indexOf('mountain') >= 0) return 'off';
    if (t.indexOf('gravel') >= 0 || t.indexOf('all') >= 0 || t.indexOf('mixed') >= 0) return 'gravel';
    if (t.indexOf('road') >= 0) return 'road';
    return '';
  };

  const DW = 'https://dotwatcher.cc';
  let dwBuild = '';
  // the data of a Next.js page (<script id="__NEXT_DATA__">)
  RT.nextData = html => {
    const k = html.indexOf('id="__NEXT_DATA__"');
    if (k < 0) throw new Error('DotWatcher hat seine Seiten umgebaut');
    const a = html.indexOf('>', k) + 1, b = html.indexOf('</script>', a);
    return JSON.parse(html.slice(a, b));
  };
  const dwItem = x => ({ slug: x.slug, title: String(x.title || x.slug).trim(), date: x.raceDate || '', end: x.raceEndDate || '',
    location: x.location || '', lengthText: x.length || '', km: RT.textKm(x.length), elevationText: x.elevation || '',
    hm: RT.textMetres(x.elevation), terrain: RT.terrainKind(x.terrain), terrainText: x.terrain || '', desc: x.shortDescription || '' });
  const dwItems = v => ((v && v.items) || []).filter(x => x && x.slug).map(dwItem);
  // DotWatcher's race list: { upcoming, live, past } (the next races, those under way, the last 25)
  RT.dwRaces = async () => {
    const nd = RT.nextData(await RT.fetchText(DW + '/races'));
    dwBuild = nd.buildId || dwBuild;
    const d = (nd.props && nd.props.pageProps && nd.props.pageProps.data) || {};
    return { upcoming: dwItems(d.upcomingRaceCollection), live: dwItems(d.liveRacesCollection), past: dwItems(d.pastRacesCollection) };
  };
  // data of a DotWatcher page (the build id in its path changes with every update of the site: then read again)
  async function dwData(path) {
    if (!dwBuild) await RT.dwRaces();
    try {
      return JSON.parse(await RT.fetchText(DW + '/_next/data/' + dwBuild + '/' + path));
    } catch (e) {
      const old = dwBuild;
      await RT.dwRaces();
      if (dwBuild === old) throw e;
      return JSON.parse(await RT.fetchText(DW + '/_next/data/' + dwBuild + '/' + path));
    }
  }
  // all races DotWatcher ever covered: [{ name, events: [{ slug, year }] }] (newest year first)
  RT.dwArchive = async () => {
    const j = await dwData('results.json');
    return ((j.pageProps && j.pageProps.allRaces) || []).filter(x => x && x.name && x.events && x.events.length)
      .map(x => ({ name: String(x.name).trim(), events: x.events.filter(e => e && e.slug).map(e => ({ slug: e.slug, year: +e.year || 0 })).sort((a, b) => b.year - a.year) }))
      .filter(x => x.events.length);
  };
  // one race: its data, where its map comes from (tracker), the organiser's website
  RT.dwRace = async slug => {
    let j;
    try { j = await dwData('race/' + encodeURIComponent(slug) + '.json?slug=' + encodeURIComponent(slug)); } catch (e) {
      if (String(e.message).indexOf('404') >= 0) throw new Error('DotWatcher hat zu diesem Rennen keine Seite mehr');
      throw e;
    }
    const d = j.pageProps && j.pageProps.data, it = d && d.racesCollection && d.racesCollection.items && d.racesCollection.items[0];
    if (!it) throw new Error('DotWatcher kennt dieses Rennen nicht');
    return Object.assign(dwItem(it), { tracker: RT.tracker(it.trackleadersRaceId), website: it.website || '', page: DW + '/race/' + slug });
  };

  // where the map of a race comes from (DotWatcher's field "trackleadersRaceId": a Trackleaders id or the tracker's address):
  // { kind: 'tl' | 'fmc' | 'madcap' | 'map' | 'other' | 'none', id, url }
  const TRACKERS = { tl: 'Trackleaders', fmc: 'FollowMyChallenge', madcap: 'Madcap', map: 'MAProgress' };
  RT.trackerName = kind => TRACKERS[kind] || '';
  RT.trackerLoads = kind => kind === 'tl' || kind === 'fmc' || kind === 'madcap';
  RT.tracker = ref => {
    const s = String(ref || '').trim();
    if (!s) return { kind: 'none' };
    if (s.indexOf('http') !== 0) return s.indexOf('/') < 0 && s.indexOf('.') < 0 && s.indexOf(' ') < 0 ? { kind: 'tl', id: s } : { kind: 'other', url: s };
    let u;
    try { u = new URL(s); } catch (e) { return { kind: 'other', url: s }; }
    const host = u.hostname.toLowerCase(), parts = u.pathname.split('/').filter(Boolean);
    const on = d => host === d || host.endsWith('.' + d);
    if (on('followmychallenge.com')) {
      const i = parts.indexOf('live'), id = i >= 0 ? parts[i + 1] : parts[0];
      return id ? { kind: 'fmc', id, url: s } : { kind: 'other', url: s };
    }
    if (host === 'app.madcap.cc') {
      const i = parts.indexOf('event');
      return i >= 0 && parts[i + 1] ? { kind: 'madcap', id: parts[i + 1], url: s } : { kind: 'other', url: s };
    }
    if (on('trackleaders.com')) {
      let id = parts[0] || '';
      if (id.endsWith('f.php')) id = id.slice(0, -5); else if (id.endsWith('.php')) id = id.slice(0, -4);
      return id ? { kind: 'tl', id, url: s } : { kind: 'other', url: s };
    }
    if (on('maprogress.com')) return { kind: 'map', url: s };
    return { kind: 'other', url: s };
  };

  // lines of a GeoJSON object (LineString, MultiLineString, also in features): [[[lat, lon, ele], ...], ...]
  RT.geoLines = g => {
    const out = [];
    const line = coords => {
      const pts = [];
      for (const c of coords || []) {
        const lon = parseFloat(c[0]), lat = parseFloat(c[1]), e = c.length > 2 ? parseFloat(c[2]) : NaN;
        if (Number.isFinite(lat) && Number.isFinite(lon)) pts.push([lat, lon, e]);
      }
      if (pts.length > 1) out.push(pts);
    };
    const geom = gm => {
      if (!gm) return;
      if (gm.type === 'LineString') line(gm.coordinates);
      else if (gm.type === 'MultiLineString') for (const c of gm.coordinates || []) line(c);
      else if (gm.type === 'GeometryCollection') for (const x of gm.geometries || []) geom(x);
    };
    const walk = o => {
      if (!o) return;
      if (o.type === 'FeatureCollection') for (const f of o.features || []) walk(f);
      else if (o.type === 'Feature') geom(o.geometry);
      else geom(o);
    };
    walk(g);
    return out;
  };
  // the parts of one route in their order as one line
  RT.joinLines = lines => {
    const out = [];
    for (const l of lines) for (let i = 0; i < l.length; i++) { if (i === 0 && out.length && RT.dist(out[out.length - 1], l[0]) < 1) continue; out.push(l[i]); }
    return out;
  };

  // a JavaScript array of numbers in a text, from its "[" to the "];" that ends it (a comma before the last "]" is allowed there)
  function jsArray(js, open) {
    const end = js.indexOf('];', open);
    if (open < 0 || end < 0) return null;
    let t = js.slice(open, end).trim();
    if (t.endsWith(',')) t = t.slice(0, -1);
    try { return JSON.parse(t + ']'); } catch (e) { return null; }
  }
  // Trackleaders, route.js: "routeptsN = [[lat,lon],...];" and the popup of each line ("<b>Route:</b> NAME<br>553.3 mi<br>")
  const TL = 'https://trackleaders.com/spot/';
  RT.parseTlRoutes = js => {
    const decls = [];
    let k = 0;
    while ((k = js.indexOf('routepts', k)) >= 0) {
      let i = k + 8, num = '';
      while (i < js.length && js[i] >= '0' && js[i] <= '9') num += js[i++];
      let j = i;
      while (js[j] === ' ') j++;
      if (num && js[j] === '=') decls.push({ num: +num, at: k, open: js.indexOf('[', j) });
      k = i;
    }
    const out = [];
    decls.forEach((d, n) => {
      const arr = jsArray(js, d.open), close = js.indexOf('];', d.open);
      if (!arr) return;
      const pts = arr.filter(p => p && Number.isFinite(p[0]) && Number.isFinite(p[1])).map(p => [p[0], p[1], NaN]);
      if (pts.length < 2) return;
      const end = n + 1 < decls.length ? decls[n + 1].at : js.length;
      let name = '', km = NaN;
      const pop = js.indexOf('bindPopup(', close);
      if (pop >= 0 && pop < end) {
        const txt = js.slice(pop, Math.min(end, pop + 600));
        const b = txt.indexOf('</b>'), br1 = b >= 0 ? txt.indexOf('<br>', b) : -1, br2 = br1 >= 0 ? txt.indexOf('<br>', br1 + 4) : -1;
        if (br1 > b) name = txt.slice(b + 4, br1).trim();
        if (br2 > br1) km = RT.textKm(txt.slice(br1 + 4, br2));
      }
      // file names ("highland25.kml-0") are no names
      if (name.indexOf('.kml') >= 0 || name.indexOf('.gpx') >= 0) name = '';
      out.push({ num: d.num, name, km, pts });
    });
    return out;
  };
  // Trackleaders, elevationN.js: the profile of line N ("ele": distance in mi or km, height in ft or m; one sample for each
  // point of the line). The distances are rounded to 0.1: the samples of one distance are spread over the next 0.1
  RT.parseTlElevation = js => {
    const unit = key => { const k = js.indexOf(key); if (k < 0) return ''; const a = js.indexOf("'", k) + 1; return a > 0 ? js.slice(a, js.indexOf("'", a)) : ''; };
    const fx = unit('exUnits') === 'mi' ? 1609.344 : 1000, fy = unit('eyUnits') === 'ft' ? 0.3048 : 1;
    const k = js.indexOf('ele = [');
    const arr = k >= 0 ? jsArray(js, js.indexOf('[', k)) : null;
    if (!arr) return null;
    const d = [], e = [];
    for (let i = 0; i < arr.length;) {
      let j = i;
      while (j < arr.length && arr[j][0] === arr[i][0]) j++;
      const x0 = arr[i][0], x1 = Math.min(j < arr.length ? arr[j][0] : x0 + 0.1, x0 + 0.1);
      for (let m = i; m < j; m++) { d.push((x0 + (x1 - x0) * (m - i) / (j - i)) * fx); e.push(arr[m][1] * fy); }
      i = j;
    }
    return d.length > 1 ? { d, e } : null;
  };
  // heights along a line from a profile: one sample for each point, or else by the distance (the profile stretched to the
  // line's length)
  RT.heightsFromProfile = (pts, prof) => {
    if (prof.e.length === pts.length) return pts.map((p, i) => [p[0], p[1], prof.e[i]]);
    const s = RT.cum(pts), total = s[s.length - 1], k = total > 0 ? prof.d[prof.d.length - 1] / total : 1;
    let j = 0;
    return pts.map((p, i) => {
      const x = s[i] * k;
      while (j < prof.d.length - 2 && prof.d[j + 1] < x) j++;
      const a = prof.d[j], b = prof.d[j + 1], u = b > a ? Math.max(0, Math.min(1, (x - a) / (b - a))) : 0;
      return [p[0], p[1], prof.e[j] + (prof.e[j + 1] - prof.e[j]) * u];
    });
  };
  // FollowMyChallenge, the race's page: route files ("prefetch.route.php?r=<file>&...") and checkpoints (a label, then its
  // marker "setLngLat([lon, lat])")
  RT.parseFmcPage = html => {
    const files = [];
    let k = 0;
    while ((k = html.indexOf('prefetch.route.php?r=', k)) >= 0) {
      k += 21;
      let e = k;
      while (e < html.length && html[e] !== '&' && html[e] !== "'" && html[e] !== '"' && html[e] !== ' ') e++;
      const f = html.slice(k, e);
      if (f && files.indexOf(f) < 0) files.push(f);
    }
    const cps = [];
    k = 0;
    while ((k = html.indexOf('checkpointFloatingLabel_CP', k)) >= 0) {
      const a = html.indexOf("' + '", k);
      const b = a >= 0 ? html.indexOf("' + '", a + 5) : -1;
      if (b < 0) break;
      const next = html.indexOf('checkpointFloatingLabel_CP', b), m = html.indexOf('setLngLat([', b);
      k = b;
      if (m < 0 || (next >= 0 && m > next)) continue;
      const c = html.slice(m + 11, html.indexOf(']', m)).split(',');
      const name = html.slice(a + 5, b).split("\\'").join("'").trim(), lon = parseFloat(c[0]), lat = parseFloat(c[1]);
      if (name && Number.isFinite(lat) && Number.isFinite(lon)) cps.push({ name, lat, lon });
    }
    return { files, cps };
  };

  // the route of a race at its tracker: { variants: [{ key, name, km, pts, heights, main, tl }], cps: [{ name, lat, lon }] }
  // variants longest first; pts [[lat, lon, ele]] (ele NaN where the tracker has no heights); onState: progress texts
  RT.raceRoute = async (tracker, onState) => {
    const say = t => { if (onState) onState(t); };
    let variants = [], cps = [];
    if (tracker.kind === 'tl') {
      say('Strecke wird bei Trackleaders geladen …');
      const lines = RT.parseTlRoutes(await RT.fetchText(TL + encodeURIComponent(tracker.id) + '/route.js'));
      variants = lines.map(l => ({ key: 'tl' + l.num, name: l.name, pts: l.pts, heights: false, tl: { id: tracker.id, num: l.num } }));
    } else if (tracker.kind === 'fmc') {
      say('Seite des Rennens bei FollowMyChallenge wird gelesen …');
      const base = 'https://www.followmychallenge.com/live/' + tracker.id + '/';
      const page = RT.parseFmcPage(await RT.fetchText(base, { stopAfter: 'prefetch.route.php?r=', stopExtra: 200000 }));
      cps = page.cps;
      for (const f of page.files) {
        say('Strecke wird bei FollowMyChallenge geladen …');
        const pts = RT.joinLines(RT.geoLines(JSON.parse(await RT.fetchText(base + 'application/helpers/prefetch.route.php?r=' + f + '&light=false'))));
        if (pts.length > 1) variants.push({ key: f, name: '', pts, heights: pts.every(p => Number.isFinite(p[2])) });
      }
    } else if (tracker.kind === 'madcap') {
      say('Strecke wird bei Madcap geladen …');
      const j = JSON.parse(await RT.fetchText('https://api2.madcap.cc/event/geo/v6', { method: 'POST', body: JSON.stringify({ event: tracker.id }), type: 'application/json' }));
      const d = j.data || {};
      for (const r of d.routes || []) {
        let g = r.geojson;
        if (typeof g === 'string') { try { g = JSON.parse(g); } catch (e) { g = null; } }
        const pts = RT.joinLines(RT.geoLines(g));
        if (pts.length > 1) variants.push({ key: String(r.id || variants.length), name: r.name && r.name !== 'Route' ? String(r.name) : '', main: !!r.is_main, pts, heights: pts.every(p => Number.isFinite(p[2])) });
      }
      cps = (d.cps || []).filter(c => c && c.cp_type !== 'INVISIBLE').sort((a, b) => (+a.order || 0) - (+b.order || 0))
        .map(c => ({ name: String(c.name || c.short_name || '').trim(), lat: +c.latitude, lon: +c.longitude }))
        .filter(c => c.name && Number.isFinite(c.lat) && Number.isFinite(c.lon));
    } else throw new Error('Von diesem Tracker kann die App keine Strecke laden');
    for (const v of variants) { const s = RT.cum(v.pts); v.km = s[s.length - 1] / 1000; }
    variants.sort((a, b) => b.km - a.km);
    return { variants, cps };
  };
  // heights of a variant: from the tracker (Madcap, some FollowMyChallenge routes) or the profile of Trackleaders; null: none
  RT.variantHeights = async v => {
    if (v.heights) return v.pts;
    if (v.tl) {
      try {
        const prof = RT.parseTlElevation(await RT.fetchText(TL + encodeURIComponent(v.tl.id) + '/elevation' + v.tl.num + '.js'));
        if (prof) return RT.heightsFromProfile(v.pts, prof);
      } catch (e) { /* no profile: terrain heights */ }
    }
    return null;
  };
  // checkpoints along a line in the order of the race: [{ name, at (metres) }]; those more than 3 km off the line drop out
  RT.placeCps = (pts, cps) => {
    const s = RT.cum(pts), out = [];
    let from = 0;
    for (const c of cps || []) {
      const nr = RT.nearest(pts, s, [c.lat, c.lon], from);
      if (nr.off > 3000) continue;
      out.push({ name: c.name, at: Math.round(nr.d) });
      from = Math.max(from, nr.d - 1000);
    }
    return out;
  };
  // the checkpoints in a stage of a project (not the start): names
  RT.stageCps = (project, st) => (project.cps || []).filter(c => c.at > 1000 && c.at >= st.from && (c.at < st.to || st.n === project.stages.length)).map(c => c.name);
  RT.cpLabel = name => (String(name).toLowerCase() === 'finish' ? 'Ziel' : String(name));
  // heights for the climbing of the stages where the tracker has none: coarse terrain tiles (zoom 10) every 200 m, in parts
  // along the route (the tiles of a part are shared); onProgress(0..1)
  RT.coarseProfile = async (pts, onProgress) => {
    const s = RT.cum(pts), grid = RT.resample(pts, s, 200), raw = [];
    for (let i = 0; i < grid.pts.length; i += 1500) {
      const part = await RT.heights(grid.pts.slice(i, i + 1500), 10);
      for (const h of part) raw.push(h);
      if (onProgress) onProgress(Math.min(1, (i + 1500) / grid.pts.length));
    }
    return { step: grid.step, ele: RT.gauss(raw, 400 / grid.step) };
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
