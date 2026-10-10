import bpy, math
from mathutils import Vector
bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
sc.render.engine = 'CYCLES'; sc.cycles.samples = 32; sc.cycles.use_denoising = False
w = bpy.data.worlds.new("W"); sc.world = w; w.use_nodes = True
nt = w.node_tree; bg = nt.nodes["Background"]
tc = nt.nodes.new("ShaderNodeTexCoord"); sep = nt.nodes.new("ShaderNodeSeparateXYZ")
nt.links.new(tc.outputs["Generated"], sep.inputs[0])
rp = nt.nodes.new("ShaderNodeValToRGB")
rp.color_ramp.elements[0].color = (0.30, 0.27, 0.24, 1); rp.color_ramp.elements[1].color = (0.98, 0.95, 0.91, 1)
nt.links.new(sep.outputs["Z"], rp.inputs[0]); nt.links.new(rp.outputs[0], bg.inputs[0])
bg.inputs[1].default_value = 0.45
def panel(name, loc, size, strength, color):
    bpy.ops.mesh.primitive_plane_add(size=1, location=loc)
    p = bpy.context.object; p.name = name; p.scale = (size[0], size[1], 1)
    p.rotation_euler = (Vector((0,0,0)) - Vector(loc)).to_track_quat('-Z','Y').to_euler()
    p.rotation_euler.rotate_axis('X', math.pi)
    m = bpy.data.materials.new(name); m.use_nodes = True
    n = m.node_tree.nodes; n.remove(n["Principled BSDF"])
    e = n.new("ShaderNodeEmission"); e.inputs[0].default_value = (*color, 1); e.inputs[1].default_value = strength
    m.node_tree.links.new(e.outputs[0], n["Material Output"].inputs[0])
    p.data.materials.append(m)
panel("Key", (-1.0, -1.6, 1.8), (1.4, 1.4), 9.0, (1.0, 0.96, 0.9))
panel("Fill", (1.9, -1.2, 0.6), (1.6, 1.8), 2.5, (0.92, 0.95, 1.0))
panel("Rim", (0.4, 1.8, 1.2), (0.9, 0.9), 6.0, (1.0, 1.0, 1.0))
bpy.ops.mesh.primitive_plane_add(size=6, location=(0,0,-0.6))
fl = bpy.context.object; fm = bpy.data.materials.new("Floor"); fm.use_nodes = True
fm.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.82, 0.78, 0.73, 1)
fm.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.9
fl.data.materials.append(fm)
cd = bpy.data.cameras.new("Pano"); cd.type = 'PANO'; cd.panorama_type = 'EQUIRECTANGULAR'
cam = bpy.data.objects.new("Pano", cd); sc.collection.objects.link(cam); sc.camera = cam
cam.location = (0, 0, 0); cam.rotation_euler = (math.radians(90), 0, math.radians(180))
sc.render.resolution_x = 2048; sc.render.resolution_y = 1024
sc.view_settings.view_transform = 'Standard'
sc.render.image_settings.file_format = 'OPEN_EXR'; sc.render.image_settings.color_depth = '16'
sc.render.filepath = "/Users/adam/.t3/projects/kiosk/Kiosk/Resources/3D/studio.exr"
bpy.ops.render.render(write_still=True)
sc.render.image_settings.file_format = 'PNG'; sc.view_settings.view_transform = 'AgX'
sc.render.filepath = "/tmp/cone/studio_preview.png"; sc.render.resolution_x = 1024; sc.render.resolution_y = 512
bpy.ops.render.render(write_still=True)
