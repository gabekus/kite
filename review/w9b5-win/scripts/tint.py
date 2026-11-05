# The theme shader (ThemeBackdrop.cpp / Kite.metal) in numpy float32, to solve for the material
# under it in a capture: obs = theme (premultiplied, 8-bit) + (1 - a) * material.
import numpy as np
from PIL import Image
f = np.float32
def fract(v): return v - np.floor(v)
def hash12(x, y):
    p = [fract(x * f(0.1031)), fract(y * f(0.1031)), fract(x * f(0.1031))]
    d = p[0] * (p[1] + f(33.33)) + p[1] * (p[2] + f(33.33)) + p[2] * (p[0] + f(33.33))
    p = [q + d for q in p]
    return fract((p[0] + p[1]) * p[2])
def srgb_to_lin(c): return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
def to_lab(rgb):
    r, g, b = [srgb_to_lin(np.float64(v)) for v in rgb]
    l = 0.4122214708*r + 0.5363325363*g + 0.0514459929*b
    m = 0.2119034982*r + 0.6806995451*g + 0.1073969566*b
    s = 0.0883024619*r + 0.2817188376*g + 0.6299787005*b
    l, m, s = np.cbrt(l), np.cbrt(m), np.cbrt(s)
    return f(0.2104542553*l + 0.7936177850*m - 0.0040720468*s), f(1.9779984951*l - 2.4285922050*m + 0.4505937099*s), f(0.0259040371*l + 0.7827717662*m - 0.8086757660*s)
ANCH = {1: [(0.5, 0.5)], 2: [(0, 0), (1, 1)], 3: [(0, 0), (1, 0.25), (0.35, 1)], 4: [(0, 0), (1, 0), (0, 1), (1, 1)]}
def shade(colors, grain, tint, W=2560, H=1640):
    py, px = np.mgrid[0:H, 0:W].astype(f) + f(0.5)
    u, v = px / f(W), py / f(H); aspect = f(W / H)
    labs = [to_lab(c) for c in colors]
    if len(labs) == 1:
        L, A, B = labs[0][0] - f(0.05) * v, np.full_like(u, labs[0][1]), np.full_like(u, labs[0][2])
    else:
        sw = np.zeros_like(u); sL = np.zeros_like(u); sA = np.zeros_like(u); sB = np.zeros_like(u)
        for (ax, ay), lab in zip(ANCH[len(labs)], labs):
            w = np.exp(-(((u - f(ax)) * aspect) ** 2 + (v - f(ay)) ** 2) * f(1.6))
            sL += lab[0] * w; sA += lab[1] * w; sB += lab[2] * w; sw += w
        k = np.maximum(sw, f(1e-4)); L, A, B = sL / k, sA / k, sB / k
    l_ = L + f(0.3963377774) * A + f(0.2158037573) * B; m_ = L - f(0.1055613458) * A - f(0.0638541728) * B; s_ = L - f(0.0894841775) * A - f(1.2914855480) * B
    l, m, s = l_ ** 3, m_ ** 3, s_ ** 3
    lin = [f(4.0767416621)*l - f(3.3077115913)*m + f(0.2309699292)*s, f(-1.2684380046)*l + f(2.6097574011)*m - f(0.3413193965)*s, f(-0.0041960863)*l - f(0.7034186147)*m + f(1.7076147010)*s]
    def enc(c):
        c = np.clip(c, 0, 1); return np.where(c <= 0.0031308, 12.92 * c, 1.055 * np.power(c, 1 / 2.4) - 0.055).astype(f)
    dither = (hash12(px + f(91.7), py + f(91.7)) - f(0.5)) / f(255)
    rgb = [np.clip(enc(c) + dither, 0, 1) * f(tint) for c in lin]
    a = f(tint)
    g = f(grain * 0.259); grey = np.clip(f(0.73) + (hash12(px, py) - f(0.5)) * f(0.735), 0, 1)
    out = [grey * g * c + grey * g * (1 - a) + c * (1 - g) for c in rgb]
    alpha = g * a + g * (1 - a) + a * (1 - g)
    q = lambda x: np.rint(np.clip(x, 0, 1) * 255) / 255
    return np.stack([q(c) for c in out], -1), np.full(out[0].shape, q(alpha))
def solve(path, colors, grain, tint, box, base=None):
    img = np.asarray(Image.open(path).convert('RGB')).astype(np.float64) / 255
    t, a = shade(colors, grain, tint)
    x0, y0, x1, y1 = box
    o = img[y0:y1, x0:x1]; tt = t[y0:y1, x0:x1]; aa = a[y0:y1, x0:x1][..., None]
    if base is not None:
        pred = tt + (1 - aa) * base
        return (o - pred) * 255
    return (o - tt) / (1 - aa) * 255
