import bpy, bmesh, math, sys, os, random
import numpy as np
from mathutils import Vector, noise, Matrix, Euler
argv = sys.argv[sys.argv.index("--")+1:]
A = "/Users/adam/.t3/projects/kiosk/Assets3D"
out = argv[0]; res = int(argv[1]); samples = int(argv[2])
D_MM = float(os.environ.get("SCOOP_MM", "50.8"))
mm = 0.001
bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene

def load(path, name):
    with bpy.data.libraries.load(path) as (src, dst):
        dst.objects = [name]
    return dst.objects[0]
cup_src = load(f"{A}/paper_cup.blend", "PaperCup")
cone_src = load(f"{A}/waffle_cone_app.blend", "WaffleCone")

r = D_MM/2*mm
ZB = -0.53
PROFILE = [(0,0.98),(0.35,0.93),(0.68,0.76),(0.9,0.46),(1.0,0.14),(1.03,-0.02),(1.10,-0.10),(1.20,-0.14),(1.29,-0.22),(1.33,-0.34),(1.27,-0.46),(1.05,-0.52),(0.6,-0.535),(0.0,-0.54)]
COLLAR_FROM, COLLAR_TO = 5, 11

def sample_profile(n):
    P = np.array(PROFILE)
    seg = np.r_[0, np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))]
    s = np.linspace(0, seg[-1], n)
    rho = np.interp(s, seg, P[:,0]); z = np.interp(s, seg, P[:,1])
    for _ in range(3):
        rho[1:-1] = (rho[:-2] + 2*rho[1:-1] + rho[2:])/4
        z[1:-1] = (z[:-2] + 2*z[1:-1] + z[2:])/4
    tr = np.gradient(rho); tz = np.gradient(z)
    nl = np.hypot(tr, tz); nr, nz = tz/nl, -tr/nl
    c0, c1 = seg[COLLAR_FROM], seg[COLLAR_TO]
    cw = np.clip(np.minimum((s - c0)/0.25, (c1 - s)/0.12), 0, 1)
    cw = cw*cw*(3-2*cw)
    return rho, z, nr, nz, cw, s/seg[-1]

def fbm(p, oct, turb=False):
    a, f, t = 1.0, 1.0, 0.0
    for _ in range(oct):
        n = noise.noise(p*f)
        t += a*(abs(n) if turb else n); a *= 0.5; f *= 2.07
    return t

def make_scoop_mesh(seed, NT=240, NTH=400):
    rng = random.Random(seed)
    off = Vector((seed*3.1+0.3, seed*1.7+0.7, seed*2.3+0.1))
    rho, z, nr, nz, cw, vv = sample_profile(NT)
    drag = rng.uniform(0, 2*math.pi); du = Vector((math.cos(drag), math.sin(drag), 0))
    tilt = Vector((rng.uniform(-0.15,0.15), rng.uniform(-0.15,0.15), 0))
    verts = []; uvs = []; melts = []
    lob = Vector((math.cos(drag+2.0), math.sin(drag+2.0), 0.45)).normalized()*0.95
    tearc = Vector((math.cos(drag-1.6), math.sin(drag-1.6), 0.7)).normalized()*0.95
    for i in range(1, NT-1):
        for j in range(NTH):
            th = 2*math.pi*j/NTH; c, sn = math.cos(th), math.sin(th)
            ring = Vector((math.cos(th)*1.4, math.sin(th)*1.4, seed*0.37))
            rr = rho[i]
            if cw[i] > 0 and rr > 1.0:
                rr = 1.0 + (rr - 1.0)*max(0.15, 0.75 + 1.1*noise.noise(ring) + 0.3*noise.noise(ring*3))
            p = Vector((rr*c, rr*sn, z[i]))
            n = Vector((nr[i]*c, nr[i]*sn, nz[i]))
            d = 0.085*fbm(p*1.1 + off, 2)
            melt = min(1.0, max(0.0, (noise.noise(p*1.4 + off + Vector((7,7,7))) - 0.32)/0.2))
            rough = 1 - 0.85*melt
            d += 0.30*math.exp(-(p - lob).length_squared/0.14)
            tm = math.exp(-(p - tearc).length_squared/0.08)
            d += tm*(0.18*fbm(p*4 + off, 2, True) + 0.06*fbm(p*11 + off, 2, True) - 0.09)
            dome = (1 - cw[i]) * (1.0 if z[i] > -0.15 else 0.0)
            if dome > 0:
                C = du*2.2 + Vector((0, 0, -0.4))
                u = (p - C).length + 0.05*noise.noise(p*3 + off) + 0.012*noise.noise(p*12 + off)
                g = abs(math.sin(math.pi*u*11.0))
                groove = (1-g)**5
                fade = max(0.0, 0.75 + noise.noise(Vector((u*3.0, seed, 0.5))*1.0) + 0.5*noise.noise(p*2+off))
                tear = 0.6 + 0.4*noise.noise(p*9 + off)
                lip = math.exp(-((g-0.3)/0.12)**2)
                d += dome*rough*min(fade,1.0)*(-0.02*groove*tear + 0.01*lip*tear)
                d += dome*rough*(0.016*fbm(p*9 + off, 3, True) - 0.008)
            if cw[i] > 0:
                d += cw[i]*(0.10*fbm(p*2.5 + off*0.7, 2, True) + 0.12*fbm(p*4.5 + off, 2, True) + 0.06*fbm(p*11 + off, 2, True) + 0.025*fbm(p*26 + off, 2, True) - 0.11)
            if vv[i] > 0.93:
                d *= 0.2
            q = p + n*d + tilt*max(0.0, p.z)*0.3
            q.z = (q.z - ZB)*0.95 + ZB
            if q.z > -0.2:
                sag = 1 + 0.07*max(0.0, 0.7 - q.z)
                q.x *= sag; q.y *= sag
            verts.append(q*r); uvs.append((j/NTH, vv[i])); melts.append(melt)
    top = len(verts); verts.append(sum(verts[:NTH], Vector())/NTH + Vector((0,0,0.004*r)))
    bot = len(verts); verts.append(sum(verts[-NTH:], Vector())/NTH)
    R = NT-2
    faces = []
    for i in range(R-1):
        for j in range(NTH):
            a = i*NTH + j; b2 = i*NTH + (j+1)%NTH
            faces.append((a, a+NTH, b2+NTH, b2))
    for j in range(NTH):
        faces.append((top, j, (j+1)%NTH))
        faces.append((bot, (R-1)*NTH + (j+1)%NTH, (R-1)*NTH + j))
    me = bpy.data.meshes.new("Scoop")
    me.from_pydata([tuple(v) for v in verts], [], faces)
    melts += [0.0, 0.0]
    at = me.attributes.new("melt", 'FLOAT', 'POINT'); at.data.foreach_set("value", np.array(melts, dtype=np.float32))
    uvl = me.uv_layers.new(name="UVMap")
    for poly in me.polygons: poly.use_smooth = True
    return me

def drape_over(o, below, rad):
    bc = below.matrix_world @ Vector((0, 0, 0.05*r))
    mw = o.matrix_world; inv = mw.inverted()
    oc = mw.translation
    for v in o.data.vertices:
        w = mw @ v.co
        if w.z > oc.z: continue
        rho = math.hypot(w.x - oc.x, w.y - oc.y)
        w.z -= min(0.18*r, max(0.0, rho - 0.85*r)*0.55)
        dv = w - bc; L = dv.length
        if L < rad and L > 1e-9:
            w = bc + dv*(rad/L)
        v.co = inv @ w

def clamp_to(o, radius_at, z_top, z_floor=None, inset=0.0006):
    mw = o.matrix_world; inv = mw.inverted()
    for v in o.data.vertices:
        w = mw @ v.co
        if z_floor is not None and w.z < z_floor: w.z = z_floor
        dx0, dy0 = w.x - cx_, w.y - cy_
        if w.z < z_top:
            R = radius_at(w.z, math.atan2(dy0, dx0))
            if R is None: continue
            dx, dy = w.x - cx_, w.y - cy_
            rho = math.hypot(dx, dy)
            lim = max(R - inset, 0.0)
            if rho > lim and rho > 1e-9:
                k = lim/rho; w.x = cx_ + dx*k; w.y = cy_ + dy*k
        v.co = inv @ w
cx_ = cy_ = 0.0

def flavor_mat(name, kind):
    m = bpy.data.materials.new(name); m.use_nodes = True
    nt = m.node_tree; N = nt.nodes; L = nt.links
    b = N["Principled BSDF"]
    tc = N.new("ShaderNodeTexCoord")
    b.inputs["Roughness"].default_value = 0.78
    b.inputs["Subsurface Weight"].default_value = 0.35
    b.inputs["Subsurface Scale"].default_value = 0.004
    b.inputs["Coat Weight"].default_value = 0.0
    b.inputs["Coat Roughness"].default_value = 0.25
    def noise_tex(scale, detail=4):
        t = N.new("ShaderNodeTexNoise"); t.inputs["Scale"].default_value = scale; t.inputs["Detail"].default_value = detail
        L.new(tc.outputs["Object"], t.inputs["Vector"]); return t
    def ramp(inp, stops):
        rp = N.new("ShaderNodeValToRGB"); cr = rp.color_ramp
        cr.elements[0].position, cr.elements[0].color = stops[0][0], (*stops[0][1], 1)
        cr.elements[1].position, cr.elements[1].color = stops[-1][0], (*stops[-1][1], 1)
        for p, c in stops[1:-1]:
            e = cr.elements.new(p); e.color = (*c, 1)
        L.new(inp, rp.inputs[0]); return rp
    base = noise_tex(40)
    if kind == "vanilla":
        col = ramp(base.outputs["Fac"], [(0.3,(0.93,0.70,0.33)),(0.7,(0.98,0.80,0.47))])
        b.inputs["Subsurface Radius"].default_value = (1, 0.8, 0.5)
        sp = N.new("ShaderNodeTexVoronoi"); sp.inputs["Scale"].default_value = 900
        L.new(tc.outputs["Object"], sp.inputs["Vector"])
        mk = ramp(sp.outputs["Distance"], [(0.0,(0.15,0.08,0.03)),(0.08,(1,1,1))])
        mix = N.new("ShaderNodeMix"); mix.data_type='RGBA'; mix.blend_type='MULTIPLY'; mix.inputs["Factor"].default_value = 1
        L.new(col.outputs[0], mix.inputs[6]); L.new(mk.outputs[0], mix.inputs[7]); out_c = mix.outputs[2]
    elif kind == "chocolate":
        col = ramp(base.outputs["Fac"], [(0.3,(0.085,0.042,0.024)),(0.7,(0.125,0.064,0.036))])
        b.inputs["Subsurface Radius"].default_value = (0.2, 0.15, 0.1)
        b.inputs["Subsurface Weight"].default_value = 0.15
        out_c = col.outputs[0]
    elif kind == "cookies":
        col = ramp(base.outputs["Fac"], [(0.3,(0.60,0.58,0.53)),(0.7,(0.68,0.66,0.60))])
        b.inputs["Subsurface Radius"].default_value = (1, 0.95, 0.85)
        def vor(scale, randomness=1.0, stretch=None, metric='EUCLIDEAN', warp=0.35):
            v = N.new("ShaderNodeTexVoronoi"); v.distance = metric; v.inputs["Scale"].default_value = scale; v.inputs["Randomness"].default_value = randomness
            dn = N.new("ShaderNodeTexNoise"); dn.inputs["Scale"].default_value = scale*0.8; dn.inputs["Detail"].default_value = 3
            L.new(tc.outputs["Object"], dn.inputs["Vector"])
            vm = N.new("ShaderNodeVectorMath"); vm.operation = 'MULTIPLY_ADD'
            L.new(dn.outputs["Color"], vm.inputs[0]); vm.inputs[1].default_value = (warp/scale,)*3; L.new(tc.outputs["Object"], vm.inputs[2])
            src = vm.outputs[0]
            if stretch:
                mp = N.new("ShaderNodeMapping"); mp.inputs["Scale"].default_value = stretch; mp.inputs["Rotation"].default_value = (0.4, 0.9, 0.2)
                L.new(src, mp.inputs["Vector"]); src = mp.outputs[0]
            L.new(src, v.inputs["Vector"]); return v
        def spots(v, keep, size):
            sp = N.new("ShaderNodeSeparateColor"); L.new(v.outputs["Color"], sp.inputs[0])
            k = N.new("ShaderNodeMath"); k.operation = 'GREATER_THAN'; k.inputs[1].default_value = keep; L.new(sp.outputs[0], k.inputs[0])
            d = N.new("ShaderNodeMath"); d.operation = 'LESS_THAN'; d.inputs[1].default_value = size; L.new(v.outputs["Distance"], d.inputs[0])
            m_ = N.new("ShaderNodeMath"); m_.operation = 'MULTIPLY'; L.new(k.outputs[0], m_.inputs[0]); L.new(d.outputs[0], m_.inputs[1])
            return m_
        dust = spots(vor(950), 0.25, 0.2)
        dust2 = spots(vor(520), 0.5, 0.22)
        chunk = spots(vor(200, 1.0, (1.0, 2.0, 1.0), 'EUCLIDEAN', 1.3), 0.8, 0.3)
        chunk2 = spots(vor(380, 1.0, (1.8, 1.0, 1.0), 'EUCLIDEAN', 1.3), 0.78, 0.28)
        def mx(a_, b_, f_, c2=None):
            m_ = N.new("ShaderNodeMix"); m_.data_type = 'RGBA'
            L.new(f_.outputs[0], m_.inputs["Factor"]); L.new(a_, m_.inputs[6])
            if c2: m_.inputs[7].default_value = c2
            return m_
        c1 = mx(col.outputs[0], None, dust, (0.22,0.21,0.20,1))
        c2_ = mx(c1.outputs[2], None, dust2, (0.10,0.095,0.09,1))
        c3 = mx(c2_.outputs[2], None, chunk2, (0.03,0.028,0.026,1))
        c4 = mx(c3.outputs[2], None, chunk, (0.022,0.02,0.019,1))
        out_c = c4.outputs[2]
        allc = N.new("ShaderNodeMath"); allc.operation = 'MAXIMUM'
        L.new(chunk.outputs[0], allc.inputs[0]); L.new(chunk2.outputs[0], allc.inputs[1])
        rmix = N.new("ShaderNodeMapRange"); rmix.inputs["To Min"].default_value = 0.6; rmix.inputs["To Max"].default_value = 0.85
        L.new(allc.outputs[0], rmix.inputs["Value"]); L.new(rmix.outputs[0], b.inputs["Roughness"])
    L.new(out_c, b.inputs["Base Color"])
    bump = N.new("ShaderNodeBump"); bump.inputs["Strength"].default_value = 0.6; bump.inputs["Distance"].default_value = 0.0004
    pv = N.new("ShaderNodeTexVoronoi"); pv.inputs["Scale"].default_value = 1400; pv.inputs["Randomness"].default_value = 1
    L.new(tc.outputs["Object"], pv.inputs["Vector"])
    pm = N.new("ShaderNodeTexNoise"); pm.inputs["Scale"].default_value = 90
    L.new(tc.outputs["Object"], pm.inputs["Vector"])
    pit = N.new("ShaderNodeMapRange"); pit.inputs["From Min"].default_value = 0.0; pit.inputs["From Max"].default_value = 0.22
    pit.inputs["To Min"].default_value = -1.0; pit.inputs["To Max"].default_value = 0.0; pit.clamp = True
    L.new(pv.outputs["Distance"], pit.inputs["Value"])
    pmask = N.new("ShaderNodeMapRange"); pmask.inputs["From Min"].default_value = 0.45; pmask.inputs["From Max"].default_value = 0.6
    L.new(pm.outputs["Fac"], pmask.inputs["Value"])
    pits = N.new("ShaderNodeMath"); pits.operation = 'MULTIPLY'
    L.new(pit.outputs[0], pits.inputs[0]); L.new(pmask.outputs[0], pits.inputs[1])
    bn = noise_tex(600, 6)
    hs = N.new("ShaderNodeMath"); hs.operation = 'MULTIPLY_ADD'; hs.inputs[1].default_value = 0.35
    L.new(bn.outputs["Fac"], hs.inputs[0]); L.new(pits.outputs[0], hs.inputs[2])
    L.new(hs.outputs[0], bump.inputs["Height"]); L.new(bump.outputs[0], b.inputs["Normal"])
    sh = N.new("ShaderNodeMapRange"); sh.inputs["To Min"].default_value = 0.55; sh.inputs["To Max"].default_value = 0.75
    L.new(pm.outputs["Fac"], sh.inputs["Value"])
    ma = N.new("ShaderNodeAttribute"); ma.attribute_name = "melt"
    rmx = N.new("ShaderNodeMix"); rmx.data_type = 'FLOAT'; rmx.inputs["B"].default_value = 0.4
    L.new(ma.outputs["Fac"], rmx.inputs["Factor"]); L.new(sh.outputs[0], rmx.inputs["A"])
    if kind != "cookies": L.new(rmx.outputs[0], b.inputs["Roughness"])
    bmul = N.new("ShaderNodeMath"); bmul.operation = 'MULTIPLY'
    inv = N.new("ShaderNodeMath"); inv.operation = 'SUBTRACT'; inv.inputs[0].default_value = 1.0
    L.new(ma.outputs["Fac"], inv.inputs[1]); L.new(hs.outputs[0], bmul.inputs[0]); L.new(inv.outputs[0], bmul.inputs[1])
    L.new(bmul.outputs[0], bump.inputs["Height"])
    for lk in list(b.inputs["Normal"].links): nt.links.remove(lk)
    g = N.new("ShaderNodeTexNoise"); g.inputs["Scale"].default_value = 1800; g.inputs["Detail"].default_value = 3; g.inputs["Roughness"].default_value = 0.65
    L.new(tc.outputs["Object"], g.inputs["Vector"])
    gs = N.new("ShaderNodeMath"); gs.operation = 'MULTIPLY_ADD'; gs.inputs[1].default_value = 0.0003; gs.inputs[2].default_value = -0.00015
    L.new(g.outputs["Fac"], gs.inputs[0])
    pv2 = N.new("ShaderNodeTexVoronoi"); pv2.inputs["Scale"].default_value = 650
    L.new(tc.outputs["Object"], pv2.inputs["Vector"])
    pr = N.new("ShaderNodeMapRange"); pr.inputs["From Min"].default_value = 0.0; pr.inputs["From Max"].default_value = 0.28
    pr.inputs["To Min"].default_value = -0.0006; pr.inputs["To Max"].default_value = 0.0; pr.clamp = True
    L.new(pv2.outputs["Distance"], pr.inputs["Value"])
    pmk = N.new("ShaderNodeTexNoise"); pmk.inputs["Scale"].default_value = 110
    L.new(tc.outputs["Object"], pmk.inputs["Vector"])
    pmr = N.new("ShaderNodeMapRange"); pmr.inputs["From Min"].default_value = 0.55; pmr.inputs["From Max"].default_value = 0.65
    L.new(pmk.outputs["Fac"], pmr.inputs["Value"])
    pp = N.new("ShaderNodeMath"); pp.operation = 'MULTIPLY'
    L.new(pr.outputs[0], pp.inputs[0]); L.new(pmr.outputs[0], pp.inputs[1])
    ce = N.new("ShaderNodeTexVoronoi"); ce.feature = 'DISTANCE_TO_EDGE'; ce.inputs["Scale"].default_value = 260
    cn = N.new("ShaderNodeTexNoise"); cn.inputs["Scale"].default_value = 400
    L.new(tc.outputs["Object"], cn.inputs["Vector"])
    cv = N.new("ShaderNodeVectorMath"); cv.operation = 'MULTIPLY_ADD'
    L.new(cn.outputs["Color"], cv.inputs[0]); cv.inputs[1].default_value = (0.002,0.002,0.002); L.new(tc.outputs["Object"], cv.inputs[2])
    L.new(cv.outputs[0], ce.inputs["Vector"])
    cr_ = N.new("ShaderNodeMapRange"); cr_.inputs["From Min"].default_value = 0.0; cr_.inputs["From Max"].default_value = 0.12
    cr_.inputs["To Min"].default_value = -0.00012; cr_.inputs["To Max"].default_value = 0.0; cr_.clamp = True
    L.new(ce.outputs["Distance"], cr_.inputs["Value"])
    cmask = N.new("ShaderNodeMapRange"); cmask.inputs["From Min"].default_value = 0.5; cmask.inputs["From Max"].default_value = 0.62
    L.new(pmk.outputs["Fac"], cmask.inputs["Value"])
    cm2 = N.new("ShaderNodeMath"); cm2.operation = 'SUBTRACT'; cm2.inputs[0].default_value = 1.0
    L.new(cmask.outputs[0], cm2.inputs[1])
    cc = N.new("ShaderNodeMath"); cc.operation = 'MULTIPLY'
    L.new(cr_.outputs[0], cc.inputs[0]); L.new(cm2.outputs[0], cc.inputs[1])
    h1 = N.new("ShaderNodeMath"); h1.operation = 'ADD'; L.new(gs.outputs[0], h1.inputs[0]); L.new(pp.outputs[0], h1.inputs[1])
    h2 = N.new("ShaderNodeMath"); h2.operation = 'ADD'; L.new(h1.outputs[0], h2.inputs[0]); L.new(cc.outputs[0], h2.inputs[1])
    mp = N.new("ShaderNodeMapping"); mp.inputs["Location"].default_value = (0.045, 0.01, 0.012)
    L.new(tc.outputs["Object"], mp.inputs["Vector"])
    wv = N.new("ShaderNodeTexWave"); wv.wave_type = 'RINGS'; wv.rings_direction = 'SPHERICAL'; wv.wave_profile = 'SAW'
    wv.inputs["Scale"].default_value = 260; wv.inputs["Distortion"].default_value = 4.5; wv.inputs["Detail"].default_value = 5
    wv.inputs["Detail Scale"].default_value = 1.6; wv.inputs["Detail Roughness"].default_value = 0.6
    L.new(mp.outputs[0], wv.inputs["Vector"])
    wm = N.new("ShaderNodeTexNoise"); wm.inputs["Scale"].default_value = 60; wm.inputs["Detail"].default_value = 2
    L.new(tc.outputs["Object"], wm.inputs["Vector"])
    wmr = N.new("ShaderNodeMapRange"); wmr.inputs["From Min"].default_value = 0.38; wmr.inputs["From Max"].default_value = 0.55
    L.new(wm.outputs["Fac"], wmr.inputs["Value"])
    wz = N.new("ShaderNodeSeparateXYZ"); L.new(tc.outputs["Object"], wz.inputs[0])
    wzr = N.new("ShaderNodeMapRange"); wzr.inputs["From Min"].default_value = -0.004; wzr.inputs["From Max"].default_value = 0.004
    L.new(wz.outputs["Z"], wzr.inputs["Value"])
    wmm = N.new("ShaderNodeMath"); wmm.operation = 'MULTIPLY'; L.new(wmr.outputs[0], wmm.inputs[0]); L.new(wzr.outputs[0], wmm.inputs[1])
    wa = N.new("ShaderNodeMath"); wa.operation = 'MULTIPLY_ADD'; wa.inputs[1].default_value = 0.0011; wa.inputs[2].default_value = -0.00055
    L.new(wv.outputs["Fac"], wa.inputs[0])
    wam = N.new("ShaderNodeMath"); wam.operation = 'MULTIPLY'; L.new(wa.outputs[0], wam.inputs[0]); L.new(wmm.outputs[0], wam.inputs[1])
    h2b = N.new("ShaderNodeMath"); h2b.operation = 'ADD'; L.new(h2.outputs[0], h2b.inputs[0]); L.new(wam.outputs[0], h2b.inputs[1])
    h3 = N.new("ShaderNodeMath"); h3.operation = 'MULTIPLY'; L.new(h2b.outputs[0], h3.inputs[0]); L.new(inv.outputs[0], h3.inputs[1])
    dsp = N.new("ShaderNodeDisplacement"); dsp.inputs["Midlevel"].default_value = 0.0; dsp.inputs["Scale"].default_value = 1.0
    L.new(h3.outputs[0], dsp.inputs["Height"])
    L.new(dsp.outputs[0], N["Material Output"].inputs["Displacement"])
    m.displacement_method = 'DISPLACEMENT'
    m.max_vertex_displacement = 0.002
    return m

MATS = {k: flavor_mat(k.title(), k) for k in ["vanilla","chocolate","cookies"]}
scoop_meshes = [make_scoop_mesh(s) for s in range(int(os.environ.get('NSCOOP','4')))]

def add_scoop(kind, loc, rotz, seed, tilt=(0,0)):
    o = bpy.data.objects.new(f"Scoop_{kind}", scoop_meshes[seed % len(scoop_meshes)].copy())
    o.data.materials.append(MATS[kind])
    o.location = loc; o.rotation_euler = (tilt[0], tilt[1], rotz)
    sc.collection.objects.link(o)
    sm = o.modifiers.new("Micro", 'SUBSURF'); sm.use_adaptive_subdivision = True; sm.adaptive_pixel_size = 1.0
    sm.levels = 0
    bpy.context.view_layer.update(); return o

CUP_FLOOR = 6.4*mm
CUP_ZB = float(os.environ.get('CUP_H', '46')) - 1.3
def cup_inner(zl, th=0.0): return (36.0 + 4.9*min(zl/mm, CUP_ZB)/CUP_ZB - 0.45)*mm

def place(container, kinds, x):
    global cx_, cy_
    rng = random.Random(len(kinds)*7 + int(x*1000))
    o = bpy.data.objects.new(container, cup_src.data if container=="cup" else cone_src.data)
    sc.collection.objects.link(o); o.location = (x, 0, 0)
    lift = -ZB*r
    if container == "cup":
        cx_, cy_ = x, 0.0
        base = CUP_FLOOR + lift*0.9 + (4.0*mm if len(kinds) == 1 else 0.0)
        centers = [Vector((0, 0, base)), Vector((0.18*r, -0.08*r, base + 0.72*r)), Vector((-0.12*r, 0.10*r, base + 1.40*r))]
        fn = cup_inner; ztop = (CUP_ZB - 0.2)*mm; zfl = CUP_FLOOR
    else:
        V = np.empty(len(o.data.vertices)*3); o.data.vertices.foreach_get("co", V); V = V.reshape(-1,3)
        rc = V[V[:,2].argmin(), :2]
        th = np.arctan2(V[:,1]-rc[1], V[:,0]-rc[0]); bins = ((th+np.pi)/(2*np.pi)*36).astype(int) % 36
        topz = np.full(36, -1.0); np.maximum.at(topz, bins, V[:,2])
        rz_low = float(topz.min()); rz = float(np.median(topz))
        rad = np.hypot(V[:,0]-rc[0], V[:,1]-rc[1])
        band = (V[:,2] > rz_low - 0.01) & (V[:,2] < rz_low)
        r_at_low = float(np.percentile(rad[band], 20))
        slope = r_at_low / rz_low
        cx_, cy_ = x + rc[0], rc[1]
        def fn(zw, thw, topz=topz, slope=slope):
            b_ = int((thw + math.pi)/(2*math.pi)*36) % 36
            rim_here = max(topz[b_], topz[(b_+1)%36], topz[(b_-1)%36])
            return slope*zw - 0.0012 if zw < rim_here else None
        ztop = float(topz.max()) + 0.002; zfl = None
        rimpts = []
        for b_ in range(36):
            m_ = bins == b_
            if m_.any():
                k_ = np.argmax(np.where(m_, V[:,2], -1)); rimpts.append(V[k_])
        rimpts = np.array(rimpts); rcen = rimpts.mean(0)
        _, _, vt = np.linalg.svd(rimpts - rcen); nrm = vt[2] if vt[2][2] > 0 else -vt[2]
        nrm = Vector(nrm).lerp(Vector((0,0,1)), 0.25).normalized()
        RIM_TILT = Vector((0,0,1)).rotation_difference(nrm)
        c0 = Vector(rcen) + nrm*(0.22*r)
        centers = [c0, c0 + Vector((0.14*r, -0.08*r, 0.74*r)), c0 + Vector((-0.10*r, 0.10*r, 1.42*r))]
    prev = None
    for i, k in enumerate(kinds):
        c = centers[i]
        so = add_scoop(k, (x + c.x, c.y, c.z), rng.uniform(0, 6.28), rng.randrange(len(scoop_meshes)),
                  tilt=(rng.uniform(-0.22,0.22), rng.uniform(-0.22,0.22)))
        if container == "cone" and i == 0:
            so.rotation_mode = 'QUATERNION'
            so.rotation_quaternion = RIM_TILT @ Euler((0, 0, rng.uniform(0, 6.28))).to_quaternion()
            bpy.context.view_layer.update()
        if i > 0: so.scale = (0.92, 0.92, 0.97); bpy.context.view_layer.update()
        if prev is not None: drape_over(so, prev, 0.80*r)
        clamp_to(so, fn, ztop, zfl)
        prev = so

SP = 0.115
layout = [("cup", ["vanilla"]), ("cup", ["chocolate","cookies"]), ("cup", ["cookies","vanilla","chocolate"]),
          ("cone", ["chocolate"]), ("cone", ["vanilla","chocolate"]), ("cone", ["cookies","chocolate","vanilla"])]
if os.environ.get("CLOSEUP"):
    for i, k in enumerate(["vanilla","chocolate","cookies"]):
        add_scoop(k, ((i-1)*0.082, 0, -ZB*r), 0.6*i, i)
else:
    if os.environ.get("ONLY") == "cones": layout = [l for l in layout if l[0] == "cone"]
    for i, (c, ks) in enumerate(layout):
        place(c, ks, (i - 2.5)*SP)

sc.render.engine = 'CYCLES'
prefs = bpy.context.preferences.addons['cycles'].preferences
prefs.compute_device_type = 'METAL'; prefs.get_devices()
for d in prefs.devices: d.use = True
sc.cycles.device = 'GPU'; sc.cycles.samples = samples; sc.cycles.use_denoising = True
sc.cycles.denoising_prefilter = 'ACCURATE'; sc.cycles.denoising_quality = 'HIGH'
sc.view_settings.view_transform = 'AgX'; sc.view_settings.look = 'AgX - Medium High Contrast'
sc.view_settings.exposure = -0.5
sc.render.resolution_x = res; sc.render.resolution_y = int(res*0.5)
w = bpy.data.worlds.new("W"); sc.world = w; w.use_nodes = True
w.node_tree.nodes["Background"].inputs[0].default_value = (0.98,0.95,0.92,1)
w.node_tree.nodes["Background"].inputs[1].default_value = 0.18
bpy.ops.mesh.primitive_plane_add(size=3, location=(0,0,0))
gp = bpy.context.object; gm = bpy.data.materials.new("Ground"); gm.use_nodes = True
gm.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.96,0.93,0.89,1)
gm.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.8
gp.data.materials.append(gm)
def light(name, loc, energy, size, color=(1,1,1)):
    ld = bpy.data.lights.new(name, 'AREA'); ld.energy = energy; ld.size = size; ld.color = color
    lo = bpy.data.objects.new(name, ld); sc.collection.objects.link(lo); lo.location = loc
    lo.rotation_euler = (Vector((0,0,0.08)) - Vector(loc)).to_track_quat('-Z','Y').to_euler()
light("Key", (-0.5, -0.8, 0.9), 22, 0.8, (1, 0.96, 0.9))
light("Fill", (0.9, -0.6, 0.3), 6, 1.0, (0.92, 0.95, 1))
light("Rim", (0.2, 0.8, 0.6), 14, 0.6)
cd = bpy.data.cameras.new("Cam"); cd.lens = 70
cam = bpy.data.objects.new("Cam", cd); sc.collection.objects.link(cam); sc.camera = cam
cam.location = (0, -0.62, 0.22) if os.environ.get("CLOSEUP") else (0, -1.15, 0.78)
cam.rotation_euler = (Vector((0,0,0.02 if os.environ.get("CLOSEUP") else 0.085)) - cam.location).to_track_quat('-Z','Y').to_euler()
if os.environ.get("SAVE_BLEND"): bpy.ops.wm.save_as_mainfile(filepath=os.environ["SAVE_BLEND"])
sc.render.filepath = out
bpy.ops.render.render(write_still=True)
