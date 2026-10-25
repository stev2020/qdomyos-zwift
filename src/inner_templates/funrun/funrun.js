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
  connect();

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
