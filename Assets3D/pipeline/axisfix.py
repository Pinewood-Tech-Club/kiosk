import bpy, numpy as np, math, sys
from mathutils import Vector, Matrix
p = "/Users/adam/.t3/projects/kiosk/Assets3D/waffle_cone_app.blend"
bpy.ops.wm.open_mainfile(filepath=p)
o = bpy.data.objects["WaffleCone"]; me = o.data
V = np.empty(len(me.vertices)*3); me.vertices.foreach_get("co", V); V = V.reshape(-1,3)
def fit_axis(V):
    z0, z1 = V[:,2].min(), V[:,2].max()
    cs = []
    for z in np.linspace(z0 + 0.12*(z1-z0), z0 + 0.55*(z1-z0), 30):
        S = V[np.abs(V[:,2]-z) < 0.0008]
        if len(S) < 50: continue
        x, y = S[:,0], S[:,1]
        A = np.c_[2*x, 2*y, np.ones_like(x)]; b = x*x + y*y
        cx, cy, _ = np.linalg.lstsq(A, b, rcond=None)[0]
        cs.append((cx, cy, z))
    C = np.array(cs); m = C.mean(0)
    d = np.linalg.svd(C - m)[2][0]
    if d[2] < 0: d = -d
    return m, d
m, d = fit_axis(V)
print("AXIS_BEFORE tilt deg", math.degrees(math.acos(d[2])), d)
q = Vector(d).rotation_difference(Vector((0,0,1)))
me.transform(q.to_matrix().to_4x4() @ Matrix.Translation(-Vector(m)))
V = np.empty(len(me.vertices)*3); me.vertices.foreach_get("co", V); V = V.reshape(-1,3)
m2, d2 = fit_axis(V)
print("AXIS_AFTER tilt deg", math.degrees(math.acos(d2[2])))
tip = V[V[:,2].argmin()]
me.transform(Matrix.Translation(Vector((-m2[0], -m2[1], -tip[2]))))
me.update()
V = np.empty(len(me.vertices)*3); me.vertices.foreach_get("co", V); V = V.reshape(-1,3)
print("TIP xy offset from axis mm", V[V[:,2].argmin()][:2]*1000, "DIMS mm", (V.max(0)-V.min(0))*1000)
bpy.ops.wm.save_as_mainfile(filepath=p)
