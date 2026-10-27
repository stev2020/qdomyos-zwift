// FunRun: "Übernehmen" in the app's browser (FunRunPage.qml). Some sites let only browsers in (DotWatcher, the trackers of
// FollowMyChallenge), so the app shows them in its browser. When "Übernehmen" is tapped there, the app runs this file in the
// page the browser shows and reads window.__funrunTake = { state: 'busy' | 'done' | 'error', text, data } until it is no
// longer busy; data goes to the FunRun page (window.funrunHandoff):
//  - DotWatcher, the page of a race: { kind: 'dwrace', item } (the race's data as DotWatcher's own page has them)
//  - FollowMyChallenge, the tracker of a race: { kind: 'fmc', id, page, routes: { <file>: <text> } } (the part of the page
//    with the route files and checkpoints, and the route files, as the app would load them itself)
// No dependency on the app, plain string handling.
(function () {
  'use strict';
  const now = window.__funrunTake;
  if (now && now.state === 'busy') return;
  const set = (state, text, data) => { window.__funrunTake = { state, text: text || '', data: data || null }; };
  const host = location.hostname.toLowerCase(), parts = location.pathname.split('/').filter(Boolean);
  const text = async url => {
    const r = await fetch(url, { credentials: 'include' });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    return r.text();
  };

  async function dotwatcher() {
    // the race of the page: its own page (/race/<slug>) or its results (/results/<year>/<slug>, from the archive)
    const slugPart = parts[0] === 'race' ? parts[1] : parts[0] === 'results' && parts.length >= 3 ? parts[2] : '';
    if (!slugPart) return set('error', 'Öffne zuerst ein Rennen (im Archiv ein Jahr), dann tippe auf „Übernehmen“.');
    // the data of the Next.js page that was loaded first (its scripts keep a copy in window.__NEXT_DATA__; before they
    // ran, that name is the script element that holds them)
    let nd = window.__NEXT_DATA__;
    if (!nd || !nd.buildId) {
      const el = document.getElementById('__NEXT_DATA__');
      try { nd = el ? JSON.parse(el.textContent) : null; } catch (e) { nd = null; }
    }
    nd = nd || {};
    const slug = decodeURIComponent(slugPart);
    const raceOf = j => {
      const d = j && j.pageProps && j.pageProps.data, c = d && d.racesCollection;
      return (c && c.items && c.items[0]) || null;
    };
    // the page's own data when it was opened directly ("/race/[slug]/[[...params]]"); else the data its links load
    // (DotWatcher's site does the same)
    const own = parts[0] === 'race' && String(nd.page || '').indexOf('/race/[slug]') === 0 && nd.query && nd.query.slug === slug;
    let it = own ? raceOf(nd.props) : null;
    if (!it) {
      if (!nd.buildId) throw new Error('DotWatcher hat seine Seiten umgebaut');
      const q = encodeURIComponent(slug);
      it = raceOf(JSON.parse(await text('/_next/data/' + nd.buildId + '/race/' + q + '.json?slug=' + q)));
    }
    if (!it) return set('error', 'DotWatcher kennt dieses Rennen nicht.');
    const item = { slug };
    for (const k of ['slug', 'title', 'raceDate', 'raceEndDate', 'location', 'length', 'elevation', 'terrain', 'shortDescription', 'trackleadersRaceId', 'website']) {
      const v = it[k];
      if (typeof v === 'string' || typeof v === 'number') item[k] = String(v);
    }
    set('done', '', { kind: 'dwrace', item });
  }

  async function followmychallenge() {
    const i = parts.indexOf('live'), id = i >= 0 ? parts[i + 1] : parts[0];
    if (!id) return set('error', 'Öffne zuerst den Tracker eines Rennens.');
    const base = location.origin + '/' + parts.slice(0, i >= 0 ? i + 2 : 1).join('/') + '/';
    const html = document.documentElement.outerHTML, mark = 'prefetch.route.php?r=';
    const first = html.indexOf(mark);
    if (first < 0) return set('error', 'Auf dieser Seite ist noch keine Strecke zu finden. Ist die Karte schon geladen?');
    const files = [];
    for (let k = first; k >= 0; k = html.indexOf(mark, k + 1)) {
      let e = k + mark.length;
      while (e < html.length && html[e] !== '&' && html[e] !== "'" && html[e] !== '"' && html[e] !== ' ') e++;
      const f = html.slice(k + mark.length, e);
      if (f && files.indexOf(f) < 0) files.push(f);
    }
    const routes = {};
    for (const f of files) {
      set('busy', 'Strecke wird gelesen …');
      routes[f] = await text(base + 'application/helpers/prefetch.route.php?r=' + f + '&light=false');
    }
    // the checkpoints are written shortly before the route files: that part of the page is enough
    const cp = html.indexOf('checkpointFloatingLabel_CP'), from = Math.max(0, Math.min(first, cp >= 0 ? cp : first) - 100000);
    set('done', '', { kind: 'fmc', id, page: html.slice(from, html.lastIndexOf(mark) + 200000), routes });
  }

  set('busy', 'Wird übernommen …');
  const job = host === 'dotwatcher.cc' || host === 'www.dotwatcher.cc' ? dotwatcher
    : host === 'followmychallenge.com' || host.endsWith('.followmychallenge.com') ? followmychallenge
      : async () => set('error', 'Von dieser Seite kann die App nichts übernehmen.');
  job().catch(e => set('error', 'Das hat nicht geklappt: ' + ((e && e.message) || e)));
})();
