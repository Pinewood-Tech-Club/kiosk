import bpy, bmesh, math, sys, os
import numpy as np
from mathutils import Vector
argv = sys.argv[sys.argv.index("--")+1:]
out_dir = argv[0]
mm = 0.001

bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene

H, R_TOP, R_BOT = float(os.environ.get("CUP_H", "46")), 43.5, 36.0
RB = 1.3
RW = R_TOP - 2*RB
Z_BEAD = H - RB
FLOOR_Z = 6.0
T = 0.38

def wall_r(z): return R_BOT + (RW - R_BOT) * z / Z_BEAD

prof = []
for i in range(0, 20):
    prof.append((i/19 * (R_BOT - 1.6 - 0.6), FLOOR_Z))
r_in = R_BOT - 1.6
for a in np.linspace(90, 0, 6)[1:]:
    prof.append((r_in - 0.6 + 0.6*math.cos(math.radians(a)), FLOOR_Z - 0.6 + 0.6*math.sin(math.radians(a))))
for z in np.linspace(FLOOR_Z - 0.8, 0.9, 6):
    prof.append((r_in + (wall_r(z) - R_BOT) * 0.0, z))
cx, cz = (r_in + R_BOT)/2, 0.8
rr = (R_BOT - r_in)/2
for a in np.linspace(180, 360, 9)[1:]:
    prof.append((cx + rr*math.cos(math.radians(a)), cz + rr*math.sin(math.radians(a))))
for z in np.linspace(0.8, Z_BEAD, 40)[1:]:
    prof.append((wall_r(z), z))
bcx, bcz = RW + RB, Z_BEAD
for k, a in enumerate(np.linspace(180, -160, 28)[1:]):
    rad = RB * (1 - 0.18 * k/27)
    prof.append((bcx + rad*math.cos(math.radians(a)), bcz + rad*math.sin(math.radians(a))))

prof = np.array(prof)
seg = np.r_[0, np.cumsum(np.linalg.norm(np.diff(prof, axis=0), axis=1))]
wall_start = int(np.argmin(np.abs(prof[:,1]-0.8) + (prof[:,0] < R_BOT-0.2)*99))

NSEG = 256
bm = bmesh.new()
uv_layer = bm.loops.layers.uv.new("UVMap")
rings = []
for j in range(NSEG + 1):
    th = 2*math.pi*j/NSEG
    c, s = math.cos(th), math.sin(th)
    rings.append([bm.verts.new((r*c*mm, r*s*mm, z*mm)) for r, z in prof] if j < NSEG else rings[0])
L = seg[-1]
for j in range(NSEG):
    a, b = rings[j], rings[j+1]
    for i in range(len(prof)-1):
        if prof[i][0] < 1e-6 and prof[i+1][0] < 1e-6: continue
        f = bm.faces.new((a[i], a[i+1], b[i+1], b[i])) if prof[i][0] > 1e-6 else bm.faces.new((a[i], a[i+1], b[i+1]))
        us = [j/NSEG, j/NSEG, (j+1)/NSEG, (j+1)/NSEG]
        vs = [seg[i]/L, seg[i+1]/L, seg[i+1]/L, seg[i]/L]
        for loop, u, v in zip(f.loops, us, vs):
            loop[uv_layer].uv = (u, v)
bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-7)
me = bpy.data.meshes.new("PaperCup")
bm.to_mesh(me); bm.free()
cup = bpy.data.objects.new("PaperCup", me)
sc.collection.objects.link(cup)
bpy.context.view_layer.objects.active = cup; cup.select_set(True)
for p in me.polygons: p.use_smooth = True

v_wall0 = seg[wall_start]/L
bead_start = len(prof) - 27
v_print_top = (seg[bead_start] - 1.2)/L

W, Hh = 4096, 1024
img = bpy.data.images.new("CupPrint", W, Hh, alpha=False)
cols = np.array([[0.95,0.42,0.33],[0.96,0.58,0.67],[0.40,0.79,0.77],[0.99,0.80,0.32]])
NSTRIPE = 12
u = (np.arange(W)+0.5)/W
v = (np.arange(Hh)+0.5)/Hh
ph = (u*NSTRIPE) % 1.0
idx = (np.floor(u*NSTRIPE).astype(int)) % 4
paper = np.array([0.985,0.975,0.955])
row = np.where((ph < 0.40)[:,None], cols[idx], paper)
edge = np.clip(np.minimum(np.abs(ph-0.0), np.abs(ph-0.40))*W/NSTRIPE/1.5, 0, 1)
tex = np.repeat(row[None,:,:], Hh, axis=0)
under = (v < v_wall0 - 0.002) | (v > v_print_top)
tex[under] = paper
rng = np.random.default_rng(3)
tex *= (1 - 0.025*rng.random((Hh, W, 1)))
lin = np.where(tex <= 0.04045, tex/12.92, ((tex+0.055)/1.055)**2.4)
px = np.concatenate([tex, np.ones((Hh, W, 1))], axis=2).astype(np.float32)
img.pixels.foreach_set(px.ravel())
img.filepath_raw = os.path.join(out_dir, "cup_print.png"); img.file_format = 'PNG'
img.save()

def make_mat(name, printed):
    m = bpy.data.materials.new(name); m.use_nodes = True
    nt = m.node_tree; b = nt.nodes["Principled BSDF"]
    if printed:
        t = nt.nodes.new("ShaderNodeTexImage"); t.image = img
        nt.links.new(t.outputs[0], b.inputs["Base Color"])
        b.inputs["Roughness"].default_value = 0.42
        b.inputs["Coat Weight"].default_value = 0.15
        b.inputs["Coat Roughness"].default_value = 0.3
    else:
        b.inputs["Base Color"].default_value = (0.93, 0.92, 0.89, 1)
        b.inputs["Roughness"].default_value = 0.3
        b.inputs["Coat Weight"].default_value = 0.35
        b.inputs["Coat Roughness"].default_value = 0.15
    b.inputs["Subsurface Weight"].default_value = 0.15
    b.inputs["Subsurface Radius"].default_value = (1, 0.9, 0.8)
    b.inputs["Subsurface Scale"].default_value = 0.0005
    return m
me.materials.append(make_mat("CupOutside", True))
me.materials.append(make_mat("CupInside", False))

sol = cup.modifiers.new("Paper", 'SOLIDIFY')
sol.thickness = T*mm; sol.offset = 1.0
sol.use_even_offset = True; sol.material_offset = 1; sol.material_offset_rim = 1
bpy.ops.object.modifier_apply(modifier="Paper")
me = cup.data

import bmesh
bm = bmesh.new(); bm.from_mesh(me); bm.normal_update()
for f in bm.faces:
    c = f.calc_center_median(); r = math.hypot(c.x, c.y)
    zc = c.z/mm
    if r < 1e-9: continue
    radial = Vector((c.x/r, c.y/r, 0))
    if zc > FLOOR_Z + 0.5 and zc < Z_BEAD - 0.2 and r/mm > 30:
        f.material_index = 0 if f.normal.dot(radial) > 0 else 1
    elif zc >= Z_BEAD - 0.2:
        f.material_index = 0
    else:
        f.material_index = 0 if (f.normal.z < -0.5 or f.normal.dot(radial) > 0.5) else 1
        if f.normal.z < -0.5 or (r/mm < R_BOT - 0.9 and f.normal.dot(radial) > 0): f.material_index = 1
bm.to_mesh(me); bm.free()
cup.data.materials[1].node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.93,0.92,0.89,1)

bpy.ops.object.shade_auto_smooth(angle=math.radians(50))
bpy.ops.object.modifier_apply(modifier=cup.modifiers[-1].name) if cup.modifiers else None

dims = cup.dimensions
print("CUP_DIMS_MM", [round(d/mm, 2) for d in dims], "TRIS", sum(len(p.vertices)-2 for p in cup.data.polygons))
iv = 0.0
zs = np.linspace(FLOOR_Z+T, H, 400)
for z0, z1 in zip(zs[:-1], zs[1:]):
    zm = (z0+z1)/2; r = wall_r(min(zm, Z_BEAD)) - T
    iv += math.pi*r*r*(z1-z0)
print("BRIMFUL_ML", round(iv/1000, 1))
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(out_dir, "paper_cup.blend"))
