import bpy, bmesh, math, sys, os
import numpy as np
from mathutils import Vector, Matrix, Euler

argv = sys.argv[sys.argv.index("--") + 1:]
src, out_usdz = argv[0], argv[1]
preview = argv[2] if len(argv) > 2 else None
TARGET_H = 0.020
PRE_ROT = [float(v) for v in os.environ.get("GUMMY_PRE_ROT", "0,0,-90").split(",")]
SUBDIV = int(os.environ.get("GUMMY_SUBDIV", "0"))

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)

meshes = sorted([o for o in bpy.data.objects if o.type == "MESH"], key=lambda o: o.name)
keep = meshes[0]
for o in list(bpy.data.objects):
    if o is not keep:
        bpy.data.objects.remove(o, do_unlink=True)

keep.parent = None
bpy.context.view_layer.objects.active = keep
keep.select_set(True)
keep.matrix_world = keep.matrix_world
me = keep.data
me.transform(keep.matrix_world)
keep.matrix_world = Matrix.Identity(4)
keep.name = "GummyBear"
me.name = "GummyBear"

me.transform(Euler([math.radians(a) for a in PRE_ROT], "XYZ").to_matrix().to_4x4())

me.materials.clear()
for a in list(me.attributes):
    if a.domain == "CORNER" and a.data_type in {"FLOAT2"}:
        me.attributes.remove(a)

P = np.empty(len(me.vertices) * 3)
me.vertices.foreach_get("co", P)
P = P.reshape(-1, 3)
ctr = (P.min(0) + P.max(0)) / 2
P = P - ctr
s = TARGET_H / (P[:, 2].max() - P[:, 2].min())
P *= s
me.vertices.foreach_set("co", P.ravel())
me.update()

bm = bmesh.new()
bm.from_mesh(me)
bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=3e-6)
bm.to_mesh(me)
bm.free()

if SUBDIV:
    mod = keep.modifiers.new("sub", "SUBSURF")
    mod.levels = SUBDIV
    mod.render_levels = SUBDIV
    bpy.ops.object.modifier_apply(modifier=mod.name)

me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
me.update()

if preview:
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_EEVEE"
    sc.render.resolution_x = sc.render.resolution_y = 1024
    sc.render.filepath = preview
    sc.world = bpy.data.worlds.new("w")
    sc.world.use_nodes = True
    sc.world.node_tree.nodes["Background"].inputs[0].default_value = (0.5, 0.5, 0.5, 1)
    mat = bpy.data.materials.new("prev")
    mat.use_nodes = True
    mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.9, 0.2, 0.2, 1)
    mat.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.35
    keep.data.materials.append(mat)
    ld = bpy.data.lights.new("sun", "SUN")
    ld.energy = 4
    lo = bpy.data.objects.new("sun", ld)
    sc.collection.objects.link(lo)
    lo.rotation_euler = (math.radians(55), 0, math.radians(-30))
    cam_d = bpy.data.cameras.new("cam")
    cam_d.type = "ORTHO"
    cam_d.ortho_scale = 0.03
    cam = bpy.data.objects.new("cam", cam_d)
    sc.collection.objects.link(cam)
    sc.camera = cam
    views = [("front", (0, -0.2, 0.02)), ("3q", (0.12, -0.15, 0.08)), ("side", (0.2, 0, 0)), ("back", (0, 0.2, 0.0))]
    import shutil
    for name, loc in views:
        cam.location = loc
        d = Vector((0, 0, 0)) - Vector(loc)
        cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
        sc.render.filepath = preview.replace(".png", f"_{name}.png")
        bpy.ops.render.render(write_still=True)
    keep.data.materials.clear()

bpy.context.scene.world = None
me.transform(Matrix.Rotation(math.radians(-90), 4, "X"))
me.update()
bpy.ops.object.select_all(action="DESELECT")
keep.select_set(True)
bpy.context.view_layer.objects.active = keep
import tempfile
from pxr import Usd, UsdGeom, Sdf, UsdUtils

tmpdir = tempfile.mkdtemp()
raw = os.path.join(tmpdir, "raw.usdc")
bpy.ops.wm.usd_export(filepath=raw, selected_objects_only=True, export_materials=False,
                      export_animation=False, export_uvmaps=False, export_lights=False,
                      convert_orientation=False, convert_scene_units="METERS")

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
