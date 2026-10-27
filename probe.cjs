// The routes of the races for the app's selection, as the app would take them (variant, heights, climbing of a project)
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
const races = [['aztr26', 1375], ['ctr26', 828], ['arkhigh26', 1635], ['tnga26', 571], ['transatlantic25', 2417], ['bcepic26', 1049],
  ['https://app.madcap.cc/event/lakes-n-knodel-26', 725], ['https://app.madcap.cc/event/say-hi-to-hermann-26', 751], ['https://app.madcap.cc/event/peninsular-divide-26', 1520]];
(async () => {
  for (const [ref, want] of races) {
    try {
      const r = await RT.raceRoute(RT.tracker(ref));
      let v = r.variants.find(x => x.main) || r.variants.slice().sort((a, b) => Math.abs(a.km - want) - Math.abs(b.km - want))[0];
      const pts = (await RT.variantHeights(v)) || null;
      let asc = 'no heights';
      if (pts) { const p = RT.makeProject({ id: 'x', name: 'x' }, pts, 50000, {}); asc = p.ascent + ' m (project), ' + (p.length / 1000).toFixed(0) + ' km'; }
      let la0 = 90, la1 = -90, lo0 = 180, lo1 = -180;
      for (const q of v.pts) { la0 = Math.min(la0, q[0]); la1 = Math.max(la1, q[0]); lo0 = Math.min(lo0, q[1]); lo1 = Math.max(lo1, q[1]); }
      const f = v.pts[0], l = v.pts[v.pts.length - 1];
      const cps = RT.placeCps(v.pts, r.cps);
      console.log(ref, '|', v.name || v.key, v.km.toFixed(0) + ' km |', asc, '| start', f[0].toFixed(3) + ',' + f[1].toFixed(3), 'end', l[0].toFixed(3) + ',' + l[1].toFixed(3),
        '| lat', la0.toFixed(2) + '..' + la1.toFixed(2), 'lon', lo0.toFixed(2) + '..' + lo1.toFixed(2), '| cps', cps.map(c => c.name + '@' + Math.round(c.at / 1000)).join(', '));
    } catch (e) { console.log(ref, '| ERROR', e.message); }
  }
})();
