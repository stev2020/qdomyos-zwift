// What the app would get from the trackers of some races (the app's own code, its user agent)
globalThis.window = globalThis;
require('./funrun-routes.js');
const RT = window.FRR;
const UA = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36 FunRun';
RT.fetchText = async (url, opts) => {
  const o = opts || {};
  const r = await fetch(url, o.method === 'POST' ? { method: 'POST', headers: { 'Content-Type': o.type || 'application/json', 'User-Agent': UA }, body: o.body || '' } : { headers: { 'User-Agent': UA } });
  if (!r.ok) throw new Error('HTTP ' + r.status);
  return r.text();
};
const refs = process.argv.slice(2).length ? process.argv.slice(2) : [
  'aztr26', 'arkhigh26', 'tnga26', 'transatlantic25', 'transatlantic26', 'logdrivers26', 'tourdivide25', 'highland26', 'ctr26', 'bcepic26', 'transam26',
  'https://app.madcap.cc/event/lakes-n-knodel-26', 'https://app.madcap.cc/event/gravel-n-grostl-26', 'https://app.madcap.cc/event/say-hi-to-hermann-26',
  'https://app.madcap.cc/event/peninsular-divide-26'];
(async () => {
  for (const ref of refs) {
    const t = RT.tracker(ref);
    let title = '';
    if (t.kind === 'tl') {
      try { const h = await RT.fetchText('https://trackleaders.com/' + t.id); const a = h.indexOf('<title>'); title = a >= 0 ? h.slice(a + 7, h.indexOf('</title>', a)) : ''; } catch (e) { title = 'page ' + e.message; }
    }
    try {
      const r = await RT.raceRoute(t);
      const vs = r.variants.map(v => (v.name || v.key) + ' ' + v.km.toFixed(0) + 'km' + (v.main ? ' main' : '') + (v.heights ? ' ele' : ''));
      let asc = '';
      const v0 = r.variants.find(v => v.main) || r.variants[0];
      if (v0 && v0.heights) { let up = 0; for (let i = 1; i < v0.pts.length; i++) { const d = v0.pts[i][2] - v0.pts[i - 1][2]; if (d > 0) up += d; } asc = ' up(raw)=' + Math.round(up); }
      if (v0 && v0.tl) { try { const p = await RT.variantHeights(v0); if (p) { let up = 0; for (let i = 1; i < p.length; i++) { const d = p[i][2] - p[i - 1][2]; if (d > 0) up += d; } asc = ' up(tl)=' + Math.round(up); } } catch (e) { asc = ' ele ' + e.message; } }
      const f = v0 && v0.pts[0], l = v0 && v0.pts[v0.pts.length - 1];
      console.log(ref, '|', title, '|', vs.join(', '), '| cps', r.cps.length, r.cps.slice(0, 8).map(c => c.name).join('/'), asc,
        '| start', f && f[0].toFixed(3) + ',' + f[1].toFixed(3), 'end', l && l[0].toFixed(3) + ',' + l[1].toFixed(3));
    } catch (e) { console.log(ref, '|', title, '| ERROR', e.message); }
  }
})();
