import bpy, sys, math, os
from mathutils import Vector
argv = sys.argv[sys.argv.index("--")+1:]
stl, out, res, samples = argv[0], argv[1], int(argv[2]), int(argv[3])
clay = len(argv) > 4 and argv[4] == "clay"
debug = argv[4] if len(argv) > 4 else ""
zoom = float(argv[7]) if len(argv) > 7 else 1.0

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.stl_import(filepath=stl)
o = bpy.context.selected_objects[0]
import numpy as np
me=o.data
V=np.empty(len(me.vertices)*3); me.vertices.foreach_get("co",V); V=V.reshape(-1,3)
tip=V[V[:,2].argmax()]
rimc=V[V[:,2]<1.5].mean(0)
axis=Vector(tip-rimc).normalized()
q=axis.rotation_difference(Vector((0,0,-1)))
from mathutils import Matrix
M=Matrix.Diagonal((0.001,0.001,0.001,1)) @ q.to_matrix().to_4x4() @ Matrix.Translation(-Vector(rimc))
me.transform(M)
V=np.empty(len(me.vertices)*3); me.vertices.foreach_get("co",V); V=V.reshape(-1,3)
c=(V.min(0)+V.max(0))/2
me.transform(Matrix.Translation(Vector((-c[0],-c[1],-c[2]))))
me.update()
print("DIMS_M", V.max(0)-V.min(0))
nv=len(me.vertices)
P=np.empty(nv*3); me.vertices.foreach_get("co",P); P=P.reshape(-1,3)
NRM=np.empty(nv*3); me.vertices.foreach_get("normal",NRM); NRM=NRM.reshape(-1,3)
E=np.empty(len(me.edges)*2,dtype=np.int64); me.edges.foreach_get("vertices",E); E=E.reshape(-1,2)
deg=np.bincount(E.ravel(),minlength=nv).astype(float)[:,None]
S=P.copy()
for _ in range(int(__import__("os").environ.get("SMOOTH_IT","40"))):
    acc=np.zeros_like(S); np.add.at(acc,E[:,0],S[E[:,1]]); np.add.at(acc,E[:,1],S[E[:,0]])
    S=0.5*S+0.5*acc/np.maximum(deg,1)
H=((P-S)*NRM).sum(1)
lo,hi=np.percentile(H,[3,97]); Hn=np.clip((H-lo)/(hi-lo),0,1)
print("H range", lo, hi)
th=np.arctan2(P[:,1],P[:,0]); bins=((th+np.pi)/(2*np.pi)*72).astype(int)%72
topz=np.full(72,-1.0); np.maximum.at(topz,bins,P[:,2])
low=(np.argmin(topz)+0.5)/72*2*np.pi-np.pi
LOW_AZ=math.degrees(math.atan2(math.cos(low), -math.sin(low)))
LOW_AZ=math.degrees(math.atan2(math.cos(low), math.sin(low))) if False else None
lx,ly=math.cos(low),math.sin(low)
LOW_AZ=math.degrees(math.atan2(lx,-ly))
print("LOW_AZ",LOW_AZ, "rim z range", topz.min(), topz.max())
att=me.attributes.new("height",'FLOAT','POINT'); att.data.foreach_set("value",Hn.astype(np.float32))
bpy.ops.object.shade_smooth()
bpy.ops.object.shade_auto_smooth(angle=math.radians(40))

m = bpy.data.materials.new("Waffle")
o.data.materials.append(m)
nt = m.node_tree; N = nt.nodes; L = nt.links
for n in list(N): N.remove(n)
outn = N.new("ShaderNodeOutputMaterial")
bsdf = N.new("ShaderNodeBsdfPrincipled")
L.new(bsdf.outputs[0], outn.inputs[0])
if clay:
    bsdf.inputs["Base Color"].default_value = (0.7,0.7,0.7,1)
    bsdf.inputs["Roughness"].default_value = 0.6
else:
    tc = N.new("ShaderNodeTexCoord")
    geo = N.new("ShaderNodeNewGeometry")

    ao = N.new("ShaderNodeAmbientOcclusion"); ao.inputs["Distance"].default_value = 0.0015; ao.samples = 16
    aoramp = N.new("ShaderNodeMapRange")
    aoramp.inputs["From Min"].default_value = 0.5; aoramp.inputs["From Max"].default_value = 0.8
    L.new(ao.outputs["AO"], aoramp.inputs["Value"])

    pt = N.new("ShaderNodeMapRange")
    pt.inputs["From Min"].default_value = 0.0; pt.inputs["From Max"].default_value = 1.0
    hat = N.new("ShaderNodeAttribute"); hat.attribute_name = "height"
    L.new(hat.outputs["Fac"], pt.inputs["Value"])

    big = N.new("ShaderNodeTexNoise"); big.inputs["Scale"].default_value = 30; big.inputs["Detail"].default_value = 6; big.inputs["Roughness"].default_value = 0.6
    L.new(tc.outputs["Object"], big.inputs["Vector"])

    # toast: edges/ridges darker, crevices slightly darker too, blotchy variation
    toast = N.new("ShaderNodeMath"); toast.operation = 'MULTIPLY_ADD'
    L.new(pt.outputs[0], toast.inputs[0]); toast.inputs[1].default_value = 1.2
    L.new(big.outputs["Fac"], toast.inputs[2])
    t2 = N.new("ShaderNodeMath"); t2.operation='SUBTRACT'
    L.new(toast.outputs[0], t2.inputs[0]); t2.inputs[1].default_value = 0.35
    t3 = N.new("ShaderNodeMath"); t3.operation='MULTIPLY_ADD'
    inv = N.new("ShaderNodeMath"); inv.operation='SUBTRACT'; inv.inputs[0].default_value=1.0
    L.new(aoramp.outputs[0], inv.inputs[1])
    L.new(inv.outputs[0], t3.inputs[0]); t3.inputs[1].default_value = 0.8
    L.new(t2.outputs[0], t3.inputs[2])
    t3.use_clamp = True

    ramp = N.new("ShaderNodeValToRGB")
    cr = ramp.color_ramp
    cr.elements[0].position = 0.0; cr.elements[0].color = (0.92, 0.55, 0.16, 1)
    cr.elements[1].position = 1.0; cr.elements[1].color = (0.28, 0.095, 0.02, 1)
    e = cr.elements.new(0.5); e.color = (0.66, 0.30, 0.06, 1)
    L.new(t3.outputs[0], ramp.inputs[0])

    # fine speckle
    fine = N.new("ShaderNodeTexNoise"); fine.inputs["Scale"].default_value = 1500; fine.inputs["Detail"].default_value = 4
    L.new(tc.outputs["Object"], fine.inputs["Vector"])
    mix = N.new("ShaderNodeMix"); mix.data_type='RGBA'; mix.blend_type='MULTIPLY'
    fr = N.new("ShaderNodeMapRange"); fr.inputs["To Min"].default_value = 0.0; fr.inputs["To Max"].default_value = 0.2
    L.new(fine.outputs["Fac"], fr.inputs["Value"])
    L.new(fr.outputs[0], mix.inputs["Factor"])
    L.new(ramp.outputs[0], mix.inputs[6]); mix.inputs[7].default_value = (0.8,0.6,0.42,1)
    L.new(mix.outputs[2], bsdf.inputs["Base Color"])

    bump = N.new("ShaderNodeBump"); bump.inputs["Strength"].default_value = 0.12; bump.inputs["Distance"].default_value = 0.0002
    vor = N.new("ShaderNodeTexVoronoi"); vor.inputs["Scale"].default_value = 2500
    L.new(tc.outputs["Object"], vor.inputs["Vector"])
    hadd = N.new("ShaderNodeMath"); hadd.operation='MULTIPLY_ADD'
    L.new(fine.outputs["Fac"], hadd.inputs[0]); hadd.inputs[1].default_value=0.6
    L.new(vor.outputs["Distance"], hadd.inputs[2])
    L.new(hadd.outputs[0], bump.inputs["Height"])
    L.new(bump.outputs[0], bsdf.inputs["Normal"])

    rr = N.new("ShaderNodeMapRange"); rr.inputs["To Min"].default_value=0.5; rr.inputs["To Max"].default_value=0.8
    L.new(big.outputs["Fac"], rr.inputs["Value"])
    L.new(rr.outputs[0], bsdf.inputs["Roughness"])
    bsdf.inputs["Specular IOR Level"].default_value = 0.35
    bsdf.inputs["Subsurface Weight"].default_value = 0.08
    bsdf.inputs["Subsurface Radius"].default_value = (1.0, 0.5, 0.25)
    bsdf.inputs["Subsurface Scale"].default_value = 0.0005

sc = bpy.context.scene
sc.render.engine = 'CYCLES'
prefs = bpy.context.preferences.addons['cycles'].preferences
prefs.compute_device_type = 'METAL'; prefs.get_devices()
for d in prefs.devices: d.use = True
sc.cycles.device = 'GPU'
sc.cycles.samples = samples
sc.cycles.use_denoising = True
sc.render.film_transparent = True
sc.render.resolution_x = res; sc.render.resolution_y = int(res*1.25)
sc.view_settings.view_transform = 'AgX'
sc.view_settings.look = 'AgX - Punchy'
sc.view_settings.exposure = -0.25
sc.render.image_settings.file_format = 'PNG'
sc.render.image_settings.color_mode = 'RGBA'

w = bpy.data.worlds.new("W"); sc.world = w; w.use_nodes = True
w.node_tree.nodes["Background"].inputs[0].default_value = (0.95,0.93,0.9,1)
w.node_tree.nodes["Background"].inputs[1].default_value = 0.35

def light(name, loc, energy, size, color=(1,1,1)):
    ld = bpy.data.lights.new(name, 'AREA'); ld.energy = energy; ld.size = size; ld.color = color
    lo = bpy.data.objects.new(name, ld); sc.collection.objects.link(lo); lo.location = loc
    d = Vector((0,0,0)) - Vector(loc); lo.rotation_euler = d.to_track_quat('-Z','Y').to_euler()
light("Key", (-0.25, -0.35, 0.3), 9, 0.25, (1.0, 0.95, 0.88))
light("Fill", (0.4, -0.25, 0.05), 2.5, 0.4, (0.9, 0.95, 1.0))
light("Rim", (0.15, 0.35, 0.25), 8, 0.15, (1.0, 0.9, 0.8))

cd = bpy.data.cameras.new("Cam"); cd.lens = 85
cam = bpy.data.objects.new("Cam", cd); sc.collection.objects.link(cam); sc.camera = cam
elev = float(argv[5]) if len(argv) > 5 else 15.0
az = (LOW_AZ + float(argv[6][4:] or 0)) if argv[6].startswith('auto') else float(argv[6])
dist = 0.6
e, a = math.radians(elev), math.radians(az)
cam.location = (dist*math.cos(e)*math.sin(a), -dist*math.cos(e)*math.cos(a), dist*math.sin(e))
cam.rotation_euler = (Vector((0,0,0)) - cam.location).to_track_quat('-Z','Y').to_euler()
bpy.context.view_layer.update()
bpy.ops.object.select_all(action='DESELECT'); o.select_set(True)
bpy.ops.view3d.camera_to_view_selected() if False else None
from bpy_extras.object_utils import world_to_camera_view
pts = [o.matrix_world @ Vector(c) for c in o.bound_box]
co = [world_to_camera_view(sc, cam, p) for p in pts]
xs=[c.x for c in co]; ys=[c.y for c in co]
span = max((max(xs)-min(xs))/1.0, (max(ys)-min(ys))/1.0)
cd.lens = cd.lens / span * 0.85 * zoom
bpy.context.view_layer.update()
co = [world_to_camera_view(sc, cam, p) for p in pts]
if os.environ.get("BAKE_DIR"):
    D = os.environ["BAKE_DIR"]
    bpy.ops.object.select_all(action='DESELECT'); o.select_set(True); bpy.context.view_layer.objects.active = o
    dm = o.modifiers.new("Dec", 'DECIMATE'); dm.ratio = float(os.environ.get("DEC", "0.12"))
    bpy.ops.object.modifier_apply(modifier="Dec")
    print("LOW_TRIS", len(o.data.polygons))
    bpy.ops.object.mode_set(mode='EDIT'); bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=math.radians(60), island_margin=0.003)
    bpy.ops.object.mode_set(mode='OBJECT')
    sc.cycles.samples = 64; sc.cycles.use_denoising = False
    sc.render.bake.margin = 8
    def bake(name, kind, noncolor):
        im = bpy.data.images.new(name, 4096, 4096, alpha=False)
        if noncolor: im.colorspace_settings.name = 'Non-Color'
        tn = N.new("ShaderNodeTexImage"); tn.image = im
        for n in N: n.select = False
        tn.select = True; N.active = tn
        if kind == 'DIFFUSE':
            bpy.ops.object.bake(type='DIFFUSE', pass_filter={'COLOR'})
        else:
            bpy.ops.object.bake(type=kind)
        im.filepath_raw = os.path.join(D, name + ".png"); im.file_format = 'PNG'; im.save()
        N.remove(tn)
        return im
    col = bake("waffle_cone_basecolor", 'DIFFUSE', False)
    nrm = bake("waffle_cone_normal", 'NORMAL', True)
    rgh = bake("waffle_cone_roughness", 'ROUGHNESS', True)
    em = bpy.data.materials.new("WaffleCone"); em.use_nodes = True
    en = em.node_tree; eb = en.nodes["Principled BSDF"]
    t1 = en.nodes.new("ShaderNodeTexImage"); t1.image = col; en.links.new(t1.outputs[0], eb.inputs["Base Color"])
    t2 = en.nodes.new("ShaderNodeTexImage"); t2.image = nrm
    nm = en.nodes.new("ShaderNodeNormalMap"); en.links.new(t2.outputs[0], nm.inputs["Color"]); en.links.new(nm.outputs[0], eb.inputs["Normal"])
    t3 = en.nodes.new("ShaderNodeTexImage"); t3.image = rgh; en.links.new(t3.outputs[0], eb.inputs["Roughness"])
    o.data.materials.clear(); o.data.materials.append(em)
    for a in [a for a in o.data.attributes if a.name == "height"]: o.data.attributes.remove(a)
    o.name = "WaffleCone"; o.data.name = "WaffleCone"
    V=np.empty(len(o.data.vertices)*3); o.data.vertices.foreach_get("co",V); V=V.reshape(-1,3)
    o.data.transform(Matrix.Translation(Vector((0,0,-V[:,2].min()))))
    for ob in [x for x in sc.objects if x.type == 'LIGHT']: bpy.data.objects.remove(ob)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(D, "waffle_cone_app.blend"))
    bpy.ops.object.select_all(action='DESELECT'); o.select_set(True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(D, "waffle_cone.glb"), export_format='GLB', use_selection=True, export_image_format='JPEG' if os.environ.get("JPG") else 'AUTO')
    bpy.ops.wm.usd_export(filepath=os.path.join(D, "waffle_cone.usdz"), selected_objects_only=True)
    print("DIMS_FINAL_MM", [round(d*1000,1) for d in o.dimensions])
    sys.exit(0)
if debug in ("ao","pt"):
    em = N.new("ShaderNodeEmission")
    L.new((ao.outputs["AO"] if debug=="ao" else pt.outputs[0]), em.inputs[0])
    L.new(em.outputs[0], outn.inputs[0])
sc.render.filepath = out
bpy.ops.render.render(write_still=True)
import os
if os.environ.get("SAVE_BLEND"):
    bpy.ops.wm.save_as_mainfile(filepath=os.environ["SAVE_BLEND"])
