# uv run --no-project --with numpy --with scikit-image python -I gummy_bear_sdf.py /tmp/bear.obj
# blender -b --factory-startup -P gummy_bear.py -- /tmp/bear.obj Kiosk/Resources/3D/GummyBear.usdz [preview.png]
# Output: lying on its back as a scattered piece rests (back on -Y, belly +Y, head toward -Z), bounding box centered.
import bpy, math, os, sys, tempfile
import numpy as np
from mathutils import Matrix, Vector

argv = sys.argv[sys.argv.index("--") + 1:]
src, out_usdz = argv[0], argv[1]
preview = argv[2] if len(argv) > 2 else None
TARGET_H = float(os.environ.get("GUMMY_HEIGHT", "0.020"))
TARGET_TRIS = int(os.environ.get("GUMMY_TRIS", "6000"))

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.obj_import(filepath=src, forward_axis="Y", up_axis="Z")
bear = next(o for o in bpy.data.objects if o.type == "MESH")
bear.name = bear.data.name = "GummyBear"
me = bear.data
bpy.context.view_layer.objects.active = bear
bear.select_set(True)


def points():
    p = np.empty(len(me.vertices) * 3)
    me.vertices.foreach_get("co", p)
    return p.reshape(-1, 3)


tris = len(me.polygons)
if tris > TARGET_TRIS:
    decimate = bear.modifiers.new("decimate", "DECIMATE")
    decimate.ratio = TARGET_TRIS / tris
    bpy.ops.object.modifier_apply(modifier=decimate.name)

p = points()
p -= (p.min(0) + p.max(0)) / 2
p *= TARGET_H / (p[:, 2].max() - p[:, 2].min())
me.vertices.foreach_set("co", p.ravel())
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
    for name, loc in [("top", (0, 0.0001, 0.2)), ("3q", (0.1, -0.12, 0.12)), ("side", (0.2, 0, 0.004))]:
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
