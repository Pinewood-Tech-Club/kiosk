"""Molds a Haribo-Goldbear-style gummy bear as a signed distance field and writes it as an OBJ in millimeters.

    uv run --no-project --with numpy --with scikit-image python -I gummy_bear_sdf.py <out.obj>

Standing, belly toward -Y, head +Z. gummy_bear.py turns it into GummyBear.usdz.
"""
import sys

import numpy as np
from skimage.measure import marching_cubes

out = sys.argv[1]
STEP = 0.08

xs = np.arange(-8, 8 + STEP, STEP)
ys = np.arange(-6, 6 + STEP, STEP)
zs = np.arange(-11.5, 11.5 + STEP, STEP)
X, Y, Z = np.meshgrid(xs, ys, zs, indexing="ij")


def ellipsoid(c, r, rot_y=0.0):
    px, py, pz = X - c[0], Y - c[1], Z - c[2]
    if rot_y:
        a = np.radians(rot_y)
        px, pz = px * np.cos(a) - pz * np.sin(a), px * np.sin(a) + pz * np.cos(a)
    k0 = np.sqrt((px / r[0]) ** 2 + (py / r[1]) ** 2 + (pz / r[2]) ** 2)
    k1 = np.sqrt((px / r[0] ** 2) ** 2 + (py / r[1] ** 2) ** 2 + (pz / r[2] ** 2) ** 2)
    return k0 * (k0 - 1) / np.maximum(k1, 1e-9)


def smin(a, b, k):
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0, 1)
    return b * (1 - h) + a * h - k * h * (1 - h)


def smax(a, b, k):
    return -smin(-a, -b, k)


head = ellipsoid((0, 0, 5.0), (4.3, 3.5, 3.9))
for s in (-1, 1):
    head = smin(head, ellipsoid((s * 3.1, 0.5, 8.2), (1.6, 1.6, 1.6)), 0.6)
head = smin(head, ellipsoid((0, -2.9, 4.6), (1.9, 1.3, 1.45)), 0.8)

body = ellipsoid((0, 0.2, -2.6), (4.6, 4.0, 5.6))
for s in (-1, 1):
    body = smin(body, ellipsoid((s * 3.7, -0.9, -0.2), (1.5, 2.2, 2.8), rot_y=-s * 14), 0.9)
    body = smin(body, ellipsoid((s * 2.6, -0.7, -7.2), (2.3, 3.0, 2.6)), 1.0)

d = smin(head, body, 1.3)
d = smax(d, Y - 3.7, 1.2)

verts, faces, _, _ = marching_cubes(d, 0.0, spacing=(STEP, STEP, STEP))
verts += np.array([xs[0], ys[0], zs[0]])
with open(out, "w") as f:
    for v in verts:
        f.write(f"v {v[0]:.5f} {v[1]:.5f} {v[2]:.5f}\n")
    for t in faces:
        f.write(f"f {t[0] + 1} {t[2] + 1} {t[1] + 1}\n")
size = verts.max(0) - verts.min(0)
print(f"gummy_bear_sdf: {len(verts)} verts, {size[0]:.1f} x {size[1]:.1f} x {size[2]:.1f} mm")
