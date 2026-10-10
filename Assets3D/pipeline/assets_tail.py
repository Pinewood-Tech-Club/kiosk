import json, struct
OUT = "/Users/adam/.t3/projects/kiosk/Kiosk/Resources/3D"
os.makedirs(OUT, exist_ok=True)
C = np.array([[1,0,0],[0,0,1],[0,-1,0]], dtype=np.float64)

def to_yup(P): return P @ C.T

def quat_yup(q):
    R = np.array(q.to_matrix())
    Ry = C @ R @ C.T
    from mathutils import Matrix as M3
    qq = M3([list(Ry[0]), list(Ry[1]), list(Ry[2])]).to_quaternion()
    return [qq.x, qq.y, qq.z, qq.w]

def mesh_arrays(me):
    n = len(me.vertices)
    P = np.empty(n*3); me.vertices.foreach_get("co", P); P = P.reshape(-1,3)
    me.calc_loop_triangles()
    T = np.empty(len(me.loop_triangles)*3, dtype=np.int64); me.loop_triangles.foreach_get("vertices", T)
    return P, T.reshape(-1,3)

def seam_pairs(me):
    W = int(me["seam_cols"]); NTH = W - 1
    rows = (len(me.vertices) - 2) // W
    a = np.array([i*W + NTH for i in range(rows)]); b = np.array([i*W for i in range(rows)])
    return a, b

def normals_tangents(P, T, UV, pairs):
    n = len(P)
    v0, v1, v2 = P[T[:,0]], P[T[:,1]], P[T[:,2]]
    fn = np.cross(v1 - v0, v2 - v0)
    N = np.zeros((n,3))
    for k in range(3): np.add.at(N, T[:,k], fn)
    e1, e2 = v1 - v0, v2 - v0
    w0, w1, w2 = UV[T[:,0]], UV[T[:,1]], UV[T[:,2]]
    d1, d2 = w1 - w0, w2 - w0
    det = d1[:,0]*d2[:,1] - d2[:,0]*d1[:,1]
    det = np.where(np.abs(det) < 1e-12, 1e-12, det)
    tf = (e1*d2[:,1:2] - e2*d1[:,1:2]) / det[:,None]
    bf = (e2*d1[:,0:1] - e1*d2[:,0:1]) / det[:,None]
    area = np.linalg.norm(fn, axis=1)[:,None]
    tf = tf / (np.linalg.norm(tf, axis=1)[:,None] + 1e-20) * area
    bf = bf / (np.linalg.norm(bf, axis=1)[:,None] + 1e-20) * area
    Tg = np.zeros((n,3)); Bg = np.zeros((n,3))
    for k in range(3):
        np.add.at(Tg, T[:,k], tf); np.add.at(Bg, T[:,k], bf)
    a, b = pairs
    for A_ in (N,):
        s_ = A_[a] + A_[b]; A_[a] = s_; A_[b] = s_
    N /= np.linalg.norm(N, axis=1)[:,None] + 1e-20
    Tg = Tg - N*(Tg*N).sum(1)[:,None]
    bad = np.linalg.norm(Tg, axis=1) < 1e-12
    if bad.any():
        alt = np.cross(N[bad], np.array([0,1.0,0])); Tg[bad] = alt
    Tg /= np.linalg.norm(Tg, axis=1)[:,None] + 1e-20
    w = np.sign((np.cross(N, Tg)*Bg).sum(1)); w[w == 0] = 1
    return N, np.c_[Tg, w]

def ball_pose(P_icon):
    c = np.array([0.0, 0.0, 0.0])
    zc = P_icon[:,2].min() + (P_icon[:,2].max() - P_icon[:,2].min())*0.45
    c[2] = zc
    D = P_icon - c
    L = np.linalg.norm(D, axis=1)[:,None]; D = D/np.maximum(L, 1e-9)
    hull_r = 0.5*(np.ptp(P_icon[:,0]) + np.ptp(P_icon[:,1]))/2
    R = 0.86*r
    jit = np.array([noise.noise(Vector(d)*2.0 + Vector((5,5,5))) for d in D])
    B = c + D*R*(1 + 0.03*jit)[:,None]
    B[:,2] += R - zc
    return B

cone_me = cone_src.data
V = np.empty(len(cone_me.vertices)*3); cone_me.vertices.foreach_get("co", V); V = V.reshape(-1,3)
th = np.arctan2(V[:,1], V[:,0]); bins = ((th+np.pi)/(2*np.pi)*72).astype(int) % 72
topz = np.full(72, -1.0); np.maximum.at(topz, bins, V[:,2])
low = (np.argmin(topz)+0.5)/72*2*np.pi - np.pi
rot = (-math.pi/2) - low
cone_me.transform(Matrix.Rotation(rot, 4, 'Z')); cone_me.update()
print("CONE rotated so low rim faces -Y (blender) / +Z (RealityKit)")

seeds = [0, 1, 2]
for mi in seeds:
    me = scoop_meshes[mi]
    me.update()

layouts = {
    "cup":  place("cup",  ["vanilla","vanilla","vanilla"], 0.0, seeds=seeds, solo_lift=0.0),
    "cone": place("cone", ["vanilla","vanilla","vanilla"], 0.0, seeds=seeds),
}
solo = place("cup", ["vanilla"], 0.0, seeds=seeds, solo_lift=4.0*mm)[0]

placements = {"cup": {}, "cone": {}}
poses = {mi: {} for mi in seeds}
heights = {}
for mi in seeds:
    raw, _ = mesh_arrays(scoop_meshes[mi])
    h = -raw[:,2].min(); heights[mi] = h
    icon = raw + np.array([0, 0, h])
    poses[mi]["icon"] = icon
    poses[mi]["ball"] = ball_pose(icon)

def record(obj, mi, key, slotname, container):
    bpy.context.view_layer.update()
    loc, rq, sc_ = obj.matrix_world.decompose()
    Pl = np.empty(len(obj.data.vertices)*3); obj.data.vertices.foreach_get("co", Pl); Pl = Pl.reshape(-1,3)
    M = np.array(obj.matrix_world)
    Wd = Pl @ M[:3,:3].T + M[:3,3]
    Rm = np.array(rq.to_matrix())
    Pp = (Wd - np.array(loc)) @ Rm + np.array([0, 0, heights[mi]])
    poses[mi][key] = Pp
    tw = np.array(loc) + Rm @ np.array([0, 0, -heights[mi]])
    placements[container][slotname] = {"translation": [float(v) for v in to_yup(tw[None])[0]], "rotation": quat_yup(rq)}

for i, o in enumerate(layouts["cup"]):  record(o, seeds[i], "cup", str(i+1), "cup")
for i, o in enumerate(layouts["cone"]): record(o, seeds[i], "cone", str(i+1), "cone")
record(solo, seeds[0], "cup_solo", "solo", "cup")
json.dump(placements, open(f"{OUT}/placements.json", "w"), indent=2)

for slot, mi in enumerate(seeds, start=1):
    me = scoop_meshes[mi]
    _, T = mesh_arrays(me)
    li = np.empty(len(me.loops), dtype=np.int64); me.loops.foreach_get("vertex_index", li)
    luv = np.empty(len(me.loops)*2, dtype=np.float32); me.uv_layers["UVMap"].data.foreach_get("uv", luv); luv = luv.reshape(-1,2)
    UV = np.zeros((len(me.vertices),2), dtype=np.float32); UV[li] = luv
    pairs = seam_pairs(me)
    names = ["icon", "ball", "cup"] + (["cup_solo"] if slot == 1 else []) + ["cone"]
    with open(f"{OUT}/Scoop{slot}.scoopmesh", "wb") as f:
        f.write(b"SCMP"); f.write(struct.pack("<IIII", 1, len(me.vertices), T.size, len(names)))
        for nm in names:
            b_ = nm.encode(); f.write(struct.pack("<I", len(b_))); f.write(b_)
        f.write(UV.astype("<f4").tobytes())
        f.write(T[:, [0,1,2]].astype("<u4").tobytes())
        for nm in names:
            Py = to_yup(poses[mi][nm])
            Ny, Ty = normals_tangents(Py, T, UV.astype(np.float64), pairs)
            f.write(Py.astype("<f4").tobytes()); f.write(Ny.astype("<f4").tobytes()); f.write(Ty.astype("<f4").tobytes())
    print("SCOOP", slot, "verts", len(me.vertices), "tris", T.shape[0], "poses", names)

def export_container(data, name):
    ob = bpy.data.objects.new(name, data); sc.collection.objects.link(ob)
    for x in sc.objects: x.select_set(False)
    ob.select_set(True); bpy.context.view_layer.objects.active = ob
    bpy.ops.wm.usd_export(filepath=f"{OUT}/{name}.usdz", selected_objects_only=True, export_materials=True,
                          convert_orientation=True, export_global_forward_selection='NEGATIVE_Z', export_global_up_selection='Y')
    bpy.data.objects.remove(ob)
export_container(cup_src.data, "Cup")
export_container(cone_src.data, "Cone")
print("EXPORTED containers")

if not os.environ.get("SKIP_BAKE"):
    sc.render.engine = 'CYCLES'
    prefs = bpy.context.preferences.addons['cycles'].preferences
    prefs.compute_device_type = 'METAL'; prefs.get_devices()
    for d in prefs.devices: d.use = True
    sc.cycles.device = 'GPU'
    for o in list(sc.objects):
        if o.type == 'MESH': o.hide_render = True
    sc.cycles.samples = 8; sc.cycles.use_denoising = False
    sc.render.bake.margin = 16
    for slot, mi in enumerate(seeds, start=1):
        for flavor in ["vanilla", "chocolate", "cookies"]:
            ob = bpy.data.objects.new(f"Bake{slot}{flavor}", scoop_meshes[mi])
            sc.collection.objects.link(ob)
            m = MATS[flavor]; m.displacement_method = 'BUMP'
            ob.data.materials.clear(); ob.data.materials.append(m)
            for x in sc.objects: x.select_set(False)
            ob.select_set(True); bpy.context.view_layer.objects.active = ob
            nt = m.node_tree
            for kind, pname, noncolor in [("DIFFUSE", "basecolor", False), ("ROUGHNESS", "roughness", True), ("NORMAL", "normal", True)]:
                im = bpy.data.images.new(f"S{slot}{flavor}{pname}", 2048, 2048, alpha=False)
                if noncolor: im.colorspace_settings.name = 'Non-Color'
                tn = nt.nodes.new("ShaderNodeTexImage"); tn.image = im
                for nd in nt.nodes: nd.select = False
                tn.select = True; nt.nodes.active = tn
                if kind == "DIFFUSE": bpy.ops.object.bake(type='DIFFUSE', pass_filter={'COLOR'})
                else: bpy.ops.object.bake(type=kind)
                im.filepath_raw = f"{OUT}/Scoop{slot}_{flavor}_{pname}.png"; im.file_format = 'PNG'; im.save()
                nt.nodes.remove(tn)
            bpy.data.objects.remove(ob)
            print("BAKED", slot, flavor)
