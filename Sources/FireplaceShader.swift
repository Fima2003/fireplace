// Metal source for the fireplace, compiled at runtime so the app builds with
// just the Command Line Tools.
//
// sceneFragment bakes everything that doesn't move (brick, wood, stone, ash) once
// per size: linear albedo, how much light each pixel gets from four lamps standing
// in for the left, centre, right and tall parts of the fire (with the logs'
// shadows and the jambs' cut-off baked in), and masks for embers, the firebox
// mouth, the front logs and the gloss of the hearth. The fire itself is a fluid
// simulation (see "fire physics"). Every frame, frameFragment reads how bright
// each part of the fire is, mixes the four lamp terms accordingly, draws the
// flame's black-body glow (visible-band Wien brightness, so tips are translucent
// red and roots white) over the scene with heat haze, mirrors it in the hearth,
// adds the bloom from glowFragment, and grades the result: white balance for
// firelight, highlights rolled to white, ACES. Sparks are stretched point sprites.
//
// Scene units: one unit is the screen height, x is centred, y grows up from the floor.
let fireplaceShaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 resolution;
    float2 viewCenter;
    float viewScale;
    float time;
    float layoutAspect;
    float seed;
    float2 simSize;
    float exposure;   // brightness of the flame's glow relative to the room
    float pad1;
};

// One log in the grate, placed from the hardware random seed.
// center.x is a fraction of the firebox width, center.y the height above its floor.
struct LogParams {
    float2 center;
    float halfLen;   // fraction of the firebox width
    float radius;
    float angle;
    float charred;
    float2 pad;
};

struct SimUniforms {
    float2 size;
    float dt;
    float time;
    float seed;
    float frame;
    float layoutAspect;
    float sparkCount;
    float burst;   // 1 right after the fire is stoked, decaying to 0
    float boost;   // 0..1, how hard the fire is being driven while the coil is held
    float sparkBurst;   // like burst, with a slower tail so the shower of sparks trails off
};

struct Spark {
    float2 pos;   // simulation cells
    float2 vel;   // cells per second
    float heat;
    float life;
    float2 pad;
};

struct VOut { float4 position [[position]]; };

vertex VOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

static float2 scenePoint(float2 fragXY, constant Uniforms& u) {
    float2 f = float2(fragXY.x, u.resolution.y - fragXY.y);
    return u.viewCenter + (f - u.resolution * 0.5) / u.resolution.y * u.viewScale;
}

// MARK: noise

static float hash11(float p) { p = fract(p * 0.1031); p *= p + 33.33; p *= p + p; return fract(p); }
static float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
static float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}
static float hash13(float3 p3) {
    p3 = fract(p3 * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return fract((p3.x + p3.y) * p3.z);
}
static float noise2(float2 x) {
    float2 i = floor(x), f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash12(i), b = hash12(i + float2(1, 0)), c = hash12(i + float2(0, 1)), d = hash12(i + float2(1, 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
static float noise3(float3 x) {
    float3 i = floor(x), f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(hash13(i), hash13(i + float3(1, 0, 0)), f.x),
                   mix(hash13(i + float3(0, 1, 0)), hash13(i + float3(1, 1, 0)), f.x), f.y),
               mix(mix(hash13(i + float3(0, 0, 1)), hash13(i + float3(1, 0, 1)), f.x),
                   mix(hash13(i + float3(0, 1, 1)), hash13(i + float3(1, 1, 1)), f.x), f.y), f.z);
}
static float fbm2(float2 p, int octaves) {
    float sum = 0.0, amp = 0.5, norm = 0.0;
    for (int i = 0; i < octaves; i++) {
        sum += amp * noise2(p); norm += amp;
        p = p * 2.03 + float2(17.1, 9.7); amp *= 0.5;
    }
    return sum / norm;
}
// Cellular noise: (distance to nearest point, to second nearest, id of nearest).
static float3 voronoi(float2 x) {
    float2 n = floor(x), f = fract(x);
    float f1 = 8.0, f2 = 8.0, id = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 g = float2(i, j);
            float2 r = g + hash22(n + g) - f;
            float d = dot(r, r);
            if (d < f1) { f2 = f1; f1 = d; id = hash12(n + g); }
            else if (d < f2) { f2 = d; }
        }
    }
    return float3(sqrt(f1), sqrt(f2), id);
}

// MARK: layout

struct Layout {
    float floorTop, sw, sy0, sy1, my0, my1, fw, hw, fy0, fh, archH, archBase, bh, bw;
};

static Layout makeLayout(float aspect) {
    Layout L;
    L.floorTop = 0.13;
    L.sw = min(0.62 * aspect, 1.05);
    L.sy0 = 0.155; L.sy1 = 0.755;
    L.my0 = 0.755; L.my1 = 0.79;
    L.fw = L.sw * 0.56; L.hw = L.fw * 0.5;
    L.fy0 = 0.155; L.fh = 0.372;
    L.archH = L.fh * 0.2;
    L.archBase = L.fy0 + L.fh - L.archH;
    L.bh = 0.04; L.bw = L.bh * 3.0;
    return L;
}

// Roughly the distance to the firebox opening's edge; positive inside.
static float openingSDF(float2 p, Layout L) {
    if (p.y < L.archBase) return min(L.hw - abs(p.x), p.y - L.fy0 + 0.05);
    float2 q = float2(p.x / L.hw, (p.y - L.archBase) / L.archH);
    float lq = max(length(q), 1e-4);
    float grad = length(float2(q.x / L.hw, q.y / L.archH)) / lq;
    return (1.0 - lq) / max(grad, 1e-4);
}

// MARK: materials

struct Surface {
    float3 albedo;
    float4 light;    // firelight from the left, centre, right and tall parts of the fire
    float ember;     // self-glow
    float opening;   // inside the firebox mouth
    float frontLog;  // in front of the flames' roots
    float aux;       // gloss of the hearth and floor below the firebox floor (how much fire they
                     // reflect); above it, the rim-light mask on the logs. The two never overlap.
};

static Surface mixSurface(Surface a, Surface b, float t) {
    Surface s;
    s.albedo = mix(a.albedo, b.albedo, t);
    s.light = mix(a.light, b.light, t);
    s.ember = mix(a.ember, b.ember, t);
    s.opening = mix(a.opening, b.opening, t);
    s.frontLog = mix(a.frontLog, b.frontLog, t);
    s.aux = mix(a.aux, b.aux, t);
    return s;
}

struct BrickSample { float3 albedo; float height; };

static BrickSample brickwork(float2 q, float bw, float bh, float seed, float3 tintA, float3 tintB, bool stagger) {
    float row = floor(q.y / bh);
    float shift = stagger ? fmod(abs(row), 2.0) * 0.5 : 0.0;
    float cx = q.x / bw + shift;
    float col = floor(cx);
    float2 local = float2(fract(cx) * bw, (q.y / bh - row) * bh);
    float2 id = float2(col, row) + seed;
    float mortar = bh * 0.1;
    float jag = (noise2(q * 350.0 + seed) - 0.5) * mortar * 0.6;
    float2 e = min(local, float2(bw, bh) - local);
    float edge = min(e.x, e.y) + jag;
    float face = smoothstep(mortar * 0.3, mortar * 0.8, edge);

    float h1 = hash12(id), h2 = hash12(id + 11.3), h3 = hash12(id + 27.1);
    float3 base = mix(tintA, tintB, h1) * (0.75 + 0.45 * h2);
    if (h3 > 0.9) base *= float3(0.5, 0.45, 0.45);
    float grain = fbm2(q * 150.0 + id * 3.7, 4);
    float mottling = fbm2(q * 35.0 + id * 1.3, 3);
    // Small, sparse pits in a sandy face.
    float pits = smoothstep(0.86, 0.9, noise2(q * 640.0 + id * 9.1));
    float sand = 0.9 + 0.2 * noise2(q * 1400.0 + id * 2.3);
    float3 brick = base * (0.65 + 0.7 * grain) * (0.8 + 0.4 * mottling) * (1.0 - 0.25 * pits) * sand;
    brick *= 0.75 + 0.25 * smoothstep(0.0, mortar * 3.0, edge);
    float3 mortarColor = float3(0.13, 0.115, 0.1) * (0.6 + 0.6 * fbm2(q * 420.0, 2));

    BrickSample s;
    s.albedo = mix(mortarColor, brick, face);
    s.height = face * (0.85 + 0.15 * grain) - pits * 0.08 * face;
    return s;
}

static float3 bumpNormal(float h, float hx, float hy, float eps, float depth) {
    return normalize(float3(-(hx - h) / eps * depth, -(hy - h) / eps * depth, 1.0));
}

static float pointLight(float3 pos, float3 n, float3 lp, float falloff) {
    float3 l = lp - pos;
    float d2 = dot(l, l);
    l *= rsqrt(d2);
    return saturate(dot(n, l)) / (1.0 + falloff * d2);
}

// The fire lights the room as four lamps: left, centre and right just above the
// coals, and a tall one up near the arch for when a tongue reaches that high. The
// bake stores what each lamp contributes; every frame the simulation says how
// bright each part of the fire is, and the four terms are mixed accordingly.
static float3 roomLamp(int i, Layout L) {
    return i < 3 ? float3(float(i - 1) * 0.3 * L.fw, L.fy0 + 0.3 * L.fh, 0.1) : float3(0.0, L.fy0 + 0.75 * L.fh, 0.1);
}

static float4 lights4(float3 pos, float3 n, Layout L, float falloff, float yShift = 0.0) {
    float4 r;
    for (int i = 0; i < 4; i++) {
        float3 lp = roomLamp(i, L);
        lp.y -= yShift;
        r[i] = pointLight(pos, n, lp, falloff);
    }
    return r;
}

// The same lamps seen from inside the firebox.
static float2 interiorLamp(int i, Layout L) {
    return i < 3 ? float2(float(i - 1) * 0.3 * L.fw, L.fy0 + 0.08) : float2(0.0, L.fy0 + 0.75 * L.fh);
}

static float4 interiorLights(float2 p, Layout L) {
    float4 r;
    for (int i = 0; i < 4; i++) {
        float2 d = (p - interiorLamp(i, L)) * float2(1.0, 1.3);
        r[i] = 0.55 / (1.0 + 55.0 * dot(d, d));
    }
    return r;
}

static float capsuleDistance(float2 p, float2 c, float halfLen, float ang, thread float2& local) {
    float cs = cos(ang), sn = sin(ang);
    float2 d = p - c;
    local = float2(d.x * cs + d.y * sn, -d.x * sn + d.y * cs);
    return length(float2(local.x - clamp(local.x, -halfLen, halfLen), local.y));
}

// Shadows the logs throw on the floor: a short march from the point toward each
// of the three low lamps, which sit just above the logs, darkening by how much of
// the path runs through wood. The samples are jittered and the wood's edge is
// soft, so the penumbrae are smooth rather than stepped. The tall lamp is left alone.
static float4 logShadow(float2 p, float lampY, Layout L, constant LogParams* logs) {
    float4 lit = float4(1.0);
    float jitter = hash12(p * 997.0);
    for (int i = 0; i < 3; i++) {
        float2 lamp = float2(float(i - 1) * 0.3 * L.fw, lampY);
        float occluded = 0.0;
        for (int j = 0; j < 12; j++) {
            float2 q = mix(p, lamp, (float(j) + jitter) / 12.0);
            float inside = 0.0;
            for (int k = 0; k < 3; k++) {
                LogParams lg = logs[k];
                float2 local;
                float d = capsuleDistance(q, float2(lg.center.x * L.fw, L.fy0 + lg.center.y), lg.halfLen * L.fw, lg.angle, local);
                inside = max(inside, smoothstep(lg.radius + 0.012, lg.radius - 0.004, d));
            }
            occluded += inside / 12.0;
        }
        lit[i] = 1.0 - 0.55 * saturate(occluded * 1.6);
    }
    return lit;
}

// The pool of light on the floor stops at the jambs, more softly the nearer the
// viewer; a little always gets round them, so the slab's ends are not cut off black.
static float jambPool(float ax, float z, Layout L) {
    return max(0.2, saturate((L.hw + 0.6 * z - ax) / (0.3 * z + 0.02)));
}

static Surface emptySurface() {
    Surface s;
    s.albedo = float3(0.0); s.light = float4(0.0); s.ember = 0.0; s.opening = 0.0; s.frontLog = 0.0; s.aux = 0.0;
    return s;
}

// Brickwork with its bump-map normal.
static BrickSample bumpedBricks(float2 q, float px, float bw, float bh, float seed, float3 ta, float3 tb, bool stagger,
                                thread float3& n) {
    BrickSample b = brickwork(q, bw, bh, seed, ta, tb, stagger);
    float hx = brickwork(q + float2(px, 0), bw, bh, seed, ta, tb, stagger).height;
    float hy = brickwork(q + float2(0, px), bw, bh, seed, ta, tb, stagger).height;
    n = bumpNormal(b.height, hx, hy, px, 0.0028);
    return b;
}

// Bump-mapped brick lit by the fire.
static Surface litBricks(float2 p, float2 q, float px, float bw, float bh, float seed, float3 ta, float3 tb,
                         bool stagger, Layout L, float falloff) {
    float3 n;
    BrickSample b = bumpedBricks(q, px, bw, bh, seed, ta, tb, stagger, n);
    Surface s = emptySurface();
    s.albedo = b.albedo;
    s.light = lights4(float3(p, 0.0), n, L, falloff) * (0.55 + 0.45 * b.height);
    return s;
}

static Surface logSurface(float2 p, float2 c, float halfLen, float r, float ang, float seed,
                          float charred, float px, thread float& coverage) {
    float cs = cos(ang), sn = sin(ang);
    float2 d = p - c;
    float2 l = float2(d.x * cs + d.y * sn, -d.x * sn + d.y * cs);
    float along = clamp(l.x, -halfLen, halfLen);
    float dist = length(float2(l.x - along, l.y));
    // Knobbly silhouette.
    float rr = r * (0.92 + 0.12 * noise2(float2(l.x * 60.0 + seed * 13.0, seed)));
    coverage = smoothstep(rr + px, rr - px, dist);
    Surface s = emptySurface();
    if (coverage <= 0.0) return s;

    float a = clamp(l.y / rr, -1.0, 1.0);
    float nz = sqrt(max(0.0, 1.0 - a * a));
    float bark = fbm2(float2(l.x * 22.0 + seed * 10.0, asin(a) * 5.0), 5);
    // Alligator char: cells stretched along the grain, only some cracks still glowing.
    float3 cells = voronoi(float2(l.x * 30.0 + seed * 7.0, asin(a) * 5.0 + seed * 3.0));
    float crack = 1.0 - smoothstep(0.0, 0.06, cells.y - cells.x);
    // The glow bleeds a little way out of each crack.
    float halo = 0.35 * (1.0 - smoothstep(0.03, 0.2, cells.y - cells.x));
    // Only patches of the char still glow, mostly underneath and in the middle.
    float live = smoothstep(0.55, 0.75, fbm2(float2(l.x * 14.0 + seed * 3.0, a * 2.0 + seed), 3));
    float ash = smoothstep(0.58, 0.72, fbm2(float2(l.x * 14.0, a * 3.0) + seed * 5.0, 4)) * saturate(a + 0.2) * charred;

    float3 wood = mix(float3(0.13, 0.075, 0.04), float3(0.12, 0.07, 0.04), bark);
    float3 charColor = float3(0.018, 0.015, 0.013) * (0.5 + bark) * (1.0 + 0.6 * cells.z);
    float charMix = saturate(charred * 1.3 + (1.0 - a) * 0.35);
    float3 albedo = mix(wood, charColor, charMix);
    albedo = mix(albedo, float3(0.20, 0.19, 0.18) * (0.7 + 0.5 * bark), ash);
    albedo *= 1.0 - crack * 0.5;

    float underside = saturate(-a * 0.8 + 0.25);
    float heat = charMix * (0.45 + 0.55 * noise2(float2(l.x * 9.0 + seed, seed * 2.0)));
    s.albedo = albedo;
    s.light = float4((0.35 + 0.9 * saturate(0.5 + 0.6 * a)) * (0.4 + 0.6 * nz) * 0.33);
    s.ember = saturate((crack + halo) * live * heat * (0.6 + 0.6 * underside) * (1.0 - ash) + underside * underside * heat * 0.6);
    s.opening = 1.0;
    // The silhouette's upper edge, where the flame behind the log rim-lights it.
    s.aux = (1.0 - nz) * (1.0 - nz) * smoothstep(-0.2, 0.5, a);
    return s;
}

static Surface firebox(float2 p, Layout L, float px, constant LogParams* logs, float gseed) {
    float bhw = L.hw * 0.62;
    float by0 = L.fy0 + 0.045;
    float by1 = L.fy0 + L.fh;
    float4 interiorLight = interiorLights(p, L);
    float3 fbA = float3(0.20, 0.13, 0.09), fbB = float3(0.30, 0.20, 0.12);
    float ax = abs(p.x);
    float depthU = saturate((ax - bhw) / (L.hw - bhw));           // 0 at the back, 1 at the mouth
    float floorLine = mix(by0, L.fy0, depthU);

    Surface s = emptySurface();
    if (p.y < floorLine) {
        // Hearth floor inside the firebox: ash, in the shadow of the logs.
        float n = fbm2(p * float2(90.0, 260.0), 4);
        s.albedo = float3(0.10, 0.095, 0.09) * (0.6 + 0.8 * n);
        s.light = interiorLight * 1.1 * logShadow(p, L.fy0 + 0.08, L, logs);
    } else if (ax < bhw && p.y < by1) {
        // Back wall: firebrick right up into the arch, blackened by soot higher up.
        float3 n;
        BrickSample b = bumpedBricks(p * 1.25, px, 0.09, 0.03, 5.0 + gseed, fbA, fbB, true, n);
        float soot = smoothstep(by0, L.fy0 + L.fh * 0.8, p.y) * (0.6 + 0.4 * fbm2(p * 30.0, 4));
        s.albedo = b.albedo * mix(1.0, 0.04, saturate(soot * 1.2));
        // The bumps catch each lamp from its own side.
        float4 bump;
        for (int i = 0; i < 4; i++) {
            float3 l = normalize(float3(interiorLamp(i, L) - p, 0.05));
            bump[i] = saturate(dot(n, l)) / max(1e-3, l.z) * (0.55 + 0.45 * b.height);
        }
        s.light = interiorLight * (0.6 + 0.4 * bump);
    } else if (ax >= bhw) {
        // Side walls in perspective.
        float top = mix(by1, L.archBase + L.archH * 0.3, depthU);
        float v = (p.y - floorLine) / max(top - floorLine, 1e-3);
        float2 q = float2((1.0 - depthU) * 0.22 * sign(p.x), v * 0.26);
        BrickSample b = brickwork(q, 0.09, 0.03, 9.0 + gseed, fbA, fbB, true);
        float soot = smoothstep(0.1, 0.8, v) * (0.5 + 0.5 * fbm2(q * 40.0, 4)) + (1.0 - depthU) * 0.35;
        s.albedo = b.albedo * mix(1.0, 0.1, saturate(soot));
        s.light = interiorLight * (0.9 + 0.3 * depthU) * (0.6 + 0.4 * b.height);
    }

    // Coal bed: dark crusts with the glow coming up through the gaps between them.
    float bedTop = L.fy0 + 0.045 + 0.012 * fbm2(float2(p.x * 40.0, 1.0), 3);
    float bedHalf = L.fw * 0.42;
    float bed = smoothstep(bedTop + 0.003, bedTop - 0.003, p.y) * smoothstep(bedHalf, bedHalf * 0.75, ax) * step(L.fy0 - 0.01, p.y);
    if (bed > 0.0) {
        float3 v = voronoi(float2(p.x * 75.0, (p.y - L.fy0) * 160.0) + gseed);
        float gap = v.y - v.x;
        float chunk = smoothstep(0.0, 0.3, gap);
        float centre = 1.0 - smoothstep(0.0, bedHalf, ax);
        Surface c = emptySurface();
        // Irregular black crusts, a few of them ashed grey, with the glow leaking
        // unevenly up through the gaps between them.
        c.albedo = float3(0.035, 0.03, 0.028) * (0.7 + 0.6 * chunk) + smoothstep(0.7, 0.95, v.z) * (0.03 + 0.05 * v.z);
        c.light = interiorLight * 0.8;
        float hot = (1.0 - chunk) * (1.0 - chunk) * 0.9 + smoothstep(0.3, 0.55, v.x) * 0.4 * step(0.3, v.z);
        hot *= 0.6 + 0.4 * noise2(p * 120.0 + gseed);
        c.ember = saturate(hot * centre * centre * (0.5 + 0.5 * noise2(p * 300.0)));
        s = mixSurface(s, c, bed);
    }

    // Logs, back to front; the first is behind the flames, the rest in front of their roots.
    for (int i = 0; i < 3; i++) {
        LogParams lp = logs[i];
        float cov;
        Surface lg = logSurface(p, float2(lp.center.x * L.fw, L.fy0 + lp.center.y), lp.halfLen * L.fw, lp.radius,
                                lp.angle, float(i + 1) + gseed, lp.charred, px, cov);
        lg.frontLog = i > 0 ? 1.0 : 0.0;
        s = mixSurface(s, lg, cov);
    }

    // Ambient occlusion where the interior meets the mouth.
    s.light *= 0.45 + 0.55 * smoothstep(0.0, 0.03, openingSDF(p, L));
    s.opening = 1.0;
    return s;
}

static Surface scene(float2 p, Layout L, float px, constant LogParams* logs, float gseed) {
    float ax = abs(p.x);
    float halfSurround = L.sw * 0.5;
    float open = openingSDF(p, L);
    float archTop = L.fy0 + L.fh;
    float rimW = L.bh * 1.5;
    float3 brickA = float3(0.30, 0.11, 0.06), brickB = float3(0.42, 0.17, 0.09);

    // Floor and hearth (nearest to the viewer).
    float hearthHalf = halfSurround + 0.035;
    if (p.y < L.fy0 && ax < hearthHalf) {
        float3 stoneN = (p.y > 0.143) ? normalize(float3(0, 1, 0.35)) : float3(0, 0, 1);
        if (p.y >= 0.118) {
            float n = fbm2(p * float2(60.0, 120.0), 5);
            float vein = smoothstep(0.48, 0.5, fbm2(p * 18.0 + 3.0, 4)) * smoothstep(0.52, 0.5, fbm2(p * 18.0 + 3.0, 4));
            float speck = step(0.86, noise2(p * 900.0));
            Surface s = emptySurface();
            s.albedo = float3(0.045, 0.04, 0.038) * (0.6 + 0.8 * n) + vein * 0.03 + speck * 0.04;
            float3 pos = float3(p, p.y > 0.143 ? 0.04 + (0.155 - p.y) * 3.0 : 0.08);
            s.light = lights4(pos, stoneN, L, 8.0) * (p.y > 0.143 ? 0.8 : 0.9);
            // Dark edge where the slab's top meets its front.
            s.light *= 1.0 - 0.6 * smoothstep(0.0025, 0.0, abs(p.y - 0.143));
            s.light *= logShadow(p, L.fy0 + 0.3 * L.fh, L, logs) * jambPool(ax, pos.z, L);
            s.aux = p.y >= 0.143 ? 0.8 : 0.0;   // the polished top mirrors the fire, the front does not
            return s;
        }
    }
    if (p.y < L.floorTop) {
        // Floorboards running toward the viewer.
        float depth = 1.0 / (0.5 - p.y);
        float X = p.x * depth;
        float boardW = 0.22;
        float board = floor(X / boardW);
        float bx = fract(X / boardW);
        float Z = depth * 1.3 + hash11(board * 3.1) * 7.0;
        float endJoint = smoothstep(0.004, 0.0, 0.5 - abs(fract(Z) - 0.5));   // where a board ends
        float seam = smoothstep(0.03, 0.0, min(bx, 1.0 - bx));
        float grain = fbm2(float2(X * 40.0 + board * 7.0, depth * 3.0), 5);
        float figure = fbm2(float2(X * 6.0, depth * 25.0 + board), 3);
        Surface s = emptySurface();
        s.albedo = float3(0.09, 0.045, 0.022) * (0.7 + 0.5 * hash11(board)) * (0.6 + 0.6 * grain) * (0.8 + 0.4 * figure);
        s.albedo *= 1.0 - 0.75 * max(seam, endJoint);
        float3 pos = float3(p.x, 0.0, 0.1 + (L.floorTop - p.y) * 2.5);
        s.light = lights4(pos, float3(0, 1, 0), L, 10.0, L.floorTop - 0.02) * 1.0;
        // Shadow line under the hearth slab.
        s.light *= 0.35 + 0.65 * smoothstep(0.0, 0.02, max(ax - hearthHalf, L.floorTop - 0.012 - p.y));
        s.light *= logShadow(p, L.fy0 + 0.3 * L.fh, L, logs) * jambPool(ax, pos.z, L);
        // Varnish: the boards reflect too, less where the grain is rough and not across the seams.
        s.aux = 0.25 * (0.7 + 0.6 * grain) * (1.0 - 0.6 * max(seam, endJoint));
        return s;
    }

    // Firebox.
    if (open > 0.0) {
        Surface s = firebox(p, L, px, logs, gseed);
        if (open < px * 2.0) {
            Surface rim = litBricks(p, p, px, L.bw, L.bh, 2.0 + gseed, brickA * 0.6, brickB * 0.6, true, L, 10.0);
            s = mixSurface(rim, s, smoothstep(0.0, px * 2.0, open));
        }
        return s;
    }

    // Brick surround, with a header course framing the opening.
    if (ax < halfSurround && p.y < L.sy1 && p.y >= L.sy0) {
        Surface s;
        if (-open < rimW) {
            float2 q;
            float across = -open;
            if (p.y < L.archBase) {
                q = float2(p.y - L.fy0, across);
            } else {
                float2 e = float2(ax / L.hw, (p.y - L.archBase) / L.archH);
                float theta = atan2(e.y, e.x);
                q = float2(L.archBase - L.fy0 + theta * L.hw * 0.75, across);
            }
            s = litBricks(p, q, px, L.bh * 1.05, rimW, 4.0 + gseed, brickA * 0.8, brickB * 0.8, false, L, 10.0);
        } else {
            s = litBricks(p, p + float2(0.0, -L.sy0), px, L.bw, L.bh, 1.0 + gseed, brickA, brickB, true, L, 10.0);
        }
        // Soot licking up from the mouth.
        float soot = smoothstep(L.hw * 1.05, L.hw * 0.2, ax) * smoothstep(archTop + 0.17, archTop - 0.02, p.y) *
                     step(L.archBase, p.y) * (0.55 + 0.45 * fbm2(p * 25.0, 4));
        s.albedo *= 1.0 - 0.8 * saturate(soot);
        // The mantel shades the top courses a little.
        s.light *= 0.75 + 0.25 * smoothstep(L.sy1, L.sy1 - 0.05, p.y);
        return s;
    }

    // Mantel shelf.
    float mantelHalf = halfSurround + 0.04;
    float underside = L.my0 - 0.009;
    if (ax < mantelHalf && p.y >= underside && p.y < L.my1) {
        float grain = fbm2(float2(p.x * 7.0, p.y * 140.0 + fbm2(p * float2(3.0, 40.0), 3) * 3.0), 5);
        float pores = noise2(float2(p.x * 300.0, p.y * 1500.0));
        Surface s = emptySurface();
        s.albedo = mix(float3(0.05, 0.022, 0.01), float3(0.12, 0.06, 0.028), grain) * (0.85 + 0.3 * pores);
        // The shelf's front leans a little toward the fire below it.
        float3 n = p.y < L.my0 ? normalize(float3(0, -1, 0.25)) : normalize(float3(0, -0.3, 1));
        // Rounded front edge picks up a highlight.
        float edgeTop = smoothstep(L.my1 - 0.006, L.my1, p.y);
        n = normalize(n + float3(0, edgeTop * 0.8, 0));
        s.light = lights4(float3(p, 0.06), n, L, 6.0) * (p.y < L.my0 ? 0.4 : 1.4);
        float endFade = smoothstep(mantelHalf, mantelHalf - 0.003, ax);
        s.light *= endFade;
        return s;
    }

    // Chimney breast above the mantel, in the mantel's shadow.
    float chimneyHalf = L.sw * 0.42;
    if (ax < chimneyHalf && p.y >= L.my1) {
        Surface s = litBricks(p, p + float2(0.0, -L.my1), px, L.bw, L.bh, 7.0 + gseed, brickA * 0.85, brickB * 0.85, true, L, 10.0);
        float shade = 0.12 + 0.1 * smoothstep(L.my1 + 0.25, L.my1, p.y);
        s.light *= shade;
        return s;
    }

    // Baseboard.
    if (p.y < L.floorTop + 0.028) {
        Surface s = emptySurface();
        float bevel = smoothstep(L.floorTop + 0.022, L.floorTop + 0.028, p.y);
        s.albedo = float3(0.22, 0.2, 0.17);
        float3 n = normalize(float3(0, bevel * 0.9, 1));
        s.light = lights4(float3(p, 0.01), n, L, 8.0);
        s.light *= 1.0 - 0.5 * smoothstep(L.floorTop + 0.004, L.floorTop, p.y);
        return s;
    }

    // Plaster wall.
    float n = fbm2(p * 60.0, 3);
    float hx = fbm2((p + float2(px, 0)) * 60.0, 3), hy = fbm2((p + float2(0, px)) * 60.0, 3);
    float3 nrm = bumpNormal(n, hx, hy, px, 0.0006);
    Surface s = emptySurface();
    s.albedo = float3(0.09, 0.075, 0.062) * (0.85 + 0.3 * fbm2(p * 8.0, 3));
    s.light = lights4(float3(p, 0.0), nrm, L, 5.0);
    // Contact shadows beside the surround and chimney.
    float side = ax - (p.y < L.my1 ? (p.y >= underside ? mantelHalf : halfSurround) : chimneyHalf);
    s.light *= 0.4 + 0.6 * smoothstep(0.0, 0.03, side);
    return s;
}

struct SceneOut {
    float4 albedo [[color(0)]];
    float4 masks [[color(1)]];   // ember, opening, frontLog, aux (see Surface)
    float4 lamps [[color(2)]];   // the four lamp terms, square-rooted to fit 8 bits
};

fragment SceneOut sceneFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                constant LogParams* logs [[buffer(1)]]) {
    Layout L = makeLayout(u.layoutAspect);
    float px = u.viewScale / u.resolution.y;
    // 2x2 supersampling: this pass only runs once, so spend the time on clean edges.
    Surface acc = emptySurface();
    for (int i = 0; i < 4; i++) {
        float2 o = float2(float(i & 1), float(i >> 1)) * 0.5 - 0.25;
        Surface s = scene(scenePoint(in.position.xy + o, u), L, px, logs, u.seed);
        acc.albedo += s.albedo * 0.25; acc.light += s.light * 0.25; acc.ember += s.ember * 0.25;
        acc.opening += s.opening * 0.25; acc.frontLog += s.frontLog * 0.25; acc.aux += s.aux * 0.25;
    }
    SceneOut o;
    o.albedo = float4(acc.albedo, 1.0);
    o.masks = float4(saturate(acc.ember), acc.opening, acc.frontLog, acc.aux);
    o.lamps = sqrt(saturate(acc.light * 0.25));
    return o;
}

// MARK: fire physics
//
// A 2D incompressible fluid over the firebox, stepped on the GPU: MacCormack
// semi-Lagrangian advection, Boussinesq buoyancy, vorticity confinement, curl-noise
// turbulence and a Jacobi pressure projection. The state texture holds
// (temperature, fuel gas, soot, local speed); the speed is only there for the
// renderer. Hot wood releases fuel gas unevenly; once the gas is hot enough it
// burns, releasing heat and soot, and everything cools by convection and T^4 radiation.

constexpr sampler simSampler(coord::pixel, filter::linear, address::clamp_to_edge);

// The simulation covers the firebox mouth with square cells. Velocities are in
// cells per second, so every constant written in cells (for 256 across) is scaled
// by cellScale when the grid is finer.
static float cellScale(float2 size) { return size.x / 256.0; }
static float2 simOrigin(Layout L) { return float2(-L.hw, L.fy0 - 0.01); }
static float2 simToScene(float2 cell, float2 size, Layout L) { return simOrigin(L) + cell / size.x * L.fw; }
static float2 sceneToSim(float2 p, float2 size, Layout L) { return (p - simOrigin(L)) / L.fw * size.x; }

static bool inGrid(uint2 gid, float2 size) { return gid.x < uint(size.x) && gid.y < uint(size.y); }

kernel void clearTexture(texture2d<float, access::write> t [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x < t.get_width() && gid.y < t.get_height()) t.write(float4(0.0), gid);
}

kernel void advectVelocity(texture2d<float, access::sample> vel [[texture(0)]],
                           texture2d<float, access::write> outVel [[texture(1)]],
                           constant SimUniforms& s [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (!inGrid(gid, s.size)) return;
    float2 pos = float2(gid) + 0.5;
    float2 v = vel.read(gid).xy;
    // Second-order back-trace: the velocity halfway along the path is what carried the cell here.
    float2 vm = vel.sample(simSampler, pos - 0.5 * s.dt * v).xy;
    float2 nv = vel.sample(simSampler, pos - s.dt * vm).xy;
    outVel.write(float4(nv, 0.0, 0.0), gid);
}

kernel void advectState(texture2d<float, access::sample> state [[texture(0)]],
                        texture2d<float, access::sample> vel [[texture(1)]],
                        texture2d<float, access::write> outState [[texture(2)]],
                        constant SimUniforms& s [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (!inGrid(gid, s.size)) return;
    float2 pos = float2(gid) + 0.5;
    float2 v = vel.read(gid).xy;
    float2 vm = vel.sample(simSampler, pos - 0.5 * s.dt * v).xy;
    outState.write(state.sample(simSampler, pos - s.dt * vm), gid);
}

// MacCormack advection: trace forward, trace back again, and use the round-trip
// error to cancel most of the first-order smearing. Clamped to the values the
// back-traced point was interpolated from, so it can't overshoot or ring.
kernel void advectBack(texture2d<float, access::sample> fwd [[texture(0)]],
                       texture2d<float, access::sample> vel [[texture(1)]],
                       texture2d<float, access::write> out [[texture(2)]],
                       constant SimUniforms& s [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (!inGrid(gid, s.size)) return;
    float2 pos = float2(gid) + 0.5;
    float2 v = vel.read(gid).xy;
    float2 vm = vel.sample(simSampler, pos + 0.5 * s.dt * v).xy;
    out.write(fwd.sample(simSampler, pos + s.dt * vm), gid);
}

kernel void macCormack(texture2d<float, access::read> orig [[texture(0)]],
                       texture2d<float, access::read> fwd [[texture(1)]],
                       texture2d<float, access::read> back [[texture(2)]],
                       texture2d<float, access::sample> vel [[texture(3)]],
                       texture2d<float, access::write> out [[texture(4)]],
                       constant SimUniforms& s [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (!inGrid(gid, s.size)) return;
    float2 pos = float2(gid) + 0.5;
    float2 v = vel.read(gid).xy;
    float4 corrected = fwd.read(gid) + 0.5 * (orig.read(gid) - back.read(gid));
    float2 vm = vel.sample(simSampler, pos - 0.5 * s.dt * v).xy;
    int2 i0 = int2(floor(pos - s.dt * vm - 0.5));
    int2 mx = int2(s.size) - 1;
    float4 lo = float4(1e9), hi = float4(-1e9);
    for (int j = 0; j < 2; j++) for (int i = 0; i < 2; i++) {
        float4 q = orig.read(uint2(clamp(i0 + int2(i, j), int2(0), mx)));
        lo = min(lo, q); hi = max(hi, q);
    }
    out.write(clamp(corrected, lo, hi), gid);
}

kernel void react(texture2d<float, access::read> stateIn [[texture(0)]],
                  texture2d<float, access::write> stateOut [[texture(1)]],
                  texture2d<float, access::read> vel [[texture(2)]],
                  constant SimUniforms& s [[buffer(0)]], constant LogParams* logs [[buffer(1)]],
                  uint2 gid [[thread_position_in_grid]]) {
    if (!inGrid(gid, s.size)) return;
    Layout L = makeLayout(s.layoutAspect);
    float2 p = simToScene(float2(gid) + 0.5, s.size, L);
    float4 st = stateIn.read(gid);
    // A touch of diffusion: MacCormack keeps edges so sharp that without it the
    // plume grows a comb of parallel filaments, more so the harder the fire is driven.
    int2 g = int2(gid), mx = int2(s.size) - 1;
    float4 avg = 0.25 * (stateIn.read(uint2(clamp(g - int2(1, 0), int2(0), mx))) + stateIn.read(uint2(clamp(g + int2(1, 0), int2(0), mx)))
                       + stateIn.read(uint2(clamp(g - int2(0, 1), int2(0), mx))) + stateIn.read(uint2(clamp(g + int2(0, 1), int2(0), mx))));
    st = mix(st, avg, 0.04 + 0.03 * s.boost);
    float T = st.x, fuel = st.y, soot = st.z;

    // Pyrolysis: hot wood gives off fuel gas, mostly from its upper surface.
    float source = 0.0;
    for (int i = 0; i < 3; i++) {
        LogParams lg = logs[i];
        float2 local;
        float d = capsuleDistance(p, float2(lg.center.x * L.fw, L.fy0 + lg.center.y), lg.halfLen * L.fw, lg.angle, local);
        float shell = smoothstep(lg.radius + 0.012, lg.radius + 0.002, d) * smoothstep(lg.radius * 0.4, lg.radius * 0.9, d);
        float upper = smoothstep(-0.5, 0.3, local.y / lg.radius);
        source = max(source, shell * upper * (0.4 + 0.6 * lg.charred));
    }
    float bed = smoothstep(L.fy0 + 0.04, L.fy0 + 0.022, p.y) * smoothstep(L.fw * 0.36, L.fw * 0.18, abs(p.x));
    source = max(source, bed * 0.55);

    // Wood doesn't outgas evenly: hot spots wander over it.
    float t = s.time;
    float spots = smoothstep(0.35, 0.75, noise3(float3(p * 65.0 + s.seed, t * 1.6)));
    float surge = 0.7 + 0.6 * noise3(float3(p * 20.0 + s.seed * 1.7, t * 0.6));
    // Gas comes off in puffs a couple of times a second, which is what makes the
    // flame pulse rather than stream; a driven fire puffs faster and harder.
    float puff = 1.0 + (0.28 + 0.25 * s.burst + 0.2 * s.boost) * sin(6.2832 * (2.4 + 0.6 * s.boost) * t + p.x * 14.0 + s.seed);
    // Stoking the fire stirs up the wood, and the coil drives it: it outgasses much harder.
    float release = source * spots * surge * puff * (1.0 + 2.5 * s.burst + 1.0 * s.boost);
    fuel += s.dt * 6.0 * release;
    T = max(T, source * (0.6 + 0.2 * s.boost + 0.2 * s.burst));  // the glowing wood ignites its own gas

    // Combustion above the ignition temperature. Burning makes soot, and soot is
    // what glows: hot gas on its own is nearly invisible.
    float ignite = smoothstep(0.2, 0.35, T);
    float burn = fuel * min(1.0, 8.0 * s.dt) * ignite;
    fuel -= burn;
    T += burn * 2.2;
    soot += burn * 1.2;

    // Cooling: mixing with room air, plus radiation going as T^4. Soot oxidises
    // fastest where it's hottest, which is what gives flames their tips.
    T -= s.dt * (0.9 * T + 1.0 * T * T * T * T);
    soot *= exp(-s.dt * (0.8 + 3.2 * T));
    fuel *= exp(-1.6 * s.dt);
    // The local speed rides along in the fourth channel so the embers can feel the draught.
    stateOut.write(float4(max(T, 0.0), max(fuel, 0.0), max(soot, 0.0), length(vel.read(gid).xy)), gid);
}

// Boundaries: solid floor and side walls; at the top, open only through the
// throat in the middle, where the chimney draws the smoke away.
static bool inThroat(int x, int2 size) { return abs(float(x) + 0.5 - float(size.x) * 0.5) < float(size.x) * 0.3; }

static float2 velAt(texture2d<float, access::read> v, int2 g, int2 size) {
    if (g.x < 0 || g.x >= size.x || g.y < 0) return float2(0.0);
    if (g.y >= size.y) g.y = size.y - 1;
    return v.read(uint2(g)).xy;
}

kernel void curl(texture2d<float, access::read> vel [[texture(0)]],
                 texture2d<float, access::write> outCurl [[texture(1)]],
                 constant SimUniforms& s [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (!inGrid(gid, s.size)) return;
    int2 g = int2(gid), n = int2(s.size);
    float w = 0.5 * ((velAt(vel, g + int2(1, 0), n).y - velAt(vel, g - int2(1, 0), n).y)
                   - (velAt(vel, g + int2(0, 1), n).x - velAt(vel, g - int2(0, 1), n).x));
    outCurl.write(float4(w, 0.0, 0.0, 0.0), gid);
}

// Curl noise: the gradient of a scalar noise field, turned through a right angle,
// is a divergence-free swirl of small eddies.
static float2 curlNoise(float2 q, float seed, float time) {
    float e = 0.004;
    float3 o = float3(seed, seed, time * 2.0);
    float dy = noise3(float3((q + float2(0.0, e)) * 25.0, 0.0) + o) - noise3(float3((q - float2(0.0, e)) * 25.0, 0.0) + o);
    float dx = noise3(float3((q + float2(e, 0.0)) * 25.0, 0.0) + o) - noise3(float3((q - float2(e, 0.0)) * 25.0, 0.0) + o);
    return float2(dy, -dx) / (2.0 * e);
}

kernel void applyForces(texture2d<float, access::read> vel [[texture(0)]],
                        texture2d<float, access::read> state [[texture(1)]],
                        texture2d<float, access::read> curlTex [[texture(2)]],
                        texture2d<float, access::write> outVel [[texture(3)]],
                        constant SimUniforms& s [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (!inGrid(gid, s.size)) return;
    int2 g = int2(gid);
    uint2 mx = uint2(s.size) - 1;
    float r = cellScale(s.size);
    float2 v = vel.read(gid).xy;
    float4 st = state.read(gid);

    // Boussinesq buoyancy: hot gas rises, soot drags it down slightly. A driven
    // fire burns hotter, so it lifts harder.
    v.y += s.dt * r * (1100.0 * (1.0 + 0.2 * s.boost) * st.x - 150.0 * st.z);

    // Vorticity confinement puts back the swirls that numerical diffusion smooths
    // away; a little less of it when the fire is driven, or the plume rolls up into
    // the tidy spiral pairs that give a 2D fluid away.
    float wl = abs(curlTex.read(uint2(clamp(g - int2(1, 0), int2(0), int2(mx)))).x);
    float wr = abs(curlTex.read(uint2(clamp(g + int2(1, 0), int2(0), int2(mx)))).x);
    float wb = abs(curlTex.read(uint2(clamp(g - int2(0, 1), int2(0), int2(mx)))).x);
    float wt = abs(curlTex.read(uint2(clamp(g + int2(0, 1), int2(0), int2(mx)))).x);
    float wc = curlTex.read(gid).x;
    float2 grad = 0.5 * float2(wr - wl, wt - wb);
    float2 nrm = grad / (length(grad) + 0.5);   // no confinement force in still air
    v += s.dt * (18.0 * (1.0 - 0.25 * s.boost) / r) * float2(nrm.y, -nrm.x) * wc;

    // Turbulence the grid is too coarse to grow on its own: curl-noise eddies about
    // ten cells across, decorrelating every half second, stirring only the gas that
    // is hot enough to burn. Three times stronger while the fire is stoked or driven,
    // which is what makes a driven flame roil.
    Layout L = makeLayout(s.layoutAspect);
    float2 q = simToScene(float2(gid) + 0.5, s.size, L);
    v += s.dt * 60.0 * r * (1.0 + 2.0 * s.burst + 1.2 * s.boost) * curlNoise(q, s.seed, s.time) * saturate(st.x * 2.0 - 0.4);

    // A little viscosity, which also keeps the collocated grid free of checkerboarding.
    float2 avg = 0.25 * (vel.read(uint2(clamp(g - int2(1, 0), int2(0), int2(mx)))).xy
                       + vel.read(uint2(clamp(g + int2(1, 0), int2(0), int2(mx)))).xy
                       + vel.read(uint2(clamp(g - int2(0, 1), int2(0), int2(mx)))).xy
                       + vel.read(uint2(clamp(g + int2(0, 1), int2(0), int2(mx)))).xy);
    // Drag standing in for the air a real plume entrains out of the third dimension:
    // momentum lasts about a second, so no box-sized vortex can build up and drag
    // the flame onto a wall. A driven fire keeps its momentum a little longer and reaches higher.
    v = mix(v, avg, 0.12 + 0.04 * (r - 1.0)) * exp(-(1.0 - 0.25 * s.boost) * s.dt);
    outVel.write(float4(v, 0.0, 0.0), gid);
}

kernel void divergence(texture2d<float, access::read> vel [[texture(0)]],
                       texture2d<float, access::write> outDiv [[texture(1)]],
                       constant SimUniforms& s [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (!inGrid(gid, s.size)) return;
    int2 g = int2(gid), n = int2(s.size);
    float d = 0.5 * ((velAt(vel, g + int2(1, 0), n).x - velAt(vel, g - int2(1, 0), n).x)
                   + (velAt(vel, g + int2(0, 1), n).y - velAt(vel, g - int2(0, 1), n).y));
    // Room air drawn in through the open front of the fireplace. A 2D slice can't
    // show that inflow directly, so it appears as a gentle mass source low down,
    // which the pressure solve then has to send up the chimney.
    d -= 2.5 * (1.0 - smoothstep(0.1, 0.35, (float(gid.y) + 0.5) / s.size.y));
    outDiv.write(float4(d, 0.0, 0.0, 0.0), gid);
}

static float pressureAt(texture2d<float, access::read> p, int2 g, int2 size, float centre) {
    if (g.x < 0 || g.x >= size.x || g.y < 0) return centre;         // walls and floor
    if (g.y >= size.y) return inThroat(g.x, size) ? 0.0 : centre;   // chimney throat or lintel
    return p.read(uint2(g)).x;
}

kernel void jacobi(texture2d<float, access::read> pressure [[texture(0)]],
                   texture2d<float, access::read> div [[texture(1)]],
                   texture2d<float, access::write> outPressure [[texture(2)]],
                   constant SimUniforms& s [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (!inGrid(gid, s.size)) return;
    int2 g = int2(gid), n = int2(s.size);
    float c = pressure.read(gid).x;
    float sum = pressureAt(pressure, g + int2(1, 0), n, c) + pressureAt(pressure, g - int2(1, 0), n, c)
              + pressureAt(pressure, g + int2(0, 1), n, c) + pressureAt(pressure, g - int2(0, 1), n, c);
    outPressure.write(float4((sum - div.read(gid).x) * 0.25, 0.0, 0.0, 0.0), gid);
}

kernel void project(texture2d<float, access::read> vel [[texture(0)]],
                    texture2d<float, access::read> pressure [[texture(1)]],
                    texture2d<float, access::write> outVel [[texture(2)]],
                    constant SimUniforms& s [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (!inGrid(gid, s.size)) return;
    int2 g = int2(gid), n = int2(s.size);
    float c = pressure.read(gid).x;
    float2 grad = 0.5 * float2(pressureAt(pressure, g + int2(1, 0), n, c) - pressureAt(pressure, g - int2(1, 0), n, c),
                               pressureAt(pressure, g + int2(0, 1), n, c) - pressureAt(pressure, g - int2(0, 1), n, c));
    float2 v = vel.read(gid).xy - grad;
    // Nothing can run away: cap the speed well above anything the tamed fire reaches.
    float cap = 900.0 * cellScale(s.size);
    float sp = length(v);
    if (sp > cap) v *= cap / sp;
    if (g.x == 0 || g.x == n.x - 1) v.x = 0.0;
    if (g.y == 0 || (g.y == n.y - 1 && !inThroat(g.x, n))) v.y = 0.0;
    if (g.y == n.y - 1) v.y = max(v.y, 0.0);   // the chimney only ever draws out
    if (g.y == 0) v = float2(0.0);
    outVel.write(float4(v, 0.0, 0.0), gid);
}

// Sparks: glowing flecks of char thrown off the logs. They ride the flow closely,
// keep burning while they are inside the flame, cool within a second or two once
// they leave it, and fall back under gravity.
kernel void updateSparks(device Spark* sparks [[buffer(0)]], constant SimUniforms& s [[buffer(1)]],
                         constant LogParams* logs [[buffer(2)]], texture2d<float, access::sample> vel [[texture(0)]],
                         texture2d<float, access::sample> state [[texture(1)]], uint id [[thread_position_in_grid]]) {
    if (id >= uint(s.sparkCount)) return;
    Spark sp = sparks[id];
    Layout L = makeLayout(s.layoutAspect);
    float r = cellScale(s.size);
    if (sp.life <= 0.0) {
        float2 h = float2(float(id) * 1.37 + s.seed, s.frame);
        if (hash12(h) < 0.0005 + 0.03 * s.sparkBurst + 0.02 * s.boost) {
            LogParams lg = logs[min(2, int(hash12(h + 3.1) * 3.0))];
            float along = (hash12(h + 5.7) - 0.5) * 1.6 * lg.halfLen * L.fw;
            float2 c = float2(lg.center.x * L.fw, L.fy0 + lg.center.y);
            float cs = cos(lg.angle), sn = sin(lg.angle);
            float2 onTop = c + float2(along * cs - lg.radius * sn, along * sn + lg.radius * cs);
            sp.pos = sceneToSim(onTop, s.size, L);
            float kick = 1.0 + 1.5 * s.burst + 0.5 * s.boost;
            sp.vel = float2((hash12(h + 7.3) - 0.5) * 60.0, 20.0 + hash12(h + 8.9) * 70.0) * kick * r;
            sp.heat = 0.7 + 0.5 * hash12(h + 9.4);
            sp.life = 0.6 + 2.0 * hash12(h + 11.2);
        }
    } else {
        float2 flow = vel.sample(simSampler, sp.pos).xy;
        float Tl = state.sample(simSampler, sp.pos).x;
        sp.vel += (flow - sp.vel) * min(1.0, s.dt * 10.0);
        sp.vel.y -= 600.0 * r * s.dt;
        sp.pos += sp.vel * s.dt;
        sp.heat = clamp(sp.heat + s.dt * (1.5 * Tl - 1.2), 0.0, 1.4);
        sp.life -= s.dt;
        float2 p = simToScene(sp.pos, s.size, L);
        if (sp.heat <= 0.0 || sp.pos.x < 0.0 || sp.pos.x > s.size.x || sp.pos.y < 0.0 || p.y > L.archBase + L.archH * 0.5) {
            sp.life = 0.0;
        }
    }
    sparks[id] = sp;
}

// MARK: drawing

// Planck's law fitted to sRGB (Tanner Helland's approximation), returned in linear RGB.
static float3 blackbody(float kelvin) {
    float t = kelvin / 100.0;
    float r = t <= 66.0 ? 1.0 : saturate(1.292936186 * pow(t - 60.0, -0.1332047592));
    float g = t <= 66.0 ? saturate(0.3900815788 * log(t) - 0.6318414438)
                        : saturate(1.129890861 * pow(t - 60.0, -0.0755148492));
    float b = t >= 66.0 ? 1.0 : (t <= 19.0 ? 0.0 : saturate(0.5432067891 * log(t - 10.0) - 1.19625408914));
    return pow(float3(r, g, b), 2.2);
}

// Simulation temperature to kelvin, and how bright a black body at that temperature
// looks: Wien's law in the visible band (an effective 0.9 um), relative to 1700 K.
// Visible light grows far faster than the total T^4 radiation, which is why the
// cool tips of a flame are a faint translucent red while the roots blaze.
static float kelvinFor(float T) { return 600.0 + 1100.0 * T; }
static float radiance(float kelvin) { return exp(9.0 * (1.0 - 1700.0 / kelvin)); }

// Hot soot radiating as a black body; thin wisps stay thin (optical depth 2.5 per unit soot).
static float3 fireEmission(float4 st, float exposure) {
    float k = kelvinFor(st.x);
    return blackbody(k) * radiance(k) * exposure * (1.0 - exp(-2.5 * st.z));
}

// The eye adapts to the firelight: balanced for a 3000 K lamp, brick reads as
// terracotta rather than blood red.
static float3 whiteBalance(float3 col) { return col * float3(0.55, 1.21, 3.4); }

static float3 aces(float3 x) {
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

// How much visible light each of the four parts of the fire (left, centre, right,
// tall) gives off right now: the radiance of the hot soot integrated over the
// whole firebox on a 32x32 grid, once per frame. The radiance of an averaged
// temperature would be the wrong thing to take (it is so convex that a tongue
// drifting across a single tap changes it fifty-fold, and the whole room pumps
// with it); the integral changes only as fast as the flame's bright area does.
struct FireLight {
    float4 bands;   // left, centre, right, tall
    float4 smooth;  // the same, relaxed over the last few frames
};

static float bandHat(float x, float centre) { return max(0.0, 1.0 - abs(x - centre) / 0.25); }

kernel void fireLight(texture2d<float> fire [[texture(0)]], device FireLight* out [[buffer(0)]],
                      constant Uniforms& u [[buffer(1)]], uint tid [[thread_index_in_threadgroup]]) {
    constexpr sampler smp(filter::linear, mip_filter::linear, address::clamp_to_edge);
    threadgroup float4 part[512];
    float lod = 2.5 + log2(cellScale(u.simSize));
    float4 e = float4(0.0);
    for (int k = 0; k < 2; k++) {
        float2 uv = (float2(float(tid & 31), float(tid >> 5) + 16.0 * float(k)) + 0.5) / 32.0;
        float4 st = fire.sample(smp, uv, level(lod));
        float r = radiance(kelvinFor(st.x)) * (1.0 - exp(-2.5 * st.z));
        float tall = smoothstep(0.4, 0.75, uv.y);
        e += r * float4(bandHat(uv.x, 0.25) * (1.0 - tall), bandHat(uv.x, 0.5) * (1.0 - tall),
                        bandHat(uv.x, 0.75) * (1.0 - tall), tall);
    }
    part[tid] = e;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid == 0) {
        float4 sum = float4(0.0);
        for (int i = 0; i < 512; i++) sum += part[i];
        sum /= 1024.0;
        FireLight prev = out[0];
        out[0].bands = sum;
        // A short memory: firelight flickers, but not frame by frame.
        out[0].smooth = any(prev.smooth > 0.0) ? mix(prev.smooth, sum, 0.35) : sum;
    }
}

// The room light's strength and how it is split between the four lamps.
static float lampStrength(float4 e, thread float4& w) {
    float total = e.x + e.y + e.z + e.w;
    w = e / (total + 1e-5);
    // A calm fire integrates to about 0.1, a driven one to 0.3-0.6.
    return total / (0.1 + total);
}

// The glow of the coals: breathing slowly in patches, and flaring wherever a gust
// of hot gas passes over them, the way embers brighten when the fire is blown on.
static float3 emberGlow(float4 st, bool inFire, float2 p, float time, float seed, float strength, float cells) {
    float gust = inFire ? smoothstep(40.0 * cells, 250.0 * cells, st.w) : 0.0;
    float slow = 0.5 + 0.5 * noise3(float3(p * 55.0, time * 0.8) + seed);
    float g = saturate(0.25 + 0.45 * slow + 0.5 * gust + 0.4 * saturate(st.x * 1.5)) * (0.4 + 0.6 * strength);
    return blackbody(900.0 + 400.0 * g) * (0.3 + 2.2 * g * g);
}

fragment float4 frameFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]], constant FireLight& light [[buffer(1)]],
                              texture2d<float> scene0 [[texture(0)]], texture2d<float> scene1 [[texture(1)]],
                              texture2d<float> fire [[texture(2)]], texture2d<float> scene2 [[texture(3)]],
                              texture2d<float> glow [[texture(4)]], texture2d<float> glowWide [[texture(5)]]) {
    constexpr sampler smp(filter::linear, mip_filter::linear, address::clamp_to_edge);
    Layout L = makeLayout(u.layoutAspect);
    float2 p = scenePoint(in.position.xy, u);
    float2 uv = in.position.xy / u.resolution;
    float4 masks = scene1.sample(smp, uv);
    float opening = masks.g;
    // The mip levels sampled below are written for a 256-wide grid.
    float cells = cellScale(u.simSize);
    float lodBias = log2(cells);

    float2 cell = sceneToSim(p, u.simSize, L);
    float2 fireUV = cell / u.simSize;
    bool inFire = opening > 0.0 && all(fireUV > 0.0) && all(fireUV < 1.0);
    float4 st0 = inFire ? fire.sample(smp, fireUV, level(0.0)) : float4(0.0);

    // The room is lit by the fire as four lamps (see roomLamp and fireLight). The
    // baked lamp terms are mixed in proportion to how much light each part of the
    // fire gives off right now, so the light swings toward whichever side the
    // flame leans and climbs the arch when a tongue is tall.
    float4 e = light.smooth;
    float4 w;
    float strength = lampStrength(e, w);

    // Heat haze: hot air bends the light passing through it, most where the gas
    // is hot and clear (above the tips), less through the sooty flame itself, and
    // it spills up over the lintel when a tall tongue sends hot air that way.
    float heat = inFire ? saturate(st0.x * 2.0) * (1.0 - 0.6 * saturate(st0.z * 3.0)) : 0.0;
    float archTop = L.fy0 + L.fh;
    float spill = smoothstep(L.hw * 1.2, L.hw * 0.6, abs(p.x)) * smoothstep(archTop + 0.14, archTop, p.y)
                * step(archTop - 0.02, p.y) * e.w * 40.0;
    float2 warpPx = float2(0.0);
    if (max(heat, spill) > 0.0) {
        float2 hz = float2(noise3(float3(p.x * 70.0, p.y * 35.0 - u.time * 3.0, u.time * 0.7) + u.seed),
                           noise3(float3(p.x * 70.0 + 9.0, p.y * 35.0 - u.time * 3.0, u.time * 0.7 + 5.0) + u.seed)) - 0.5;
        warpPx = hz * 0.004 * max(heat, spill) * u.resolution.y / u.viewScale * float2(1.0, 0.6);
    }
    float2 warpUV = warpPx / u.resolution;

    // Sub-cell detail: the simulation's cells are three pixels wide, so the lookup
    // is jittered by noise that scrolls up at about the flame's rise speed, only
    // where there is soot. The thin, clear far side of the flame also wobbles with
    // the haze, like the bricks behind it.
    float4 st = st0;
    if (inFire) {
        float3 q = float3(p.x * 150.0, p.y * 150.0 - u.time * 45.0, u.time * 1.3) + u.seed;
        float2 jit = (float2(noise3(q), noise3(q + 19.3)) - 0.5) * 1.8 * saturate(st0.z * 3.0);
        float2 warpCells = warpPx * float2(1.0, -1.0) * (u.viewScale / u.resolution.y) * (u.simSize.x / L.fw);
        float2 jcell = cell + jit + 0.5 * warpCells * (1.0 - smoothstep(0.02, 0.08, st0.z));
        st = fire.sample(smp, jcell / u.simSize, level(0.0));
    }

    float4 base = scene0.sample(smp, uv + warpUV);
    float4 lamps = scene2.sample(smp, uv + warpUV);
    lamps = lamps * lamps * 4.0;
    // Dim, warm ambient (warm after the white balance below, so a neutral grey
    // before it) so the far corners of the room are not simply black.
    float3 ambient = float3(0.36, 0.13, 0.03);
    float3 col = base.rgb * (ambient + blackbody(2500.0) * strength * 13.5 * dot(lamps, w));

    // The fire mirrored in the polished hearth and the varnished boards. The slab
    // mirrors about the firebox floor, so it shows the roots and the coals, sharply;
    // the boards mirror about the floor line, stretching the flame's body down
    // toward the viewer and blurring it the nearer it comes. The mirrored masks cut
    // the reflection where the front logs would hide it and let the embers reflect.
    if (p.y < L.fy0 && masks.a > 0.0) {
        bool slab = p.y >= 0.143;
        float mirrorY = slab ? L.fy0 : L.floorTop;
        float stretch = slab ? 6.0 : 2.4;
        float2 m = float2(p.x, mirrorY + (mirrorY - p.y) * stretch);
        float2 muv = sceneToSim(m, u.simSize, L) / u.simSize;
        float lod = (slab ? 1.5 : 2.5 + (L.floorTop - p.y) * 15.0) + lodBias;
        float4 ms = all(muv > 0.0) && all(muv < 1.0) ? fire.sample(smp, muv, level(lod)) : float4(0.0);
        float2 f = (m - u.viewCenter) * u.resolution.y / u.viewScale + u.resolution * 0.5;
        float4 mm = scene1.sample(smp, float2(f.x, u.resolution.y - f.y) / u.resolution);
        float3 refl = fireEmission(ms, u.exposure) * mm.g * (1.0 - 0.7 * mm.b) + mm.r * blackbody(1150.0) * 0.8;
        float fresnel = slab ? 0.6 : 0.25 + 0.6 * smoothstep(0.0, L.floorTop, p.y);
        col += refl * masks.a * fresnel * (slab ? 0.1 : 0.15) * smoothstep(L.hw + 0.05, L.hw - 0.05, abs(p.x));
    }

    col += masks.r * emberGlow(st, inFire, p, u.time, u.seed, strength, cells);

    if (inFire) {
        // The inside of the firebox is lit by whatever burns in front of it, so the
        // back wall and the bark glow orange beside a tongue and stay dark elsewhere.
        // The glare is compressed so that the roots don't bleach the wood white.
        float3 nearby = fireEmission(fire.sample(smp, fireUV, level(2.5 + lodBias)), u.exposure);
        col += base.rgb * nearby * (0.25 / (1.0 + 0.8 * dot(nearby, float3(0.2126, 0.7152, 0.0722)))) * opening;
        // The front logs' tops catch the flame rising just behind them.
        float3 above = fireEmission(fire.sample(smp, fireUV + float2(0.0, 0.025 / L.fw * u.simSize.x / u.simSize.y), level(1.0 + lodBias)), u.exposure);
        col += masks.b * masks.a * above * (0.3 / (1.0 + 0.3 * dot(above, float3(0.2126, 0.7152, 0.0722))));
        // Hot soot radiates as a black body; cool soot is smoke, which blocks the
        // view and scatters a little firelight. The front logs are opaque.
        float3 emitted = fireEmission(st, u.exposure);
        float tau = st.z * (1.0 - saturate(st.x * 2.5)) * 1.0;
        float hidden = masks.b * 0.97;
        col = col * exp(-tau) + blackbody(2500.0) * strength * 0.2 * (1.0 - exp(-tau)) * opening + emitted * opening * (1.0 - hidden);
    }

    // Bloom: the glare of the brightest parts spilling over their surroundings,
    // at two scales (see glowFragment).
    col += 0.25 * glow.sample(smp, uv).rgb + 0.15 * glowWide.sample(smp, uv).rgb;

    // Photographic grade: white balance, the brightest highlights rolled off to
    // white the way film does, a gentle vignette, then tone-mapping.
    col = whiteBalance(col);
    float lum = dot(col, float3(0.2126, 0.7152, 0.0722));
    col = mix(col, float3(lum), 0.9 * smoothstep(0.5, 4.0, lum));
    float2 vq = uv - float2(0.5, 0.55);
    col *= 1.0 - 0.45 * smoothstep(0.25, 0.75, dot(vq, vq));
    col = aces(col);
    // Dither at the size of the local sRGB step, so the shadows don't speckle.
    col += (hash12(in.position.xy + fract(u.time * 7.0) * 113.0) - 0.5) * (2.3 / 255.0) * pow(max(col, 1e-4), 0.58);
    return float4(col, 1.0);
}

// MARK: bloom

// The emissive parts of the picture on their own, drawn at an eighth of the
// resolution: the flame, the embers and (drawn after this) the sparks. Blurred at
// two scales and added back, they become the glare a camera or an eye sees
// around anything this bright. Only what is really bright gets in, so dull red
// tips and smoke stay crisp.
fragment float4 glowFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]], constant FireLight& light [[buffer(1)]],
                             texture2d<float> scene1 [[texture(1)]], texture2d<float> fire [[texture(2)]]) {
    constexpr sampler smp(filter::linear, mip_filter::linear, address::clamp_to_edge);
    Layout L = makeLayout(u.layoutAspect);
    float2 p = scenePoint(in.position.xy, u);
    float2 uv = in.position.xy / u.resolution;
    float4 masks = scene1.sample(smp, uv);
    float2 fireUV = sceneToSim(p, u.simSize, L) / u.simSize;
    bool inFire = masks.g > 0.0 && all(fireUV > 0.0) && all(fireUV < 1.0);
    float cells = cellScale(u.simSize);
    float4 st = inFire ? fire.sample(smp, fireUV, level(1.0 + log2(cells))) : float4(0.0);
    float4 w;
    float strength = lampStrength(light.smooth, w);
    float3 e = fireEmission(st, u.exposure) * masks.g * (1.0 - 0.97 * masks.b)
             + masks.r * emberGlow(st, inFire, p, u.time, u.seed, strength, cells);
    e *= smoothstep(0.3, 1.5, dot(e, float3(0.2126, 0.7152, 0.0722)));
    return float4(e, 1.0);
}

struct BlurParams {
    float2 dir;          // one blur direction, in source texels
    float2 targetSize;
};

constant float blurWeights[9] = {0.028, 0.067, 0.124, 0.179, 0.204, 0.179, 0.124, 0.067, 0.028};

// One direction of a separable Gaussian, sigma two taps wide.
fragment float4 blurFragment(VOut in [[stage_in]], constant BlurParams& b [[buffer(0)]],
                             texture2d<float> src [[texture(0)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float2 uv = in.position.xy / b.targetSize;
    float2 step = b.dir / float2(src.get_width(), src.get_height());
    float3 acc = float3(0.0);
    for (int i = 0; i < 9; i++) acc += blurWeights[i] * src.sample(smp, uv + step * float(i - 4)).rgb;
    return float4(acc, 1.0);
}

struct SparkOut {
    float4 position [[position]];
    float size [[point_size]];
    float heat;
    float twinkle;
    float2 dir;      // direction of travel on screen
    float stretch;   // how far the motion blur stretches the sprite along it
};

vertex SparkOut sparkVertex(uint vid [[vertex_id]], const device Spark* sparks [[buffer(0)]],
                            constant Uniforms& u [[buffer(1)]]) {
    Spark sp = sparks[vid];
    Layout L = makeLayout(u.layoutAspect);
    float2 p = simToScene(sp.pos, u.simSize, L);
    SparkOut o;
    o.position = sp.life > 0.0 ? float4(2.0 * (p - u.viewCenter) * u.resolution.y / (u.viewScale * u.resolution), 0.0, 1.0)
                               : float4(-10.0, -10.0, 0.0, 1.0);
    // A spark moving fast smears into a streak over the frame, in the direction it
    // travels; hot sparks are bigger and they shrink as they cool.
    float2 vs = sp.vel / u.simSize.x * L.fw * u.resolution.y / u.viewScale;   // pixels per second
    float len = length(vs) / 30.0;
    float size = max(2.0, (0.002 + 0.005 * saturate(sp.heat)) * u.resolution.y / u.viewScale);
    o.stretch = clamp(1.0 + len / size, 1.0, 4.0);
    o.size = sp.life > 0.0 ? size * o.stretch : 0.0;
    o.dir = length(vs) > 1.0 ? normalize(vs) * float2(1.0, -1.0) : float2(1.0, 0.0);   // point_coord y points down
    o.heat = sp.heat;
    // Burning sparks tumble, so their brightness flickers frame to frame.
    o.twinkle = 0.45 + 1.1 * hash12(float2(float(vid) * 7.13, floor(u.time * 24.0)));
    return o;
}

static float3 sparkColor(SparkOut in, float2 pc) {
    float2 q = (pc - 0.5) * 2.0;
    float along = dot(q, in.dir);
    float across = dot(q, float2(-in.dir.y, in.dir.x)) * in.stretch;
    float d = length(float2(along, across));
    float tail = 1.0 - 0.5 * saturate(-along);   // brighter at the head of the streak
    float glow = exp(-d * d * 7.0);
    float k = 1100.0 + 700.0 * saturate(in.heat);
    return blackbody(k) * radiance(k) * glow * tail * (in.heat < 0.5 ? in.twinkle : 1.0);
}

fragment float4 sparkFragment(SparkOut in [[stage_in]], float2 pc [[point_coord]]) {
    // Drawn onto the graded frame, so graded the same way, and blended as the
    // brighter of the two (a spark in front of the flame is no brighter than the
    // flame) rather than added, so it is never clipped to a flat lemon pill; the
    // bloom pass carries its halo.
    return float4(aces(whiteBalance(sparkColor(in, pc))), 0.0);
}

// The sparks' contribution to the bloom, in linear light.
fragment float4 sparkGlowFragment(SparkOut in [[stage_in]], float2 pc [[point_coord]]) {
    return float4(sparkColor(in, pc) * 1.5, 0.0);
}
"""#
