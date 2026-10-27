// FunRun world: a painted fantasy world along the route (three.js, no map service, no key, works offline).
// Only the course of the route and its elevation profile are used. The land around it, forests, towns with walls
// and gates, castles on their rocks, villages, stone circles, watchtowers with beacons and the torches along the way
// are made up here, the same every time for the same route. Look: winter in the blue hour (painted light: warm torches,
// cool snow, the last light on the peaks, an aurora).
// welt.htm: const w = Welt.create(container); w.setRoute(route, checkpoints); w.frame(dt, state) on every frame.
(function () {
'use strict';
const T = window.THREE;

// ------------------------------------------------------------------ helpers
const clamp = (x, a, b) => (x < a ? a : x > b ? b : x);
const mix = (a, b, t) => a + (b - a) * t;
const smooth = (a, b, x) => { const t = clamp((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); };
function hash2(ix, iz, seed) {
  let h = Math.imul(ix, 374761393) ^ Math.imul(iz, 668265263) ^ Math.imul(seed | 0, 1442695041);
  h = Math.imul(h ^ (h >>> 13), 1274126177);
  return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
}
function vnoise(x, z, seed) {
  const ix = Math.floor(x), iz = Math.floor(z), fx = x - ix, fz = z - iz;
  const u = fx * fx * (3 - 2 * fx), v = fz * fz * (3 - 2 * fz);
  const a = hash2(ix, iz, seed), b = hash2(ix + 1, iz, seed), c = hash2(ix, iz + 1, seed), d = hash2(ix + 1, iz + 1, seed);
  return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v;
}
function fbm(x, z, oct, seed) {
  let s = 0, amp = 0.5, f = 1, norm = 0;
  for (let i = 0; i < oct; i++) { s += amp * vnoise(x * f, z * f, seed + i * 17); norm += amp; f *= 2.03; amp *= 0.5; }
  return s / norm;
}
function rng(seed) {
  let a = seed >>> 0;
  return () => { a = (a + 0x6D2B79F5) | 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}
function hashStr(s) { let h = 2166136261; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return h >>> 0; }
const C = c => new T.Color(c);
const gkey = (a, b) => (a + 0x8000) * 0x10000 + (b + 0x8000);

// ------------------------------------------------------------------ the look: winter, blue hour
const LOOK = {
  snow: '#f3f5fa', snow2: '#e7edf5', warm: '#fff3ef', cool: '#d5e0f2', floor: '#d3d9e8', forestFar: '#45667a', rock: '#9a9cc0',
  verge: '#d8d1df', town: '#e1e0ec', road: '#cbc5d6',
  sky: ['#24386f', '#f6c2ae'], skyMid: '#8a7cbc', fog: '#8d8fc0', fogSun: '#e8aaa2', fogDensity: 0.00011,
  sun: '#ff9f86', sunI: 2.6, hemi: ['#6f8fd6', '#9b8fc4'], hemiI: 1.35,
  conifer: '#24525a', trunk: '#4a3a33', snowCap: '#fbfdff',
  walls: ['#efe4d6', '#e6d6c2', '#eadcd0', '#dccbb5'], roofs: ['#f4f6fb', '#56607a', '#f4f6fb', '#7a5f58'], tower: '#56607a',
  stone: '#c8c2c8', stones: '#aaa5ba', flag: '#c8443a', jersey: '#ff7a1a',
  haze: 0.18, wrap: 0.25, term: [0.18, 0.04, 0.02], bloom: 0.42, aurora: 0.6, exposure: 1.2,
};
const NOISE_Q = 8192; // the brush noise repeats every 8.192 km, so it does not jump when the world origin moves

// ------------------------------------------------------------------ painted materials
// Lambert with soft wrapped light and a warm band where light turns to shadow, brush noise in the colours,
// haze in the valleys and fog that warms towards the sun; the sun itself only lights the high ground (alpenglow).
const PU = {
  uSunDirW: { value: new T.Vector3(0.75, 0.1, -0.64).normalize() }, uFogSun: { value: C(LOOK.fogSun) },
  uHaze: { value: LOOK.haze }, uHazeBase: { value: 0 }, uHazeFall: { value: 70 },
  uWrap: { value: LOOK.wrap }, uTerm: { value: new T.Vector3(...LOOK.term) },
  uAlpen: { value: new T.Vector3(1, 650, 1250) }, uNoiseOff: { value: new T.Vector2() },
};
const PAINT_PARS = `
varying vec3 vWPos;
uniform vec3 uSunDirW; uniform vec3 uFogSun; uniform float uHaze; uniform float uHazeBase; uniform float uHazeFall;
uniform float uWrap; uniform vec3 uTerm; uniform float uBrush; uniform vec3 uAlpen; uniform vec2 uNoiseOff;
float pHash(vec3 p) { p = fract(p * 0.3183099 + 0.1); p *= 17.0; return fract(p.x * p.y * p.z * (p.x + p.y + p.z)); }
float pNoise(vec3 x, float per) {
  vec3 i = floor(x), f = fract(x); f = f * f * (3.0 - 2.0 * f);
  vec3 j = vec3(mod(i.x + 1.0, per), i.y + 1.0, mod(i.z + 1.0, per)); i = vec3(mod(i.x, per), i.y, mod(i.z, per));
  return mix(mix(mix(pHash(i), pHash(vec3(j.x, i.y, i.z)), f.x), mix(pHash(vec3(i.x, j.y, i.z)), pHash(vec3(j.x, j.y, i.z)), f.x), f.y),
    mix(mix(pHash(vec3(i.x, i.y, j.z)), pHash(vec3(j.x, i.y, j.z)), f.x), mix(pHash(vec3(i.x, j.y, j.z)), pHash(vec3(j.x, j.y, j.z)), f.x), f.y), f.z);
}
float pAlpen() { return uAlpen.x > 0.5 ? smoothstep(uAlpen.y, uAlpen.z, vWPos.y) : 1.0; }
`;
const PAINT_LAMBERT = `
varying vec3 vViewPosition;
struct LambertMaterial { vec3 diffuseColor; float specularStrength; };
void RE_Direct_Lambert( const in IncidentLight directLight, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in LambertMaterial material, inout ReflectedLight reflectedLight ) {
  float ndl = dot( geometryNormal, directLight.direction );
  float w = clamp( ( ndl + uWrap ) / ( 1.0 + uWrap ), 0.0, 1.0 );
  float band = smoothstep( 0.0, 0.22, w ) * ( 1.0 - smoothstep( 0.22, 0.6, w ) );
  vec3 irradiance = directLight.color * ( vec3( w ) + band * uTerm );
  reflectedLight.directDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
void RE_IndirectDiffuse_Lambert( const in vec3 irradiance, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in LambertMaterial material, inout ReflectedLight reflectedLight ) {
  reflectedLight.indirectDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
#define RE_Direct RE_Direct_Lambert
#define RE_IndirectDiffuse RE_IndirectDiffuse_Lambert
`;
let PAINT_LIGHTS = T.ShaderChunk.lights_fragment_begin;
{
  // the sun (the directional light) only on the high ground; the torches (point lights) everywhere
  const a = PAINT_LIGHTS.indexOf('NUM_DIR_LIGHTS > 0'), b = PAINT_LIGHTS.indexOf('RE_Direct( directLight', a);
  if (a >= 0 && b > a) PAINT_LIGHTS = PAINT_LIGHTS.slice(0, b) + 'directLight.color *= pAlpen();\n\t\t' + PAINT_LIGHTS.slice(b);
}
const PAINT_BRUSH = `
if ( uBrush > 0.0 ) {
  vec3 q = vec3( vWPos.x + uNoiseOff.x, vWPos.y, vWPos.z + uNoiseOff.y );
  float b = pNoise( q / 8.0, ${NOISE_Q / 8}.0 ) * 0.6 + pNoise( q / 2.0 + vec3( 0.0, 11.0, 0.0 ), ${NOISE_Q / 2}.0 ) * 0.4 - 0.5;
  float hue = pNoise( q / 32.0 + vec3( 0.0, 5.0, 0.0 ), ${NOISE_Q / 32}.0 );
  diffuseColor.rgb *= 1.0 + b * 0.3 * uBrush;
  diffuseColor.rgb *= mix( vec3( 1.0 ), mix( vec3( 0.93, 0.99, 1.08 ), vec3( 1.07, 1.01, 0.91 ), hue ), 0.7 * uBrush );
}
`;
const PAINT_FOG = `
#ifdef USE_FOG
  float pfd = vFogDepth;
  float pf = 1.0 - exp( - fogDensity * fogDensity * pfd * pfd );
  float ph = uHaze * exp( - max( vWPos.y - uHazeBase, 0.0 ) / uHazeFall ) * ( 1.0 - exp( - pfd / 700.0 ) );
  pf = clamp( pf + ph * ( 1.0 - pf ), 0.0, 1.0 );
  vec3 pvd = normalize( vWPos - cameraPosition );
  float psa = pow( max( dot( pvd, uSunDirW ), 0.0 ), 4.0 );
  gl_FragColor.rgb = mix( gl_FragColor.rgb, mix( fogColor, uFogSun, psa ), pf );
#endif
`;
function paint(m, brush) {
  m.onBeforeCompile = sh => {
    Object.assign(sh.uniforms, PU, { uBrush: { value: brush || 0 } });
    sh.vertexShader = 'varying vec3 vWPos;\n' + sh.vertexShader.replace('#include <project_vertex>',
      '#include <project_vertex>\n{ vec4 pw = vec4( transformed, 1.0 );\n#ifdef USE_INSTANCING\npw = instanceMatrix * pw;\n#endif\nvWPos = ( modelMatrix * pw ).xyz; }');
    sh.fragmentShader = PAINT_PARS + sh.fragmentShader
      .replace('#include <lights_lambert_pars_fragment>', PAINT_LAMBERT)
      .replace('#include <lights_fragment_begin>', PAINT_LIGHTS)
      .replace('#include <color_fragment>', '#include <color_fragment>\n' + PAINT_BRUSH)
      .replace('#include <fog_fragment>', PAINT_FOG);
  };
  m.customProgramCacheKey = () => 'funrun-paint';
  return m;
}
const lambert = (opts, brush) => paint(new T.MeshLambertMaterial(opts), brush == null ? 0.5 : brush);

// ------------------------------------------------------------------ geometry helpers
// unit shapes standing on y = 0, placed and sized by a matrix
const UNIT = {};
function units() {
  if (UNIT.box) return UNIT;
  UNIT.box = new T.BoxGeometry(1, 1, 1).translate(0, 0.5, 0);
  UNIT.cyl = new T.CylinderGeometry(1, 1, 1, 14, 1).translate(0, 0.5, 0);
  UNIT.cyl6 = new T.CylinderGeometry(1, 1, 1, 6, 1).translate(0, 0.5, 0);
  UNIT.cone = new T.ConeGeometry(1, 1, 14, 1).translate(0, 0.5, 0);
  UNIT.cone10 = new T.ConeGeometry(1, 1, 10, 1).translate(0, 0.5, 0);
  UNIT.tcone = new T.ConeGeometry(1, 1, 8, 1, true).translate(0, 0.5, 0);
  UNIT.tcyl = new T.CylinderGeometry(1, 1, 1, 5, 1, true).translate(0, 0.5, 0);
  UNIT.pyr = new T.ConeGeometry(1, 1, 4, 1).rotateY(Math.PI / 4).translate(0, 0.5, 0);
  // roof prism: ridge along z, base from x -0.5 to 0.5 at y 0, ridge at y 1
  const sh = new T.Shape([new T.Vector2(-0.5, 0), new T.Vector2(0.5, 0), new T.Vector2(0, 1)]);
  UNIT.prism = new T.ExtrudeGeometry(sh, { depth: 1, bevelEnabled: false }).translate(0, 0, -0.5);
  UNIT.stone = new T.CylinderGeometry(0.72, 1, 1, 5, 1).translate(0, 0.5, 0);
  return UNIT;
}
const _m4 = new T.Matrix4(), _q = new T.Quaternion(), _e = new T.Euler(), _p = new T.Vector3(), _s = new T.Vector3();
function M(x, y, z, rotY, sx, sy, sz, rotX, rotZ) {
  _e.set(rotX || 0, rotY || 0, rotZ || 0, 'YXZ');
  return _m4.compose(_p.set(x, y, z), _q.setFromEuler(_e), _s.set(sx == null ? 1 : sx, sy == null ? 1 : sy, sz == null ? 1 : sz)).clone();
}
// many parts merged into one geometry (one draw call): positions, normals, uv, a colour per part
class GeoBuilder {
  constructor() { this.p = []; this.n = []; this.u = []; this.c = []; }
  add(geo, m4, color) {
    const g = geo.index ? geo.toNonIndexed() : geo;
    const P = g.attributes.position, N = g.attributes.normal, U = g.attributes.uv;
    const nm = new T.Matrix3().getNormalMatrix(m4), v = new T.Vector3();
    const r = color ? color.r : 1, gg = color ? color.g : 1, b = color ? color.b : 1;
    for (let i = 0; i < P.count; i++) {
      v.fromBufferAttribute(P, i).applyMatrix4(m4); this.p.push(v.x, v.y, v.z);
      v.fromBufferAttribute(N, i).applyMatrix3(nm).normalize(); this.n.push(v.x, v.y, v.z);
      if (U) this.u.push(U.getX(i), U.getY(i)); else this.u.push(0, 0);
      this.c.push(r, gg, b);
    }
    return this;
  }
  get empty() { return this.p.length === 0; }
  build() {
    const g = new T.BufferGeometry();
    g.setAttribute('position', new T.Float32BufferAttribute(this.p, 3));
    g.setAttribute('normal', new T.Float32BufferAttribute(this.n, 3));
    g.setAttribute('uv', new T.Float32BufferAttribute(this.u, 2));
    g.setAttribute('color', new T.Float32BufferAttribute(this.c, 3));
    g.computeBoundingSphere();
    return g;
  }
}
function canvasTex(w, h, draw, srgb) {
  const cv = document.createElement('canvas'); cv.width = w; cv.height = h;
  draw(cv.getContext('2d'), w, h);
  const t = new T.CanvasTexture(cv);
  if (srgb !== false) t.colorSpace = T.SRGBColorSpace;
  return t;
}

// ------------------------------------------------------------------ the land: heights around the route
// Close to the road the ground lies at the road's height; further away it rolls, and beyond a kilometre or so
// mountains rise, higher where the route itself is in the mountains. Towns, villages, castle rocks and the knolls of
// stone circles and watchtowers shape it too.
class Field {
  constructor(route, seed) {
    this.seed = seed;
    const STEP = this.STEP = 15, n = this.n = Math.max(2, Math.floor(route.total / STEP) + 1);
    const sx = this.sx = new Float64Array(n), sz = this.sz = new Float64Array(n), se = this.se = new Float64Array(n);
    const p = {};
    let sum = 0;
    for (let k = 0; k < n; k++) {
      const s = Math.min(k * STEP, route.total);
      route.xzAt(s, p); sx[k] = p.x; sz[k] = p.z; se[k] = route.eleAt(s); sum += se[k];
    }
    this.meanE = sum / n;
    this.CS = 16;
    this.fine = this.grid(1, 300);
    this.coarse = this.grid(this.CS, 1500);
    // how mountainous the land is along the route (0 flat .. 1 high mountains)
    const W = Math.round(4000 / STEP), nc = Math.ceil(n / this.CS), raw = new Float64Array(nc);
    for (let c = 0; c < nc; c++) {
      const k = c * this.CS;
      let lo = Infinity, hi = -Infinity;
      for (let j = Math.max(0, k - W); j <= Math.min(n - 1, k + W); j += 2) { lo = Math.min(lo, se[j]); hi = Math.max(hi, se[j]); }
      raw[c] = clamp(clamp((hi - lo - 40) / 600, 0, 1) * 0.75 + clamp((se[k] - 500) / 1500, 0, 1) * 0.45, 0, 1);
    }
    this.rugC = new Float64Array(nc);
    for (let c = 0; c < nc; c++) {
      let a = 0, w = 0;
      for (let j = Math.max(0, c - 8); j <= Math.min(nc - 1, c + 8); j++) { a += raw[j]; w++; }
      this.rugC[c] = a / w;
    }
    this.places = [];
    this._fc = []; this._cc = [];
  }
  grid(stride, cell) {
    const m = new Map();
    for (let k = 0; k < this.n; k += stride) {
      const key = gkey(Math.floor(this.sx[k] / cell), Math.floor(this.sz[k] / cell));
      let l = m.get(key);
      if (!l) m.set(key, l = []);
      l.push(k);
    }
    return { m, cell };
  }
  gather(g, x0, z0, x1, z1, out) {
    out.length = 0;
    const c = g.cell, ax = Math.floor(x0 / c), bx = Math.floor(x1 / c), az = Math.floor(z0 / c), bz = Math.floor(z1 / c);
    for (let i = ax; i <= bx; i++) for (let j = az; j <= bz; j++) { const l = g.m.get(gkey(i, j)); if (l) for (let q = 0; q < l.length; q++) out.push(l[q]); }
    return out;
  }
  rugAt(k) { return k < 0 ? 0.3 : this.rugC[Math.min(this.rugC.length - 1, Math.floor(k / this.CS))]; }
  // the route near a point: d (distance), en (height of the road there), eb (heights of the route parts around,
  // weighted: no steps between the legs of hairpins), k (sample), rug
  nearest(x, z, fineC, coarseC, o) {
    const sx = this.sx, sz = this.sz, se = this.se;
    let best = Infinity, bk = -1;
    for (let q = 0; q < fineC.length; q++) {
      const k = fineC[q], dx = sx[k] - x, dz = sz[k] - z, d2 = dx * dx + dz * dz;
      if (d2 < best) { best = d2; bk = k; }
    }
    let d = Infinity, en = this.meanE, ebF = 0, haveF = false;
    if (bk >= 0 && best < 640000) {
      haveF = true;
      d = Math.sqrt(best); en = se[bk];
      for (const k2 of [bk - 1, bk + 1]) {
        if (k2 < 0 || k2 >= this.n) continue;
        const ax = sx[bk], az = sz[bk], dx = sx[k2] - ax, dz = sz[k2] - az, l2 = dx * dx + dz * dz;
        if (l2 <= 0) continue;
        const t = clamp(((x - ax) * dx + (z - az) * dz) / l2, 0, 1), px = ax + dx * t - x, pz = az + dz * t - z, dd = Math.sqrt(px * px + pz * pz);
        if (dd < d) { d = dd; en = se[bk] + (se[k2] - se[bk]) * t; }
      }
      const lim = (Math.sqrt(best) + 60) * (Math.sqrt(best) + 60);
      let sw = 0, swe = 0;
      for (let q = 0; q < fineC.length; q++) {
        const k = fineC[q], dx = sx[k] - x, dz = sz[k] - z, d2 = dx * dx + dz * dz;
        if (d2 < lim) { const w = 1 / (d2 + 400); sw += w; swe += w * se[k]; }
      }
      ebF = swe / sw;
      o.k = bk;
    }
    let ebC = ebF;
    if (!haveF || d > 500) {
      let bc = Infinity, kc = -1;
      for (let q = 0; q < coarseC.length; q++) {
        const k = coarseC[q], dx = sx[k] - x, dz = sz[k] - z, d2 = dx * dx + dz * dz;
        if (d2 < bc) { bc = d2; kc = k; }
      }
      if (kc < 0) { ebC = this.meanE; if (!haveF) { d = 9000; o.k = -1; } }
      else {
        if (!haveF) {
          let dc = Math.sqrt(bc);
          for (const k2 of [kc - this.CS, kc + this.CS]) {
            if (k2 < 0 || k2 >= this.n) continue;
            const ax = sx[kc], az = sz[kc], dx = sx[k2] - ax, dz = sz[k2] - az, l2 = dx * dx + dz * dz;
            if (l2 <= 0) continue;
            const t = clamp(((x - ax) * dx + (z - az) * dz) / l2, 0, 1), px = ax + dx * t - x, pz = az + dz * t - z;
            dc = Math.min(dc, Math.sqrt(px * px + pz * pz));
          }
          d = Math.max(dc, 790); en = se[kc]; o.k = kc;
        }
        const lim = (Math.sqrt(bc) + 800) * (Math.sqrt(bc) + 800);
        let sw = 0, swe = 0;
        for (let q = 0; q < coarseC.length; q++) {
          const k = coarseC[q], dx = sx[k] - x, dz = sz[k] - z, d2 = dx * dx + dz * dz;
          if (d2 < lim) { const w = 1 / (d2 + 40000); sw += w; swe += w * se[k]; }
        }
        ebC = swe / sw;
      }
    }
    o.d = d; o.en = en;
    o.eb = haveF ? mix(ebF, ebC, smooth(500, 800, d)) : ebC;
    o.rug = this.rugAt(o.k);
    return o;
  }
  // the land without towns and castles
  compose(x, z, nf) {
    const sd = this.seed, d = nf.d, rug = nf.rug;
    const corridor = smooth(9, 38, d);
    let h = mix(nf.en - 0.4, nf.eb, corridor);
    const hillAmp = 18 + 150 * rug, n1 = fbm(x / 420 + 31.7, z / 420 + 7.3, 4, sd + 1);
    h += corridor * hillAmp * ((n1 - 0.42) * 1.4 * (0.5 + 0.5 * smooth(30, 500, d)) + 0.55 * smooth(60, 900, d) * n1);
    const far = smooth(700, 5200, d);
    if (far > 0) {
      const n2 = fbm(x / 1700 + 3.1, z / 1700 + 9.9, 5, sd + 2);
      const rr = 1 - Math.abs(2 * vnoise(x / 1300 + 5.5, z / 1300 + 1.7, sd + 3) - 1);
      let hm = far * ((420 + 1500 * rug) * (0.35 + 0.65 * n2) + (500 + 900 * rug) * rr * rr * rr);
      const o = 0.8 * fbm(x / 900, z / 900, 2, sd + 4), Tb = 230, t = hm / Tb + o, ft = t - Math.floor(t);
      hm = mix(hm, (Math.floor(t) + smooth(0.35, 0.65, ft) - o) * Tb, 0.3);
      h += hm;
    }
    return h;
  }
  // towns and villages lie flat around the road; castles stand on rocks; stone circles and towers on knolls
  shape(x, z, h, nf, places) {
    for (let i = 0; i < places.length; i++) {
      const p = places[i];
      if (p.kind === 'town') {
        const dt = Math.hypot(x - p.x, z - p.z);
        if (dt < p.r + 130) h = mix(h, nf.en - 0.4, 1 - smooth(p.r - 6, p.r + 130, dt));
      } else if (p.kind === 'village') {
        if (nf.k >= 0 && nf.d < 150) {
          const s = nf.k * this.STEP, a = smooth(p.s0 - 160, p.s0, s) * (1 - smooth(p.s1, p.s1 + 160, s));
          if (a > 0) h = mix(h, nf.en - 0.4, a * (1 - smooth(40, 120, nf.d)));
        }
      } else if (p.kind === 'castle') {
        const dc = Math.hypot(x - p.x, z - p.z);
        if (dc < p.r1 + 40) {
          const k = dc * (1 + 0.22 * Math.cos(Math.atan2(z - p.z, x - p.x) - p.ang));
          h += p.hb * smooth(p.r1, p.r0, k + 14 * (vnoise(x / 28, z / 28, 61) - 0.5)) + 12 * (fbm(x / 24, z / 24, 2, 63) - 0.5) * smooth(p.r1 + 30, p.r0 + 22, k);
        }
      } else if (p.kind === 'stones' || p.kind === 'tower') {
        const ds = Math.hypot(x - p.x, z - p.z);
        if (ds < 60) h += p.knoll * smooth(58, 12, ds);
      }
    }
    return h;
  }
  placesIn(x0, z0, x1, z1, out) {
    out.length = 0;
    for (const p of this.places) if (p.bx1 >= x0 && p.bx0 <= x1 && p.bz1 >= z0 && p.bz0 <= z1) out.push(p);
    return out;
  }
  // the ground at one point (camera, houses, flags)
  heightAt(x, z) {
    this.gather(this.fine, x - 800, z - 800, x + 800, z + 800, this._fc);
    this.gather(this.coarse, x - 6000, z - 6000, x + 6000, z + 6000, this._cc);
    const nf = this.nearest(x, z, this._fc, this._cc, this._nf || (this._nf = {}));
    return this.shape(x, z, this.compose(x, z, nf), nf, this.placesIn(x, z, x, z, this._pl || (this._pl = [])));
  }
  forestAt(x, z, h, nf) {
    return fbm(x / 650 + 3, z / 650 + 9, 4, this.seed + 5) - 0.1 + 0.08 * nf.rug - 0.5 * smooth(nf.en + 600, nf.en + 900, h) - 0.6 * smooth(2200, 2500, h);
  }
}

// ------------------------------------------------------------------ trees: snowy conifers, merged with their colours
function treeGeos() {
  const u = units(), near = new GeoBuilder(), far = new GeoBuilder();
  const cT = C(LOOK.trunk), cC = C(LOOK.conifer), cS = C(LOOK.snowCap);
  near.add(UNIT.tcyl, M(0, 0, 0, 0, 0.32, 3.2, 0.32), cT);
  for (const [r, h, y, cr, ch, cy] of [[2.8, 5.2, 2.0, 2.0, 2.6, 4.6], [2.2, 4.6, 4.8, 1.6, 2.3, 6.95], [1.5, 4.0, 7.5, 1.05, 2.2, 9.5]]) {
    near.add(UNIT.tcone, M(0, y, 0, 0, r, h, r), cC);
    near.add(UNIT.tcone, M(0, cy, 0, 0.4, cr, ch, cr), cS);
  }
  far.add(UNIT.tcone, M(0, 1.0, 0, 0, 2.6, 10.5, 2.6), cC);
  far.add(UNIT.tcone, M(0, 6.2, 0, 0.4, 1.5, 5.3, 1.5), cS);
  void u;
  return { near: near.build(), far: far.build() };
}

// ------------------------------------------------------------------ the cyclist (rider and ghost), pedalling
function makeCyclist(ghost) {
  const g = new T.Group(), parts = {};
  const mat = c => (ghost ? new T.MeshBasicMaterial({ color: 0xeaf6ff, transparent: true, opacity: 0.5, depthWrite: false }) : lambert({ color: C(c) }, 0));
  const frameM = mat('#1d1f26'), tireM = mat('#15161a'), jerseyM = mat(LOOK.jersey), shortsM = mat('#22242c'), skinM = mat('#2a2c31'), metalM = mat('#5d6170');
  const cylGeo = new T.CylinderGeometry(1, 1, 1, 8);
  const limb = (r, m) => { const me = new T.Mesh(cylGeo, m); me.userData.r = r; g.add(me); return me; };
  const up = new T.Vector3(0, 1, 0), dv = new T.Vector3();
  const place = (me, a, b) => {
    dv.subVectors(b, a); const len = dv.length();
    me.position.addVectors(a, b).multiplyScalar(0.5);
    me.quaternion.setFromUnitVectors(up, dv.multiplyScalar(1 / (len || 1)));
    me.scale.set(me.userData.r, len, me.userData.r);
  };
  const V = (x, y, z) => new T.Vector3(x, y, z);
  // wheels with spokes that turn
  parts.wheels = [];
  for (const zz of [-0.52, 0.52]) {
    const wg = new T.Group(); wg.position.set(0, 0.36, zz);
    const tire = new T.Mesh(new T.TorusGeometry(0.34, 0.035, 8, 28), tireM); tire.rotation.y = Math.PI / 2; wg.add(tire);
    for (let k = 0; k < 3; k++) { const sp = new T.Mesh(new T.BoxGeometry(0.012, 0.66, 0.012), metalM); sp.rotation.x = k * Math.PI / 3; wg.add(sp); }
    g.add(wg); parts.wheels.push(wg);
  }
  const RA = V(0, 0.36, -0.52), BB = V(0, 0.32, 0.02), ST = V(0, 0.92, -0.2), HT = V(0, 0.86, 0.38), FA = V(0, 0.36, 0.52), BAR = V(0, 0.98, 0.44);
  for (const [a, b] of [[RA, BB], [BB, ST], [ST, HT], [BB, HT], [RA, ST], [HT, FA], [HT, BAR]]) place(limb(0.022, frameM), a, b);
  place(limb(0.016, frameM), V(-0.22, 0.98, 0.46), V(0.22, 0.98, 0.46));
  const HIP = V(0, 1.02, -0.16), SH = V(0, 1.36, 0.26), HEAD = V(0, 1.55, 0.38);
  place(limb(0.14, jerseyM), HIP, SH);
  const head = new T.Mesh(new T.SphereGeometry(0.12, 12, 10), skinM); head.position.copy(HEAD); g.add(head);
  const hel = new T.Mesh(new T.SphereGeometry(0.135, 12, 8, 0, Math.PI * 2, 0, Math.PI / 2), skinM); hel.position.set(HEAD.x, HEAD.y + 0.01, HEAD.z - 0.02); hel.scale.z = 1.25; g.add(hel);
  for (const sx of [-1, 1]) place(limb(0.04, jerseyM), V(sx * 0.15, SH.y - 0.02, SH.z), V(sx * 0.18, 1.0, 0.45));
  // legs and cranks: placed every frame (pedal circle, knee by two-bone IK)
  parts.legs = [-1, 1].map(sx => ({ sx, thigh: limb(0.07, shortsM), shin: limb(0.05, skinM), crank: limb(0.016, metalM), pedal: limb(0.03, metalM) }));
  const L1 = 0.46, L2 = 0.47, hip = new T.Vector3(), ped = new T.Vector3(), knee = new T.Vector3(), bb = new T.Vector3(), tmp = new T.Vector3();
  let crank = Math.random() * Math.PI * 2, roll = 0;
  function pose() {
    for (const L of parts.legs) {
      const a = crank + (L.sx > 0 ? 0 : Math.PI);
      bb.set(L.sx * 0.06, BB.y, BB.z);
      ped.set(L.sx * 0.1, BB.y + 0.17 * Math.cos(a), BB.z + 0.17 * Math.sin(a));
      place(L.crank, bb, tmp.set(L.sx * 0.08, ped.y, ped.z));
      place(L.pedal, tmp.set(L.sx * 0.06, ped.y, ped.z), knee.set(L.sx * 0.15, ped.y, ped.z));
      hip.set(L.sx * 0.1, HIP.y, HIP.z);
      const dy = ped.y - hip.y, dz = ped.z - hip.z, d = clamp(Math.hypot(dy, dz), 0.3, L1 + L2 - 0.01), uy = dy / Math.hypot(dy, dz), uz = dz / Math.hypot(dy, dz);
      const al = Math.acos(clamp((L1 * L1 + d * d - L2 * L2) / (2 * L1 * d), -1, 1));
      const vy = uz, vz = -uy; // perpendicular, the knee forward
      knee.set(L.sx * 0.11, hip.y + L1 * (uy * Math.cos(al) + vy * Math.sin(al)), hip.z + L1 * (uz * Math.cos(al) + vz * Math.sin(al)));
      place(L.thigh, hip, knee);
      place(L.shin, knee, ped);
    }
  }
  pose();
  g.traverse(o => { if (o.isMesh) o.frustumCulled = false; });
  return {
    group: g,
    // cadence in rpm, speed in m/s
    animate(dt, cad, v) {
      crank += 2 * Math.PI * (cad / 60) * dt;
      roll += (v / 0.34) * dt;
      for (const w of parts.wheels) w.rotation.x = roll;
      pose();
    },
  };
}

// ------------------------------------------------------------------ the engine
const LEVELS = [900, 760, 640, 540, 450, 380]; // inner picture height in pixels (painted look: soft, so it can be small)
const LODS = [[0, 384, 1150], [1, 1536, 4200], [2, 6144, 14000]]; // land: level, chunk size, reach (metres)

class Engine {
  constructor(container, opts) {
    this.opts = opts || {};
    this.container = container;
    const renderer = this.renderer = new T.WebGLRenderer({ antialias: false, powerPreference: 'high-performance', stencil: false });
    renderer.toneMapping = T.NeutralToneMapping;
    renderer.toneMappingExposure = LOOK.exposure;
    renderer.setClearColor(C(LOOK.fog));
    container.appendChild(renderer.domElement);
    renderer.domElement.style.width = '100%'; renderer.domElement.style.height = '100%'; renderer.domElement.style.display = 'block';
    const scene = this.scene = new T.Scene();
    scene.fog = new T.FogExp2(C(LOOK.fog), LOOK.fogDensity);
    this.world = new T.Group(); scene.add(this.world);
    this.camera = new T.PerspectiveCamera(50, 1, 0.4, 40000);
    this.camera.rotation.order = 'YXZ';
    this.origin = { x: 0, z: 0, set: false };
    // light: blue sky and snow, the last sun on the peaks, torches
    scene.add(new T.HemisphereLight(C(LOOK.hemi[0]), C(LOOK.hemi[1]), LOOK.hemiI));
    this.sun = new T.DirectionalLight(C(LOOK.sun), LOOK.sunI);
    scene.add(this.sun); scene.add(this.sun.target);
    this.sunAz = null;
    this.torchLights = [];
    for (let i = 0; i < 4; i++) { const l = new T.PointLight(0xffa04a, 0, 26, 2); this.world.add(l); this.torchLights.push(l); }
    this.makeSky();
    this.makeMaterials();
    this.trees = treeGeos();
    this.rider = makeCyclist(false); this.world.add(this.rider.group);
    this.ghost = makeCyclist(true); this.world.add(this.ghost.group); this.ghost.group.visible = false;
    this.blob = new T.Mesh(new T.PlaneGeometry(1.4, 2.4).rotateX(-Math.PI / 2), new T.MeshBasicMaterial({
      map: canvasTex(64, 64, (g2) => { const gr = g2.createRadialGradient(32, 32, 2, 32, 32, 31); gr.addColorStop(0, 'rgba(20,24,52,0.55)'); gr.addColorStop(1, 'rgba(20,24,52,0)'); g2.fillStyle = gr; g2.fillRect(0, 0, 64, 64); }),
      transparent: true, depthWrite: false, polygonOffset: true, polygonOffsetFactor: -4, polygonOffsetUnits: -4 }));
    this.world.add(this.blob);
    this.chunks = new Map();
    this.queue = [];
    this.route = null;
    this.time = 0;
    this.q = { mode: 'auto', level: 2, kr: 0, acc: 0, n: 0, slowFor: 0, fastFor: 0, bad: {}, fps: 0, lastRender: 0 };
    this.makeComposer();
    this.resize();
  }

  // ---------------------------------------------------------------- materials and textures
  makeMaterials() {
    const warm = C('#ffb15e');
    this.mat = {
      terrain: lambert({ vertexColors: true }, 1.0),
      tree: lambert({ vertexColors: true }, 0.6),
      stone: lambert({ color: C(LOOK.stone) }, 0.8),
      stones: lambert({ color: C(LOOK.stones), flatShading: true }, 0.9),
      roof: lambert({ vertexColors: true }, 0.45),
      banner: lambert({ color: C(LOOK.flag), side: T.DoubleSide }, 0.15),
      slit: new T.MeshBasicMaterial({ color: warm.clone().multiplyScalar(3.2) }),
      wood: lambert({ color: C('#5b4334') }, 0.2),
      iron: lambert({ color: C('#3a3a40') }, 0),
      flame: new T.MeshBasicMaterial({ color: new T.Color(1.0, 0.55, 0.16).multiplyScalar(5.7), fog: false }),
    };
    // half-timbered walls with windows; the windows glow
    const timber = mask => canvasTex(128, 128, (g) => {
      g.fillStyle = mask ? '#000000' : '#ffffff'; g.fillRect(0, 0, 128, 128);
      if (!mask) {
        g.fillStyle = '#5c4535';
        g.fillRect(0, 0, 128, 6); g.fillRect(0, 122, 128, 6); g.fillRect(0, 0, 6, 128); g.fillRect(122, 0, 6, 128); g.fillRect(0, 60, 128, 6);
        g.fillRect(41, 0, 5, 128); g.fillRect(83, 0, 5, 128);
        g.strokeStyle = '#5c4535'; g.lineWidth = 5; g.beginPath(); g.moveTo(6, 118); g.lineTo(41, 70); g.moveTo(6, 56); g.lineTo(41, 10); g.stroke();
      }
      g.fillStyle = mask ? '#ffffff' : '#3b4150';
      g.fillRect(52, 16, 20, 26); g.fillRect(94, 16, 20, 26); g.fillRect(52, 80, 20, 22);
      if (!mask) { g.fillStyle = '#4b3729'; g.fillRect(95, 78, 20, 44); }
    });
    this.mat.walls = lambert({ vertexColors: true, map: timber(false), emissive: warm, emissiveMap: timber(true), emissiveIntensity: 2.6 }, 0.25);
    // the glow around flames: soft points
    const glowTex = canvasTex(64, 64, (g) => {
      const gr = g.createRadialGradient(32, 32, 0, 32, 32, 32);
      gr.addColorStop(0, 'rgba(255,225,170,1)'); gr.addColorStop(0.22, 'rgba(255,170,80,0.6)'); gr.addColorStop(1, 'rgba(255,120,40,0)');
      g.fillStyle = gr; g.fillRect(0, 0, 64, 64);
    });
    this.mat.glow = new T.PointsMaterial({ map: glowTex, size: 3.0, sizeAttenuation: true, transparent: true, opacity: 0.75, depthWrite: false, blending: T.AdditiveBlending, fog: false });
    this.mat.beaconGlow = new T.PointsMaterial({ map: glowTex, size: 9, sizeAttenuation: true, transparent: true, opacity: 0.85, depthWrite: false, blending: T.AdditiveBlending, fog: false });
    // the road: trodden snow, two tracks, soft edges into the snow
    const base = C(LOOK.road), snowC = C(LOOK.snow);
    const roadTex = canvasTex(128, 256, (g, w, h) => {
      const px = g.createImageData(w, h), c = new T.Color(), o = {};
      for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
        const u = x / (w - 1), k = (y * w + x) * 4;
        const track = Math.exp(-(((u - 0.32) / 0.08) ** 2)) + Math.exp(-(((u - 0.68) / 0.08) ** 2));
        const mid = Math.exp(-(((u - 0.5) / 0.06) ** 2));
        const n2 = vnoise(x / 5, y / 9, 91) * 0.6 + vnoise(x / 1.7, y / 3, 93) * 0.4;
        c.copy(base).lerp(snowC, 0.35 * mid).multiplyScalar(1 - 0.12 * track + (n2 - 0.5) * 0.12).getRGB(o, T.SRGBColorSpace);
        const e = Math.min(u, 1 - u), a = smooth(0.0, 0.17, e + (vnoise(x / 3, y / 7, 95) - 0.5) * 0.08);
        px.data[k] = clamp(o.r, 0, 1) * 255; px.data[k + 1] = clamp(o.g, 0, 1) * 255; px.data[k + 2] = clamp(o.b, 0, 1) * 255; px.data[k + 3] = a * 255;
      }
      g.putImageData(px, 0, 0);
    });
    roadTex.wrapS = roadTex.wrapT = T.RepeatWrapping;
    roadTex.anisotropy = 4;
    this.mat.road = lambert({ map: roadTex, transparent: true, depthWrite: false, polygonOffset: true, polygonOffsetFactor: -2, polygonOffsetUnits: -2 }, 0.35);
  }

  // ---------------------------------------------------------------- sky: the gradient of the blue hour, stars, an aurora
  makeSky() {
    const g = new T.SphereGeometry(25000, 48, 24);
    const m = new T.ShaderMaterial({
      side: T.BackSide, depthWrite: false, fog: false,
      uniforms: { top: { value: C(LOOK.sky[0]) }, bottom: { value: C(LOOK.sky[1]) }, mid: { value: C(LOOK.skyMid) }, sunDir: { value: PU.uSunDirW.value },
        sunCol: { value: C(LOOK.sun) }, glow: { value: 0.45 }, aurora: { value: LOOK.aurora }, aurCol: { value: C('#5ff0b4') } },
      vertexShader: 'varying vec3 vDir; void main(){ vDir = normalize(position); gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }',
      fragmentShader: `uniform vec3 top; uniform vec3 bottom; uniform vec3 mid; uniform vec3 sunDir; uniform vec3 sunCol; uniform float glow; uniform float aurora; uniform vec3 aurCol; varying vec3 vDir;
        float h21(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
        float n21(vec2 p){ vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f); return mix(mix(h21(i), h21(i + vec2(1.0, 0.0)), f.x), mix(h21(i + vec2(0.0, 1.0)), h21(i + vec2(1.0, 1.0)), f.x), f.y); }
        void main(){
          float y = max(vDir.y, 0.0); vec3 c = mix(bottom, mid, smoothstep(0.0, 0.12, y)); c = mix(c, top, smoothstep(0.1, 0.55, y));
          float s = max(dot(normalize(vDir), normalize(sunDir)), 0.0); c += sunCol * (pow(s, 6.0) * 0.35 * glow + pow(s, 400.0) * 1.2);
          float az = atan(vDir.x, vDir.z); float n = n21(vec2(az * 6.0, y * 14.0)) * 0.6 + n21(vec2(az * 17.0, y * 40.0)) * 0.4;
          c *= 1.0 + (n - 0.5) * 0.07; c += sunCol * pow(s, 3.0) * 0.16 * glow;
          if (aurora > 0.0) {
            float y0 = 0.2 + 0.05 * sin(az * 2.5 + 1.0) + 0.03 * sin(az * 6.1 + 2.0);
            float d = y - y0, rib = smoothstep(0.09, 0.0, abs(d)) * (0.55 + 0.45 * smoothstep(-0.09, 0.05, d));
            float rays = 0.45 + 0.55 * n21(vec2(az * 70.0, 0.5)) * n21(vec2(az * 23.0, 3.5));
            c += mix(aurCol, vec3(0.55, 0.35, 0.95), smoothstep(0.0, 0.09, d)) * rib * rays * aurora;
          }
          if (vDir.y < 0.0) c = bottom;
          gl_FragColor = vec4(c, 1.0);
        }`,
    });
    this.sky = new T.Group();
    this.sky.add(new T.Mesh(g, m));
    // stars, fainter towards the horizon
    const r = rng(77), pos = [], col = [];
    for (let i = 0; i < 520; i++) {
      const az = r() * Math.PI * 2, el = Math.asin(0.12 + 0.88 * r()), R = 20000;
      pos.push(Math.cos(az) * Math.cos(el) * R, Math.sin(el) * R, Math.sin(az) * Math.cos(el) * R);
      const b = (0.35 + 0.65 * r()) * smooth(0.1, 0.5, Math.sin(el));
      col.push(b * 0.9, b * 0.95, b);
    }
    const sg = new T.BufferGeometry();
    sg.setAttribute('position', new T.Float32BufferAttribute(pos, 3));
    sg.setAttribute('color', new T.Float32BufferAttribute(col, 3));
    this.sky.add(new T.Points(sg, new T.PointsMaterial({ size: 1.6, sizeAttenuation: false, vertexColors: true, transparent: true, depthWrite: false, fog: false })));
    this.sky.children.forEach(o => { o.frustumCulled = false; o.renderOrder = -10; });
    this.scene.add(this.sky);
  }

  // ---------------------------------------------------------------- post: paint strokes, glow, colour grade
  makeComposer() {
    const r = this.renderer;
    this.composer = new T.EffectComposer(r);
    this.composer.addPass(new T.RenderPass(this.scene, this.camera));
    this.kuwahara = null;
    this.bloom = new T.UnrealBloomPass(new T.Vector2(256, 256), LOOK.bloom, 0.6, 0.95);
    this.grade = new T.ShaderPass({
      uniforms: { tDiffuse: { value: null }, res: { value: new T.Vector2(1, 1) }, cool: { value: C('#6b8fd8') }, warm: { value: C('#fff1dc') } },
      vertexShader: 'varying vec2 vUv; void main(){ vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }',
      fragmentShader: `uniform sampler2D tDiffuse; uniform vec2 res; uniform vec3 cool; uniform vec3 warm; varying vec2 vUv;
        float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
        float vn(vec2 p) { vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
          return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y); }
        void main() {
          vec3 c = texture2D(tDiffuse, vUv).rgb;
          float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
          c += cool * 0.05 * (1.0 - smoothstep(0.0, 0.35, l));
          c = mix(c, c * warm, smoothstep(0.25, 0.9, l) * 0.5);
          float l2 = dot(c, vec3(0.2126, 0.7152, 0.0722));
          c = max(mix(vec3(l2), c, 1.12), 0.0);
          c *= 1.0 + (vn(vUv * res / 2.5) - 0.5) * 0.045;
          vec2 d = vUv - 0.5; c *= 1.0 - dot(d, d) * 0.32;
          gl_FragColor = vec4(c, 1.0);
        }`,
    });
    this.output = new T.OutputPass();
    this.composer.addPass(this.bloom);
    this.composer.addPass(this.grade);
    this.composer.addPass(this.output);
  }
  // the paint strokes: generalized Kuwahara filter (8 sectors), radius kr pixels
  setKuwahara(kr) {
    if (this.q.kr === kr) return;
    if (this.kuwahara) { this.composer.removePass(this.kuwahara); this.kuwahara.dispose && this.kuwahara.dispose(); this.kuwahara = null; }
    this.q.kr = kr;
    if (!kr) return;
    this.kuwahara = new T.ShaderPass({
      uniforms: { tDiffuse: { value: null }, res: { value: new T.Vector2(1, 1) } },
      vertexShader: 'varying vec2 vUv; void main(){ vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }',
      fragmentShader: `uniform sampler2D tDiffuse; uniform vec2 res; varying vec2 vUv;
        #define KR ${kr}
        void main() {
          vec2 px = 1.0 / res;
          vec4 m[8]; vec3 s[8];
          for (int k = 0; k < 8; k++) { m[k] = vec4(0.0); s[k] = vec3(0.0); }
          float zeta = 0.33, zc = 0.58, sz = sin(zc), eta = (zeta + cos(zc)) / (sz * sz);
          for (int y = -KR; y <= KR; y++) for (int x = -KR; x <= KR; x++) {
            vec2 v = vec2(float(x), float(y)) / float(KR);
            if (dot(v, v) > 1.0) continue;
            vec3 c = texture2D(tDiffuse, vUv + vec2(float(x), float(y)) * px).rgb;
            float w[8]; float sum = 0.0, z, vxx, vyy;
            vxx = zeta - eta * v.x * v.x; vyy = zeta - eta * v.y * v.y;
            z = max(0.0, v.y + vxx); w[0] = z * z; sum += w[0];
            z = max(0.0, -v.x + vyy); w[2] = z * z; sum += w[2];
            z = max(0.0, -v.y + vxx); w[4] = z * z; sum += w[4];
            z = max(0.0, v.x + vyy); w[6] = z * z; sum += w[6];
            vec2 r = 0.70710678 * vec2(v.x - v.y, v.x + v.y);
            vxx = zeta - eta * r.x * r.x; vyy = zeta - eta * r.y * r.y;
            z = max(0.0, r.y + vxx); w[1] = z * z; sum += w[1];
            z = max(0.0, -r.x + vyy); w[3] = z * z; sum += w[3];
            z = max(0.0, -r.y + vxx); w[5] = z * z; sum += w[5];
            z = max(0.0, r.x + vyy); w[7] = z * z; sum += w[7];
            float gw = exp(-0.78 * dot(v, v)) / max(sum, 1e-6);
            for (int k = 0; k < 8; k++) { float wk = w[k] * gw; m[k] += vec4(c * wk, wk); s[k] += c * c * wk; }
          }
          vec4 o = vec4(0.0);
          for (int k = 0; k < 8; k++) {
            vec3 mk = m[k].rgb / max(m[k].w, 1e-6);
            vec3 sk = abs(s[k] / max(m[k].w, 1e-6) - mk * mk);
            float wk = 1.0 / (1.0 + pow(800.0 * (sk.r + sk.g + sk.b), 4.0));
            o += vec4(mk * wk, wk);
          }
          gl_FragColor = vec4(o.rgb / max(o.w, 1e-6), 1.0);
        }`,
    });
    this.composer.insertPass(this.kuwahara, 1);
    this.resize();
  }
  // picture quality: the inner picture height (LEVELS) and the stroke radius follow from the level
  applyLevel(level) {
    const q = this.q;
    q.level = clamp(level, 0, LEVELS.length - 1);
    const kr = clamp(Math.round(LEVELS[q.level] / 150), 3, 6);
    this.resize();
    this.setKuwahara(kr);
  }
  setQuality(mode) {
    this.q.mode = mode;
    if (mode === 'auto') return;
    this.applyLevel(mode === 'hoch' ? 0 : mode === 'mittel' ? 2 : 4);
  }
  info() {
    const q = this.q, cv = this.renderer.domElement;
    return { mode: q.mode, level: q.level, fps: q.fps, width: cv.width, height: cv.height, kr: q.kr };
  }
  resize() {
    const w = Math.max(1, this.container.clientWidth), h = Math.max(1, this.container.clientHeight);
    const pr = clamp(LEVELS[this.q.level] / h, 0.25, Math.min(window.devicePixelRatio || 1, 2));
    this.renderer.setPixelRatio(pr);
    this.renderer.setSize(w, h, false);
    this.composer.setPixelRatio(pr);
    this.composer.setSize(w, h);
    const W = Math.round(w * pr), H = Math.round(h * pr);
    this.bloom.resolution.set(W, H);
    this.grade.uniforms.res.value.set(W, H);
    if (this.kuwahara) this.kuwahara.uniforms.res.value.set(W, H);
    this.camera.aspect = w / h;
    this.camera.updateProjectionMatrix();
    this.cssW = w; this.cssH = h;
  }

  // ---------------------------------------------------------------- the route and its places
  setRoute(route, checkpoints) {
    this.clear();
    this.route = route;
    const seed = hashStr((route.name || '') + '|' + Math.round(route.total));
    this.seed = seed;
    this.field = new Field(route, seed);
    this.makePlaces(checkpoints || []);
    this.makeTorches();
    this.roadWin = null;
  }
  clear() {
    for (const c of this.chunks.values()) this.dropChunk(c);
    this.chunks.clear();
    this.queue = [];
    if (this.places) for (const p of this.places) this.dropPlace(p);
    if (this.roadMesh) { this.world.remove(this.roadMesh); this.roadMesh.geometry.dispose(); this.roadMesh = null; }
    if (this.torchObj) { for (const o of this.torchObj) { this.world.remove(o); o.geometry.dispose(); } this.torchObj = null; }
  }
  // towns at the checkpoints (or every 18 to 30 km), a town at the finish, villages between, castles on rocks
  // near the towns, stone circles and watchtowers with beacons along the way
  makePlaces(cps) {
    const f = this.field, route = this.route, total = route.total, r = rng(this.seed ^ 0x9e3779b9);
    const places = this.places = [];
    const towns = [];
    if (cps.length) for (const c of cps) towns.push({ s: clamp(c.s, 0, total), name: c.name || '' });
    else {
      for (let s = 2500 + r() * 2500; s < total - 5000; s += 18000 + r() * 12000) towns.push({ s, name: '' });
      if (total > 4000) towns.push({ s: total - 120, name: '' });
    }
    const used = [];
    const free = (s, gap) => used.every(u => Math.abs(u - s) > gap);
    const p0 = {};
    const at = s => { route.xzAt(clamp(s, 0, total), p0); return { x: p0.x, z: p0.z }; };
    for (const t of towns) {
      if (!free(t.s, 900)) continue;
      used.push(t.s);
      const c = at(t.s), rad = 118 + r() * 18;
      places.push({ kind: 'town', s: t.s, x: c.x, z: c.z, r: rad, name: t.name, cp: !!cps.length, rnd: r() });
      // a castle on a rock beside the town
      if (r() < 0.8) this.addCastle(places, t.s + (r() - 0.5) * 300, 300 + r() * 180, r);
    }
    for (let s = 4000 + r() * 3000; s < total - 1500; s += 5000 + r() * 4500) {
      if (!free(s, 2500)) continue;
      used.push(s);
      const len = 160 + r() * 140;
      places.push({ kind: 'village', s0: s - len / 2, s1: s + len / 2, s, rnd: r() });
    }
    for (let s = 1800 + r() * 4000; s < total - 800; s += 7000 + r() * 5000) {
      if (!free(s, 700)) continue;
      const side = r() < 0.5 ? -1 : 1, off = 32 + r() * 26, q = this.offsetPoint(s, side * off);
      if (this.clearOf(q.x, q.z, 22)) places.push({ kind: 'stones', s, x: q.x, z: q.z, knoll: 6 + r() * 3, rnd: r() });
    }
    for (let s = 6000 + r() * 6000; s < total - 1500; s += 9000 + r() * 7000) {
      if (!free(s, 1200)) continue;
      const side = r() < 0.5 ? -1 : 1, off = 60 + r() * 70, q = this.offsetPoint(s, side * off);
      if (this.clearOf(q.x, q.z, 45)) places.push({ kind: 'tower', s, x: q.x, z: q.z, knoll: 9 + r() * 6, rnd: r() });
    }
    for (let s = 26000 + r() * 8000; s < total - 3000; s += 26000 + r() * 12000) if (free(s, 6000)) this.addCastle(places, s, 380 + r() * 300, r);
    // bounding boxes (for the chunks) and the order along the route
    for (const p of places) {
      let R = 60;
      if (p.kind === 'town') R = p.r + 140;
      else if (p.kind === 'castle') R = p.r1 + 45;
      if (p.kind === 'village') {
        const a = at(p.s0), b = at(p.s), c2 = at(p.s1);
        p.x = b.x; p.z = b.z;
        p.bx0 = Math.min(a.x, b.x, c2.x) - 200; p.bx1 = Math.max(a.x, b.x, c2.x) + 200; p.bz0 = Math.min(a.z, b.z, c2.z) - 200; p.bz1 = Math.max(a.z, b.z, c2.z) + 200;
      } else { p.bx0 = p.x - R; p.bx1 = p.x + R; p.bz0 = p.z - R; p.bz1 = p.z + R; }
    }
    places.sort((a, b) => a.s - b.s);
    f.places = places;
  }
  offsetPoint(s, side) {
    const p = {}, a = {}, total = this.route.total;
    s = clamp(s, 0, total);
    this.route.xzAt(s, p);
    if (s + 10 <= total) this.route.xzAt(s + 10, a);
    else { this.route.xzAt(Math.max(0, s - 10), a); a.x = 2 * p.x - a.x; a.z = 2 * p.z - a.z; }
    let tx = a.x - p.x, tz = a.z - p.z;
    const l = Math.hypot(tx, tz) || 1; tx /= l; tz /= l;
    // right of the direction of travel: (-tz, tx) in x/z (z points south)
    return { x: p.x - tz * side, z: p.z + tx * side, tx, tz };
  }
  // far enough from every part of the route
  clearOf(x, z, dist) {
    const f = this.field;
    f.gather(f.fine, x - dist - 300, z - dist - 300, x + dist + 300, z + dist + 300, f._fc);
    for (const k of f._fc) if (Math.hypot(f.sx[k] - x, f.sz[k] - z) < dist) return false;
    return true;
  }
  addCastle(places, s, off, r) {
    for (const side of r() < 0.5 ? [-1, 1] : [1, -1]) {
      const q = this.offsetPoint(s, side * off);
      if (!this.clearOf(q.x, q.z, 190)) continue;
      if (places.some(p => Math.hypot(p.x - q.x, p.z - q.z) < 320)) continue;
      places.push({ kind: 'castle', s, x: q.x, z: q.z, r0: 50, r1: 112, hb: 70 + r() * 45, ang: r() * 6.28, rot: Math.atan2(-q.tx * side, q.tz * side), rnd: r() });
      return;
    }
  }

  // ---------------------------------------------------------------- terrain chunks
  // near (LOD 0): 384 m chunks, 12 m cells, with trees; LOD 1: 1536 m, 48 m cells; LOD 2: 6144 m, 192 m cells (the far
  // mountains). Coarser levels lie a little lower, hidden below the finer ones; there forests are dark patches.
  wantChunks(x, z) {
    const want = [];
    for (const [lod, size, R] of LODS) {
      const ax = Math.floor((x - R) / size), bx = Math.floor((x + R) / size), az = Math.floor((z - R) / size), bz = Math.floor((z + R) / size);
      for (let i = ax; i <= bx; i++) for (let j = az; j <= bz; j++) {
        const cx = (i + 0.5) * size, cz = (j + 0.5) * size, d = Math.hypot(cx - x, cz - z);
        if (d < R + size * 0.5) want.push({ key: lod + ':' + i + ':' + j, lod, i, j, d });
      }
    }
    return want;
  }
  updateChunks(x, z, ahead, budgetMs) {
    const now = performance.now();
    if (!this.lastWant || Math.hypot(x - this.lastWant.x, z - this.lastWant.z) > 60 || this.queue.length === 0 && this.lastWant.n !== this.chunks.size) {
      const want = this.wantChunks(x, z), keep = new Set();
      for (const w of want) keep.add(w.key);
      for (const [key, c] of this.chunks) {
        if (keep.has(key)) continue;
        const size = LODS[c.lod][1], R = LODS[c.lod][2], d = Math.hypot((c.i + 0.5) * size - x, (c.j + 0.5) * size - z);
        if (d > R + size) { this.dropChunk(c); this.chunks.delete(key); }
      }
      // nearest first, the way ahead before the way behind, near before far
      this.queue = want.filter(w => !this.chunks.has(w.key)).map(w => {
        const size = LODS[w.lod][1], dx = (w.i + 0.5) * size - x, dz = (w.j + 0.5) * size - z;
        const fwd = ahead ? (dx * ahead.x + dz * ahead.z) / (w.d || 1) : 0;
        w.prio = w.d * (1.25 - 0.45 * fwd) * [1, 0.5, 0.2][w.lod];
        return w;
      }).sort((a, b) => a.prio - b.prio);
      this.lastWant = { x, z, n: want.length };
    }
    while (this.queue.length && performance.now() - now < budgetMs) {
      const w = this.queue.shift();
      if (this.chunks.has(w.key)) continue;
      this.chunks.set(w.key, this.buildChunk(w.lod, w.i, w.j));
    }
  }
  buildChunk(lod, ci, cj) {
    const f = this.field, size = LODS[lod][1], cells = 32, st = size / cells, x0 = ci * size, z0 = cj * size;
    const N = cells + 3, H = new Float64Array(N * N), D = new Float64Array(N * N), EN = new Float64Array(N * N), RG = new Float64Array(N * N), TW = new Uint8Array(N * N);
    const fineC = f.gather(f.fine, x0 - 800, z0 - 800, x0 + size + 800, z0 + size + 800, []);
    const coarseC = f.gather(f.coarse, x0 - 6000, z0 - 6000, x0 + size + 6000, z0 + size + 6000, []);
    const pl = f.placesIn(x0 - st, z0 - st, x0 + size + st, z0 + size + st, []);
    const towns = pl.filter(p => p.kind === 'town');
    const nf = {};
    for (let j = 0; j < N; j++) for (let i = 0; i < N; i++) {
      const x = x0 + (i - 1) * st, z = z0 + (j - 1) * st, q = j * N + i;
      f.nearest(x, z, fineC, coarseC, nf);
      let h = f.shape(x, z, f.compose(x, z, nf), nf, pl);
      if (lod) h -= (lod === 1 ? 4 : 14) + (lod === 1 ? 10 : 30) * (1 - smooth(25, lod === 1 ? 90 : 300, nf.d));
      H[q] = h; D[q] = nf.d; EN[q] = nf.en; RG[q] = nf.rug;
      for (const t of towns) if (Math.hypot(x - t.x, z - t.z) < t.r - 4) TW[q] = 1;
    }
    const nv = (cells + 1) * (cells + 1), pos = new Float32Array(nv * 3), nor = new Float32Array(nv * 3), col = new Float32Array(nv * 3);
    const cS = C(LOOK.snow), cS2 = C(LOOK.snow2), cW = C(LOOK.warm), cC = C(LOOK.cool), cF = C(lod ? LOOK.forestFar : LOOK.floor), cR = C(LOOK.rock), cV = C(LOOK.verge), cT = C(LOOK.town);
    const c = new T.Color(), nfo = { rug: 0, en: 0 };
    let v = 0;
    for (let j = 1; j <= cells + 1; j++) for (let i = 1; i <= cells + 1; i++, v++) {
      const q = j * N + i, x = x0 + (i - 1) * st, z = z0 + (j - 1) * st, h = H[q];
      pos[v * 3] = x - x0; pos[v * 3 + 1] = h; pos[v * 3 + 2] = z - z0;
      let nx = (H[q - 1] - H[q + 1]) / (2 * st), nz = (H[q - N] - H[q + N]) / (2 * st);
      const l = Math.sqrt(nx * nx + 1 + nz * nz); nx /= l; nz /= l;
      nor[v * 3] = nx; nor[v * 3 + 1] = 1 / l; nor[v * 3 + 2] = nz;
      const slope = 1 - 1 / l, d = D[q];
      c.copy(cS).lerp(cS2, fbm(x / 160, z / 160, 3, 11));
      c.lerp(cW, Math.max(0, fbm(x / 520 + 4, z / 520 + 1, 3, 51) - 0.48) * 1.6);
      c.lerp(cC, Math.max(0, fbm(x / 430 + 8, z / 430 + 6, 3, 53) - 0.5) * 1.4);
      nfo.rug = RG[q]; nfo.en = EN[q];
      const fo = f.forestAt(x, z, h, nfo);
      if (fo > 0.5 && d > 20) c.lerp(cF, smooth(0.5, 0.58, fo) * (lod ? 0.8 : 0.45));
      c.lerp(cR, smooth(0.24, 0.45, slope));
      if (d < 9) c.lerp(cV, smooth(9, 3, d));
      if (TW[q]) c.lerp(cT, 0.8);
      col[v * 3] = c.r; col[v * 3 + 1] = c.g; col[v * 3 + 2] = c.b;
    }
    const geo = new T.BufferGeometry();
    geo.setAttribute('position', new T.BufferAttribute(pos, 3));
    geo.setAttribute('normal', new T.BufferAttribute(nor, 3));
    geo.setAttribute('color', new T.BufferAttribute(col, 3));
    geo.setIndex(new T.BufferAttribute(this.gridIndex(cells), 1));
    geo.computeBoundingSphere();
    const mesh = new T.Mesh(geo, this.mat.terrain);
    mesh.position.set(x0, 0, z0);
    this.world.add(mesh);
    const chunk = { lod, i: ci, j: cj, mesh, trees: null, x: x0 + size / 2, z: z0 + size / 2 };
    if (!lod) chunk.trees = this.plantTrees(chunk, x0, z0, size, st, N, H, D, EN, RG, pl);
    return chunk;
  }
  gridIndex(cells) {
    this.idx = this.idx || {};
    if (this.idx[cells]) return this.idx[cells];
    const n = cells + 1, a = [];
    for (let j = 0; j < cells; j++) for (let i = 0; i < cells; i++) {
      const p = j * n + i;
      a.push(p, p + n, p + 1, p + 1, p + n, p + n + 1);
    }
    this.idx[cells] = new Uint16Array(a);
    return this.idx[cells];
  }
  plantTrees(chunk, x0, z0, size, st, N, H, D, EN, RG, pl) {
    const f = this.field, r = rng(hash2(chunk.i, chunk.j, this.seed));
    const mats = [], cols = [], nfo = { rug: 0, en: 0 };
    const at = (A, x, z) => { // bilinear in the chunk grid (with its border)
      const gx = (x - x0) / st + 1, gz = (z - z0) / st + 1, i = clamp(Math.floor(gx), 0, N - 2), j = clamp(Math.floor(gz), 0, N - 2), u = gx - i, w = gz - j;
      return mix(mix(A[j * N + i], A[j * N + i + 1], u), mix(A[(j + 1) * N + i], A[(j + 1) * N + i + 1], u), w);
    };
    const m4 = new T.Matrix4(), q = new T.Quaternion(), e = new T.Euler(), p = new T.Vector3(), sc = new T.Vector3(), c = new T.Color();
    for (let gz = 0; gz < size; gz += 12) for (let gx = 0; gx < size; gx += 12) {
      const x = x0 + gx + 1 + r() * 10, z = z0 + gz + 1 + r() * 10, keep = r(), sz = 0.75 + r() * 0.7, rot = r() * 6.28, tint = r();
      const d = at(D, x, z);
      if (d < 16 || (d < 36 && keep > 0.18)) continue;
      const h = at(H, x, z);
      nfo.rug = at(RG, x, z); nfo.en = at(EN, x, z);
      const fo = f.forestAt(x, z, h, nfo);
      const pr = fo > 0.53 ? 0.6 : fo > 0.48 ? 0.22 : 0.01;
      if (keep > pr) continue;
      // slope from the grid
      const sx2 = (at(H, x + 4, z) - at(H, x - 4, z)) / 8, sz2 = (at(H, x, z + 4) - at(H, x, z - 4)) / 8;
      if (sx2 * sx2 + sz2 * sz2 > 0.5) continue;
      let blocked = false;
      for (const pp of pl) {
        const dd = Math.hypot(x - pp.x, z - pp.z);
        if ((pp.kind === 'town' && dd < pp.r + 18) || (pp.kind === 'castle' && dd < pp.r0 + 12) || ((pp.kind === 'stones' || pp.kind === 'tower') && dd < 26)) { blocked = true; break; }
        if (pp.kind === 'village' && d < 45 && this.inVillage(pp, x, z)) { blocked = true; break; }
      }
      if (blocked) continue;
      const s = sz * (tint > 0.97 ? 1.6 : 1);
      m4.compose(p.set(x - x0, h - 0.3, z - z0), q.setFromEuler(e.set(0, rot, 0)), sc.set(s, s * (0.9 + 0.25 * tint), s));
      mats.push(m4.clone());
      cols.push(c.setScalar(0.88 + 0.2 * tint).clone());
    }
    if (!mats.length) return null;
    const im = new T.InstancedMesh(this.trees.far, this.mat.tree, mats.length);
    mats.forEach((m, k) => { im.setMatrixAt(k, m); im.setColorAt(k, cols[k]); });
    im.instanceMatrix.needsUpdate = true;
    if (im.instanceColor) im.instanceColor.needsUpdate = true;
    im.position.set(x0, 0, z0);
    im.computeBoundingSphere();
    im.userData.near = false;
    this.world.add(im);
    return im;
  }
  inVillage(p, x, z) {
    const f = this.field, k0 = Math.max(0, Math.floor(p.s0 / f.STEP)), k1 = Math.min(f.n - 1, Math.ceil(p.s1 / f.STEP));
    for (let k = k0; k <= k1; k += 2) if (Math.hypot(f.sx[k] - x, f.sz[k] - z) < 42) return true;
    return false;
  }
  dropChunk(c) {
    this.world.remove(c.mesh); c.mesh.geometry.dispose();
    if (c.trees) { this.world.remove(c.trees); c.trees.dispose(); }
  }
  // detailed trees near the camera, simple ones further away
  treeLod(cx, cz) {
    for (const c of this.chunks.values()) {
      if (!c.trees) continue;
      const near = Math.hypot(c.x - cx, c.z - cz) < 700;
      if (near !== c.trees.userData.near) { c.trees.userData.near = near; c.trees.geometry = near ? this.trees.near : this.trees.far; }
    }
  }

  // ---------------------------------------------------------------- the road (a ribbon over the next 3 km)
  updateRoad(s) {
    const route = this.route, total = route.total;
    if (this.roadWin && s > this.roadWin.a + 150 && s < this.roadWin.b - 2600 && !(this.roadWin.b < total && s > this.roadWin.b - 2700)) return;
    if (this.roadWin && Math.abs(s - this.roadWin.s) < 200) return;
    const a = Math.max(0, s - 250), b = Math.min(total, s + 3300), HW = 3.2;
    const pts = [];
    for (let t = a; t < b; t += t - s < 600 ? 3 : 8) pts.push(t);
    pts.push(b);
    const p = {}, q = {}, o = {};
    route.xzAt(a, o);
    const P = new Float32Array(pts.length * 6), U = new Float32Array(pts.length * 4), N = new Float32Array(pts.length * 6), I = [];
    pts.forEach((t, i) => {
      route.xzAt(t, p); route.xzAt(Math.min(total, t + 2), q);
      let tx = q.x - p.x, tz = q.z - p.z;
      if (t + 2 > total) { route.xzAt(Math.max(0, t - 2), q); tx = p.x - q.x; tz = p.z - q.z; }
      const l = Math.hypot(tx, tz) || 1; tx /= l; tz /= l;
      const y = route.eleAt(t) + 0.12;
      P.set([p.x - tz * -HW - o.x, y, p.z + tx * -HW - o.z, p.x - tz * HW - o.x, y, p.z + tx * HW - o.z], i * 6);
      U.set([0, t / 12, 1, t / 12], i * 4);
      N.set([0, 1, 0, 0, 1, 0], i * 6);
      if (i) I.push((i - 1) * 2, i * 2, (i - 1) * 2 + 1, (i - 1) * 2 + 1, i * 2, i * 2 + 1);
    });
    const g = new T.BufferGeometry();
    g.setAttribute('position', new T.BufferAttribute(P, 3));
    g.setAttribute('normal', new T.BufferAttribute(N, 3));
    g.setAttribute('uv', new T.BufferAttribute(U, 2));
    g.setIndex(I);
    g.computeBoundingSphere();
    if (this.roadMesh) { this.world.remove(this.roadMesh); this.roadMesh.geometry.dispose(); }
    const m = this.roadMesh = new T.Mesh(g, this.mat.road);
    m.position.set(o.x, 0, o.z);
    m.renderOrder = 1;
    m.material.side = T.DoubleSide;
    this.world.add(m);
    this.roadWin = { a, b, s };
  }

  // ---------------------------------------------------------------- torches along the way
  // close together near towns and villages, otherwise every 150 to 200 m, on alternating sides
  makeTorches() {
    const route = this.route, total = route.total, list = [];
    const near = [];
    for (const p of this.places) {
      if (p.kind === 'town') near.push([p.s - p.r - 700, p.s + p.r + 450, 22, 4.6]);
      else if (p.kind === 'village') near.push([p.s0 - 250, p.s1 + 250, 28, 4.6]);
    }
    let s = 40, side = 1;
    while (s < total - 10) {
      const zone = near.find(z => s >= z[0] && s <= z[1]);
      const town = this.places.find(p => p.kind === 'town' && Math.abs(p.s - s) < p.r + 2);
      if (town) {
        // inside the walls: torches by the houses along the street (and none in the gate)
        const dIn = Math.abs(s - town.s);
        if (dIn < town.r - 14) list.push({ s, side, off: 6.2 });
      } else if (!this.places.some(p => p.kind === 'town' && Math.abs(Math.abs(s - p.s) - p.r) < 9)) list.push({ s, side, off: zone ? zone[3] : 4.6 });
      s += zone ? zone[2] / 2 : 75 + hash2(Math.floor(s), 3, this.seed) * 25;
      side = -side;
    }
    this.torches = list;
    this.torchWin = null;
  }
  updateTorches(s) {
    if (this.torchWin && Math.abs(s - this.torchWin) < 150) return;
    this.torchWin = s;
    if (this.torchObj) for (const o of this.torchObj) { this.world.remove(o); o.geometry.dispose(); }
    const route = this.route, a = s - 300, b = s + 3000, sel = [];
    for (const t of this.torches) if (t.s >= a && t.s <= b) sel.push(t);
    for (const p of this.places) if (p.kind === 'tower' && p.s > a - 500 && p.s < b + 4000 && p.top) sel.push({ beacon: true, x: p.x, y: p.top, z: p.z });
    const o = {}; route.xzAt(clamp(s, 0, route.total), o);
    const poles = new GeoBuilder(), bowls = new GeoBuilder(), flames = new GeoBuilder(), glow = [], beacons = [];
    const u = units();
    this.torchPts = [];
    for (const t of sel) {
      if (t.beacon) { beacons.push(t.x - o.x, t.y + 2.2, t.z - o.z); flames.add(UNIT.cone10, M(t.x - o.x, t.y + 0.4, t.z - o.z, 0, 0.8, 2.6, 0.8)); continue; }
      const q = this.offsetPoint(t.s, t.side * t.off), y = route.eleAt(t.s) - 0.3;
      const x = q.x - o.x, z = q.z - o.z;
      poles.add(UNIT.cyl6, M(x, y, z, 0, 0.075, 2.7, 0.075));
      bowls.add(u.cyl, M(x, y + 2.62, z, 0, 0.2, 0.24, 0.2));
      flames.add(UNIT.cone10, M(x, y + 2.86, z, 0, 0.17, 0.62, 0.17));
      glow.push(x, y + 3.1, z);
      this.torchPts.push({ x: q.x, y: y + 3.2, z: q.z, s: t.s });
    }
    const objs = [];
    const add = (b, m) => { if (b.empty) return; const me = new T.Mesh(b.build(), m); me.position.set(o.x, 0, o.z); this.world.add(me); objs.push(me); };
    add(poles, this.mat.wood); add(bowls, this.mat.iron); add(flames, this.mat.flame);
    for (const [arr, m] of [[glow, this.mat.glow], [beacons, this.mat.beaconGlow]]) {
      if (!arr.length) continue;
      const g = new T.BufferGeometry(); g.setAttribute('position', new T.Float32BufferAttribute(arr, 3)); g.computeBoundingSphere();
      const pts = new T.Points(g, m); pts.position.set(o.x, 0, o.z); pts.renderOrder = 2; this.world.add(pts); objs.push(pts);
    }
    this.torchObj = objs;
  }
  // the nearest torches light the road (a fixed number of lights, so the shaders never change)
  updateTorchLights(rx, rz) {
    const pts = (this.torchPts || []).map(p => ({ p, d: Math.hypot(p.x - rx, p.z - rz) })).filter(a => a.d < 160).sort((a, b) => a.d - b.d);
    this.torchLights.forEach((l, i) => {
      const a = pts[i];
      if (!a) { l.intensity = 0; return; }
      l.position.set(a.p.x, a.p.y, a.p.z);
      l.intensity = 16 * (0.88 + 0.12 * Math.sin(this.time * 11 + i * 1.7) * Math.sin(this.time * 7.3 + i));
    });
  }

  // ---------------------------------------------------------------- towns, villages, castles, stones, towers
  updatePlaces(x, z) {
    for (const p of this.places) {
      const d = Math.hypot(p.x - x, p.z - z);
      if (!p.obj && d < 5200) this.buildPlace(p);
      else if (p.obj && d > 6500) this.dropPlace(p);
    }
  }
  dropPlace(p) {
    if (!p.obj) return;
    for (const o of p.obj) { this.world.remove(o); o.geometry.dispose(); }
    p.obj = null;
  }
  buildPlace(p) {
    const f = this.field, u = units(), r = rng(hash2(Math.floor(p.x), Math.floor(p.z), this.seed));
    const stone = new GeoBuilder(), roofs = new GeoBuilder(), walls = new GeoBuilder(), banners = new GeoBuilder(), slits = new GeoBuilder(), rocks = new GeoBuilder();
    const ox = p.x, oz = p.z, hy = (x, z) => f.heightAt(x, z);
    const roofC = LOOK.roofs.map(C), wallC = LOOK.walls.map(C), towerRoof = C(LOOK.tower);
    const crenel = (x0, z0, x1, z1, y, offx, offz) => {
      const len = Math.hypot(x1 - x0, z1 - z0), n = Math.max(1, Math.round(len / 2.4)), rot = Math.atan2(x1 - x0, z1 - z0) + Math.PI / 2;
      for (let k = 0; k < n; k++) { const t = (k + 0.5) / n; stone.add(u.box, M(x0 + (x1 - x0) * t + offx - ox, y, z0 + (z1 - z0) * t + offz - oz, rot, 1.1, 1.3, 0.8)); }
    };
    const house = (x, z, rot, w, d, hh) => {
      const y = Math.min(hy(x - 3, z - 3), hy(x + 3, z + 3), hy(x, z)) - 0.6;
      walls.add(u.box, M(x - ox, y, z - oz, rot, w, hh, d), wallC[Math.floor(r() * wallC.length)]);
      roofs.add(u.prism, M(x - ox, y + hh, z - oz, rot, w + 1.2, w * 0.85, d + 1.0), roofC[Math.floor(r() * roofC.length)]);
    };
    if (p.kind === 'town') {
      const route = this.route, k0 = Math.max(0, Math.floor((p.s - p.r - 60) / f.STEP)), k1 = Math.min(f.n - 1, Math.ceil((p.s + p.r + 60) / f.STEP));
      // where the road crosses the wall
      let sIn = -1, sOut = -1;
      for (let k = k0; k <= k1; k++) if (Math.hypot(f.sx[k] - ox, f.sz[k] - oz) < p.r) { if (sIn < 0) sIn = k * f.STEP; sOut = k * f.STEP; }
      const nearRoad = (x, z, dist) => { for (let k = k0; k <= k1; k++) if (Math.hypot(f.sx[k] - x, f.sz[k] - z) < dist) return true; return false; };
      const nSeg = Math.ceil(2 * Math.PI * p.r / 9.6), segLen = 2 * Math.PI * p.r / nSeg, WH = 12.5;
      for (let k = 0; k < nSeg; k++) {
        const th = (k + 0.5) / nSeg * Math.PI * 2, x = ox + Math.cos(th) * p.r, z = oz + Math.sin(th) * p.r;
        if (nearRoad(x, z, 10.5)) continue;
        const y = hy(x, z) - 3, tx = -Math.sin(th), tz = Math.cos(th);
        stone.add(u.box, M(x - ox, y, z - oz, Math.atan2(tx, tz) + Math.PI / 2, segLen + 0.4, WH, 2.4));
        crenel(x - tx * segLen / 2, z - tz * segLen / 2, x + tx * segLen / 2, z + tz * segLen / 2, y + WH, Math.cos(th) * 0.8, Math.sin(th) * 0.8);
      }
      for (let k = 0; k < 10; k++) {
        const th = k / 10 * Math.PI * 2 + p.rnd * 6, x = ox + Math.cos(th) * p.r, z = oz + Math.sin(th) * p.r;
        if (nearRoad(x, z, 24)) continue;
        const y = hy(x, z) - 3;
        stone.add(u.cyl, M(x - ox, y, z - oz, 0, 4.5, 18, 4.5));
        roofs.add(u.cone, M(x - ox, y + 18, z - oz, 0, 5.3, 8.5, 5.3), towerRoof);
      }
      const gates = [];
      if (sIn > 1) gates.push([sIn, -1]);
      if (sOut > 0 && sOut < route.total - 5) gates.push([sOut, 1]);
      for (const [s0, outward] of gates) {
        const q = this.offsetPoint(s0, 0), y = route.eleAt(s0) - 2;
        const along = Math.atan2(q.tx, q.tz); // box depth along the road
        for (const side of [-1, 1]) {
          const a = this.offsetPoint(s0, side * 6.6);
          stone.add(u.box, M(a.x - ox, y, a.z - oz, along, 5.4, 19, 8.5));
          // banners on the outer face
          const bx = a.x + outward * q.tx * 4.32, bz = a.z + outward * q.tz * 4.32;
          banners.add(u.box, M(bx - ox, y + 9.5, bz - oz, along, 2.6, 7.5, 0.08));
        }
        stone.add(u.box, M(q.x - ox, y + 12, q.z - oz, along, 8.2, 7, 8.5));
        roofs.add(u.prism, M(q.x - ox, y + 19, q.z - oz, along + Math.PI / 2, 9.8, 7.5, 20), towerRoof);
      }
      // houses: rows along the street and behind it; a church with a tall spire
      const tc = this.offsetPoint(p.s, 0), ux = tc.tx, uz = tc.tz, vx = -tc.tz, vz = tc.tx, rotT = Math.atan2(ux, uz);
      const cq = this.offsetPoint(Math.min(route.total, p.s + 30), -38), church = Math.hypot(cq.x - ox, cq.z - oz) < p.r - 22 ? cq : null;
      for (let a = -p.r; a <= p.r; a += 10.5) for (let b = -p.r; b <= p.r; b += 12.5) {
        const ja = a + (r() - 0.5) * 2.4, jb = b + (r() - 0.5) * 2.4, x = ox + ux * ja + vx * jb, z = oz + uz * ja + vz * jb;
        const keep = r(), w = 8.4 + r() * 2.4, d = 7.4 + r() * 2.2, hh = 8 + r() * 6, rot = rotT + (r() - 0.5) * 0.1;
        if (Math.hypot(x - ox, z - oz) > p.r - 10 || nearRoad(x, z, 10.5) || (church && Math.hypot(x - church.x, z - church.z) < 26) || keep < 0.08) continue;
        house(x, z, rot, w, d, hh);
      }
      if (church) {
        const y = hy(church.x, church.z) - 1, rot = Math.atan2(church.tx, church.tz), sx = Math.sin(rot), sz = Math.cos(rot);
        stone.add(u.box, M(church.x - ox, y, church.z - oz, rot, 14, 17, 30));
        roofs.add(u.prism, M(church.x - ox, y + 17, church.z - oz, rot, 15.4, 12.5, 31), towerRoof);
        const tx = church.x - sx * 19.5, tz = church.z - sz * 19.5;
        stone.add(u.box, M(tx - ox, y, tz - oz, rot, 9, 40, 9));
        roofs.add(u.pyr, M(tx - ox, y + 40, tz - oz, rot, 6.6, 26, 6.6), towerRoof);
        slits.add(u.box, M(tx - sx * 4.6 - ox, y + 29.4, tz - sz * 4.6 - oz, rot, 1.3, 3.2, 0.4));
      }
      p.gates = gates;
    } else if (p.kind === 'village') {
      for (let s = p.s0; s < p.s1; s += 18 + r() * 10) for (const side of [-1, 1]) {
        if (r() < 0.25) continue;
        const q = this.offsetPoint(s, side * (15 + r() * 12)), rot = Math.atan2(q.tx, q.tz) + (r() - 0.5) * 0.3;
        if (!this.clearOf(q.x, q.z, 10)) continue;
        house(q.x, q.z, rot, 7.5 + r() * 2, 8 + r() * 3, 6 + r() * 2.5);
      }
      // a small chapel
      const q = this.offsetPoint(p.s, (p.rnd < 0.5 ? -1 : 1) * 34), rot = Math.atan2(q.tx, q.tz), y = hy(q.x, q.z) - 1;
      if (this.clearOf(q.x, q.z, 14)) {
        stone.add(u.box, M(q.x - ox, y, q.z - oz, rot, 8, 9, 14));
        roofs.add(u.prism, M(q.x - ox, y + 9, q.z - oz, rot, 9, 7, 15), towerRoof);
        stone.add(u.box, M(q.x - ox - Math.sin(rot) * 9, y, q.z - oz - Math.cos(rot) * 9, rot, 4.5, 17, 4.5));
        roofs.add(u.pyr, M(q.x - ox - Math.sin(rot) * 9, y + 17, q.z - oz - Math.cos(rot) * 9, rot, 3.5, 10, 3.5), towerRoof);
      }
    } else if (p.kind === 'castle') {
      const cy = hy(ox, oz) - 2.5, rot = p.rot;
      const at = (lx, lz) => [ox + Math.cos(rot) * lx + Math.sin(rot) * lz, oz - Math.sin(rot) * lx + Math.cos(rot) * lz];
      const S = 27, H0 = 15, corners = [[-S, -S], [S, -S], [S, S], [-S, S]];
      for (let k = 0; k < 4; k++) {
        const [ax, az] = corners[k], [bx, bz] = corners[(k + 1) % 4], [x, z] = at((ax + bx) / 2, (az + bz) / 2);
        const along = ax === bx ? [2.8, 2 * S] : [2 * S, 2.8];
        stone.add(u.box, M(x - ox, cy, z - oz, rot, along[0], H0, along[1]));
        const [x0, z0] = at(ax, az), [x1, z1] = at(bx, bz), [x2, z2] = at((ax + bx) / 2 * 1.035, (az + bz) / 2 * 1.035);
        crenel(x0, z0, x1, z1, cy + H0, x2 - x, z2 - z);
      }
      for (const [lx, lz] of corners) {
        const [x, z] = at(lx, lz);
        stone.add(u.cyl, M(x - ox, cy, z - oz, 0, 4.8, 21, 4.8));
        roofs.add(u.cone, M(x - ox, cy + 21, z - oz, 0, 5.8, 9.5, 5.8), towerRoof);
      }
      const [kx, kz] = at(7, 6), KH = 42, K = 9.5;
      stone.add(u.box, M(kx - ox, cy, kz - oz, rot, 2 * K, KH, 2 * K));
      const kc = [[-K, -K], [K, -K], [K, K], [-K, K]].map(([a, b]) => at(7 + a, 6 + b));
      for (let k = 0; k < 4; k++) {
        const [x0, z0] = kc[k], [x1, z1] = kc[(k + 1) % 4], mx = (x0 + x1) / 2 - kx, mz = (z0 + z1) / 2 - kz, ml = Math.hypot(mx, mz);
        crenel(x0, z0, x1, z1, cy + KH, mx / ml * 0.4, mz / ml * 0.4);
      }
      for (const [a, b] of [[0, -K - 0.15], [0, K + 0.15], [-K - 0.15, 0], [K + 0.15, 0]]) for (const hh of [16, 26]) {
        const [wx, wz] = at(7 + a, 6 + b);
        slits.add(u.box, M(wx - ox, cy + hh, wz - oz, rot, a ? 0.4 : 1.2, 2.4, a ? 1.2 : 0.4));
      }
      const [bxx, bzz] = at(7, 6 + K + 0.25);
      banners.add(u.box, M(bxx - ox, cy + KH - 15, bzz - oz, rot, 4.2, 13, 0.08));
      const [tx, tz] = at(-11, -11), TH = 62;
      stone.add(u.cyl, M(tx - ox, cy, tz - oz, 0, 4.0, TH, 4.0));
      roofs.add(u.cone, M(tx - ox, cy + TH, tz - oz, 0, 4.9, 14, 4.9), towerRoof);
      slits.add(u.box, M(tx - ox, cy + TH - 8, tz - oz + 4.1, 0, 1.0, 2.6, 0.4));
    } else if (p.kind === 'stones') {
      for (let k = 0; k < 11; k++) {
        if (k === 4) continue;
        const a = k / 11 * Math.PI * 2 + p.rnd * 6, x = ox + Math.cos(a) * 8.5, z = oz + Math.sin(a) * 8.5, hs = 2.4 + r() * 1.8;
        rocks.add(u.stone, M(x - ox, hy(x, z) - 0.4, z - oz, r() * 6, 0.62 + r() * 0.15, hs, 0.62 + r() * 0.15, (r() - 0.5) * 0.16, (r() - 0.5) * 0.16));
      }
      rocks.add(u.stone, M(2.2, hy(ox + 2.2, oz - 1.5) + 0.25, -1.5, 0.7, 0.65, 3.4, 0.65, 0, Math.PI / 2 - 0.05));
    } else if (p.kind === 'tower') {
      const y = hy(ox, oz) - 1, TH = 16;
      stone.add(u.cyl, M(0, y, 0, 0, 3.4, TH, 3.4));
      for (let k = 0; k < 10; k++) { const a = k / 10 * Math.PI * 2; stone.add(u.box, M(Math.cos(a) * 3.1, y + TH, Math.sin(a) * 3.1, -a, 1.0, 1.2, 0.7)); }
      stone.add(u.cyl, M(0, y + TH, 0, 0, 0.9, 1.6, 0.9));
      p.top = y + TH + 1.6;
      slits.add(u.box, M(0, y + 9, 3.35, 0, 0.8, 1.8, 0.3));
    }
    const objs = [];
    const add = (b, m) => { if (b.empty) return; const me = new T.Mesh(b.build(), m); me.position.set(ox, 0, oz); this.world.add(me); objs.push(me); };
    add(stone, this.mat.stone); add(roofs, this.mat.roof); add(walls, this.mat.walls); add(banners, this.mat.banner); add(slits, this.mat.slit); add(rocks, this.mat.stones);
    p.obj = objs;
    if (p.kind === 'tower') this.torchWin = null; // the beacon shows with the torches
  }

  // ---------------------------------------------------------------- the world origin moves with the rider
  // (keeps the numbers on the graphics card small, also on routes of a thousand kilometres)
  setOrigin(x, z) {
    this.origin.x = x; this.origin.z = z; this.origin.set = true;
    this.world.position.set(-x, 0, -z);
    const mod = v => ((v % NOISE_Q) + NOISE_Q) % NOISE_Q;
    PU.uNoiseOff.value.set(mod(x), mod(z));
  }

  heightAt(x, z) { return this.field ? this.field.heightAt(x, z) : 0; }

  // screen position (CSS pixels) of a world point, or null when it is behind the camera
  toScreen(x, y, z, out) {
    const v = this._v || (this._v = new T.Vector3());
    v.set(x - this.origin.x, y, z - this.origin.z);
    const cam = this.camera;
    const dx = v.x - cam.position.x, dy = v.y - cam.position.y, dz = v.z - cam.position.z;
    const dir = this._d || (this._d = new T.Vector3());
    cam.getWorldDirection(dir);
    if (dx * dir.x + dy * dir.y + dz * dir.z <= 0) return null;
    v.project(cam);
    out = out || {};
    out.x = (v.x + 1) / 2 * this.cssW; out.y = (1 - v.y) / 2 * this.cssH;
    return out;
  }

  // ---------------------------------------------------------------- every frame
  // st: { s (rider, route metres), v (m/s), cad (rpm), ghost: { s, v } or null, riderAlpha (0..1),
  //       cam: { x, y, z (world), yaw (from north, clockwise), pitch, fov (vertical, degrees) } }
  frame(dt, st, noPicture) {
    if (!this.route) return;
    this.time += dt;
    const route = this.route, s = clamp(st.s, 0, route.total);
    const p = this._rp || (this._rp = {});
    route.xzAt(s, p);
    if (!this.origin.set || Math.hypot(p.x - this.origin.x, p.z - this.origin.z) > 3000) this.setOrigin(p.x, p.z);
    const hd = route.headingAt(s, 8, 14), ahead = { x: Math.sin(hd), z: -Math.cos(hd) };
    // land, road, torches, places
    this.updateChunks(p.x, p.z, ahead, this.firstFrames > 0 ? 40 : 7);
    if (this.firstFrames > 0) this.firstFrames--;
    this.updateRoad(s);
    this.updateTorches(s);
    if (!this._plT || this.time - this._plT > 0.5) { this._plT = this.time; this.updatePlaces(p.x, p.z); }
    // rider and ghost
    const ry = route.eleAt(s) + 0.12, g0 = route.gradeAt(s) / 100;
    const right = this.offsetPoint(s, 1.6);
    const R = this.rider.group;
    R.position.set(right.x, ry, right.z);
    R.rotation.set(-Math.atan(g0), Math.PI - hd, 0, 'YXZ');
    R.scale.setScalar(1.05);
    R.visible = st.riderAlpha > 0.05;
    this.rider.animate(dt, st.cad || 0, st.v || 0);
    this.blob.position.set(right.x, ry + 0.03, right.z);
    this.blob.rotation.set(0, Math.PI - hd, 0, 'YXZ');
    this.blob.visible = R.visible;
    const G = this.ghost.group;
    if (st.ghost && st.ghost.s != null) {
      const gs = clamp(st.ghost.s, 0, route.total), gq = this.offsetPoint(gs, 0.6), gh = route.headingAt(gs, 8, 14);
      G.visible = true;
      G.position.set(gq.x, route.eleAt(gs) + 0.12, gq.z);
      G.rotation.set(-Math.atan(route.gradeAt(gs) / 100), Math.PI - gh, 0, 'YXZ');
      G.scale.setScalar(1.05);
      this.ghost.animate(dt, (st.ghost.v || 0) > 0.5 ? 82 : 0, st.ghost.v || 0);
    } else G.visible = false;
    // camera
    const cam = this.camera, c = st.cam;
    cam.position.set(c.x - this.origin.x, c.y, c.z - this.origin.z);
    cam.rotation.set(c.pitch, -c.yaw, 0, 'YXZ');
    if (Math.abs(cam.fov - c.fov) > 0.01) { cam.fov = c.fov; cam.updateProjectionMatrix(); }
    cam.updateMatrixWorld();
    if (!this._lodT || this.time - this._lodT > 0.5) { this._lodT = this.time; this.treeLod(c.x, c.z); }
    this.updateTorchLights(p.x, p.z);
    // the sun: low, ahead and to the right of the general direction of the route (turns slowly)
    const hLong = route.headingAt(s, 1500, 3000) + 0.62;
    this.sunAz = this.sunAz == null ? hLong : this.sunAz + Math.atan2(Math.sin(hLong - this.sunAz), Math.cos(hLong - this.sunAz)) * (1 - Math.exp(-dt / 40));
    const el = 0.1, sd = PU.uSunDirW.value.set(Math.sin(this.sunAz) * Math.cos(el), Math.sin(el), -Math.cos(this.sunAz) * Math.cos(el)).normalize();
    this.sun.position.copy(cam.position).addScaledVector(sd, 1000);
    this.sun.target.position.copy(cam.position);
    // haze in the valley around the rider, the last light only on the ground well above
    const re = route.eleAt(s);
    this.eleSm = this.eleSm == null ? re : this.eleSm + (re - this.eleSm) * (1 - Math.exp(-dt / 6));
    PU.uHazeBase.value = this.eleSm - 20;
    PU.uAlpen.value.set(1, this.eleSm + 480, this.eleSm + 1100);
    this.sky.position.copy(cam.position);
    if (!noPicture) this.render(dt);
  }
  renderNow() {
    if (!this.q.kr && !this._init) { this._init = true; this.applyLevel(this.q.level); }
    this.composer.render();
  }

  // about 30 pictures per second; the quality adapts when the device cannot keep up
  render(dt) {
    const q = this.q, now = performance.now();
    if (q.lastRender && now - q.lastRender < 30) return;
    const gap = q.lastRender ? now - q.lastRender : 33;
    q.lastRender = now;
    if (!this.q.kr && q.mode === 'auto' && !this._init) { this._init = true; this.applyLevel(q.level); }
    this.composer.render();
    q.acc += gap; q.n++;
    if (q.acc > 2500) {
      const ms = q.acc / q.n;
      q.fps = Math.round(1000 / ms);
      q.acc = 0; q.n = 0;
      if (q.mode === 'auto' && !this.queue.length) {
        if (ms > 40 && q.level < LEVELS.length - 1) { q.bad[q.level] = (q.bad[q.level] || 0) + 1; q.slowFor = 0; this.applyLevel(q.level + 1); }
        else if (ms < 36) { q.fastFor++; if (q.fastFor >= 4 && q.level > 0 && (q.bad[q.level - 1] || 0) < 2) { q.fastFor = 0; this.applyLevel(q.level - 1); } }
        else q.fastFor = 0;
      }
    }
  }
}

window.Welt = {
  create(container, opts) {
    const e = new Engine(container, opts);
    e.firstFrames = 20;
    return e;
  },
  LOOK,
};
})();
