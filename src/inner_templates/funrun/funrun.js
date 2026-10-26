// FunRun pages: connection to the app over the template web socket (/funrun-ws) and shared helpers.
// Test without the app: ?demo=<folder with rides.json and rides/<id>.json>
(function () {
  'use strict';
  const FR = (window.FR = {});
  FR.qs = new URLSearchParams(location.search);
  FR.$ = id => document.getElementById(id);

  // ---------------------------------------------------------------- formatting (German)
  FR.num = (x, d) => (Number.isFinite(x) ? x : 0).toLocaleString('de-DE', { minimumFractionDigits: d || 0, maximumFractionDigits: d || 0 });
  FR.km = m => FR.num(m / 1000, 1);
  // 8929 -> "2:28:49", 2850 -> "47:30"
  FR.time = sec => {
    sec = Math.max(0, Math.round(sec || 0));
    const h = Math.floor(sec / 3600), m = Math.floor(sec / 60) % 60, s = sec % 60;
    const p2 = v => String(v).padStart(2, '0');
    return h ? h + ':' + p2(m) + ':' + p2(s) : m + ':' + p2(s);
  };
  // signed difference: "−2:13" / "+0:41"
  FR.diff = sec => (sec < 0 ? '−' : '+') + FR.time(Math.abs(sec));
  const DAYS = ['So', 'Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa'];
  const DAYS_LONG = ['Sonntag', 'Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag'];
  const MONTHS = ['Januar', 'Februar', 'März', 'April', 'Mai', 'Juni', 'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember'];
  FR.date = iso => new Date(iso);
  FR.clock = d => d.getHours() + ':' + String(d.getMinutes()).padStart(2, '0');
  FR.day = d => DAYS[d.getDay()] + ', ' + d.getDate() + '. ' + MONTHS[d.getMonth()];
  FR.dayLong = d => DAYS_LONG[d.getDay()] + ', ' + d.getDate() + '. ' + MONTHS[d.getMonth()] + ' ' + d.getFullYear();
  FR.months = MONTHS;
  FR.daysShort = DAYS;
  // "Heute", "Gestern", "Do, 22.10."
  FR.when = d => {
    const now = new Date(), a = new Date(now.getFullYear(), now.getMonth(), now.getDate()), b = new Date(d.getFullYear(), d.getMonth(), d.getDate());
    const days = Math.round((a - b) / 86400000);
    if (days === 0) return 'Heute';
    if (days === 1) return 'Gestern';
    return DAYS[d.getDay()] + ', ' + d.getDate() + '.' + (d.getMonth() + 1) + '.';
  };
  const COMPASS = ['Norden', 'Nordosten', 'Osten', 'Südosten', 'Süden', 'Südwesten', 'Westen', 'Nordwesten'];
  FR.compass = deg => COMPASS[Math.floor(((((deg % 360) + 360) % 360) + 22.5) / 45) % 8];
  const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' };
  FR.esc = s => Array.from(String(s == null ? '' : s), c => ESC[c] || c).join('');

  // heart rate zones as at Orangetheory (share of the maximum heart rate)
  FR.HR_ZONES = [
    { name: 'Grau', color: '#b9c2cc' }, { name: 'Blau', color: '#3d9bff' }, { name: 'Grün', color: '#3fcf5e' },
    { name: 'Orange', color: '#ff8c1a' }, { name: 'Rot', color: '#ff4d4d' },
  ];

  // a route ride: its time from the start of the route (finished) or none
  FR.routeTime = r => (r && r.route && r.route.finished ? r.route.time : null);
  FR.title = r => (r.route ? r.route.name : 'Freie Fahrt');

  // ---------------------------------------------------------------- talking to the app
  const demo = FR.qs.get('demo');
  let ws = null, open = false;
  const queue = [], pending = [];
  function connect() {
    if (demo || !location.host) return;
    try { ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/funrun-ws'); } catch (e) { setTimeout(connect, 2000); return; }
    ws.onopen = () => { open = true; while (queue.length) ws.send(queue.shift()); };
    ws.onclose = () => { open = false; ws = null; setTimeout(connect, 2000); };
    ws.onerror = () => { try { ws.close(); } catch (e) { /* ignore */ } };
    ws.onmessage = ev => {
      let m;
      try { m = JSON.parse(ev.data); } catch (e) { return; }
      if (m.msg === 'workout') { FR.workout = m.content || {}; for (const f of workoutListeners) f(FR.workout); return; }
      for (let i = 0; i < pending.length; i++) {
        const p = pending[i];
        if (p.reply === m.msg && (!p.match || p.match(m.content))) { pending.splice(i, 1); clearTimeout(p.timer); p.resolve(m.content); return; }
      }
    };
  }
  FR.send = (msg, content) => {
    const data = JSON.stringify(content === undefined ? { msg } : { msg, content });
    if (open && ws) ws.send(data); else queue.push(data);
  };
  function request(msg, content, match) {
    return new Promise((resolve, reject) => {
      const p = { reply: 'R_' + msg, match, resolve };
      p.timer = setTimeout(() => { const i = pending.indexOf(p); if (i >= 0) pending.splice(i, 1); reject(new Error('Keine Antwort von der App')); }, 20000);
      pending.push(p);
      FR.send(msg, content);
    });
  }
  async function demoJson(path) {
    const r = await fetch((demo.endsWith('/') ? demo : demo + '/') + path);
    if (!r.ok) throw new Error(path + ': HTTP ' + r.status);
    return r.json();
  }
  // summaries of all rides, newest first
  FR.rides = async () => (demo ? (await demoJson('rides.json')).rides || [] : (await request('funrun_rides')) || []);
  // one whole ride: { summary, samples }
  FR.ride = async id => (demo ? demoJson('rides/' + id + '.json') : ((await request('funrun_ride', { id }, c => c && c.id === id)) || {}).ride);
  FR.remove = async id => (demo ? { ok: true } : request('funrun_delete', { id }, c => c && c.id === id));
  // closes this page in the app: 'home' goes back to the start page, 'back' one page back
  FR.close = to => FR.send('funrun_close', { to: to || 'home' });
  // GPX routes of the app (name, length, ascent, outline, profile)
  FR.routes = async () => {
    if (!demo) return (await request('funrun_routes')) || [];
    let saved = [];
    try { saved = JSON.parse(sessionStorage.getItem('funrunDemoRoutes') || '[]') || []; } catch (e) { /* none */ }
    return ((await demoJson('routes.json')).routes || []).concat(saved);
  };
  // starts a route: the app loads it, starts the ride and shows the 3D map
  FR.start = file => (demo ? Promise.resolve({ ok: true }) : request('funrun_start', { file }));
  // pages of the app: 'settings', 'menu', 'tiles', 'trainingprograms', 'gpxlist', 'gpx' (import)
  FR.open = what => FR.send('funrun_open', { what });
  // a web page in the browser of the device (https only)
  FR.openUrl = url => (demo ? window.open(url, '_blank') : FR.send('funrun_open', { what: 'url', url }));

  // demo: what the pages "saved" (routes, long route projects), kept in the tab's storage
  const demoStore = key => { try { return JSON.parse(sessionStorage.getItem(key) || 'null'); } catch (e) { return null; } };
  const demoKeep = (key, v) => { try { sessionStorage.setItem(key, JSON.stringify(v)); } catch (e) { /* not available */ } };
  let tagCounter = 0;
  // a new route in the app's gpx folder: { ok, file } (demo: info is the route's description for the list)
  FR.saveGpx = async (name, gpx, info) => {
    if (demo) {
      const file = '/demo/gpx/' + name + '.gpx', saved = demoStore('funrunDemoRoutes') || [];
      if (info) saved.push(Object.assign({}, info, { name, file, key: name.toLowerCase() }));
      demoKeep('funrunDemoRoutes', saved);
      return { ok: true, file };
    }
    const tag = 't' + Date.now() + '-' + (++tagCounter);
    return request('funrun_save_gpx', { name, gpx, tag }, c => c && c.tag === tag);
  };
  // text of a route file of the app
  FR.readGpx = async file => {
    if (demo) { const r = await fetch(file); return r.ok ? r.text() : ''; }
    const c = await request('funrun_read_gpx', { file }, x => x && x.file === file);
    return c && c.ok ? c.text : '';
  };
  // long routes in stages
  FR.ultraList = async () => (demo ? Object.values(demoStore('funrunDemoUltra') || {}).map(p => Object.assign({}, p, { track: undefined }))
    : (await request('funrun_ultra_list')) || []);
  FR.ultraGet = async id => (demo ? (demoStore('funrunDemoUltra') || {})[id] || null
    : ((await request('funrun_ultra_get', { id }, c => c && c.id === id)) || {}).project || null);
  FR.ultraSave = async project => {
    if (demo) { const all = demoStore('funrunDemoUltra') || {}; all[project.id] = project; demoKeep('funrunDemoUltra', all); return { ok: true }; }
    return request('funrun_ultra_save', { project }, c => c && c.id === project.id);
  };
  FR.ultraDelete = async id => {
    if (demo) { const all = demoStore('funrunDemoUltra') || {}; delete all[id]; demoKeep('funrunDemoUltra', all); return { ok: true }; }
    return request('funrun_ultra_delete', { id }, c => c && c.id === id);
  };
  // moves an imported route file into the long route's folder (it is no longer listed as one route)
  FR.ultraAdopt = async (file, id) => (demo ? { ok: true, file } : request('funrun_ultra_adopt', { file, id }, c => c && c.id === id));
  // app settings
  // (demo: kept in the tab's storage, so a choice survives going to another FunRun page)
  let demoSettings = {};
  try { demoSettings = JSON.parse(sessionStorage.getItem('funrunDemoSettings') || '{}') || {}; } catch (e) { /* not available */ }
  FR.getSettings = async keys => {
    if (demo) { const o = {}; for (const k of keys) o[k] = demoSettings[k] !== undefined ? demoSettings[k] : null; return o; }
    return (await request('getsettings', { keys })) || {};
  };
  FR.setSettings = obj => {
    if (!demo) { FR.send('setsettings', obj); return; }
    Object.assign(demoSettings, obj);
    try { sessionStorage.setItem('funrunDemoSettings', JSON.stringify(demoSettings)); } catch (e) { /* not available */ }
  };
  // ride time estimate of routes: speed on the flat and climbing rate, fixed or learned from the rides
  // (pages that use it load funrun-routes.js)
  FR.speedParams = async rides => {
    const st = await FR.getSettings(['funrun_flat_speed', 'funrun_climb_rate', 'funrun_speed_adaptive']);
    const on = v => v === true || v === 'true' || v === 1 || v === '1';
    return window.FRR.speedParams({ flat: +st.funrun_flat_speed || 25, climb: +st.funrun_climb_rate || 700,
      adaptive: on(st.funrun_speed_adaptive) }, rides || []);
  };
  // live values of the app (every second): bike, heart rate, auto resistance ...
  FR.workout = null;
  const workoutListeners = [];
  FR.onWorkout = f => workoutListeners.push(f);
  // (demo: tests hand in live values here)
  if (demo) FR.demoWorkout = w => { FR.workout = w; for (const f of workoutListeners) f(w); };
  connect();

  // the app calls window.funrunRefresh() when the page shows again (back from a ride, from the settings)
  FR.onRefresh = f => { window.funrunRefresh = f; };

  // bottom navigation of the FunRun pages
  FR.tabs = active => {
    const items = [
      ['start.htm', 'Fahren', '<circle cx="5.5" cy="16.5" r="3.5"/><circle cx="18.5" cy="16.5" r="3.5"/><path d="M5.5 16.5 9 9h6.5l3 7.5M9 9l3.5 7.5M14 5.5h2.5l-1 3.5"/>'],
      ['strecken.htm', 'Strecken', '<circle cx="6" cy="18" r="2"/><circle cx="18" cy="6" r="2"/><path d="M8 18h7.5a3.5 3.5 0 0 0 0-7h-7a3.5 3.5 0 0 1 0-7H16"/>'],
      ['verlauf.htm', 'Verlauf', '<path d="M4 20V11M10 20V5M16 20v-6M22 20H2"/>'],
      ['einstellungen.htm', 'Einstellungen', '<path d="M4 6h9M17 6h3M4 12h3M11 12h9M4 18h11M19 18h1"/><circle cx="15" cy="6" r="2"/><circle cx="9" cy="12" r="2"/><circle cx="17" cy="18" r="2"/>'],
    ];
    const nav = document.createElement('nav');
    nav.className = 'tabs';
    nav.setAttribute('aria-label', 'FunRun');
    for (const [page, label, icon] of items) {
      const a = document.createElement('a');
      a.href = '#';
      if (page === active) { a.className = 'on'; a.setAttribute('aria-current', 'page'); }
      a.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + icon + '</svg>' + label;
      a.addEventListener('click', e => { e.preventDefault(); if (page !== active) FR.go(page); });
      nav.appendChild(a);
    }
    document.body.appendChild(nav);
    document.body.classList.add('withtabs');
  };
  // to another FunRun page in the same view (no history: the app's back button closes the FunRun pages)
  FR.go = (page, query) => location.replace(page + '?v=' + Date.now() + (query ? '&' + query : '') + (demo ? '&demo=' + encodeURIComponent(demo) : ''));

  // ---------------------------------------------------------------- samples of a ride
  // route rides: time since the start of the route by distance along the route (for comparing rides)
  FR.routeTrack = samples => {
    const t = samples.t, d = samples.d, T = [], D = [];
    let t0 = null, dmax = -1;
    for (let i = 0; i < t.length; i++) {
      if (!(d[i] >= 0)) continue;
      if (t0 == null) t0 = t[i];
      if (d[i] < dmax) continue; // distance never goes back
      dmax = d[i];
      T.push(t[i] - t0); D.push(d[i]);
    }
    return { T, D, reached: dmax };
  };
  // time when the track reached distance x (null beyond its end)
  FR.timeAt = (tr, x) => {
    const D = tr.D, T = tr.T;
    if (!D.length || x > D[D.length - 1]) return null;
    let lo = 0, hi = D.length - 1;
    if (x <= D[0]) return T[0];
    while (hi - lo > 1) { const m = (lo + hi) >> 1; if (D[m] <= x) lo = m; else hi = m; }
    const u = D[hi] > D[lo] ? (x - D[lo]) / (D[hi] - D[lo]) : 0;
    return T[lo] + u * (T[hi] - T[lo]);
  };
  // distance reached at time x
  FR.distAt = (tr, x) => {
    const D = tr.D, T = tr.T;
    if (!T.length) return 0;
    if (x <= T[0]) return D[0];
    if (x >= T[T.length - 1]) return D[D.length - 1];
    let lo = 0, hi = T.length - 1;
    while (hi - lo > 1) { const m = (lo + hi) >> 1; if (T[m] <= x) lo = m; else hi = m; }
    const u = T[hi] > T[lo] ? (x - T[lo]) / (T[hi] - T[lo]) : 0;
    return D[lo] + u * (D[hi] - D[lo]);
  };
})();
