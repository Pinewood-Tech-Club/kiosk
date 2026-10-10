import bpy, sys, math, os
from mathutils import Vector
from bpy_extras.object_utils import world_to_camera_view
argv = sys.argv[sys.argv.index("--")+1:]
out, res, samples, elev, az, zoom = argv[0], int(argv[1]), int(argv[2]), float(argv[3]), float(argv[4]), float(argv[5])
sc = bpy.context.scene
o = [x for x in sc.objects if x.type == 'MESH'][0]
sc.render.engine = 'CYCLES'
prefs = bpy.context.preferences.addons['cycles'].preferences
prefs.compute_device_type = 'METAL'; prefs.get_devices()
for d in prefs.devices: d.use = True
sc.cycles.device = 'GPU'; sc.cycles.samples = samples; sc.cycles.use_denoising = True
sc.render.film_transparent = True
sc.render.resolution_x = res; sc.render.resolution_y = res
sc.view_settings.view_transform = 'AgX'; sc.view_settings.look = 'AgX - Medium High Contrast'
sc.render.image_settings.file_format = 'PNG'; sc.render.image_settings.color_mode = 'RGBA'
w = bpy.data.worlds.new("W"); sc.world = w; w.use_nodes = True
w.node_tree.nodes["Background"].inputs[0].default_value = (0.95,0.93,0.9,1)
w.node_tree.nodes["Background"].inputs[1].default_value = 0.4
c0 = sum((o.matrix_world @ Vector(c) for c in o.bound_box), Vector()) / 8
def light(name, loc, energy, size, color=(1,1,1)):
    ld = bpy.data.lights.new(name, 'AREA'); ld.energy = energy; ld.size = size; ld.color = color
    lo = bpy.data.objects.new(name, ld); sc.collection.objects.link(lo); lo.location = Vector(loc) + c0
    lo.rotation_euler = (c0 - lo.location).to_track_quat('-Z','Y').to_euler()
light("Key", (-0.25, -0.35, 0.3), 9, 0.25, (1.0, 0.96, 0.9))
light("Fill", (0.4, -0.25, 0.05), 3, 0.4, (0.92, 0.95, 1.0))
light("Rim", (0.15, 0.35, 0.25), 6, 0.15)
cd = bpy.data.cameras.new("Cam"); cd.lens = 85
cam = bpy.data.objects.new("Cam", cd); sc.collection.objects.link(cam); sc.camera = cam
e, a = math.radians(elev), math.radians(az)
cam.location = c0 + 0.6*Vector((math.cos(e)*math.sin(a), -math.cos(e)*math.cos(a), math.sin(e)))
cam.rotation_euler = (c0 - cam.location).to_track_quat('-Z','Y').to_euler()
bpy.context.view_layer.update()
co = [world_to_camera_view(sc, cam, o.matrix_world @ Vector(c)) for c in o.bound_box]
span = max(max(c.x for c in co)-min(c.x for c in co), max(c.y for c in co)-min(c.y for c in co))
cd.lens = cd.lens / span * 0.8 * zoom
sc.render.filepath = out
bpy.ops.render.render(write_still=True)
