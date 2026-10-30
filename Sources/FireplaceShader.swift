// Metal source for the fireplace, compiled at runtime so the app builds with
// just the Command Line Tools.
//
// sceneFragment bakes everything that doesn't move (brick, wood, stone, ash) once
// per size: linear albedo, how much firelight each pixel receives, and masks for
// embers, the firebox mouth and the front logs. The fire itself is a fluid
// simulation (see "fire physics"), and frameFragment draws its black-body glow
// over the baked scene every frame, lighting the room by the fire's heat.
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
    float2 pad;
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
    float pad;
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
static float fbm3(float3 p, int octaves) {
    float sum = 0.0, amp = 0.5, norm = 0.0;
    for (int i = 0; i < octaves; i++) {
        sum += amp * noise3(p); norm += amp;
        p = p * 2.02 + float3(17.1, 9.7, 3.3); amp *= 0.5;
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
    float light;     // firelight this point receives (before flicker)
    float ember;     // self-glow
    float opening;   // inside the firebox mouth
    float frontLog;  // in front of the flames' roots
};

static Surface mixSurface(Surface a, Surface b, float t) {
    Surface s;
    s.albedo = mix(a.albedo, b.albedo, t);
    s.light = mix(a.light, b.light, t);
    s.ember = mix(a.ember, b.ember, t);
    s.opening = mix(a.opening, b.opening, t);
    s.frontLog = mix(a.frontLog, b.frontLog, t);
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
    float jag = (noise2(q * 700.0 + seed) - 0.5) * mortar * 0.6;
    float2 e = min(local, float2(bw, bh) - local);
    float edge = min(e.x, e.y) + jag;
    float face = smoothstep(mortar * 0.3, mortar * 0.8, edge);

    float h1 = hash12(id), h2 = hash12(id + 11.3), h3 = hash12(id + 27.1);
    float3 base = mix(tintA, tintB, h1) * (0.75 + 0.45 * h2);
    if (h3 > 0.9) base *= float3(0.5, 0.45, 0.45);
    float grain = fbm2(q * 150.0 + id * 3.7, 4);
    float mottling = fbm2(q * 35.0 + id * 1.3, 3);
    float pits = smoothstep(0.74, 0.8, noise2(q * 650.0 + id * 9.1));
    float3 brick = base * (0.65 + 0.7 * grain) * (0.8 + 0.4 * mottling) * (1.0 - 0.4 * pits);
    brick *= 0.75 + 0.25 * smoothstep(0.0, mortar * 3.0, edge);
    float3 mortarColor = float3(0.13, 0.115, 0.1) * (0.6 + 0.6 * fbm2(q * 420.0, 3));

    BrickSample s;
    s.albedo = mix(mortarColor, brick, face);
    s.height = face * (0.85 + 0.15 * grain) - pits * 0.15 * face;
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

static Surface emptySurface() {
    Surface s;
    s.albedo = float3(0.0); s.light = 0.0; s.ember = 0.0; s.opening = 0.0; s.frontLog = 0.0;
    return s;
}

// Bump-mapped brick lit by the fire.
static Surface litBricks(float2 p, float2 q, float px, float bw, float bh, float seed, float3 ta, float3 tb,
                         bool stagger, float3 lp, float falloff) {
    BrickSample b = brickwork(q, bw, bh, seed, ta, tb, stagger);
    float hx = brickwork(q + float2(px, 0), bw, bh, seed, ta, tb, stagger).height;
    float hy = brickwork(q + float2(0, px), bw, bh, seed, ta, tb, stagger).height;
    float3 n = bumpNormal(b.height, hx, hy, px, 0.0028);
    Surface s = emptySurface();
    s.albedo = b.albedo;
    s.light = pointLight(float3(p, 0.0), n, lp, falloff) * (0.55 + 0.45 * b.height);
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
    float3 cells = voronoi(float2(l.x * 38.0 + seed * 7.0, asin(a) * 7.0 + seed * 3.0));
    float crack = 1.0 - smoothstep(0.0, 0.045, cells.y - cells.x);
    float live = smoothstep(0.35, 0.7, noise2(float2(l.x * 18.0 + seed * 3.0, a * 2.0 + seed)));
    float ash = smoothstep(0.6, 0.75, fbm2(float2(l.x * 14.0, a * 3.0) + seed * 5.0, 4)) * saturate(a + 0.2) * charred * 0.7;

    float3 wood = mix(float3(0.07, 0.04, 0.022), float3(0.12, 0.07, 0.04), bark);
    float3 charColor = float3(0.018, 0.015, 0.013) * (0.5 + bark) * (1.0 + 0.6 * cells.z);
    float charMix = saturate(charred + (1.0 - a) * 0.35);
    float3 albedo = mix(wood, charColor, charMix);
    albedo = mix(albedo, float3(0.32, 0.30, 0.28) * (0.7 + 0.5 * bark), ash);
    albedo *= 1.0 - crack * 0.5;

    float underside = saturate(-a * 0.8 + 0.25);
    float heat = charMix * (0.45 + 0.55 * noise2(float2(l.x * 9.0 + seed, seed * 2.0)));
    s.albedo = albedo;
    s.light = (0.35 + 0.9 * saturate(0.5 + 0.6 * a)) * (0.4 + 0.6 * nz) * 0.9;
    s.ember = saturate(crack * live * heat * (0.6 + 0.6 * underside) * (1.0 - ash) + underside * underside * heat * 0.3);
    s.opening = 1.0;
    return s;
}

static Surface firebox(float2 p, Layout L, float px, constant LogParams* logs, float gseed) {
    float bhw = L.hw * 0.62;
    float by0 = L.fy0 + 0.045;
    float by1 = L.fy0 + L.fh * 0.74;
    float2 fire = float2(0.0, L.fy0 + 0.08);
    float d = length((p - fire) * float2(1.0, 1.3));
    float interiorLight = 1.5 / (1.0 + 55.0 * d * d);
    float3 fbA = float3(0.17, 0.09, 0.05), fbB = float3(0.26, 0.15, 0.08);
    float ax = abs(p.x);
    float depthU = saturate((ax - bhw) / (L.hw - bhw));           // 0 at the back, 1 at the mouth
    float floorLine = mix(by0, L.fy0, depthU);

    Surface s = emptySurface();
    if (p.y < floorLine) {
        // Hearth floor inside the firebox: ash.
        float n = fbm2(p * float2(90.0, 260.0), 4);
        s.albedo = float3(0.10, 0.095, 0.09) * (0.6 + 0.8 * n);
        s.light = interiorLight * 1.1;
    } else if (ax < bhw && p.y < by1) {
        // Back wall: firebrick, blackened higher up.
        Surface b = litBricks(p, p * 1.25, px, 0.09, 0.03, 5.0 + gseed, fbA, fbB, true, float3(fire, 0.05), 40.0);
        float soot = smoothstep(by0, by1 - 0.03, p.y) * (0.55 + 0.45 * fbm2(p * 30.0, 4));
        s.albedo = b.albedo * mix(1.0, 0.1, saturate(soot * 1.2));
        s.light = interiorLight * (0.6 + 0.4 * b.light / max(1e-3, pointLight(float3(p, 0.0), float3(0, 0, 1), float3(fire, 0.05), 40.0)));
    } else if (ax >= bhw) {
        // Side walls in perspective.
        float top = mix(by1, L.archBase + L.archH * 0.3, depthU);
        float v = (p.y - floorLine) / max(top - floorLine, 1e-3);
        float2 q = float2((1.0 - depthU) * 0.22 * sign(p.x), v * 0.26);
        BrickSample b = brickwork(q, 0.09, 0.03, 9.0 + gseed, fbA, fbB, true);
        float soot = smoothstep(0.1, 0.8, v) * (0.5 + 0.5 * fbm2(q * 40.0, 4)) + (1.0 - depthU) * 0.2;
        s.albedo = b.albedo * mix(1.0, 0.1, saturate(soot));
        s.light = interiorLight * (0.9 + 0.3 * depthU) * (0.6 + 0.4 * b.height);
    } else {
        // Throat into the chimney: black.
        s.albedo = float3(0.01, 0.008, 0.007) * (0.6 + 0.8 * fbm2(p * 50.0, 3));
        s.light = interiorLight * 0.3 * smoothstep(by1 + 0.1, by1, p.y);
    }

    // Glowing coal bed.
    float bedTop = L.fy0 + 0.028 + 0.012 * fbm2(float2(p.x * 40.0, 1.0), 3);
    float bedHalf = L.fw * 0.36;
    float bed = smoothstep(bedTop + 0.003, bedTop - 0.003, p.y) * smoothstep(bedHalf, bedHalf * 0.75, ax) * step(L.fy0 - 0.01, p.y);
    if (bed > 0.0) {
        float3 v = voronoi(float2(p.x * 110.0, (p.y - L.fy0) * 230.0) + gseed);
        float gap = v.y - v.x;
        float chunk = smoothstep(0.02, 0.18, gap);
        float centre = 1.0 - smoothstep(0.0, bedHalf, ax);
        Surface c = emptySurface();
        c.albedo = mix(float3(0.02, 0.018, 0.016), float3(0.22, 0.21, 0.2), step(0.78, v.z)) * (0.6 + 0.4 * chunk);
        c.light = interiorLight * 0.8;
        float hot = (1.0 - chunk) * 0.7 * step(0.3, v.z) + step(v.z, 0.25) * chunk * (1.0 - v.x) * 0.6;
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
    float3 lp = float3(0.0, L.fy0 + L.fh * 0.3, 0.1);
    float ax = abs(p.x);
    float halfSurround = L.sw * 0.5;
    float open = openingSDF(p, L);
    float archTop = L.fy0 + L.fh;
    float rimW = L.bh * 1.5;
    float3 brickA = float3(0.2, 0.055, 0.03), brickB = float3(0.32, 0.1, 0.05);

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
            s.light = pointLight(pos, stoneN, lp, 8.0) * (p.y > 0.143 ? 2.2 : 0.9);
            // Dark edge where the slab's top meets its front.
            s.light *= 1.0 - 0.6 * smoothstep(0.0025, 0.0, abs(p.y - 0.143));
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
        float endJoint = smoothstep(0.004, 0.0, abs(fract(Z) - 0.5) - 0.497);
        float seam = smoothstep(0.03, 0.0, min(bx, 1.0 - bx));
        float grain = fbm2(float2(X * 40.0 + board * 7.0, depth * 3.0), 5);
        float figure = fbm2(float2(X * 6.0, depth * 25.0 + board), 3);
        Surface s = emptySurface();
        s.albedo = float3(0.09, 0.045, 0.022) * (0.7 + 0.5 * hash11(board)) * (0.6 + 0.6 * grain) * (0.8 + 0.4 * figure);
        s.albedo *= 1.0 - 0.75 * max(seam, endJoint);
        float3 pos = float3(p.x, 0.0, 0.1 + (L.floorTop - p.y) * 2.5);
        float3 lpf = float3(lp.x, lp.y - L.floorTop + 0.02, lp.z);
        s.light = pointLight(pos, float3(0, 1, 0), lpf, 10.0) * 2.6;
        // Shadow line under the hearth slab.
        s.light *= 0.35 + 0.65 * smoothstep(0.0, 0.02, max(ax - hearthHalf, L.floorTop - 0.012 - p.y));
        return s;
    }

    // Firebox.
    if (open > 0.0) {
        Surface s = firebox(p, L, px, logs, gseed);
        if (open < px * 2.0) {
            Surface rim = litBricks(p, p, px, L.bw, L.bh, 2.0 + gseed, brickA * 0.6, brickB * 0.6, true, lp, 10.0);
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
            s = litBricks(p, q, px, L.bh * 1.05, rimW, 4.0 + gseed, brickA * 0.8, brickB * 0.8, false, lp, 10.0);
        } else {
            s = litBricks(p, p + float2(0.0, -L.sy0), px, L.bw, L.bh, 1.0 + gseed, brickA, brickB, true, lp, 10.0);
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
        float3 n = p.y < L.my0 ? normalize(float3(0, -1, 0.25)) : float3(0, 0, 1);
        // Rounded front edge picks up a highlight.
        float edgeTop = smoothstep(L.my1 - 0.006, L.my1, p.y);
        n = normalize(n + float3(0, edgeTop * 0.8, 0));
        s.light = pointLight(float3(p, 0.06), n, lp, 6.0) * (p.y < L.my0 ? 2.4 : 1.4);
        float endFade = smoothstep(mantelHalf, mantelHalf - 0.003, ax);
        s.light *= endFade;
        return s;
    }

    // Chimney breast above the mantel, in the mantel's shadow.
    float chimneyHalf = L.sw * 0.42;
    if (ax < chimneyHalf && p.y >= L.my1) {
        Surface s = litBricks(p, p + float2(0.0, -L.my1), px, L.bw, L.bh, 7.0 + gseed, brickA * 0.85, brickB * 0.85, true, lp, 10.0);
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
        s.light = pointLight(float3(p, 0.01), n, lp, 8.0);
        s.light *= 1.0 - 0.5 * smoothstep(L.floorTop + 0.004, L.floorTop, p.y);
        return s;
    }

    // Plaster wall.
    float n = fbm2(p * 60.0, 5);
    float hx = fbm2((p + float2(px, 0)) * 60.0, 5), hy = fbm2((p + float2(0, px)) * 60.0, 5);
    float3 nrm = bumpNormal(n, hx, hy, px, 0.0006);
    Surface s = emptySurface();
    s.albedo = float3(0.09, 0.075, 0.062) * (0.85 + 0.3 * fbm2(p * 8.0, 3));
    s.light = pointLight(float3(p, 0.0), nrm, lp, 5.0);
    // Contact shadows beside the surround and chimney.
    float side = ax - (p.y < L.my1 ? (p.y >= underside ? mantelHalf : halfSurround) : chimneyHalf);
    s.light *= 0.4 + 0.6 * smoothstep(0.0, 0.03, side);
    return s;
}

struct SceneOut {
    float4 albedoLight [[color(0)]];
    float4 masks [[color(1)]];
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
        acc.opening += s.opening * 0.25; acc.frontLog += s.frontLog * 0.25;
    }
    SceneOut o;
    o.albedoLight = float4(acc.albedo, acc.light);
    o.masks = float4(saturate(acc.ember), acc.opening, acc.frontLog, 1.0);
    return o;
}

// MARK: fire physics
//
// A 2D incompressible fluid over the firebox, stepped on the GPU: semi-Lagrangian
// advection, Boussinesq buoyancy, vorticity confinement and a Jacobi pressure
// projection. The state texture holds (temperature, fuel gas, soot). Hot wood
// releases fuel gas unevenly; once the gas is hot enough it burns, releasing heat
// and soot, and everything cools by convection and T^4 radiation.

constexpr sampler simSampler(coord::pixel, filter::linear, address::clamp_to_edge);

// The simulation covers the firebox mouth with square cells.
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
    float2 nv = vel.sample(simSampler, pos - s.dt * v).xy;
    outVel.write(float4(nv, 0.0, 0.0), gid);
}

kernel void advectState(texture2d<float, access::sample> state [[texture(0)]],
                        texture2d<float, access::read> vel [[texture(1)]],
                        texture2d<float, access::write> outState [[texture(2)]],
                        constant SimUniforms& s [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (!inGrid(gid, s.size)) return;
    float2 pos = float2(gid) + 0.5;
    float2 v = vel.read(gid).xy;
    outState.write(state.sample(simSampler, pos - s.dt * v), gid);
}

static float capsuleDistance(float2 p, float2 c, float halfLen, float ang, thread float2& local) {
    float cs = cos(ang), sn = sin(ang);
    float2 d = p - c;
    local = float2(d.x * cs + d.y * sn, -d.x * sn + d.y * cs);
    return length(float2(local.x - clamp(local.x, -halfLen, halfLen), local.y));
}

kernel void react(texture2d<float, access::read> stateIn [[texture(0)]],
                  texture2d<float, access::write> stateOut [[texture(1)]],
                  constant SimUniforms& s [[buffer(0)]], constant LogParams* logs [[buffer(1)]],
                  uint2 gid [[thread_position_in_grid]]) {
    if (!inGrid(gid, s.size)) return;
    Layout L = makeLayout(s.layoutAspect);
    float2 p = simToScene(float2(gid) + 0.5, s.size, L);
    float4 st = stateIn.read(gid);
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
    float t = fmod(s.time, 4000.0);
    float spots = smoothstep(0.35, 0.75, noise3(float3(p * 65.0 + s.seed, t * 1.6)));
    float surge = 0.45 + noise3(float3(p * 8.0 + s.seed * 1.7, t * 0.35));
    // Stoking the fire stirs up the wood: it outgasses much harder for a moment.
    float release = source * spots * surge * (1.0 + 2.5 * s.burst);
    fuel += s.dt * 6.0 * release;
    T = max(T, source * 0.6);                    // the glowing wood ignites its own gas

    // Combustion above the ignition temperature. Burning makes soot, and soot is
    // what glows: hot gas on its own is nearly invisible.
    float ignite = smoothstep(0.2, 0.35, T);
    float burn = fuel * min(1.0, 5.0 * s.dt) * ignite;
    fuel -= burn;
    T += burn * 2.6;
    soot += burn * 1.2;

    // Cooling: mixing with room air, plus radiation going as T^4. Soot oxidises
    // fastest where it's hottest, which is what gives flames their tips.
    T -= s.dt * (1.5 * T + 0.6 * T * T * T * T);
    soot *= exp(-s.dt * (0.8 + 3.2 * T));
    fuel *= exp(-1.6 * s.dt);
    stateOut.write(float4(max(T, 0.0), max(fuel, 0.0), max(soot, 0.0), 0.0), gid);
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

kernel void applyForces(texture2d<float, access::read> vel [[texture(0)]],
                        texture2d<float, access::read> state [[texture(1)]],
                        texture2d<float, access::read> curlTex [[texture(2)]],
                        texture2d<float, access::write> outVel [[texture(3)]],
                        constant SimUniforms& s [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (!inGrid(gid, s.size)) return;
    int2 g = int2(gid);
    uint2 mx = uint2(s.size) - 1;
    float2 v = vel.read(gid).xy;
    float4 st = state.read(gid);

    // Boussinesq buoyancy: hot gas rises, soot drags it down slightly.
    v.y += s.dt * (1100.0 * st.x - 150.0 * st.z);

    // Vorticity confinement puts back the swirls that numerical diffusion smooths away.
    float wl = abs(curlTex.read(uint2(clamp(g - int2(1, 0), int2(0), int2(mx)))).x);
    float wr = abs(curlTex.read(uint2(clamp(g + int2(1, 0), int2(0), int2(mx)))).x);
    float wb = abs(curlTex.read(uint2(clamp(g - int2(0, 1), int2(0), int2(mx)))).x);
    float wt = abs(curlTex.read(uint2(clamp(g + int2(0, 1), int2(0), int2(mx)))).x);
    float wc = curlTex.read(gid).x;
    float2 grad = 0.5 * float2(wr - wl, wt - wb);
    float2 nrm = grad / (length(grad) + 0.5);   // no confinement force in still air
    v += s.dt * 28.0 * float2(nrm.y, -nrm.x) * wc;

    // A little viscosity, which also keeps the collocated grid free of checkerboarding.
    float2 avg = 0.25 * (vel.read(uint2(clamp(g - int2(1, 0), int2(0), int2(mx)))).xy
                       + vel.read(uint2(clamp(g + int2(1, 0), int2(0), int2(mx)))).xy
                       + vel.read(uint2(clamp(g - int2(0, 1), int2(0), int2(mx)))).xy
                       + vel.read(uint2(clamp(g + int2(0, 1), int2(0), int2(mx)))).xy);
    v = mix(v, avg, 0.12) * exp(-0.2 * s.dt);
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
    if (g.x == 0 || g.x == n.x - 1) v.x = 0.0;
    if (g.y == 0 || (g.y == n.y - 1 && !inThroat(g.x, n))) v.y = 0.0;
    if (g.y == 0) v = float2(0.0);
    outVel.write(float4(v, 0.0, 0.0), gid);
}

// Sparks: heavy glowing particles thrown off the logs, dragged along by the flow.
kernel void updateSparks(device Spark* sparks [[buffer(0)]], constant SimUniforms& s [[buffer(1)]],
                         constant LogParams* logs [[buffer(2)]], texture2d<float, access::sample> vel [[texture(0)]],
                         uint id [[thread_position_in_grid]]) {
    if (id >= uint(s.sparkCount)) return;
    Spark sp = sparks[id];
    Layout L = makeLayout(s.layoutAspect);
    if (sp.life <= 0.0) {
        float2 h = float2(float(id) * 1.37 + s.seed, s.frame);
        if (hash12(h) < 0.0015 + 0.06 * s.burst * s.burst) {
            LogParams lg = logs[min(2, int(hash12(h + 3.1) * 3.0))];
            float along = (hash12(h + 5.7) - 0.5) * 1.6 * lg.halfLen * L.fw;
            float2 c = float2(lg.center.x * L.fw, L.fy0 + lg.center.y);
            float cs = cos(lg.angle), sn = sin(lg.angle);
            float2 onTop = c + float2(along * cs - lg.radius * sn, along * sn + lg.radius * cs);
            sp.pos = sceneToSim(onTop, s.size, L);
            float kick = 1.0 + 2.2 * s.burst;
            sp.vel = float2((hash12(h + 7.3) - 0.5) * 80.0 * kick, (60.0 + hash12(h + 8.9) * 160.0) * kick);
            sp.heat = 0.7 + 0.5 * hash12(h + 9.4) + 0.4 * s.burst;
            sp.life = 1.0 + 2.5 * hash12(h + 11.2);
        }
    } else {
        float2 flow = vel.sample(simSampler, sp.pos).xy;
        sp.vel += (flow - sp.vel) * min(1.0, s.dt * 3.0);
        sp.vel.y -= 90.0 * s.dt;
        sp.pos += sp.vel * s.dt;
        sp.heat -= s.dt * 0.4;
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

// Simulation temperature to kelvin, and Stefan-Boltzmann brightness relative to 1700 K.
static float kelvinFor(float T) { return 500.0 + 1150.0 * T; }
static float radiance(float kelvin) { float k = kelvin / 1700.0; return k * k * k * k; }

static float3 aces(float3 x) {
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

fragment float4 frameFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                              texture2d<float> scene0 [[texture(0)]], texture2d<float> scene1 [[texture(1)]],
                              texture2d<float> fire [[texture(2)]]) {
    constexpr sampler smp(filter::linear, mip_filter::linear, address::clamp_to_edge);
    Layout L = makeLayout(u.layoutAspect);
    float2 p = scenePoint(in.position.xy, u);
    float2 uv = in.position.xy / u.resolution;
    float4 masks = scene1.sample(smp, uv);
    float opening = masks.g;

    float2 cell = sceneToSim(p, u.simSize, L);
    float2 fireUV = cell / u.simSize;
    bool inFire = opening > 0.0 && all(fireUV > 0.0) && all(fireUV < 1.0);
    float4 st = inFire ? fire.sample(smp, fireUV, level(0.0)) : float4(0.0);

    // Heat shimmer: hot air bends the light passing through it.
    float2 warpUV = float2(0.0);
    if (inFire) {
        float n = noise3(float3(p.x * 70.0, p.y * 35.0 - u.time * 3.0, u.time * 0.7) + u.seed) - 0.5;
        warpUV.x = n * 0.004 * saturate(st.x * 2.0) * u.resolution.y / (u.viewScale * u.resolution.x);
    }
    float4 base = scene0.sample(smp, uv + warpUV);

    // The room is lit by the whole fire: its mean temperature sets the light's strength and colour.
    float meanT = fire.sample(smp, float2(0.5), level(16.0)).x;
    float strength = saturate(meanT / 0.05) * 0.75 + 0.25 * saturate(meanT / 0.02);
    float3 fireLight = blackbody(1500.0 + 300.0 * strength) * strength;
    float wobble = 0.9 + 0.2 * noise3(float3(p.x * 2.5, p.y * 2.0, u.time * 2.0) + u.seed);
    float3 ambient = float3(0.006, 0.007, 0.011);
    float3 col = base.rgb * (ambient + fireLight * wobble * base.a * 3.0);

    float breathe = 0.5 + 0.5 * noise3(float3(p * 55.0, u.time * 0.8) + u.seed);
    col += masks.r * blackbody(1000.0 + 250.0 * breathe) * (0.4 + 1.4 * breathe) * (0.5 + 0.5 * strength);

    if (inFire) {
        // Hot soot radiates as a black body; cool soot is smoke that blocks the view.
        float k = kelvinFor(st.x);
        float emissivity = 1.0 - exp(-st.z * 5.0);
        float3 emitted = blackbody(k) * radiance(k) * 2.4 * emissivity;
        float smoke = st.z * (1.0 - saturate(st.x * 2.5));
        float hidden = masks.b * 0.85;
        col = col * exp(-smoke * 1.5) + emitted * opening * (1.0 - hidden);
    }

    float2 vq = uv - float2(0.5, 0.55);
    col *= 1.0 - smoothstep(0.15, 0.6, dot(vq, vq));
    col = aces(col);
    col += (hash12(in.position.xy + fract(u.time * 7.0) * 113.0) - 0.5) * (1.5 / 255.0);
    return float4(col, 1.0);
}

struct SparkOut {
    float4 position [[position]];
    float size [[point_size]];
    float heat;
    float twinkle;
};

vertex SparkOut sparkVertex(uint vid [[vertex_id]], const device Spark* sparks [[buffer(0)]],
                            constant Uniforms& u [[buffer(1)]]) {
    Spark sp = sparks[vid];
    Layout L = makeLayout(u.layoutAspect);
    float2 p = simToScene(sp.pos, u.simSize, L);
    SparkOut o;
    o.position = sp.life > 0.0 ? float4(2.0 * (p - u.viewCenter) * u.resolution.y / (u.viewScale * u.resolution), 0.0, 1.0)
                               : float4(-10.0, -10.0, 0.0, 1.0);
    // Fresh, hot sparks are bigger; they shrink as they cool.
    o.size = sp.life > 0.0 ? max(2.0, (0.003 + 0.004 * saturate(sp.heat)) * u.resolution.y / u.viewScale) : 0.0;
    o.heat = sp.heat;
    // Burning sparks tumble, so their brightness flickers frame to frame.
    o.twinkle = 0.45 + 1.1 * hash12(float2(float(vid) * 7.13, floor(u.time * 24.0)));
    return o;
}

fragment float4 sparkFragment(SparkOut in [[stage_in]], float2 pc [[point_coord]]) {
    float d = length(pc - 0.5) * 2.0;
    float glow = exp(-d * d * 7.0);
    float k = 900.0 + 900.0 * saturate(in.heat);
    float core = exp(-d * d * 30.0);   // white-hot centre
    return float4((blackbody(k) * glow * (0.5 + 1.8 * in.heat * in.heat) + core * saturate(in.heat - 0.6)) * in.twinkle, 0.0);
}
"""#
