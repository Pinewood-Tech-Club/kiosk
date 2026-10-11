# blender -b --factory-startup -P gummy_bear.py -- Assets3D/gummy_bears/scene.gltf Kiosk/Resources/3D/GummyBear.usdz [preview.png]
# Source: "Gummy Bears" by Styro (CC-BY-4.0). Its mesh is a triangulated slab with cracks, custom split normals and
# hard vertical sides, so it is voxel remeshed (watertight), its sides pillowed and rounded, its belly, head and
# snout domed like a molded Goldbear, then decimated with plain smooth normals.
# Output: lying on its back as a scattered piece rests (back on -Y, belly +Y, head toward -Z), bounding box centered.
import bpy, math, os, sys, tempfile
import numpy as np
from mathutils import Matrix, Vector

argv = sys.argv[sys.argv.index("--") + 1:]
src, out_usdz = argv[0], argv[1]
preview = argv[2] if len(argv) > 2 else None
TARGET_H = float(os.environ.get("GUMMY_HEIGHT", "0.020"))
VOXEL = float(os.environ.get("GUMMY_VOXEL", "0.00016"))
SMOOTH_ITER = int(os.environ.get("GUMMY_SMOOTH", "12"))
TARGET_TRIS = int(os.environ.get("GUMMY_TRIS", "6000"))
ROUND = float(os.environ.get("GUMMY_ROUND", "0.0012"))
BELLY = float(os.environ.get("GUMMY_BELLY", "2.0"))
PILLOW = float(os.environ.get("GUMMY_PILLOW", "0.2"))
THICKNESS = float(os.environ.get("GUMMY_THICKNESS", "0.85"))

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)

bear = sorted([o for o in bpy.data.objects if o.type == "MESH"], key=lambda o: o.name)[0]
world = bear.matrix_world.copy()
for o in list(bpy.data.objects):
    if o is not bear:
        bpy.data.objects.remove(o, do_unlink=True)
bear.parent = None
me = bear.data
me.transform(world)
bear.matrix_world = Matrix.Identity(4)
bear.name = me.name = "GummyBear"
me.materials.clear()
bpy.context.view_layer.objects.active = bear
bear.select_set(True)

# Standing: height along +Z, belly toward -Y.
me.transform(Matrix.Rotation(math.radians(-90), 4, "Z"))


def points():
    p = np.empty(len(me.vertices) * 3)
    me.vertices.foreach_get("co", p)
    return p.reshape(-1, 3)


def fit_height():
    p = points()
    p -= (p.min(0) + p.max(0)) / 2
    p *= TARGET_H / (p[:, 2].max() - p[:, 2].min())
    me.vertices.foreach_set("co", p.ravel())
    me.update()


def apply(mod):
    bpy.ops.object.modifier_apply(modifier=mod.name)


def remesh():
    mod = bear.modifiers.new("remesh", "REMESH")
    mod.mode = "VOXEL"
    mod.voxel_size = VOXEL
    mod.adaptivity = 0
    apply(mod)


def smooth(iterations):
    mod = bear.modifiers.new("smooth", "SMOOTH")
    mod.factor = 0.6
    mod.iterations = iterations
    apply(mod)


def offset(distance):
    mod = bear.modifiers.new("offset", "DISPLACE")
    mod.direction = "NORMAL"
    mod.mid_level = 0
    mod.strength = distance
    apply(mod)
    remesh()


def pillow():
    p = points()
    half = (p[:, 1].max() - p[:, 1].min()) / 2
    mid = (p[:, 1].max() + p[:, 1].min()) / 2
    t = ((p[:, 1] - mid) / half) ** 2
    p[:, 0] *= 1 - PILLOW * t
    p[:, 2] *= 1 - 0.35 * PILLOW * t
    p[:, 1] = mid + (p[:, 1] - mid) * THICKNESS
    me.vertices.foreach_set("co", p.ravel())
    me.update()


def mold(bumps, side):
    p = points()
    n = np.empty(len(me.vertices) * 3)
    me.vertices.foreach_get("normal", n)
    n = n.reshape(-1, 3)
    facing = np.clip(side * n[:, 1], 0, 1) ** 1.5
    lift = np.zeros(len(p))
    for x, z, sx, sz, amount in bumps:
        lift += amount * np.exp(-((p[:, 0] - x) ** 2 / (2 * sx * sx) + (p[:, 2] - z) ** 2 / (2 * sz * sz)))
    p[:, 1] += side * facing * lift
    me.vertices.foreach_set("co", p.ravel())
    me.update()


fit_height()
if me.has_custom_normals:
    bpy.ops.mesh.customdata_custom_splitnormals_clear()
for name in ("sharp_edge", "sharp_face"):
    if name in me.attributes:
        me.attributes.remove(me.attributes[name])
for uv in list(me.uv_layers):
    me.uv_layers.remove(uv)

remesh()
smooth(4)
pillow()
mm = 0.001
mold([(0, -2.2 * mm, 2.8 * mm, 3.2 * mm, BELLY * mm),
      (0, 5.0 * mm, 2.4 * mm, 2.2 * mm, 0.7 * BELLY * mm),
      (0, 3.6 * mm, 1.1 * mm, 0.9 * mm, 0.5 * BELLY * mm)], side=-1)
mold([(0, 0, 4 * mm, 7 * mm, 0.35 * BELLY * mm)], side=1)
remesh()
smooth(4)
if ROUND > 0:
    offset(-ROUND)
    smooth(4)
    offset(ROUND)
smooth(SMOOTH_ITER)

tris = sum(len(p.vertices) - 2 for p in me.polygons)
if tris > TARGET_TRIS:
    decimate = bear.modifiers.new("decimate", "DECIMATE")
    decimate.ratio = TARGET_TRIS / tris
    decimate.use_collapse_triangulate = True
    apply(decimate)
apply(bear.modifiers.new("tri", "TRIANGULATE"))
fit_height()
# Lying on its back in Blender's Z-up frame: belly (-Y) to +Z, head (+Z) to +Y.
me.transform(Matrix.Rotation(math.radians(-90), 4, "X"))
me.update()
me.shade_smooth()
p = points()
size = p.max(0) - p.min(0)
print(f"GummyBear: {len(me.vertices)} verts, {len(me.polygons)} tris, "
      f"{size[0]*1000:.1f} wide x {size[1]*1000:.1f} tall x {size[2]*1000:.1f} thick mm")

if preview:
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.samples = 64
    sc.render.resolution_x = sc.render.resolution_y = 800
    sc.world = bpy.data.worlds.new("w")
    sc.world.color = (0.9, 0.9, 0.9)
    mat = bpy.data.materials.new("gummy")
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (0.95, 0.08, 0.05, 1)
    bsdf.inputs["Roughness"].default_value = 0.15
    bsdf.inputs["Transmission Weight"].default_value = 0.85
    bsdf.inputs["Coat Weight"].default_value = 1.0
    bsdf.inputs["Coat Roughness"].default_value = 0.05
    me.materials.append(mat)
    floor = bpy.data.objects.new("floor", bpy.data.meshes.new("floor"))
    floor.data.from_pydata([(-1, -1, 0), (1, -1, 0), (1, 1, 0), (-1, 1, 0)], [], [(0, 1, 2, 3)])
    floor.location.z = -size[2] / 2
    sc.collection.objects.link(floor)
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 3
    sun.rotation_euler = (math.radians(40), 0, math.radians(-30))
    sc.collection.objects.link(sun)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = 0.026
    sc.collection.objects.link(cam)
    sc.camera = cam
    for name, loc in [("top", (0, -0.0001, 0.2)), ("3q", (0.1, -0.12, 0.12)), ("side", (0.2, 0, 0.004))]:
        cam.location = loc
        cam.rotation_euler = (Vector((0, 0, 0)) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
        sc.render.filepath = preview.replace(".png", f"_{name}.png")
        bpy.ops.render.render(write_still=True)
    bpy.data.objects.remove(floor, do_unlink=True)
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
                      export_animation=False, export_uvmaps=False, export_lights=False,
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
