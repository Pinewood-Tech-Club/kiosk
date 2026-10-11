# blender -b --factory-startup -P gummy_bear.py -- Assets3D/gummy_bears/scene.gltf Kiosk/Resources/3D/GummyBear.usdz [preview.png]
# Source: "Gummy Bears" by Styro (CC-BY-4.0). Its mesh is a flat-backed slab with a shallow relief, so it is resampled as
# a height field (outline and belly relief), then rebuilt as a chunky molded Goldbear: the outline is inflated with
# rounded sides, the source relief is kept, and the head, snout, ears, arms, belly, legs and back are
# sculpted on as soft domes before a voxel remesh, smoothing and decimation.
# Output: lying on its back as a scattered piece rests (back on -Y, belly +Y, head toward -Z), bounding box centered.
# UV channel "st" carries shading data rather than a layout: u = how squarely the surface faces the belly or back
# axis (1 face-on, 0 side wall), v = local thickness through the jelly along the inward normal
# (1 = twice the depth of the bear or more).
import bpy, math, os, sys, tempfile
import numpy as np
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

argv = sys.argv[sys.argv.index("--") + 1:]
src, out_usdz = argv[0], argv[1]
preview = argv[2] if len(argv) > 2 else None
env = lambda name, default: float(os.environ.get(name, default))
TARGET_H = env("GUMMY_HEIGHT", "0.020")
STEP = env("GUMMY_STEP", "0.00007")
VOXEL = env("GUMMY_VOXEL", "0.0001")
SMOOTH_ITER = int(env("GUMMY_SMOOTH", "20"))
TARGET_TRIS = int(env("GUMMY_TRIS", "7000"))
EDGE = env("GUMMY_EDGE", "2.4")
FRONT = env("GUMMY_FRONT", "2.2")
BACK = env("GUMMY_BACK", "2.5")
RELIEF = env("GUMMY_RELIEF", "0.3")
FEATURES = env("GUMMY_FEATURES", "1.0")
BLUR = env("GUMMY_BLUR", "0.25")

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)

source = sorted([o for o in bpy.data.objects if o.type == "MESH"], key=lambda o: o.name)[0]
sm = source.data
sm.transform(source.matrix_world)
# Standing: height along +Z, belly toward -Y.
sm.transform(Matrix.Rotation(math.radians(-90), 4, "Z"))
sp = np.array([v.co[:] for v in sm.vertices])
sm.transform(Matrix.Translation(Vector(-(sp.min(0) + sp.max(0)) / 2)))
sm.transform(Matrix.Scale(TARGET_H / (sp[:, 2].max() - sp[:, 2].min()), 4))
sp = np.array([v.co[:] for v in sm.vertices])
bvh = BVHTree.FromPolygons([v.co for v in sm.vertices], [p.vertices[:] for p in sm.polygons])
lo, hi = sp.min(0), sp.max(0)

pad = 3
xs = np.arange(lo[0] - pad * STEP, hi[0] + pad * STEP, STEP)
zs = np.arange(lo[2] - pad * STEP, hi[2] + pad * STEP, STEP)
front = np.full((len(zs), len(xs)), np.nan)
for i, z in enumerate(zs):
    for j, x in enumerate(xs):
        hit = bvh.ray_cast(Vector((x, lo[1] - 0.01, z)), Vector((0, 1, 0)))
        if hit[0] is not None:
            front[i, j] = hit[0].y
for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)

inside = ~np.isnan(front)
plane = np.nanpercentile(front, 70)
relief = np.where(inside, np.clip(plane - front, 0, None), 0)
for _ in range(6):
    relief = (relief + np.roll(relief, 1, 0) + np.roll(relief, -1, 0) + np.roll(relief, 1, 1) + np.roll(relief, -1, 1)) / 5
    relief *= inside

edge_cells = inside & ~(np.roll(inside, 1, 0) & np.roll(inside, -1, 0) & np.roll(inside, 1, 1) & np.roll(inside, -1, 1))
X, Z = np.meshgrid(xs, zs)
bx, bz = X[edge_cells], Z[edge_cells]
dist = np.zeros_like(X)
ii, jj = np.nonzero(inside)
for k in range(0, len(ii), 4000):
    px, pz = X[ii[k:k + 4000], jj[k:k + 4000]], Z[ii[k:k + 4000], jj[k:k + 4000]]
    d = np.sqrt((px[:, None] - bx[None]) ** 2 + (pz[:, None] - bz[None]) ** 2).min(1)
    dist[ii[k:k + 4000], jj[k:k + 4000]] = d + STEP / 2

mm = 0.001
x, z = X / mm, Z / mm
rim = np.sqrt(1 - (1 - np.clip(dist / (EDGE * mm), 0, 1)) ** 2)


def dome(cx, cz, rx, rz, height, angle=0.0, power=0.5):
    c, s = math.cos(angle), math.sin(angle)
    u, w = (x - cx) * c + (z - cz) * s, -(x - cx) * s + (z - cz) * c
    r2 = (u / rx) ** 2 + (w / rz) ** 2
    return height * np.clip(1 - r2, 0, None) ** power


def mirrored(cx, *rest, angle=0.0, **kw):
    return dome(cx, *rest, angle=angle, **kw) + dome(-cx, *rest, angle=-angle, **kw)


def blur(field, sigma=BLUR * mm):
    radius = int(3 * sigma / STEP)
    kernel = np.exp(-0.5 * (np.arange(-radius, radius + 1) * STEP / sigma) ** 2)
    kernel /= kernel.sum()
    field = np.apply_along_axis(lambda r: np.convolve(r, kernel, mode="same"), 0, field)
    return np.apply_along_axis(lambda r: np.convolve(r, kernel, mode="same"), 1, field)


def smax(a, b, k=0.5):
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0, 1)
    return a * (1 - h) + b * h + k * h * (1 - h)


head = dome(0, 6.4, 4.7, 3.5, 1.35)
snout = dome(0, 4.9, 1.75, 1.35, 0.8, power=0.7) + dome(0, 5.35, 0.7, 0.5, 0.25)
ears = mirrored(4.2, 8.5, 1.6, 1.4, 0.8)
arms = mirrored(3.4, 1.5, 1.45, 2.9, 1.25, angle=-0.75)
belly = dome(0, -2.0, 3.4, 3.9, 1.15)
legs = mirrored(3.2, -6.6, 2.35, 2.6, 1.35)
features = blur(smax(smax(head + snout + ears, belly), smax(arms, legs)))
F = FRONT * rim + RELIEF * relief / mm * np.sqrt(rim) + FEATURES * features * np.sqrt(rim)
back = blur(dome(0, 6.0, 4.4, 3.4, 0.8) + dome(0, -3.0, 4.6, 5.2, 0.85) + mirrored(3.2, -6.8, 2.2, 2.2, 0.35))
B = BACK * rim + FEATURES * back * np.sqrt(rim)

ring = ~inside & (np.roll(inside, 1, 0) | np.roll(inside, -1, 0) | np.roll(inside, 1, 1) | np.roll(inside, -1, 1)
                  | np.roll(np.roll(inside, 1, 0), 1, 1) | np.roll(np.roll(inside, 1, 0), -1, 1)
                  | np.roll(np.roll(inside, -1, 0), 1, 1) | np.roll(np.roll(inside, -1, 0), -1, 1))
used = inside | ring
top_index = -np.ones(X.shape, dtype=np.int64)
bottom_index = -np.ones(X.shape, dtype=np.int64)
verts = []
for (i, j) in zip(*np.nonzero(used)):
    top_index[i, j] = len(verts)
    verts.append((X[i, j], -F[i, j] * mm if inside[i, j] else 0.0, Z[i, j]))
for (i, j) in zip(*np.nonzero(inside)):
    bottom_index[i, j] = len(verts)
    verts.append((X[i, j], B[i, j] * mm, Z[i, j]))
bottom_index[ring] = top_index[ring]
faces = []
for i in range(len(zs) - 1):
    for j in range(len(xs) - 1):
        corners = [(i, j), (i, j + 1), (i + 1, j + 1), (i + 1, j)]
        if not all(used[c] for c in corners) or not any(inside[c] for c in corners):
            continue
        faces.append([top_index[c] for c in corners])
        faces.append([bottom_index[c] for c in reversed(corners)])

me = bpy.data.meshes.new("GummyBear")
me.from_pydata(verts, [], faces)
me.update()
bear = bpy.data.objects.new("GummyBear", me)
bpy.context.scene.collection.objects.link(bear)
bpy.context.view_layer.objects.active = bear
bear.select_set(True)


def points():
    p = np.empty(len(me.vertices) * 3)
    me.vertices.foreach_get("co", p)
    return p.reshape(-1, 3)


def apply(mod):
    bpy.ops.object.modifier_apply(modifier=mod.name)


def remesh():
    mod = bear.modifiers.new("remesh", "REMESH")
    mod.mode = "VOXEL"
    mod.voxel_size = VOXEL
    mod.adaptivity = 0
    apply(mod)


def smooth(iterations, factor=0.5):
    mod = bear.modifiers.new("smooth", "LAPLACIANSMOOTH")
    mod.iterations = iterations
    mod.lambda_factor = factor
    mod.use_volume_preserve = True
    apply(mod)


remesh()
smooth(SMOOTH_ITER)
remesh()
smooth(4)

tris = sum(len(p.vertices) - 2 for p in me.polygons)
if tris > TARGET_TRIS:
    decimate = bear.modifiers.new("decimate", "DECIMATE")
    decimate.ratio = TARGET_TRIS / tris
    decimate.use_collapse_triangulate = True
    apply(decimate)
apply(bear.modifiers.new("tri", "TRIANGULATE"))
p = points()
p -= (p.min(0) + p.max(0)) / 2
me.vertices.foreach_set("co", p.ravel())
me.update()
me.shade_smooth()

normals = np.array([v.normal[:] for v in me.vertices])
tree = BVHTree.FromPolygons([v.co for v in me.vertices], [pl.vertices[:] for pl in me.polygons])
thickness = np.zeros(len(me.vertices))
for k, v in enumerate(me.vertices):
    inward = -Vector(normals[k])
    hit = tree.ray_cast(v.co + inward * 1e-5, inward)
    thickness[k] = hit[3] if hit[0] is not None else 0.0
for _ in range(3):
    acc, cnt = np.zeros_like(thickness), np.zeros_like(thickness)
    for e in me.edges:
        a, b = e.vertices
        acc[a] += thickness[b]; acc[b] += thickness[a]
        cnt[a] += 1; cnt[b] += 1
    thickness = 0.5 * thickness + 0.5 * acc / np.maximum(cnt, 1)
facing = np.abs(normals[:, 1])
depth = p[:, 1].max() - p[:, 1].min()
shade_uv = np.stack([facing, np.clip(thickness / (2 * depth), 0, 1)], 1)
uv = me.uv_layers.new(name="st")
loop_vertices = np.empty(len(me.loops), dtype=np.int64)
me.loops.foreach_get("vertex_index", loop_vertices)
uv.data.foreach_set("uv", shade_uv[loop_vertices].ravel())

size = p.max(0) - p.min(0)
print(f"GummyBear: {len(me.vertices)} verts, {len(me.polygons)} tris, "
      f"{size[0]*1000:.1f} wide x {size[2]*1000:.1f} tall x {size[1]*1000:.1f} thick mm, "
      f"median thickness {np.median(thickness)*1000:.1f} mm")

# Lying on its back in Blender's Z-up frame: belly (-Y) to +Z, head (+Z) to +Y.
me.transform(Matrix.Rotation(math.radians(-90), 4, "X"))
me.update()

if preview:
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.samples = 64
    sc.render.resolution_x = sc.render.resolution_y = 600
    sc.world = bpy.data.worlds.new("w")
    sc.world.color = (0.9, 0.9, 0.9)
    mat = bpy.data.materials.new("gummy")
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (0.95, 0.08, 0.05, 1)
    bsdf.inputs["Roughness"].default_value = 0.35
    me.materials.append(mat)
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 3
    sun.rotation_euler = (math.radians(40), 0, math.radians(-30))
    sc.collection.objects.link(sun)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = 0.024
    sc.collection.objects.link(cam)
    sc.camera = cam
    for name, loc in [("top", (0, -0.0001, 0.2)), ("3q", (0.1, -0.12, 0.12)), ("side", (0.2, 0, 0.0)),
                      ("end", (0, -0.2, 0.0))]:
        cam.location = loc
        cam.rotation_euler = (Vector((0, 0, 0)) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
        sc.render.filepath = preview.replace(".png", f"_{name}.png")
        bpy.ops.render.render(write_still=True)
    me.materials.clear()
    sc.world = None

from pxr import Sdf, Usd, UsdGeom, UsdUtils

# Exported without axis conversion under a Y-up stage: Blender +Z becomes +Y and +Y becomes -Z.
me.transform(Matrix.Rotation(math.radians(-90), 4, "X"))
me.update()
bpy.ops.object.select_all(action="DESELECT")
bear.select_set(True)
tmpdir = tempfile.mkdtemp()
raw = os.path.join(tmpdir, "raw.usdc")
bpy.ops.wm.usd_export(filepath=raw, selected_objects_only=True, export_materials=False,
                      export_animation=False, export_uvmaps=True, export_lights=False,
                      export_cameras=False, convert_orientation=False, convert_scene_units="METERS")

src_stage = Usd.Stage.Open(raw)
mesh_path = next(str(p.GetPath()) for p in src_stage.Traverse() if p.IsA(UsdGeom.Mesh))
final = os.path.join(tmpdir, "GummyBear.usdc")
dst = Usd.Stage.CreateNew(final)
UsdGeom.SetStageUpAxis(dst, UsdGeom.Tokens.y)
UsdGeom.SetStageMetersPerUnit(dst, 1.0)
Sdf.CopySpec(src_stage.GetRootLayer(), mesh_path, dst.GetRootLayer(), "/GummyBear")
dst.SetDefaultPrim(dst.GetPrimAtPath("/GummyBear"))
dst.GetRootLayer().Save()
if os.path.exists(out_usdz):
    os.remove(out_usdz)
UsdUtils.CreateNewUsdzPackage(final, out_usdz)
