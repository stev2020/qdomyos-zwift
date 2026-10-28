"""Paints the textures of the Kvest style test.

textures/grass.png    grass clumps for the crossing cards, 2 x 3 cells of 512 x 256:
                      0 lush meadow, 1 seed heads, 2 short and dense,
                      3 with small white and yellow flowers, 4 pink and violet flowers, 5 reeds
textures/leaves.png   leaf clusters and fir branches, 2 x 4 cells of 512 x 512: oval leaves, small leaves,
                      fir branches, maple leaves (leaves light grey, the shader tints them per tree)
textures/leaves_n.png the matching normals (every leaf is tilted a bit and bent along its midrib)

Run: python3 tools/make_textures.py
"""
import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter

SS = 2  # supersampling
HERE = os.path.dirname(os.path.abspath(__file__))
TEX = os.path.join(HERE, "..", "textures")


# ------------------------------------------------------------------ helpers
def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(len(a)))


def rgb255(c, a=255):
    return (int(max(0, min(1, c[0])) * 255), int(max(0, min(1, c[1])) * 255), int(max(0, min(1, c[2])) * 255), a)


def bleed(img, radius=9):
    """Gives transparent pixels the colour of nearby painted pixels, so mipmaps keep the colour."""
    rgb = img.convert("RGB").filter(ImageFilter.MaxFilter(radius))
    alpha = img.getchannel("A")
    out = Image.composite(img.convert("RGB"), rgb, alpha.point(lambda v: 255 if v > 8 else 0))
    out.putalpha(alpha)
    return out


# ------------------------------------------------------------------ grass
GRASS_DARK = (0.13, 0.24, 0.06)
GRASS_MID = (0.36, 0.55, 0.13)
GRASS_TIP = (0.70, 0.80, 0.30)
DRY_TIP = (0.86, 0.78, 0.42)


def blade(d, rng, x0, y0, height, lean, width, col_base, col_tip, steps=14):
    """A curved blade from (x0, y0) upwards, drawn as small quads with a colour gradient."""
    tipx = x0 + lean * height
    ctrlx = x0 + lean * height * rng.uniform(0.1, 0.45)
    ctrly = y0 - height * rng.uniform(0.45, 0.7)
    tipy = y0 - height
    prev = None
    for i in range(steps + 1):
        t = i / steps
        x = (1 - t) ** 2 * x0 + 2 * (1 - t) * t * ctrlx + t * t * tipx
        y = (1 - t) ** 2 * y0 + 2 * (1 - t) * t * ctrly + t * t * tipy
        w = width * (1 - t) ** 0.85 + 0.3
        if prev is not None:
            px, py, pw = prev
            dx, dy = x - px, y - py
            ln = math.hypot(dx, dy) or 1
            nx, ny = -dy / ln, dx / ln
            c = rgb255(mix(col_base, col_tip, t ** 0.75))
            d.polygon([(px + nx * pw, py + ny * pw), (x + nx * w, y + ny * w),
                       (x - nx * w, y - ny * w), (px - nx * pw, py - ny * pw)], fill=c)
        prev = (x, y, w)
    return tipx, tipy


def grass_cell(rng, w, h, kind):
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    base_y = h - 2 * SS
    n = {0: 120, 1: 95, 2: 150, 3: 105, 4: 70, 5: 60}[kind]
    hmin, hmax = {0: 0.55, 1: 0.5, 2: 0.3, 3: 0.4, 4: 0.4, 5: 0.7}[kind], {0: 0.97, 1: 0.9, 2: 0.62, 3: 0.75, 4: 0.75, 5: 0.99}[kind]
    blades = []
    for _ in range(n):
        x0 = w * 0.5 + rng.gauss(0, w * 0.17)
        x0 = max(w * 0.06, min(w * 0.94, x0))
        height = h * rng.uniform(hmin, hmax) * (1 - abs(x0 / w - 0.5) * 0.7)
        lean = rng.gauss(0, 0.28) + (x0 / w - 0.5) * 0.9
        depth = rng.random()  # 0 back .. 1 front
        blades.append((depth, x0, height, lean))
    blades.sort()
    tips = []
    for depth, x0, height, lean in blades:
        shade = 0.72 + 0.28 * depth
        dry = rng.random() < (0.22 if kind in (0, 1) else 0.1)
        tip = DRY_TIP if dry else mix(GRASS_TIP, GRASS_MID, rng.uniform(0, 0.35))
        if kind == 5:  # reeds: darker, bluer, straighter
            tip = (0.42, 0.56, 0.30)
            lean *= 0.35
        base = tuple(c * shade for c in GRASS_DARK)
        tip = tuple(c * (0.85 + 0.15 * depth) for c in tip)
        width = SS * rng.uniform(2.6, 4.6) * (1.4 if kind == 5 else 1.0)
        tips.append((blade(d, rng, x0, base_y, height, lean, width, base, tip), depth))
    # seed heads, flowers and spikes on top of some blades
    if kind == 1:
        for (tx, ty), depth in tips[::3]:
            d.ellipse([tx - 3 * SS, ty - 7 * SS, tx + 3 * SS, ty + 2 * SS], fill=rgb255((0.80, 0.70, 0.46)))
    if kind == 3:
        for (tx, ty), depth in tips[::4]:
            col = (0.98, 0.97, 0.92) if rng.random() < 0.7 else (1.0, 0.84, 0.22)
            r = SS * rng.uniform(3.2, 4.6)
            for k in range(6):
                a = k * math.pi / 3 + rng.uniform(0, 0.4)
                d.ellipse([tx + math.cos(a) * r - r * 0.55, ty + math.sin(a) * r - r * 0.55,
                           tx + math.cos(a) * r + r * 0.55, ty + math.sin(a) * r + r * 0.55], fill=rgb255(col))
            d.ellipse([tx - r * 0.45, ty - r * 0.45, tx + r * 0.45, ty + r * 0.45], fill=rgb255((1.0, 0.78, 0.18)))
    if kind == 4:
        for (tx, ty), depth in tips[::2]:
            col = mix((0.80, 0.30, 0.72), (0.55, 0.32, 0.85), rng.random())
            for k in range(9):
                yy = ty + k * 4.2 * SS
                rr = SS * (2.0 + k * 0.35)
                c = rgb255(mix(col, (1.0, 0.75, 0.95), 0.25 * (1 - k / 9)) if k < 7 else mix(col, (0.3, 0.2, 0.3), 0.3))
                d.ellipse([tx - rr, yy - rr * 0.8, tx + rr, yy + rr * 0.8], fill=c)
    return img


GRASS_ROWS = 240


def make_grass():
    cw, ch = 512, 256
    big = Image.new("RGBA", (2 * cw * SS, 3 * ch * SS), (0, 0, 0, 0))
    rng = random.Random(11)
    for k in range(6):
        # 240 of the 256 rows are painted; the empty rows below keep the mipmaps of the cells apart
        cell = grass_cell(rng, cw * SS, GRASS_ROWS * SS, k)
        big.paste(cell, ((k % 2) * cw * SS, (k // 2) * ch * SS), cell)
    img = bleed(big.resize((2 * cw, 3 * ch), Image.LANCZOS), 7)
    img.save(os.path.join(TEX, "grass.png"))


# ------------------------------------------------------------------ leaves
def leaf_halves(cx, cy, length, width, angle, steps=10):
    """Two halves of an almond shaped leaf (left and right of the midrib)."""
    ca, sa = math.cos(angle), math.sin(angle)
    halves = []
    for side in (1, -1):
        pts = []
        for i in range(steps + 1):
            t = i / steps
            x = (t - 0.5) * length
            y = side * math.sin(math.pi * t) ** 0.8 * width * 0.5
            pts.append((cx + x * ca - y * sa, cy + x * sa + y * ca))
        halves.append(pts)
    return halves


def normal_rgb(n):
    ln = math.sqrt(n[0] ** 2 + n[1] ** 2 + n[2] ** 2)
    return (int((n[0] / ln * 0.5 + 0.5) * 255), int((n[1] / ln * 0.5 + 0.5) * 255), int((n[2] / ln * 0.5 + 0.5) * 255), 255)


def maple_leaf(cx, cy, length, angle, steps=60):
    """Star shaped leaf with five pointed lobes."""
    ca, sa = math.cos(angle), math.sin(angle)
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        r = length * 0.5 * (0.5 + 0.5 * abs(math.cos(2.5 * t)) ** 3) * (0.8 + 0.2 * math.cos(t))
        x, y = math.cos(t) * r, math.sin(t) * r
        pts.append((cx + x * ca - y * sa, cy + x * sa + y * ca))
    return pts


def leaf_cluster(rng, size, kind="oval"):
    """kind: oval (beech and most trees), small (birch and rowan, airy), maple (star leaves)."""
    col = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    nrm = Image.new("RGBA", (size, size), (128, 128, 255, 0))
    dc, dn = ImageDraw.Draw(col), ImageDraw.Draw(nrm)
    c = size / 2
    radius = size * (0.37 if kind == "small" else 0.43)
    amp = (0.12, 0.24) if kind == "small" else (0.07, 0.15)
    lobes = [(rng.uniform(*amp), rng.randint(3, 6), rng.uniform(0, 6.3)) for _ in range(2)]

    def outline(a):
        r = 1.0
        for amp, freq, ph in lobes:
            r += amp * math.sin(freq * a + ph)
        return radius * r

    for _ in range(rng.randint(3, 5)):  # twigs
        a = rng.uniform(0, 2 * math.pi)
        r = outline(a) * rng.uniform(0.5, 0.8)
        dc.line([(c, c + size * 0.12), (c + math.cos(a) * r, c + math.sin(a) * r)], fill=(70, 58, 46, 255), width=max(2, size // 170))

    leaves = []
    count = {"oval": 260, "small": 210, "maple": 120}[kind]
    for _ in range(count):
        a = rng.uniform(0, 2 * math.pi)
        rr = outline(a) * math.sqrt(rng.uniform(0, 1))
        leaves.append((rr / outline(a), c + math.cos(a) * rr, c + math.sin(a) * rr, a))
    leaves.sort()
    for depth, x, y, a in leaves:
        length = size * (rng.uniform(0.05, 0.068) if kind == "small" else rng.uniform(0.11, 0.15) if kind == "maple" else rng.uniform(0.07, 0.1))
        width = length * rng.uniform(0.5, 0.62)
        ang = a + rng.uniform(-0.9, 0.9)
        shade = max(0.45, min(1.0, 0.6 + 0.4 * depth + rng.uniform(-0.08, 0.08)))
        warm = rng.uniform(-0.05, 0.05)
        colour = (min(1, shade + warm), shade, max(0, shade - warm * 0.6))
        # tilt: outwards at the rim (round cluster), random elsewhere
        tx = math.cos(a) * depth * 0.55 + rng.uniform(-0.35, 0.35)
        ty = -math.sin(a) * depth * 0.55 + rng.uniform(-0.35, 0.35)
        bend = 0.32
        ca, sa = math.cos(ang), math.sin(ang)
        # the across-leaf direction in texture space (x right, y down) -> normal space (y up)
        ax, ay = -sa, -ca
        if kind == "maple":
            poly = maple_leaf(x, y, length, ang)
            dc.polygon(poly, fill=rgb255(colour))
            dn.polygon(poly, fill=normal_rgb((tx, ty, 1.0)))
            dc.line(poly + [poly[0]], fill=rgb255(tuple(v * 0.74 for v in colour)), width=max(1, size // 420))
            for k in range(5):
                va = ang + k * 2 * math.pi / 5
                dc.line([(x, y), (x + math.cos(va) * length * 0.4, y + math.sin(va) * length * 0.4)],
                        fill=rgb255(tuple(v * 0.8 for v in colour)), width=max(1, size // 520))
            continue
        for k, half in enumerate(leaf_halves(x, y, length, width, ang)):
            s = 1 if k == 0 else -1
            n = (tx + ax * bend * s, ty + ay * bend * s, 1.0)
            dc.polygon(half, fill=rgb255(colour))
            dn.polygon(half, fill=normal_rgb(n))
        edge = rgb255(tuple(v * 0.74 for v in colour))
        h1, h2 = leaf_halves(x, y, length, width, ang)
        dc.line(h1 + h2[::-1] + [h1[0]], fill=edge, width=max(1, size // 420))
        dc.line([(x - ca * length * 0.38, y - sa * length * 0.38), (x + ca * length * 0.38, y + sa * length * 0.38)],
                fill=rgb255(tuple(v * 0.82 for v in colour)), width=max(1, size // 520))
    return col, nrm


FIR_DARK = (0.12, 0.20, 0.08)
FIR_MID = (0.30, 0.42, 0.14)
FIR_TIP = (0.55, 0.64, 0.24)


def fir_branch(rng, size):
    """A drooping fir branch seen from the side: twig from the left (trunk) to the right (tip),
    side twigs and short needles. Painted in its own colours (the shader tint stays near white)."""
    col = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    nrm = Image.new("RGBA", (size, size), (128, 128, 255, 0))
    dc, dn = ImageDraw.Draw(col), ImageDraw.Draw(nrm)
    y0 = size * 0.5

    def twig_point(t):
        return size * (0.02 + 0.95 * t), y0 + size * 0.06 * t * t

    # side twigs: (start t, angle, length)
    twigs = []
    t = 0.08
    side = 1
    while t < 0.92:
        length = size * (0.42 - 0.3 * t) * rng.uniform(0.85, 1.15)
        twigs.append((t, side * rng.uniform(0.5, 0.9), length))
        side = -side
        t += rng.uniform(0.035, 0.055)
    strokes = []

    def needles_along(x0, y0_, x1, y1, density, length, spread):
        dx, dy = x1 - x0, y1 - y0_
        ln = math.hypot(dx, dy) or 1
        ux, uy = dx / ln, dy / ln
        steps = int(ln / density)
        for i in range(steps):
            f = i / max(1, steps)
            px, py = x0 + dx * f, y0_ + dy * f
            for s in (1, -1):
                a = math.atan2(uy, ux) + s * spread + rng.uniform(-0.2, 0.2)
                ll = length * rng.uniform(0.7, 1.1) * (1 - 0.35 * f)
                strokes.append((rng.random(), px, py, px + math.cos(a) * ll, py + math.sin(a) * ll, s))

    for t0, ang, length in twigs:
        sx, sy = twig_point(t0)
        a = ang + 0.1
        ex, ey = sx + math.cos(a) * length, sy + math.sin(a) * length * 0.75
        dc.line([(sx, sy), (ex, ey)], fill=rgb255((0.22, 0.17, 0.12)), width=max(2, size // 300))
        needles_along(sx, sy, ex, ey, size / 170, size * 0.06, 1.0)
    pts = [twig_point(i / 30) for i in range(31)]
    dc.line(pts, fill=rgb255((0.25, 0.19, 0.13)), width=max(3, size // 170))
    for i in range(30):
        needles_along(pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1], size / 170, size * 0.065, 1.05)
    strokes.sort()
    w = max(3, size // 200)
    for depth, x0, y0_, x1, y1, s in strokes:
        shade = 0.7 + 0.3 * depth
        c0 = tuple(v * shade for v in FIR_DARK)
        c1 = tuple(v * shade for v in (FIR_TIP if depth > 0.6 else FIR_MID))
        mx, my = (x0 + x1) / 2, (y0_ + y1) / 2
        dc.line([(x0, y0_), (mx, my)], fill=rgb255(c0), width=w)
        dc.line([(mx, my), (x1, y1)], fill=rgb255(c1), width=w)
        n = normal_rgb(((x1 - x0) / size * 6, -(y1 - y0_) / size * 6 + 0.25 * s, 1.0))
        dn.line([(x0, y0_), (x1, y1)], fill=n, width=w + 1)
    return col, nrm


LEAF_CELLS = ["oval", "oval", "small", "small", "fir", "fir", "maple", "maple"]


def make_leaves():
    """2 x 4 cells: oval leaves, small leaves, fir branches, maple leaves (two of each)."""
    cell = 512
    rows = len(LEAF_CELLS) // 2
    bigc = Image.new("RGBA", (2 * cell * SS, rows * cell * SS), (0, 0, 0, 0))
    bign = Image.new("RGBA", (2 * cell * SS, rows * cell * SS), (128, 128, 255, 0))
    rng = random.Random(7)
    for k, kind in enumerate(LEAF_CELLS):
        c, n = fir_branch(rng, cell * SS) if kind == "fir" else leaf_cluster(rng, cell * SS, kind)
        pos = ((k % 2) * cell * SS, (k // 2) * cell * SS)
        bigc.paste(c, pos, c)
        bign.paste(n, pos, n)
    col = bleed(bigc.resize((2 * cell, rows * cell), Image.LANCZOS), 9)
    col.save(os.path.join(TEX, "leaves.png"))
    nrm = bign.resize((2 * cell, rows * cell), Image.LANCZOS)
    flat = Image.new("RGB", nrm.size, (128, 128, 255))
    nrm = Image.composite(nrm.convert("RGB"), flat, nrm.getchannel("A").point(lambda v: 255 if v > 8 else 0))
    nrm.save(os.path.join(TEX, "leaves_n.png"))


if __name__ == "__main__":
    os.makedirs(TEX, exist_ok=True)
    make_grass()
    make_leaves()
    print("textures written to", os.path.abspath(TEX))
