// ─────────────────────────────────────────────────────────────
//  Metal shaders
//  passes: key-light shadow map · top-down height map (contact AO)
//          · scene (floor, seeds, bubbles, knife; MSAA) · jelly back-face depth
//          · jelly (refraction/absorption; MSAA) + mesh overlay · tone map
// ─────────────────────────────────────────────────────────────

#include <metal_stdlib>
using namespace metal;

struct U {
    float4x4 viewProj;
    float4x4 view;
    float4x4 invViewProj;
    float4x4 lightVP;
    float4x4 topVP;
    float4 camPos;     // xyz, w = time
    float4 camFwd;
    float4 keyDir;     // xyz toward light, w = intensity
    float4 screen;     // w, h, 1/w, 1/h
    float4 flesh;      // transmission tint of the flesh
    float4 fleshDeep;  // scattering albedo of the flesh
    float4 pale;
    float4 skin;
    float4 stripe;
    float4 seed;
    float4 shape;      // T, Ro, skinDepth, paleDepth
    float4 misc;       // exposure, meshAlpha, floorY, unused
    float4 bg;
    float4 shadowTint;
};

constant float PI = 3.14159265;

// smoothstep that also accepts reversed edges (as WGSL implementations do)
static inline float sstep(float e0, float e1, float x) {
    float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

static inline float hash3(float3 p) {
    float3 q = fract(p * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

static inline float vnoise(float3 p) {
    float3 i = floor(p); float3 f = fract(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    float a = mix(mix(hash3(i + float3(0, 0, 0)), hash3(i + float3(1, 0, 0)), u.x), mix(hash3(i + float3(0, 1, 0)), hash3(i + float3(1, 1, 0)), u.x), u.y);
    float b = mix(mix(hash3(i + float3(0, 0, 1)), hash3(i + float3(1, 0, 1)), u.x), mix(hash3(i + float3(0, 1, 1)), hash3(i + float3(1, 1, 1)), u.x), u.y);
    return mix(a, b, u.z);
}

static inline float fbm(float3 p) {
    return 0.55 * vnoise(p) + 0.3 * vnoise(p * 2.13 + 7.1) + 0.15 * vnoise(p * 4.37 + 3.3);
}

// rounded rectangle softbox seen along direction d
static float softbox(float3 d, float3 c, float3 up, float2 size, float blur) {
    float cd = dot(d, c);
    if (cd <= 0.0) { return 0.0; }
    float3 t1 = normalize(cross(up, c));
    float3 t2 = cross(c, t1);
    float2 uv = float2(dot(d, t1), dot(d, t2)) / cd;
    float2 q = abs(uv) - size;
    float sd = length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - 0.04;
    return 1.0 - sstep(-blur, blur, sd);
}

// procedural photo studio: pale cyclorama, overhead softbox, back-left strip, front-right fill card
static float3 studioEnv(float3 d, float rough, float3 bg) {
    float b = 0.012 + rough * 0.55;
    float y = d.y;
    float3 col = mix(bg * 0.62, bg * 1.05, sstep(-0.35, 0.25, y));
    // the bright paper sweep near the horizon gives vertical walls something to reflect
    col += bg * 0.55 * (1.0 - sstep(0.0, 0.3, abs(y + 0.08)));
    col = mix(col, bg * 0.8, sstep(0.3, 1.0, y));
    col += float3(1.0, 0.985, 0.96) * 3.2 * softbox(d, normalize(float3(0.05, 1.0, -0.15)), float3(0.0, 0.0, 1.0), float2(0.55, 0.32), b);
    col += float3(1.0, 0.98, 0.95) * 3.0 * softbox(d, normalize(float3(-0.42, 0.34, -0.8)), float3(0.0, 1.0, 0.0), float2(0.7, 0.06), b);
    col += float3(1.0, 0.97, 0.93) * 4.0 * softbox(d, normalize(float3(-0.8, 0.38, -0.2)), float3(0.0, 1.0, 0.0), float2(0.08, 0.55), b);
    col += float3(0.95, 0.97, 1.0) * 1.2 * softbox(d, normalize(float3(0.85, 0.3, 0.55)), float3(0.0, 1.0, 0.0), float2(0.45, 0.5), b * 1.3);
    return col;
}

static float ggx(float3 N, float3 V, float3 L, float rough) {
    float3 H = normalize(V + L);
    float a = max(rough * rough, 0.002);
    float a2 = a * a;
    float NdH = max(dot(N, H), 0.0);
    float NdL = max(dot(N, L), 0.0);
    float NdV = max(dot(N, V), 1e-3);
    float dd = NdH * NdH * (a2 - 1.0) + 1.0;
    float D = a2 / (PI * dd * dd);
    float k = a * 0.5;
    float G = (NdL / (NdL * (1.0 - k) + k)) * (NdV / (NdV * (1.0 - k) + k));
    return D * G / max(4.0 * NdL * NdV, 1e-3) * NdL;
}

static inline float linearDepth(constant U& u, float3 p) { return dot(p - u.camPos.xyz, u.camFwd.xyz); }

static inline float2 fullTri(uint i) {
    return float2(float((i << 1u) & 2u), float(i & 2u)) * 2.0 - 1.0;
}

// ── depth-only (shadow map, height map) ──
struct PosIn { float3 p [[attribute(0)]]; };

vertex float4 vsDepth(PosIn v [[stage_in]], constant float4x4& m [[buffer(4)]]) {
    return m * float4(v.p, 1.0);
}

// ── scene: background / floor with soft shadows, then seeds, bubbles and the knife ──
struct FSOut { float4 pos [[position]]; float2 ndc; };

vertex FSOut vsFullNdc(uint i [[vertex_id]]) {
    FSOut o;
    float2 p = fullTri(i);
    o.pos = float4(p, 0.0, 1.0); o.ndc = p;
    return o;
}

constant float2 POISSON[16] = {
    float2(-0.94201624, -0.39906216), float2(0.94558609, -0.76890725), float2(-0.094184101, -0.92938870), float2(0.34495938, 0.29387760),
    float2(-0.91588581, 0.45771432), float2(-0.81544232, -0.87912464), float2(-0.38277543, 0.27676845), float2(0.97484398, 0.75648379),
    float2(0.44323325, -0.97511554), float2(0.53742981, -0.47373420), float2(-0.26496911, -0.41893023), float2(0.79197514, 0.19090188),
    float2(-0.24188840, 0.99706507), float2(-0.81409955, 0.91437590), float2(0.19984126, 0.78641367), float2(0.14383161, -0.14100790)
};

constexpr sampler cmpSampler(coord::normalized, filter::linear, address::clamp_to_edge, compare_func::less);
constexpr sampler linSampler(coord::normalized, filter::linear, address::clamp_to_edge);

static float keyShadow(constant U& u, float3 P, depth2d<float> shadowMap) {
    float4 lp = u.lightVP * float4(P, 1.0);
    float2 uv = float2(lp.x * 0.5 + 0.5, 0.5 - lp.y * 0.5);
    float z = lp.z;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) { return 1.0; }
    // blocker search → penumbra size (PCSS-lite)
    float2 dims = float2(shadowMap.get_width(), shadowMap.get_height());
    float blk = 0.0; float nb = 0.0;
    for (int i = 0; i < 16; i++) {
        float2 s = uv + POISSON[i] * 0.02;
        float d = shadowMap.read(uint2(clamp(s, float2(0.0), float2(0.999)) * dims));
        if (d < z - 0.002) { blk += d; nb += 1.0; }
    }
    if (nb < 0.5) { return 1.0; }
    blk /= nb;
    float pen = clamp((z - blk) * 0.45, 0.003, 0.022);
    float sum = 0.0;
    float rot = hash3(P * 91.7) * 6.2831;
    float2 cs = float2(cos(rot), sin(rot));
    for (int i = 0; i < 16; i++) {
        float2 o = POISSON[i];
        float2 r = float2(o.x * cs.x - o.y * cs.y, o.x * cs.y + o.y * cs.x);
        sum += shadowMap.sample_compare(cmpSampler, uv + r * pen, z - 0.0015, level(0));
    }
    return sum / 16.0;
}

static float contactAO(constant U& u, float3 P, depth2d<float> heightMap) {
    float4 tp = u.topVP * float4(P, 1.0);
    float2 uv = float2(tp.x * 0.5 + 0.5, 0.5 - tp.y * 0.5);
    float2 dims = float2(heightMap.get_width(), heightMap.get_height());
    float occ = 0.0;
    // heightmap depth encodes y linearly over [-1, 4]
    for (int ring = 0; ring < 3; ring++) {
        float rad = 0.012 + float(ring) * 0.028;
        for (int i = 0; i < 8; i++) {
            float a = float(i) * 0.785398 + float(ring) * 0.39;
            float2 s = uv + float2(cos(a), sin(a)) * rad;
            if (s.x < 0.0 || s.x > 1.0 || s.y < 0.0 || s.y > 1.0) { continue; }
            float d = heightMap.read(uint2(min(s * dims, dims - 1.0)));
            float h = d * 5.0 - 1.0;
            if (d < 0.9999) {
                float dist = float(ring) * 0.028 * 5.2 + 0.05;
                occ += (1.0 - sstep(0.0, 0.55 + dist, h)) * (1.0 - float(ring) * 0.22);
            }
        }
    }
    return clamp(occ / 16.0, 0.0, 1.0);
}

fragment float4 fsBackground(FSOut i [[stage_in]],
                             constant U& u [[buffer(4)]],
                             depth2d<float> shadowMap [[texture(0)]],
                             depth2d<float> heightMap [[texture(1)]]) {
    float4 a = u.invViewProj * float4(i.ndc, 0.0, 1.0);
    float4 b = u.invViewProj * float4(i.ndc, 1.0, 1.0);
    float3 ro = a.xyz / a.w;
    float3 rd = normalize(b.xyz / b.w - ro);
    float3 col = u.bg.rgb;
    float dep = 1000.0;
    // slight falloff above the horizon, like a paper sweep lit from above
    col *= 1.0 - 0.08 * sstep(0.0, 0.6, rd.y);
    if (rd.y < -1e-4) {
        float t = (u.misc.z - ro.y) / rd.y;
        float3 P = ro + rd * t;
        dep = linearDepth(u, P);
        float sh = keyShadow(u, P, shadowMap);
        float ao = contactAO(u, P, heightMap);
        // translucent jelly casts a tinted shadow; contact occlusion stays neutral
        float3 shadowCol = mix(float3(1.0), u.shadowTint.rgb, 1.0 - sh);
        float3 fl = u.bg.rgb * (0.9 + 0.1 * clamp(1.0 - length(P.xz - float2(0.0, 0.8)) * 0.12, 0.0, 1.0));
        fl *= shadowCol;
        fl *= 1.0 - ao * 0.72;
        float fade = sstep(7.0, 22.0, t);
        col = mix(fl, col, fade);
    }
    return float4(col, dep);
}

struct MeshIn {
    float3 p [[attribute(0)]];
    float3 n [[attribute(1)]];
    float3 rest [[attribute(2)]];
    float mat [[attribute(3)]];
};
struct MeshOut {
    float4 pos [[position]];
    float3 wp;
    float3 n;
    float3 rest;
    float mat;
};

vertex MeshOut vsMesh(MeshIn v [[stage_in]], constant U& u [[buffer(4)]]) {
    MeshOut o;
    o.pos = u.viewProj * float4(v.p, 1.0);
    o.wp = v.p; o.n = v.n; o.rest = v.rest; o.mat = v.mat;
    return o;
}

fragment float4 fsProps(MeshOut i [[stage_in]], constant U& u [[buffer(4)]]) {
    float3 N = normalize(i.n);
    float3 V = normalize(u.camPos.xyz - i.wp);
    float NdV = max(dot(N, V), 1e-3);
    float3 L = u.keyDir.xyz;
    float3 col;
    if (i.mat < 1.5) {
        // seed: dark, lacquered, faint warm brown where it thins out
        float fres = 0.05 + 0.95 * pow(1.0 - NdV, 5.0);
        float n1 = vnoise(i.rest * 90.0);
        float3 base = u.seed.rgb * (0.8 + 0.4 * n1);
        float rim = pow(1.0 - NdV, 2.0);
        base += float3(0.09, 0.035, 0.015) * rim;
        float dif = max(dot(N, L), 0.0) * 0.5 + 0.35;
        float3 env = studioEnv(reflect(-V, N), 0.22, u.bg.rgb);
        // seeds sit just under the jelly skin, so the jelly supplies the gloss; keep the seed itself matte-dark
        col = base * dif + min(env, float3(0.5)) * fres * 0.06;
    } else if (i.mat > 2.8 && i.mat < 4.5) {
        // knife steel: a product-shot gradient (dark board below, bright sweep above) across the blade,
        // brushed along its length, a lighter satin bevel at the edge and a polished bolster
        float bevel = 1.0 - sstep(3.05, 3.4, i.mat);
        float bolster = sstep(3.55, 3.65, i.mat);
        float brush = vnoise(float3(i.rest.x * 3.0, i.rest.y * 260.0, i.rest.z * 40.0));
        float rough = mix(mix(0.12 + 0.06 * brush, 0.22, bevel), 0.06, bolster);
        float3 F0 = float3(0.56, 0.57, 0.585);
        float3 fres = F0 + (float3(1.0) - F0) * pow(1.0 - NdV, 5.0);
        float3 R = reflect(-V, N);
        float hz = R.y * 0.8 + (i.rest.y / 0.63 - 0.45) * 1.1 + 0.28 + (brush - 0.5) * 0.06;
        float sweep = sstep(-0.35, 0.45, hz);
        float3 env = mix(float3(0.045, 0.047, 0.05), float3(0.5, 0.51, 0.53), sweep);
        // the studio's softboxes still show up as crisp streaks
        env += max(studioEnv(R, rough, u.bg.rgb) - u.bg.rgb * 1.15, float3(0.0)) * 0.9;
        env *= 0.92 + 0.16 * brush;
        float spec = ggx(N, V, L, max(rough, 0.1)) * u.keyDir.w;
        col = env * fres + fres * spec * 0.5 + float3(0.02) * max(dot(N, L), 0.0);
        col = mix(col, col * 0.85 + float3(0.12, 0.122, 0.125), bevel * 0.7);
        col = min(col, float3(6.0));
    } else if (i.mat > 4.5) {
        // handle: dark walnut, straight grain along the handle, a satin oil finish and three steel rivets
        float p = clamp((-i.rest.x - 0.07) / 0.84, 0.0, 1.0);
        float cy = 0.56 - 0.028 * p * p;
        float rivet = 0.0;
        for (int k = 0; k < 3; k++) {
            float rx = -0.24 - float(k) * 0.25;
            float dd = length(float2(i.rest.x - rx, i.rest.y - cy));
            rivet = max(rivet, 1.0 - sstep(0.017, 0.021, dd));
        }
        rivet *= sstep(0.03, 0.045, abs(i.rest.z));
        float g = fbm(float3(i.rest.x * 2.2, i.rest.y * 38.0 + vnoise(i.rest * 9.0) * 2.0, i.rest.z * 38.0));
        float3 wood = mix(float3(0.028, 0.014, 0.008), float3(0.085, 0.045, 0.024), sstep(0.3, 0.75, g));
        float dif = max(dot(N, L), 0.0) * 0.8 + 0.3;
        float fr = 0.04 + 0.96 * pow(1.0 - NdV, 5.0);
        float3 envW = studioEnv(reflect(-V, N), 0.35, u.bg.rgb);
        col = wood * dif + envW * fr * 0.35 + float3(ggx(N, V, L, 0.35)) * 0.08 * u.keyDir.w;
        float3 envR = studioEnv(reflect(-V, N), 0.1, u.bg.rgb);
        col = mix(col, envR * 0.7 + float3(ggx(N, V, L, 0.12)) * 0.4, rivet);
    } else {
        // air bubble: soft and low-contrast — a lighter pocket with a faint rim and one pin-point highlight
        float rim = pow(1.0 - NdV, 2.0);
        col = mix(float3(0.9, 0.84, 0.82), float3(0.62, 0.55, 0.55), rim) + float3(ggx(N, V, L, 0.08)) * 0.5;
    }
    return float4(col, linearDepth(u, i.wp));
}

// ── back faces → linear depth (for view-ray thickness) ──
struct BackOut { float4 pos [[position]]; float3 wp; };

vertex BackOut vsBack(PosIn v [[stage_in]], constant U& u [[buffer(4)]]) {
    BackOut o; o.pos = u.viewProj * float4(v.p, 1.0); o.wp = v.p; return o;
}

fragment float4 fsBack(BackOut i [[stage_in]], constant U& u [[buffer(4)]]) {
    return float4(linearDepth(u, i.wp), 0.0, 0.0, 1.0);
}

// ── main: copy the scene, then the jelly itself, then the optional mesh overlay ──
vertex float4 vsFull(uint i [[vertex_id]]) {
    return float4(fullTri(i), 0.0, 1.0);
}

fragment float4 fsCopy(float4 fc [[position]], texture2d<float> sceneTex [[texture(0)]]) {
    return float4(sceneTex.read(uint2(fc.xy)).rgb, 1.0);
}

struct JellyOut {
    float4 pos [[position]];
    float3 wp;
    float3 n;
    float3 rest;
};

vertex JellyOut vsJelly(MeshIn v [[stage_in]], constant U& u [[buffer(4)]]) {
    JellyOut o;
    o.pos = u.viewProj * float4(v.p, 1.0);
    o.wp = v.p; o.n = v.n; o.rest = v.rest;
    return o;
}

static inline float2 toUV(constant U& u, float3 p) {
    float4 c = u.viewProj * float4(p, 1.0);
    float2 n = c.xy / c.w;
    return float2(n.x * 0.5 + 0.5, 0.5 - n.y * 0.5);
}

fragment float4 fsJelly(JellyOut i [[stage_in]],
                        bool ff [[front_facing]],
                        constant U& u [[buffer(4)]],
                        texture2d<float> sceneTex [[texture(0)]],
                        texture2d<float> backTex [[texture(1)]]) {
    float3 N = normalize(i.n);
    if (!ff) { N = -N; }
    float3 P = i.wp;
    float3 V = normalize(u.camPos.xyz - P);
    float3 L = u.keyDir.xyz;
    float key = u.keyDir.w;
    float NdV = max(dot(N, V), 1e-3);

    // ── material regions from rest-space coordinates (they deform with the body) ──
    float3 Q = i.rest;
    float Ro = u.shape.y;
    float r = length(Q.xz);
    float th = atan2(Q.x, Q.z);
    float wob = (fbm(float3(th * 9.0, Q.y * 3.0, 1.7)) - 0.5);
    float depth = Ro - r + wob * 0.018;
    float skinW = 1.0 - sstep(u.shape.z - 0.008, u.shape.z + 0.01, depth);
    float paleEdge = u.shape.w + wob * 0.035;
    float paleW = (1.0 - sstep(paleEdge - 0.035, paleEdge + 0.035, depth)) * (1.0 - skinW);
    float fleshW = 1.0 - skinW - paleW;

    // irregular stripes running across the rind, pole to pole
    float sn = fbm(float3(th * 5.0, Q.y * 2.2, 3.0));
    float stripeF = sin(th * 34.0 + sn * 7.0 + fbm(float3(th * 22.0, Q.y * 7.0, 9.0)) * 2.5);
    float stripe = sstep(-0.05, 0.35, stripeF) * sstep(0.1, 0.02, depth);
    float speck = sstep(0.62, 0.8, vnoise(float3(th * 160.0, Q.y * 40.0, 2.0)));
    float3 skinCol = mix(u.skin.rgb, u.stripe.rgb, clamp(stripe + speck * 0.35, 0.0, 1.0));
    // the cut face shows a lighter green inner skin band
    skinCol = mix(skinCol, mix(u.skin.rgb, u.pale.rgb, 0.35), sstep(0.02, 0.07, depth) * 0.6);

    // ── thickness along the view ray ──
    float2 uv = i.pos.xy * u.screen.zw;
    uint2 pix = uint2(i.pos.xy);
    float fz = linearDepth(u, P);
    float bz = backTex.read(pix).r;
    float sz = sceneTex.read(pix).a;
    float cosv = max(dot(-V, u.camFwd.xyz), 0.35);
    float thick = clamp((min(bz, sz) - fz) / cosv, 0.0, 3.0);
    float thickBack = clamp((bz - fz) / cosv, 0.0, 3.0);

    // internal texture: soft crystalline grain radiating from the heart of the melon
    float grain = fbm(float3(r * 26.0, th * 18.0, Q.y * 14.0));
    float grain2 = vnoise(Q * 55.0);
    float dens = 1.0 + (grain - 0.5) * 0.5 + (grain2 - 0.5) * 0.18;

    // ── absorption / scattering coefficients per material ──
    float3 fleshT = clamp(u.flesh.rgb, float3(0.002), float3(0.999));
    float3 sigF = -log(fleshT) * 3.4 * dens;
    float3 paleT = clamp(u.pale.rgb, float3(0.01), float3(0.999));
    float3 sigP = -log(paleT) * 2.0 + float3(0.5);
    float3 sigS = -log(clamp(u.skin.rgb, float3(0.002), float3(0.99))) * 3.5 + float3(2.0);
    float3 sigma = sigF * fleshW + sigP * paleW + sigS * skinW;
    float scatK = 1.7 * fleshW + 4.5 * paleW + 26.0 * skinW;
    float rough = mix(mix(0.1, 0.2, paleW), 0.14 + stripe * 0.04, skinW);

    // ── refraction: bend the view ray into the jelly, find where it leaves ──
    float ior = 1.42;
    float3 Rr = refract(-V, N, 1.0 / ior);
    float3 exitP = P + Rr * min(thickBack, 0.9) * 0.55;
    float2 ruv = toUV(u, exitP);
    ruv = mix(uv, ruv, 0.85);
    // a little diffusion inside the candy blurs what lies behind
    float blurR = (0.001 + 0.007 * min(thick, 1.0)) * (0.6 + scatK * 0.02);
    // each tap is absorbed over its own path length (to a seed, a bubble or out through the back)
    float3 behind = float3(0.0);
    float3 transmitted = float3(0.0);
    float pathL = 0.0;
    for (int k = 0; k < 7; k++) {
        float a = float(k) * 0.8976 + 0.3;
        float2 o = (k == 6) ? float2(0.0) : float2(cos(a), sin(a)) * blurR;
        float4 s = sceneTex.sample(linSampler, clamp(ruv + o, float2(0.001), float2(0.999)), level(0.0));
        float pl = clamp(min(thickBack, max(s.a - fz, 0.0) / cosv + 0.03), 0.0, 3.0);
        behind += s.rgb;
        transmitted += s.rgb * exp(-sigma * pl);
        pathL += pl;
    }
    behind /= 7.0; transmitted /= 7.0; pathL /= 7.0;
    float scat = 1.0 - exp(-scatK * pathL * 0.5 - scatK * 0.02);

    // ── light arriving inside the body ──
    float NdL = dot(N, L);
    float wrap = clamp((NdL + 0.6) / 1.6, 0.0, 1.0);
    float3 amb = u.bg.rgb * mix(0.3, 0.75, N.y * 0.5 + 0.5);
    // flesh brightens toward the rind, as in a real melon
    float nearPale = 1.0 - sstep(u.shape.w, u.shape.w + 0.3, depth);
    float3 fleshAlb = mix(u.fleshDeep.rgb, u.flesh.rgb * 0.9, nearPale * 0.45);
    float3 albedo = fleshAlb * fleshW + u.pale.rgb * 0.7 * paleW + skinCol * skinW;
    float3 inner = albedo * (amb + float3(1.0, 0.97, 0.92) * key * 0.45 * wrap);

    // thin edges glow when the key light is behind them
    float back = pow(clamp(dot(V, -L), 0.0, 1.0), 3.0) * 1.4 + 0.25;
    float3 thinK = exp(-sigma * (pathL * 0.6 + 0.05));
    float3 glowTint = u.flesh.rgb * fleshW + float3(0.9, 0.95, 0.78) * paleW + skinCol * 0.6 * skinW;
    float3 glow = glowTint * thinK * back * key * 0.42 * (1.0 - skinW * 0.7) * clamp(1.0 - NdL * 0.6, 0.0, 1.0);

    // ── assemble body color ──
    float3 body = transmitted * (1.0 - scat) + inner * scat + glow;

    // tiny sub-surface glints in the flesh (sugar crystals)
    float3 R = reflect(-V, N);
    float3 cell = floor(Q * float3(70.0, 70.0, 70.0));
    float spark = step(0.985, hash3(cell)) * pow(max(dot(R, L), 0.0), 40.0) * fleshW;
    body += float3(1.0, 0.85, 0.8) * spark * 0.2;

    // ── surface: Fresnel reflection of the studio + key highlight ──
    float F0 = mix(0.034, 0.045, skinW);
    float F = F0 + (1.0 - F0) * pow(1.0 - NdV, 5.0);
    float3 env = studioEnv(R, rough, u.bg.rgb);
    float3 spec = ggx(N, V, L, rough) * key * float3(1.0, 0.97, 0.93);
    float3 col = body * (1.0 - F) + env * F + spec * mix(0.9, 1.1, skinW) * (F0 / 0.04);

    return float4(col, 1.0);
}

// ── mesh overlay ──
struct LineOut { float4 pos [[position]]; float d; };

vertex LineOut vsLine(PosIn v [[stage_in]], constant U& u [[buffer(4)]]) {
    LineOut o; o.pos = u.viewProj * float4(v.p, 1.0); o.d = linearDepth(u, v.p); return o;
}

fragment float4 fsLine(LineOut i [[stage_in]], constant U& u [[buffer(4)]]) {
    float a = u.misc.y * mix(0.9, 0.35, clamp((i.d - 5.0) * 0.5, 0.0, 1.0));
    return float4(float3(0.04, 0.05, 0.06) * a, a);
}

// ── post: exposure, Khronos PBR Neutral tone mapping, sRGB, dither ──
static float3 neutral(float3 c0) {
    float startC = 0.8 - 0.04;
    float desat = 0.15;
    float x = min(c0.r, min(c0.g, c0.b));
    float off = (x < 0.08) ? x - 6.25 * x * x : 0.04;
    float3 c = c0 - off;
    float peak = max(c.r, max(c.g, c.b));
    if (peak < startC) { return c; }
    float d = 1.0 - startC;
    float np = 1.0 - d * d / (peak + d - startC);
    c *= np / peak;
    float g = 1.0 - 1.0 / (desat * (peak - np) + 1.0);
    return mix(c, float3(np), g);
}

static float3 oetf(float3 c) {
    return select(1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, c * 12.92, c <= float3(0.0031308));
}

fragment float4 fsPost(float4 fc [[position]], constant U& u [[buffer(4)]], texture2d<float> hdr [[texture(0)]]) {
    float3 c = hdr.read(uint2(fc.xy)).rgb * u.misc.x;
    c = neutral(max(c, float3(0.0)));
    float3 s = oetf(clamp(c, float3(0.0), float3(1.0)));
    s += (hash3(float3(fc.xy, 1.0)) - 0.5) / 255.0;
    return float4(s, 1.0);
}
