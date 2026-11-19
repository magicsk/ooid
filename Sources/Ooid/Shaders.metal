#include <metal_stdlib>
using namespace metal;

// Uniforms shared by every fragment shader. One buffer, ring-rotated by renderer.
struct Uniforms {
    float2 res;
    float2 mouse;         // normalised 0..1, y-up
    float2 mouseV;
    float  time;
    float  click;         // decays from 1 on click
    float2 clickPos;      // 0..1, y-up
    float  mouseEffects;  // 1 = enabled, 0 = disabled
    float  dt;            // seconds since the previous frame
    float4 opt;           // shader-specific tunables, interpreted per shader
    float4 col0;          // palette stop 0 (shadow)  .xyz used, .w reserved
    float4 col1;          // palette stop 1 (mid)
    float4 col2;          // palette stop 2 (hot)
};

struct VSOut { float4 position [[position]]; };

// Fullscreen triangle — three verts, no index or vertex buffer needed. Cheaper than a quad.
vertex VSOut vs_fullscreen(uint vid [[vertex_id]]) {
    float2 p = float2((vid == 1) ? 3.0 : -1.0,
                      (vid == 2) ? 3.0 : -1.0);
    VSOut o; o.position = float4(p, 0.0, 1.0); return o;
}

constant float PI = 3.14159265359;

// GLSL-semantics modulo (fmod differs for negative inputs).
static inline float glmod(float x, float y) { return x - y * floor(x / y); }

static inline float2x2 rot(float a) {
    float c = cos(a), s = sin(a);
    return float2x2(c, -s, s, c);
}

// ---------- shared noise toolkit (mirrors the HTML prototype) ----------
static inline float hash12(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}
static inline float2 hash22(float2 p) {
    p = float2(dot(p, float2(127.1, 311.7)),
               dot(p, float2(269.5, 183.3)));
    return fract(sin(p) * 43758.5453);
}
// Value noise over a 256² random lattice texture uploaded once by the
// renderer. Fast path: Hermite-warp the coordinate and let the filter unit do
// the bilinear blend — one sample() instead of four hash12() calls (~3× cheaper).
constexpr sampler noiseSampler(filter::linear, address::repeat);
static inline float vnoise(float2 p, texture2d<float> nt) {
    float2 i = floor(p), f = fract(p);
    return nt.sample(noiseSampler, (i + f * f * (3.0 - 2.0 * f) + 0.5) / 256.0, level(0)).r;  // level: also runs in vs12_rod
}
// Exact path for heights that get finite-differenced into normals: the filter
// unit's 8-bit sub-texel weights show up as streaks in tight speculars, so
// gather the four corners and blend in float ALU instead (~1.3× the fast path).
static inline float vnoiseExact(float2 p, texture2d<float> nt) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float4 g = nt.gather(noiseSampler, (i + 1.0) / 256.0);  // w=(0,0) z=(1,0) x=(0,1) y=(1,1)
    return mix(mix(g.w, g.z, u.x), mix(g.x, g.y, u.x), u.y);
}
// 5-octave fbm. The 6th octave of the original contributes ≤3% of the
// amplitude — inaudible in motion — so we drop it for a clean 17% saving
// across every noise call in the whole library.
static inline float fbm(float2 p, texture2d<float> nt) {
    float s = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) { s += a * vnoise(p, nt); p *= 2.02; a *= 0.5; }
    return s;
}
static inline float fbmExact(float2 p, texture2d<float> nt) {
    float s = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) { s += a * vnoiseExact(p, nt); p *= 2.02; a *= 0.5; }
    return s;
}

// Static film grain: 320² cells of white noise stretched over the view and
// overlay-blended at up to 6%. This used to be an AppKit layer with an overlay
// compositing filter, which made WindowServer re-blend the whole window every
// frame (~7% GPU full-screen). Overlay-blending white at alpha g lifts each
// channel by g·min(c, 1 − c).
static inline float3 grain(float3 col, float4 position, float2 res, texture2d<float> nt) {
    float g = 0.06 * nt.sample(noiseSampler, position.xy / res * (320.0 / 256.0)).r;
    col = saturate(col);
    return col + g * min(col, 1.0 - col);
}

// Convert Metal's top-left pixel coord to the GLSL bottom-left gl_FragCoord convention.
static inline float2 fragCoordFromPosition(float4 position, float2 res) {
    return float2(position.x, res.y - position.y);
}

// Aspect-corrected mouse (matches `m.x *= uRes.x/uRes.y` in the prototype).
static inline float2 aspectCorrectedMouse(float2 mouseNorm, float2 res) {
    float2 m = mouseNorm * 2.0 - 1.0;
    m.x *= res.x / res.y;
    return m;
}

// ======================================================================
// SHADER 01 — Liquid mercury caustics
// ======================================================================
static float3 s1_sky(float3 d) {
    float y = d.y;
    float3 top    = float3(0.78, 0.86, 0.98);
    float3 horiz  = float3(0.95, 0.72, 0.55);
    float3 floorC = float3(0.04, 0.05, 0.08);
    float3 col = mix(horiz, top, smoothstep(-0.05, 0.6, y));
    col = mix(floorC, col, smoothstep(-0.25, 0.02, y));
    float sun = pow(max(dot(d, normalize(float3(0.6, 0.65, 0.4))), 0.0), 64.0);
    col += float3(1.2, 0.9, 0.7) * sun * 1.2;
    float rim = pow(max(dot(d, normalize(float3(-0.7, 0.2, -0.3))), 0.0), 16.0);
    col += float3(0.3, 0.5, 0.9) * rim * 0.8;
    return col;
}
static float s1_mercuryH(float2 p, constant Uniforms& u, texture2d<float> nt) {
    float t = u.time * 0.25;
    float h = 0.0;
    h += 0.06 * sin(length(p * 3.0) - t * 2.5);
    h += 0.05 * fbmExact(p * 1.6 + float2(t * 0.3, -t * 0.2), nt);
    h += 0.03 * fbmExact(p * 4.0 - float2(t * 0.5), nt);
    float2 m = aspectCorrectedMouse(u.mouse, u.res);
    float d = length(p - m);
    h -= 0.20 * exp(-d * d * 8.0);
    h += 0.08 * sin(d * 24.0 - u.time * 6.0) * exp(-d * 2.0);
    float2 cp = aspectCorrectedMouse(u.clickPos, u.res);
    float cd = length(p - cp);
    h += 0.22 * u.click * sin(cd * 30.0 - (1.0 - u.click) * 40.0) * exp(-cd * 3.0);
    return h;
}
static float3 s1_mercuryN(float2 p, constant Uniforms& u, texture2d<float> nt) {
    float e = 0.006;
    float h  = s1_mercuryH(p, u, nt);
    float hx = s1_mercuryH(p + float2(e, 0.0), u, nt);
    float hy = s1_mercuryH(p + float2(0.0, e), u, nt);
    return normalize(float3((h - hx) / e, (h - hy) / e, 1.0));
}
fragment float4 fs1_mercury(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                            texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;

    float3 n = s1_mercuryN(p, u, nt);
    float3 v = float3(0.0, 0.0, -1.0);
    float3 r = reflect(v, n);

    float f0 = 0.88;
    float fres = f0 + (1.0 - f0) * pow(1.0 - max(dot(-v, n), 0.0), 5.0);
    float3 reflCol = s1_sky(r);

    float3 refr = refract(v, n, 1.0 / 1.89);
    float t = (-1.2) / refr.z;
    float2 floorP = p + refr.xy * t;
    float caustic = 0.0;
    caustic += pow(fbm(floorP * 3.0 + u.time * 0.2, nt), 3.0) * 2.4;
    caustic += pow(abs(sin(floorP.x * 6.0 + u.time) * sin(floorP.y * 6.0 - u.time * 0.7)), 5.0) * 1.8;
    float3 floorCol = mix(float3(0.02, 0.025, 0.04), float3(0.7, 0.85, 1.1), caustic);

    float3 mercuryTint = float3(0.86, 0.9, 0.98);
    reflCol *= mercuryTint;

    float3 col = mix(floorCol * 0.35, reflCol, fres);

    float3 L = normalize(float3(0.3, 0.5, 0.7));
    float spec = pow(max(dot(r, L), 0.0), 180.0);
    col += spec * float3(1.4, 1.2, 1.0);

    col *= 1.0 - 0.25 * length(p) * 0.5;
    col.r = mix(col.r, col.r * 1.02, fres * 0.5);
    col.b = mix(col.b, col.b * 1.04, fres * 0.5);

    return float4(grain(pow(col, float3(0.92)), in.position, u.res, nt), 1.0);
}

// ======================================================================
// SHADER 02 — Volumetric aurora smoke
// ======================================================================
static float s2_density(float3 p, constant Uniforms& u, texture2d<float> nt) {
    float2 m = aspectCorrectedMouse(u.mouse, u.res);
    float d = length(p.xz - m);
    float thermal = exp(-d * 1.2) * (0.8 + 0.2 * sin(u.time * 2.0 + d * 4.0));

    float3 q = p;
    q.y -= u.time * 0.18;
    q.xz += float2(sin(p.y * 1.2 + u.time * 0.4), cos(p.y * 1.0 - u.time * 0.3)) * 0.25;

    float f = fbm(q.xz * 1.4 + q.y * 0.6, nt);
    float g = fbm(q.xz * 3.0 - q.y * 0.8 + 3.3, nt);
    float dens = smoothstep(0.35, 0.9, f * 0.7 + g * 0.5);

    dens += thermal * 0.8;
    dens *= smoothstep(1.6, 0.0, abs(p.y));
    return dens;
}
static float3 s2_aurora(float t) {
    float3 a = float3(0.20, 0.08, 0.35);
    float3 b = float3(0.10, 0.85, 0.75);
    float3 c = float3(0.95, 0.30, 0.65);
    float3 d = float3(0.30, 0.45, 1.10);
    float x = fract(t);
    return a + b * cos(2.0 * PI * (c * x + d * 0.25));
}
fragment float4 fs2_aurora(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                            texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;

    float3 ro = float3(0.0, 0.0, -3.0);
    float3 rd = normalize(float3(p, 1.4));

    float3 col = float3(0.02, 0.01, 0.03);
    float T = 1.0;

    // The absorption formula `1 - exp(-d*dt*k)` is step-size independent
    // (Beer-Lambert), so halving the step count doesn't brighten or darken
    // the volume — it only coarsens the silhouette. 28 steps already hits
    // the early-out (T < 0.02) on anything dense, so cutting from 40 saves
    // work only on thin/empty rays where coarser sampling is imperceptible.
    const int STEPS = 28;
    float tStart = 1.2, tEnd = 4.2;
    float dt = (tEnd - tStart) / float(STEPS);

    for (int i = 0; i < STEPS; i++) {
        float t = tStart + float(i) * dt;
        float3 pos = ro + rd * t;
        float d = s2_density(pos, u, nt);
        if (d > 0.01) {
            float hue = 0.5 + 0.5 * sin(pos.x * 0.6 + pos.y * 0.4 + u.time * 0.3);
            float3 em = s2_aurora(hue + pos.y * 0.1);
            float2 m = aspectCorrectedMouse(u.mouse, u.res);
            float ml = exp(-length(pos.xz - m) * 1.2);
            em += float3(1.3, 0.7, 0.4) * ml * 1.4;
            float a = 1.0 - exp(-d * dt * 2.4);
            col += T * a * em;
            T *= (1.0 - a);
            if (T < 0.02) break;
        }
    }

    float2 cp = aspectCorrectedMouse(u.clickPos, u.res);
    float cd = length(p - cp);
    col += u.click * float3(1.0, 0.6, 0.9) * 0.6 * exp(-cd * 2.0) * sin(cd * 20.0 - (1.0 - u.click) * 28.0);

    col = col / (1.0 + col);
    col = pow(col, float3(0.88));
    col *= 1.0 - 0.35 * length(p) * 0.6;
    return float4(grain(col, in.position, u.res, nt), 1.0);
}

// ======================================================================
// SHADER 03 — Iridescent soap film
// ======================================================================
static float3 s3_thinFilm(float thickness_nm, float cosTheta) {
    float n = 1.33;
    float opd = 2.0 * n * thickness_nm * cosTheta;
    float phR = 2.0 * PI * opd / 650.0;
    float phG = 2.0 * PI * opd / 550.0;
    float phB = 2.0 * PI * opd / 450.0;
    float3 I = 0.5 + 0.5 * float3(cos(phR), cos(phG), cos(phB));
    float mgray = (I.r + I.g + I.b) / 3.0;
    I = mix(float3(mgray), I, 1.5);
    return clamp(I, 0.0, 1.0);
}
static float s3_thickness(float2 p, constant Uniforms& u, texture2d<float> nt) {
    float2 m = aspectCorrectedMouse(u.mouse, u.res);
    float d = length(p - m);
    float base = 300.0;
    base += 120.0 * fbm(p * 1.5 + u.time * 0.08, nt);
    base += 60.0  * sin(p.x * 3.2 + u.time * 0.4) * sin(p.y * 2.4 - u.time * 0.3);
    base -= 220.0 * exp(-d * d * 4.0);
    base += 35.0 * sin(d * 18.0 - u.time * 4.0) * exp(-d * 1.4);
    float2 cp = aspectCorrectedMouse(u.clickPos, u.res);
    float cd = length(p - cp);
    base += 160.0 * u.click * sin(cd * 22.0 - (1.0 - u.click) * 30.0) * exp(-cd * 2.0);
    return clamp(base, 60.0, 620.0);
}
fragment float4 fs3_soap(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                            texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;

    float2 m = aspectCorrectedMouse(u.mouse, u.res);
    float e = 0.004;
    float d0 = length(p - m);
    float dx = length(p + float2(e, 0.0) - m);
    float dy = length(p + float2(0.0, e) - m);
    float h0 = -exp(-d0 * d0 * 4.0) * 0.35;
    float hx = -exp(-dx * dx * 4.0) * 0.35;
    float hy = -exp(-dy * dy * 4.0) * 0.35;
    float3 n = normalize(float3((h0 - hx) / e, (h0 - hy) / e, 1.0));
    float3 v = float3(0.0, 0.0, -1.0);
    float cosTheta = max(dot(-v, n), 0.05);

    float t_nm = s3_thickness(p, u, nt);
    float3 tf = s3_thinFilm(t_nm, cosTheta);

    float3 bg = float3(0.03, 0.035, 0.05);
    bg += 0.15 * fbm(p * 3.0 + u.time * 0.1, nt);
    bg *= float3(0.7, 0.8, 1.0);

    float fres = pow(1.0 - cosTheta, 2.2);
    float3 col = mix(bg, tf, 0.55 + 0.45 * fres);

    float3 L = normalize(float3(0.3, 0.6, 1.0));
    float3 r = reflect(v, n);
    float spec = pow(max(dot(r, L), 0.0), 120.0);
    col += spec * float3(1.1, 1.05, 1.0) * 0.5;

    float shim = fbm(p * 8.0 + u.time * 0.6, nt);
    col += 0.04 * shim * tf;

    float thinEdge = smoothstep(120.0, 70.0, t_nm);
    col = mix(col, float3(0.0), thinEdge * 0.8);

    col *= 1.0 - 0.25 * length(p) * 0.5;
    return float4(grain(pow(col, float3(0.95)), in.position, u.res, nt), 1.0);
}

// ======================================================================
// SHADER 04 — Diffraction crystal lattice
// ======================================================================
static float3 s4_palette(float t) {
    return 0.5 + 0.5 * cos(2.0 * PI * (float3(1.0) * t + float3(0.00, 0.33, 0.67)));
}
static float2 s4_fold(float2 p, float n) {
    float a = atan2(p.y, p.x);
    float r = length(p);
    float sect = 2.0 * PI / n;
    a = glmod(a, sect) - sect * 0.5;
    return float2(cos(a), sin(a)) * r;
}
static float s4_facet(float2 p, float time) {
    float s = 0.0;
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float2 q = p * (1.0 + fi * 0.35);
        q = rot(time * 0.1 + fi * 0.7) * q;
        q = s4_fold(q, 6.0 + fi);
        float d = abs(q.x) + abs(q.y) * 0.5;
        s += smoothstep(0.9, 0.0, d) * (1.0 - fi * 0.15);
    }
    return s;
}
static float3 s4_sampleField(float2 p, float shift, constant Uniforms& u) {
    float2 m = aspectCorrectedMouse(u.mouse, u.res);
    float2 dir = normalize(p - m + float2(0.0001));
    float2 q = p + dir * shift * 0.18;
    float ang = u.time * 0.15 + (m.x * 0.6 + m.y * 0.4);
    q = rot(ang) * q;
    float f = s4_facet(q, u.time);
    float ring = 0.5 + 0.5 * sin(length(q - m) * 34.0 - u.time * 2.0 + shift * 8.0);
    ring = pow(ring, 3.0);
    float2 gv = rot(u.time * 0.3) * q;
    float grat = 0.5 + 0.5 * sin(gv.x * 60.0 + shift * 6.0);
    grat = pow(grat, 6.0);
    float v = f * 0.8 + ring * 0.4 + grat * 0.25;
    float beam = exp(-length(p - m) * 1.2);
    v += beam * (0.6 + 0.4 * sin(u.time * 3.0));
    return s4_palette(v + shift) * v;
}
fragment float4 fs4_crystal(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                            texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;

    float3 col = float3(0.0);
    col.r = s4_sampleField(p, -0.6, u).r * 1.05;
    col.g = s4_sampleField(p,  0.0, u).g * 1.0;
    col.b = s4_sampleField(p,  0.6, u).b * 1.05;
    float3 mid = s4_sampleField(p, 0.3, u);
    col += mid * 0.25;

    float2 cp = aspectCorrectedMouse(u.clickPos, u.res);
    float cd = length(p - cp);
    col += u.click * s4_palette(cd * 2.0 + u.time) * exp(-cd * 1.5) * (0.5 + 0.5 * sin(cd * 30.0));

    col *= 1.0 - 0.28 * length(p);
    col = col / (1.0 + col * 0.7);
    col = pow(col, float3(0.9));
    return float4(grain(col, in.position, u.res, nt), 1.0);
}

// ======================================================================
// SHADER 05 — Plasma silk
// ======================================================================
static float2 s5_weaveDir(float2 p) {
    float2 cell = floor(p * float2(18.0, 18.0));
    float parity = glmod(cell.x + cell.y, 2.0);
    float2 t1 = float2(1.0, 0.08);
    float2 t2 = float2(0.08, 1.0);
    return normalize(mix(t1, t2, parity));
}
static float s5_anisoSpec(float2 T, float2 L, float2 V, float sh) {
    float tl = dot(T, L);
    float tv = dot(T, V);
    float s = sqrt(max(0.0, 1.0 - tl * tl)) * sqrt(max(0.0, 1.0 - tv * tv));
    return pow(clamp(s, 0.0, 1.0), sh);
}
fragment float4 fs5_silk(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                            texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;

    float2 ps = p + float2(fbm(p * 0.8 + u.time * 0.05, nt),
                           fbm(p * 0.8 - u.time * 0.05, nt)) * 0.04;
    float2 m = aspectCorrectedMouse(u.mouse, u.res);

    float3 col = float3(0.0);
    float3 base = float3(0.09, 0.08, 0.13);
    col += base;

    float2 q = ps * 48.0;
    float weave = 0.5 + 0.5 * sin(q.x) * 0.5 + 0.5 * sin(q.y);
    col += 0.02 * weave * float3(0.9, 0.9, 1.0);

    float3 lightPos = float3(m, 0.35);
    float3 surfP = float3(ps, 0.0);
    float3 toL = lightPos - surfP;
    float dist = length(toL);
    float3 L3 = toL / dist;
    float3 V3 = normalize(float3(0.0, 0.0, 1.0) - surfP);

    float pulse = 0.8 + 0.3 * sin(u.time * 6.0) + 0.2 * sin(u.time * 13.0);
    float atten = pulse / (0.4 + dist * dist * 1.2);

    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float2 pp = ps * (1.0 + fi * 0.3);
        float cs = cos(fi * 0.6), sn = sin(fi * 0.6);
        pp = float2x2(cs, -sn, sn, cs) * pp;
        float2 T = s5_weaveDir(pp);
        float sh = 40.0 + fi * 30.0;
        float a = s5_anisoSpec(T, L3.xy, V3.xy, sh);
        float3 plasma = float3(0.8, 0.4, 1.2) * (1.0 - fi * 0.2) + float3(0.2, 0.8, 1.0) * fi * 0.25;
        col += a * plasma * atten * (1.2 - fi * 0.25);
    }

    float wrap = clamp(dot(float3(0, 0, 1), L3) * 0.5 + 0.5, 0.0, 1.0);
    col += wrap * float3(0.25, 0.20, 0.35) * atten * 0.8;

    float3 H = normalize(L3 + V3);
    float hn = max(H.z, 0.0);
    float3 sheen = 0.5 + 0.5 * cos(2.0 * PI * (float3(1.0) * hn + float3(0.0, 0.33, 0.67)));
    col += pow(hn, 8.0) * sheen * atten * 0.6;

    float core = exp(-length(p - m) * 3.0);
    col += core * float3(1.2, 0.9, 1.6) * pulse * 0.6;

    float2 rd = normalize(p - m + float2(0.0001));
    float streak = pow(max(dot(normalize(s5_weaveDir(ps)), rd), 0.0), 6.0);
    col += streak * float3(0.6, 0.4, 0.9) * atten * 0.3;

    float2 cp = aspectCorrectedMouse(u.clickPos, u.res);
    float cd = length(p - cp);
    col += u.click * float3(1.0, 0.7, 1.4) * exp(-cd * 2.5) * (0.6 + 0.4 * sin(cd * 18.0));

    col *= 1.0 - 0.35 * length(p) * 0.55;
    col = col / (1.0 + col * 0.8);
    col = pow(col, float3(0.92));
    return float4(grain(col, in.position, u.res, nt), 1.0);
}

// ======================================================================
// SHADER 06 — Holographic foil
// ======================================================================
static float3 s6_spectrum(float t) {
    t = clamp(t, 0.0, 1.0);
    float3 c;
    c.r = smoothstep(0.0, 0.15, t) * (1.0 - smoothstep(0.55, 0.85, t));
    c.g = smoothstep(0.15, 0.45, t) * (1.0 - smoothstep(0.75, 1.0, t));
    c.b = smoothstep(0.45, 0.75, t);
    c.r += smoothstep(0.85, 1.0, t) * 0.6;
    c.b += smoothstep(0.85, 1.0, t) * 0.8;
    return c;
}
fragment float4 fs6_foil(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                            texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;
    float2 m  = aspectCorrectedMouse(u.mouse, u.res);

    float emboss = fbm(p * 3.0, nt) * 0.3 + 0.7;

    float2 pp = p * 2.5;
    float2 tId = floor(pp);
    float2 tF  = fract(pp) - 0.5;

    float3 V = normalize(float3(-p, 2.0));
    float3 L = normalize(float3(m - p * 0.2, 1.2));
    float3 H = normalize(L + V);

    // 2×2 neighbour loop (4 taps) — the exp(-d²·2.2) Gaussian weight on
    // opposite-corner cells contributes <0.02 per tap to any given pixel,
    // so dropping the full 3×3 (9 taps) removes ~55% of the shader cost
    // with no perceptible change to the foil texture.
    float3 col = float3(0.0);
    float2 baseOff = float2(tF.x >= 0.0 ? 0.0 : -1.0,
                            tF.y >= 0.0 ? 0.0 : -1.0);
    for (int j = 0; j < 2; j++) {
        for (int i = 0; i < 2; i++) {
            float2 ot = baseOff + float2(float(i), float(j));
            float2 t = tId + ot;
            float seed = hash12(t);
            float ang = seed * PI * 2.0 + u.time * 0.08 * sign(seed - 0.5);
            float2 gd = float2(cos(ang), sin(ang));
            float2 d = tF - ot;
            float w = exp(-dot(d, d) * 2.2);

            float phase = dot(float2(H.x, H.y), float2(-gd.y, gd.x)) * 14.0 + seed * 10.0 + u.time * 0.4;
            phase += length(p - m) * 2.5 * sign(dot(p - m, gd));
            float hue = fract(phase * 0.08 + 0.5);
            float3 sp = s6_spectrum(hue);

            float ridge = abs(sin(dot(p - m, gd) * 60.0 + phase));
            float bright = pow(ridge, 3.0) * 0.6 + 0.4;
            col += sp * bright * w;
        }
    }
    col /= 1.6;

    float crumple = fbm(p * 6.0 + u.time * 0.03, nt);
    col *= emboss * (0.6 + 0.6 * crumple);

    float sp2 = exp(-length(p - m) * 2.0);
    col += sp2 * float3(1.2, 1.1, 1.0) * 0.35;

    float sparkle = pow(fract(sin(dot(floor(p * 160.0), float2(12.9898, 78.233))) * 43758.5), 64.0);
    col += sparkle * 0.8 * s6_spectrum(fract(u.time * 0.5 + length(p - m)));

    float2 cp = aspectCorrectedMouse(u.clickPos, u.res);
    float cd = length(p - cp);
    col += u.click * s6_spectrum(fract(cd - (1.0 - u.click) * 2.0)) * exp(-cd * 1.8) * 0.8;

    col *= 1.0 - 0.25 * length(p) * 0.5;
    col = col / (1.0 + col * 0.6);
    col = pow(col, float3(0.9));
    return float4(grain(col, in.position, u.res, nt), 1.0);
}

// ======================================================================
// SHADER 07 — Ferrofluid spikes
// ======================================================================
// Heights at p, p+(e,0), p+(0,e) in one pass. Hash, mouse field and wobble
// are per-cell, so the three finite-difference taps share them and only the
// Gaussian differs — ~3× cheaper than three separate 9-cell passes. Taps use
// p's cell neighbourhood (e is 1/40 of a cell, so it's the same one almost
// everywhere).
static float3 s7_spikeHeights(float2 p, float e, constant Uniforms& u) {
    float2 m = aspectCorrectedMouse(u.mouse, u.res);
    float2 px = p + float2(e, 0.0), py = p + float2(0.0, e);

    float2 q = p * 6.0;
    float2 a = float2(1.0, 0.0);
    float2 b = float2(0.5, 0.866);
    float hx = dot(q, float2(1.0, -0.577));
    float hy = dot(q, float2(0.0,  1.155));
    float2 hi = floor(float2(hx, hy));
    float3 h = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 cell = hi + float2(float(i), float(j));
            float2 cp = cell.x * a + cell.y * b;
            cp = cp / 6.0;
            cp += (hash22(cell) - 0.5) * 0.08;
            float mField = exp(-length(cp - m) * 0.9);
            float sz = 0.18 * mField + 0.04;
            float amp = (0.7 + 0.3 * sin(u.time * 2.0 + hash12(cell) * 10.0))
                      * smoothstep(0.05, 0.45, mField);
            float3 d2 = float3(length_squared(p - cp), length_squared(px - cp), length_squared(py - cp));
            h = max(h, exp(-d2 / (sz * sz * 0.8)) * amp);
        }
    }
    h += 0.15 * exp(-float3(length(p - m), length(px - m), length(py - m)) * 0.9);

    float2 cp2 = aspectCorrectedMouse(u.clickPos, u.res);
    float3 cd2 = float3(length_squared(p - cp2), length_squared(px - cp2), length_squared(py - cp2));
    h -= u.click * 0.3 * exp(-cd2 * 6.0);
    return h;
}
fragment float4 fs7_ferro(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                            texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;
    float2 m  = aspectCorrectedMouse(u.mouse, u.res);

    float e = 0.004;
    float3 hs = s7_spikeHeights(p, e, u);
    float h = hs.x;
    float3 n = normalize(float3((h - hs.y) / e, (h - hs.z) / e, 1.0));
    float3 V = float3(0.0, 0.0, -1.0);
    float3 r = reflect(V, n);

    float3 L = normalize(float3(-0.5, 0.8, 0.7));
    float3 H = normalize(L - V);
    float NdotL = max(dot(n, L), 0.0);
    float spec = pow(max(dot(n, H), 0.0), 80.0);

    float3 L2 = normalize(float3(0.6, -0.3, 0.5));
    float rim = pow(max(dot(n, L2), 0.0), 16.0);

    float3 base = float3(0.015, 0.018, 0.025);
    float f = 0.04 + 0.96 * pow(1.0 - max(dot(-V, n), 0.0), 5.0);
    float3 refl = mix(float3(0.02, 0.05, 0.12), float3(0.85, 0.9, 1.1), max(r.y, 0.0));

    float3 col = base;
    col = mix(col, refl, f * 0.6);
    col += float3(1.0, 0.95, 0.9) * spec * 1.4;
    col += float3(0.4, 0.5, 0.9) * rim * 0.4;
    col += float3(0.9, 0.8, 0.7) * NdotL * 0.15;

    col += float3(1.0, 0.9, 0.8) * smoothstep(0.25, 0.55, h) * 0.5;

    col += float3(0.3, 0.25, 0.4) * exp(-length(p - m) * 2.5) * 0.25;

    float thin = 1.0 - smoothstep(0.0, 0.12, h);
    col += thin * float3(0.12, 0.06, 0.18) * 0.3;

    float2 cp = aspectCorrectedMouse(u.clickPos, u.res);
    float cd = length(p - cp);
    col += u.click * float3(0.8, 0.9, 1.2) * exp(-cd * cd * 6.0) * 0.5;

    col *= 1.0 - 0.3 * length(p) * 0.5;
    col = pow(col, float3(0.92));
    return float4(grain(col, in.position, u.res, nt), 1.0);
}

// ======================================================================
// SHADER 08 — Oil on water
// ======================================================================
static float3 s8_thinFilmCol(float t_nm, float cosTheta) {
    float n = 1.45;
    float opd = 2.0 * n * t_nm * cosTheta;
    float phR = 2.0 * PI * opd / 680.0;
    float phG = 2.0 * PI * opd / 545.0;
    float phB = 2.0 * PI * opd / 450.0;
    float3 I = 0.5 + 0.5 * float3(cos(phR), cos(phG), cos(phB));
    float mu = (I.r + I.g + I.b) / 3.0;
    I = mix(float3(mu), I, 1.6);
    return clamp(I, 0.0, 1.0);
}
static float s8_wave(float2 p, constant Uniforms& u, texture2d<float> nt) {
    float t = u.time;
    float2 m = aspectCorrectedMouse(u.mouse, u.res);
    float d = length(p - m);

    float w = 0.0;
    w += 0.08 * sin(d * 10.0 - t * 3.0) * exp(-d * 1.0);
    w += 0.05 * sin(dot(p, float2(3.0, 2.0)) + t * 0.8);
    w += 0.04 * sin(dot(p, float2(-2.5, 3.5)) - t * 0.6);
    w += 0.03 * fbmExact(p * 2.5 + t * 0.1, nt);

    float2 cp = aspectCorrectedMouse(u.clickPos, u.res);
    float cd = length(p - cp);
    w += 0.15 * u.click * sin(cd * 22.0 - (1.0 - u.click) * 26.0) * exp(-cd * 1.8);
    return w;
}
fragment float4 fs8_oil(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                            texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;
    float2 m  = aspectCorrectedMouse(u.mouse, u.res);

    float e = 0.005;
    float h  = s8_wave(p, u, nt);
    float hx = s8_wave(p + float2(e, 0.0), u, nt);
    float hy = s8_wave(p + float2(0.0, e), u, nt);
    float3 n = normalize(float3((h - hx) / e, (h - hy) / e, 1.0));
    float3 V = float3(0.0, 0.0, -1.0);
    float cosT = max(dot(-V, n), 0.05);

    float t_nm = 180.0
               + 120.0 * fbm(p * 1.2 + float2(u.time * 0.08, -u.time * 0.06), nt)
               + 160.0 * h
               + 40.0  * sin(p.x * 3.0 + u.time * 0.3);
    t_nm += 80.0 * exp(-length(p - m) * 1.5);
    t_nm = clamp(t_nm, 40.0, 520.0);

    float3 film = s8_thinFilmCol(t_nm, cosT);

    float3 refr = refract(V, n, 1.0 / 1.33);
    float tt = (-0.6) / refr.z;
    float2 wp = p + refr.xy * tt;
    float caus = pow(fbm(wp * 3.5 + u.time * 0.2, nt), 3.0) * 2.2
               + pow(abs(sin(wp.x * 7.0 + u.time * 0.8) * sin(wp.y * 6.0 - u.time * 0.6)), 5.0) * 1.5;
    float3 water = mix(float3(0.02, 0.05, 0.08), float3(0.7, 0.95, 1.2), caus) * 0.8;

    float fres = pow(1.0 - cosT, 2.0);
    float3 col = mix(water * 0.6, film, 0.55 + 0.45 * fres);
    col += water * 0.25;

    float3 L = normalize(float3(0.3, 0.6, 1.0));
    float3 H = normalize(L - V);
    col += pow(max(dot(n, H), 0.0), 160.0) * float3(1.2, 1.15, 1.0) * 0.9;

    float edge = smoothstep(60.0, 30.0, t_nm);
    col = mix(col, float3(0.02, 0.02, 0.03), edge * 0.8);

    col *= 1.0 - 0.3 * length(p) * 0.55;
    col = pow(col, float3(0.95));
    return float4(grain(col, in.position, u.res, nt), 1.0);
}

// ======================================================================
// SHADER 09 — Bismuth hopper
// ======================================================================
static float s9_steps(float2 p, float time, texture2d<float> nt) {
    float2 q = p;
    q = rot(time * 0.08) * q;
    q += 0.15 * float2(fbmExact(p * 1.2, nt), fbmExact(p * 1.2 + 3.7, nt));
    float d = max(abs(q.x), abs(q.y));
    float tiers = 8.0;
    float s = floor(d * tiers);
    float inner = fract(d * tiers);
    float shelf = smoothstep(0.85, 1.0, inner);
    return s + shelf * 0.5;
}
static float s9_heightAt(float2 p, constant Uniforms& u, texture2d<float> nt) {
    float2 m = aspectCorrectedMouse(u.mouse, u.res);
    float heat = exp(-length(p - m) * 1.6);
    float2 pp = p - m * heat * 0.3;
    float s = s9_steps(pp, u.time, nt);
    float h = -s * 0.08;
    h += heat * 0.25;
    return h;
}
static float3 s9_oxide(float thickness_nm) {
    float phR = 2.0 * PI * 2.0 * 1.4 * thickness_nm / 680.0;
    float phG = 2.0 * PI * 2.0 * 1.4 * thickness_nm / 550.0;
    float phB = 2.0 * PI * 2.0 * 1.4 * thickness_nm / 440.0;
    return 0.5 + 0.5 * float3(cos(phR), cos(phG), cos(phB));
}
fragment float4 fs9_bismuth(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                            texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;
    float2 m  = aspectCorrectedMouse(u.mouse, u.res);

    float e = 0.004;
    float h  = s9_heightAt(p, u, nt);
    float hx = s9_heightAt(p + float2(e, 0.0), u, nt);
    float hy = s9_heightAt(p + float2(0.0, e), u, nt);
    float3 n = normalize(float3((h - hx) / e, (h - hy) / e, 1.0));

    float3 L = normalize(float3(0.6, 0.7, 0.4));
    float3 V = float3(0.0, 0.0, -1.0);
    float3 H = normalize(L - V);
    float NdotL = max(dot(n, L), 0.0);
    float spec = pow(max(dot(n, H), 0.0), 60.0);

    float tier = s9_steps(p, u.time, nt);
    float t_nm = 180.0 + tier * 60.0 + fbm(p * 4.0, nt) * 80.0 + exp(-length(p - m) * 1.6) * 120.0;
    float3 oxCol = s9_oxide(t_nm);

    float3 metal = float3(0.55, 0.56, 0.6);
    float oxMix = 0.7 + 0.3 * fbm(p * 5.0, nt);
    float3 base = mix(metal, oxCol, oxMix);

    float edge = smoothstep(0.3, 1.0, length(float2(h - hx, h - hy)) / e);
    float3 col = base * (0.35 + 0.75 * NdotL);
    col += spec * mix(float3(1.0), oxCol, 0.5) * 1.2;
    col += edge * oxCol * 0.4;

    float3 L2 = normalize(float3(-0.3, -0.6, 0.5));
    col += float3(0.3, 0.45, 0.7) * max(dot(n, L2), 0.0) * 0.15;

    float heat = exp(-length(p - m) * 1.8);
    col += float3(1.3, 0.4, 0.1) * heat * 0.35 * (0.7 + 0.3 * sin(u.time * 6.0));

    float cracks = smoothstep(0.45, 0.5, fract(tier * 0.5));
    col *= 1.0 - cracks * 0.25;

    float2 cp = aspectCorrectedMouse(u.clickPos, u.res);
    float cd = length(p - cp);
    col += u.click * s9_oxide(120.0 + cd * 600.0) * exp(-cd * 1.8) * 0.8;

    col *= 1.0 - 0.25 * length(p) * 0.55;
    col = pow(col, float3(0.92));
    return float4(grain(col, in.position, u.res, nt), 1.0);
}

// ======================================================================
// SHADER 10 — Gravitational lens
// ======================================================================
static float s10_stars(float2 p, float time, texture2d<float> nt) {
    float s = 0.0;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float2 q = p * (3.0 + fi * 5.0);
        float2 id = floor(q); float2 f = fract(q);
        float h = hash12(id + fi * 17.3);
        if (h > 0.985 - fi * 0.005) {
            float2 c = f - 0.5;
            float br = pow(1.0 - length(c) * 2.2, 16.0);
            float tw = 0.6 + 0.4 * sin(time * 3.0 + h * 40.0);
            s += br * tw * (1.0 - fi * 0.3);
        }
    }
    s += 0.18 * pow(smoothstep(0.55, 1.0, fbm(p * 1.2 + float2(0.0, time * 0.02), nt)), 2.0);
    return s;
}
static float3 s10_starColor(float2 p, float time, texture2d<float> nt) {
    float s = s10_stars(p, time, nt);
    float t = fbm(p * 0.6, nt);
    float3 tint = mix(float3(1.1, 0.95, 0.8), float3(0.8, 0.9, 1.2), t);
    float3 milky = mix(float3(0.04, 0.03, 0.08), float3(0.35, 0.25, 0.45), fbm(p * 2.0 + float2(time * 0.01, 0.0), nt));
    return tint * s + milky * 0.15;
}
static float3 s10_disk(float2 p, float2 m, float rs, float time, texture2d<float> nt) {
    float r = length(p - m);
    float a = atan2(p.y - m.y, p.x - m.x);
    float innerR = rs * 2.2;
    float outerR = rs * 6.5;
    if (r < innerR || r > outerR) return float3(0.0);
    float ang = a + time * 0.4 / (r * r + 0.2);
    float swirl = fbm(float2(cos(ang) * r * 2.0, sin(ang) * r * 2.0) + time * 0.2, nt);
    float beam = 0.5 + 0.5 * sin(ang * 1.0);
    float temp = smoothstep(outerR, innerR, r);
    float3 hot = mix(float3(1.4, 0.4, 0.1), float3(1.5, 1.3, 0.9), temp);
    float3 c = hot * swirl * (0.5 + 1.4 * beam) * temp;
    float edge = smoothstep(innerR * 0.95, innerR * 1.05, r) * (1.0 - smoothstep(outerR * 0.85, outerR, r));
    return c * edge;
}
fragment float4 fs10_lens(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                            texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;
    float2 m  = aspectCorrectedMouse(u.mouse, u.res);

    float rs = 0.15;
    rs *= 1.0 + u.click * 0.8;

    float2 d = p - m;
    float r = length(d);

    if (r < rs) {
        float glow = smoothstep(rs, rs * 0.9, r);
        return float4(grain(float3(glow * 0.15, glow * 0.05, 0.0), in.position, u.res, nt), 1.0);
    }

    float alpha = 2.0 * rs / r;
    alpha = min(alpha, 1.2);
    float2 sampleP = p - normalize(d) * alpha * rs * 2.5;

    float ring  = smoothstep(0.02, 0.0, abs(r - 1.5 * rs));
    float ering = smoothstep(0.05, 0.0, abs(r - 2.2 * rs)) * 0.6;

    float3 bg = s10_starColor(sampleP, u.time, nt);
    float3 dk = s10_disk(sampleP, m, rs, u.time, nt);

    float3 col = bg + dk;
    col += float3(1.3, 0.8, 0.4) * ring * 1.2;
    col += float3(0.9, 0.7, 1.0) * ering;

    float a = atan2(d.y, d.x);
    float dopp = smoothstep(-1.2, 1.2, sin(a)) * smoothstep(1.0, 3.0, 1.0 / max(r, 0.01));
    col += float3(-0.1, 0.05, 0.3) * dopp;

    col += float3(0.3, 0.15, 0.45) * exp(-r * 4.0) * 0.1;
    col *= 1.0 - 0.2 * length(p) * 0.4;
    col = col / (1.0 + col * 0.6);
    col = pow(col, float3(0.92));
    return float4(grain(col, in.position, u.res, nt), 1.0);
}

// ======================================================================
// SHADER 11 — Colour drift (macOS Drift-style flow-field ribbons)
// ======================================================================
// Nine layers of noise-warped ribbons, each with its own scale, drift speed
// and palette phase. The mouse is a soft attractor that bends the flow
// field toward itself — gentle enough that the ribbons feel like they're
// floating, not tethered.
static float3 s11_palette(float t) {
    return 0.55 + 0.45 * cos(2.0 * PI * (float3(1.0) * t + float3(0.10, 0.40, 0.62)));
}

fragment float4 fs11_drift(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                            texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;
    float2 m  = aspectCorrectedMouse(u.mouse, u.res);

    float3 col = float3(0.014, 0.018, 0.028);

    // Mouse deforms the flow field; falls off with distance so the rest of
    // the screen keeps its own motion.
    float2 mouseBend = (m - p) * 0.18 * exp(-length(p - m) * 1.1);

    // Seven layers — the 8th and 9th in the original were the "far thick
    // slow" band whose brightness mix value sat below 0.23, i.e. they
    // contributed <10% of the frame's luminance despite running two full
    // fbm() calls each. Dropping them saves ≈22% of the shader's fbm
    // evaluations; the remaining 7 layers still span near-thin-fast through
    // mid-range, so the ribbon silhouette is unchanged.
    const int LAYERS = 7;
    for (int i = 0; i < LAYERS; i++) {
        float fi = float(i);
        float layer = fi / float(LAYERS - 1);     // 0 = near-thin-fast, 1 = far-thick-slow

        float speed     = mix(0.38, 0.11, layer);
        float scale     = mix(1.60, 0.55, layer);
        float thickness = mix(0.045, 0.20, layer);
        float brightness = mix(0.85, 0.18, layer);

        // Coord in this layer's frame, drifting sideways with time.
        float2 q = p * scale + float2(u.time * speed * 0.25, 0.0);
        q += mouseBend * (0.35 + 0.65 * layer);

        // Two fbm-driven warps give that glassy, fluid, non-repeating motion.
        q += 0.42 * float2(
            fbm(q * 0.55 + float2(u.time * speed, fi * 11.3), nt),
            fbm(q * 0.55 + float2(fi * 7.1, -u.time * speed), nt)
        );

        // The ribbon lives at the 0.5 iso-contour of a slowly-drifting noise
        // field — i.e. the boundary between "light" and "dark" halves of
        // an fbm, which naturally traces long smooth curves.
        float field = fbm(q * 0.40 + float2(u.time * speed * 0.10, fi), nt);
        float d = field - 0.5;

        // Gaussian cross-section for soft, filmy edges.
        float alpha = exp(-(d * d) / (thickness * thickness) * 2.2);

        // Colour drifts slowly per-layer; noise breaks the banding.
        float colorT = fi * 0.11 + u.time * 0.025 + fbm(q * 0.8, nt) * 0.35;
        float3 c = s11_palette(colorT);

        col += c * alpha * brightness;
    }

    // Click releases a rainbow pulse.
    float2 cp = aspectCorrectedMouse(u.clickPos, u.res);
    float cd = length(p - cp);
    col += u.click * s11_palette(cd * 1.2 + u.time * 0.4) * exp(-cd * 1.8) * 0.75;

    // Gentle Reinhard tonemap + gamma.
    col = col / (1.0 + col * 0.42);
    col = pow(col, float3(0.86));

    // Subtle radial falloff so the centre pops.
    col *= 1.0 - 0.28 * length(p) * 0.5;

    return float4(grain(col, in.position, u.res, nt), 1.0);
}

// ======================================================================
// SHADER 12 — Copper flow field
// ======================================================================
// Grid of oriented copper streaks aligned to a curled, slowly-evolving flow
// field. Rods are long thin capsules (rounded caps, tapered brightness
// from tail to head). A separate noise masks density so most of the frame
// stays black — only the densest regions render streaks, giving the deep
// contrast of the reference image.
//
// Base motion: a gentle global "wind" advects the noise sample, so the
// whole field slowly drifts and individual rods sway in different phases.
// The cursor adds a local counter-clockwise vortex (hand-held fan), whose
// strength falls off with distance and ramps up with mouse speed.

// Single-octave angle field with strong wind advection — the whole pattern
// drifts visibly and individual angles turn noticeably over a few seconds.
// A second fine-scale octave used to add ~±0.8π extra jitter, but one
// octave already covers the full 2π rotation range, so dropping it halves
// the angle-field cost with no perceptible change to rod orientation.
static float s12_angleField(float2 p, float time, texture2d<float> nt) {
    float2 wind = float2(0.12, 0.06);
    float2 q    = p + time * wind;
    return vnoise(q * 0.55 + float2(time * 0.11, time * 0.08), nt) * 2.0 * PI;
}

// Density mask. Two-octave fbm-style sum. A third octave used to add
// ±0.166 amplitude; removing it barely shifts the statistics (mean ≈ 0.43,
// range ≈ [0, 0.85] vs. 0.44 / 0.88) but saves one vnoise call per rod.
//
// densityBias: shader opt.x  (default 0.45)  — higher = more dark zones
static float s12_density(float2 p, float time, float densityBias, texture2d<float> nt) {
    float2 q = p * 0.45 + float2(-time * 0.040, time * 0.034);
    float d  = 0.55 * vnoise(q, nt);
    d       += 0.3025 * vnoise(q * 2.03, nt);
    return d - densityBias * 0.55;
}

// Per-rod sway — faster phase and slightly larger amplitude than before
// so rods actively flutter, not just rotate.
static float2 s12_rodWobble(float2 cellHash, float2 seedG, float time) {
    return float2(
        sin(time * 0.85 + cellHash.x * 6.2831853 + seedG.y * 0.30),
        cos(time * 0.72 + cellHash.y * 6.2831853 + seedG.x * 0.30)
    ) * 0.14;
}

// Rods are drawn as instanced quads, one per grid cell, additively into an
// r16Float accumulation texture (pass 1), which fs12_flowfield then maps
// through the palette (pass 2). Each covered pixel pays for one capsule test
// per rod that actually touches it, instead of every pixel testing all nine
// neighbouring cells — about 1/20 of the fragment work at default settings.
//
// Options consumed from uniform `opt`:
//   opt.x = density bias     (0..1, default 0.40)  — higher = more dark
//   opt.y = rod length       (0..1, default 1.00)  — mapped to halfL
//   opt.z = swirl/curl amt   (0..1, default 1.00)  — scales angle-field
//   opt.w = wind speed       (0..1, default 0.70)  — scales time drift
constant float S12_SCALE = 30.0;   // grid cells per unit of p; Renderer sizes the instance grid from it
constant float S12_RAD   = 0.075;  // rod half-width, in cells

struct RodOut {
    float4 position [[position]];
    float2 local;              // (along, across) the rod axis, in cells, from the seed
    float  weight [[flat]];    // density fade for the whole rod
};

// grid = (first cell x, first cell y, cells per row, unused)
vertex RodOut vs12_rod(uint vid [[vertex_id]], uint iid [[instance_id]],
                       constant Uniforms& u [[buffer(0)]],
                       constant int4& grid [[buffer(1)]],
                       texture2d<float> nt [[texture(0)]]) {
    float2 cellId = float2(grid.x + int(iid) % grid.z, grid.y + int(iid) / grid.z);
    float timeScaled = u.time * (0.6 + u.opt.w * 1.4);
    float halfL = mix(0.40, 1.10, u.opt.y);
    float2 mouseW = aspectCorrectedMouse(u.mouse, u.res);

    float2 rand   = hash22(cellId);
    float2 seedG  = cellId + 0.5 + (rand - 0.5) * 0.55;
    seedG        += s12_rodWobble(rand, seedG, timeScaled);
    float2 seedW  = seedG / S12_SCALE;

    // Density sampled at the seed: rods fade or vanish as a whole.
    float mDist   = length(seedW - mouseW);
    float mPull   = u.mouseEffects * exp(-mDist * 1.2);
    float dens    = s12_density(seedW, timeScaled, u.opt.x, nt) + 0.70 * mPull;

    // Angle field. At swirl=0, rods align to a constant wind direction; at
    // swirl=1, the full curled noise field takes over.
    float ang     = s12_angleField(seedW, timeScaled, nt);
    ang           = mix(0.35, ang, clamp(0.10 + u.opt.z * 0.95, 0.0, 1.0));
    float2 dir    = float2(cos(ang), sin(ang));

    // Cursor vortex — only when mouse effects are on and the pull is
    // strong enough to matter (exp(-1.2 × 3.2) ≈ 0.021).
    if (u.mouseEffects > 0.5 && mPull > 0.02) {
        float2 radial = (seedW - mouseW) / max(mDist, 0.0001);
        float2 swirl  = float2(-radial.y, radial.x);
        float swirlStrength = mPull * (0.75 + min(length(u.mouseV) * 22.0, 1.5));
        dir           = normalize(mix(dir, swirl, clamp(swirlStrength, 0.0, 1.0)));
    }

    // Triangle-strip corner of the capsule's bounding box.
    float2 local = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0)
                 * float2(halfL + S12_RAD, S12_RAD);
    float2 p = (seedG + dir * local.x + float2(-dir.y, dir.x) * local.y) / S12_SCALE;

    RodOut o;
    // Rods in low-density regions collapse off-screen and are never rasterised.
    o.position = dens < 0.12 ? float4(-2.0, -2.0, 0.0, 1.0)
                             : float4(p.x * u.res.y / u.res.x, p.y, 0.0, 1.0);
    o.local    = local;
    o.weight   = smoothstep(0.08, 0.50, dens);
    return o;
}

fragment float fs12_rod(RodOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float halfL = mix(0.40, 1.10, u.opt.y);
    float al    = in.local.x, pe = in.local.y;
    float dEnd  = abs(al) - halfL;
    float dSeg  = (dEnd > 0.0) ? length(float2(dEnd, pe)) : abs(pe);
    float alpha = 1.0 - smoothstep(S12_RAD * 0.25, S12_RAD, dSeg);
    // Head-to-tail taper: tail fades, head stays bright.
    alpha      *= smoothstep(-0.18, 0.75, (al + halfL) / (2.0 * halfL));
    return alpha * in.weight;
}

fragment float4 fs12_flowfield(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                            texture2d<float> nt [[texture(0)]],
                            texture2d<float> rods [[texture(1)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;
    float total = rods.read(uint2(in.position.xy)).r;

    // User-configurable 3-stop palette. Boost past 1.0 so near-white stops
    // keep pop through the tonemap below.
    float3 black  = float3(0.0);
    float3 shadow = u.col0.xyz * 1.15;
    float3 mid    = u.col1.xyz * 1.30;
    float3 hot    = u.col2.xyz * 1.45;

    float3 col = mix(black,  shadow, smoothstep(0.06, 0.28, total));
    col        = mix(col,    mid,    smoothstep(0.30, 0.75, total));
    col        = mix(col,    hot,    smoothstep(0.95, 1.45, total));

    // Click shockwave uses the mid stop so it reads as part of the palette.
    float2 cp = aspectCorrectedMouse(u.clickPos, u.res);
    float  cd = length(p - cp);
    float  ringT = u.click * 2.4;
    col += u.click * mid * exp(-abs(cd - (1.0 - u.click) * ringT) * 3.0) * 0.7;

    // Softer Reinhard — preserves more of the bright mid-range without
    // letting the hot band clip to white.
    col = col / (1.0 + col * 0.18);
    col = pow(col, float3(0.95));

    // Softer vignette so corners don't go pitch-black.
    col *= 1.0 - 0.22 * length(p) * 0.40;

    return float4(grain(col, in.position, u.res, nt), 1.0);
}

// ======================================================================
// Shared by the pre-pass shaders below (13–22 were designed to fit a
// ~0.15 ms/frame budget on a 16" MBP at 1 px/pt; see `--bench`).
// ======================================================================
constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);

// Phosphor persistence: drawn over the accumulation texture with blend
// factors (zero, blendColor), so it scales what's there by the renderer's
// per-frame decay without reading it here.
fragment float fs_fade(VSOut in [[stage_in]]) { return 0.0; }

static inline float3 s_tonemap(float3 col, float k, float gamma) {
    col = col / (1.0 + col * k);
    return pow(max(col, 0.0), float3(gamma));
}

// ======================================================================
// SHADER 13 — Ripple tank interference
// ======================================================================
// Three dippers (plus the cursor) drive circular waves of one wavelength, so
// the surface is a plain sum of sines and its slope comes analytically from
// the same terms — a few sin/cos per pixel, no noise. Crests focus the
// overhead light into bright lines (the tank's shadowgraph); the floor grid
// is displaced by the slope.
static float s13_source(float2 p, float2 s, float phase, float amp, float t, thread float2& grad) {
    float2 d = p - s;
    float r = length(d) + 1e-4;
    float a = amp / sqrt(1.0 + 5.0 * r);
    float w = 40.0 * r - 3.0 * t + phase;
    grad += a * 40.0 * cos(w) * d / r;
    return a * sin(w);
}
fragment float4 fs13_ripple(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                            texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;
    float t   = u.time;

    float2 g = 0.0;
    float h = 0.0;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float2 s = float2(0.8 * cos(t * 0.045 + fi * 2.094), 0.55 * sin(t * 0.031 + fi * 2.094 + 0.6));
        h += s13_source(p, s, fi * 1.7, 0.36, t, g);
    }
    h += s13_source(p, aspectCorrectedMouse(u.mouse, u.res), 0.0, 0.36 * u.mouseEffects, t, g);

    // Dropped stone: a wave packet riding outward as the click decays.
    float cr = length(p - aspectCorrectedMouse(u.clickPos, u.res)) - (1.0 - u.click) * 1.8;
    h += 0.9 * u.click * exp(-cr * cr * 50.0) * sin(cr * 40.0);

    float crest = pow(saturate(0.55 + 0.8 * h), 5.0);       // crests converge light into lines
    float2 gl = abs(fract((p + g * 0.0015) * 6.0) - 0.5);   // floor tiles, refracted
    float grid = smoothstep(0.485, 0.5, max(gl.x, gl.y));

    float3 col = float3(0.008, 0.035, 0.05) + float3(0.04, 0.11, 0.13) * saturate(0.5 + 0.5 * h);
    col += float3(0.35, 0.88, 1.0) * crest * 1.6;
    col += float3(0.55, 0.85, 1.0) * grid * 0.035;
    col *= 1.0 - 0.15 * length(p);
    return float4(grain(s_tonemap(col, 0.55, 0.95), in.position, u.res, nt), 1.0);
}

// ======================================================================
// SHADER 14 — Topographic contours
// ======================================================================
// Four fast noise octaves of terrain, surveyed as isolines whose width is
// held at ~1 px with fwidth(). Below sea level the lines turn to soundings.
static float s14_height(float2 p, constant Uniforms& u, texture2d<float> nt) {
    float t = u.time * 0.012;
    float h = 0.52 * vnoise(p * 0.85 + float2(t, -0.6 * t), nt)
            + 0.26 * vnoise(p * 1.9 + float2(-0.8 * t, 0.5 * t) + 7.3, nt)
            + 0.13 * vnoise(p * 4.1 + float2(1.3 * t, t) + 3.1, nt)
            + 0.07 * vnoise(p * 8.7 + 11.9, nt);
    h += 0.42 * u.mouseEffects * exp(-length_squared(p - aspectCorrectedMouse(u.mouse, u.res)) * 5.0);
    // Meteor: a crater that opens and heals as the click decays.
    float cd = length(p - aspectCorrectedMouse(u.clickPos, u.res));
    float cr = 0.03 + 0.15 * sqrt(1.0 - u.click);
    h += u.click * (-0.3 * exp(-cd * cd / (cr * cr)) + 0.1 * exp(-(cd - cr) * (cd - cr) * 500.0));
    return h;
}
fragment float4 fs14_contour(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                             texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;
    float h = s14_height(p, u, nt);

    float L  = h * 22.0;                                     // 22 isolines per unit
    float aa = max(fwidth(L), 1e-4);
    float line  = saturate(1.0 - (0.5 - abs(fract(L) - 0.5)) / (aa * 1.1));
    float index = saturate(1.0 - (0.5 - abs(fract(L / 5.0) - 0.5)) * 5.0 / (aa * 1.9));

    const float sea = 0.36;
    float hAA  = max(fwidth(h), 1e-4);
    float land = smoothstep(sea - hAA, sea + hAA, h);
    float coast = saturate(1.0 - abs(h - sea) / (hAA * 1.4));

    // Hillshade from the screen-space slope (2×2-quad granularity is fine for
    // a shade this soft).
    float2 slope = float2(dfdx(h), -dfdy(h)) * u.res.y * 0.5;
    float shade = 0.85 + 0.35 * dot(normalize(float3(-slope * 0.12, 1.0)), normalize(float3(-0.6, 0.7, 0.6)));

    float3 ground = mix(float3(0.060, 0.072, 0.064), float3(0.15, 0.13, 0.095), smoothstep(sea, 0.95, h));
    float3 water  = mix(float3(0.016, 0.040, 0.075), float3(0.035, 0.085, 0.13), smoothstep(0.0, sea, h));
    float3 col = mix(water, ground * shade, land);

    float3 ink = mix(float3(0.45, 0.70, 0.90), mix(float3(0.84, 0.79, 0.66), float3(1.0, 0.78, 0.45),
                                                   smoothstep(0.7, 1.05, h)), land);
    col = mix(col, ink, max(line * mix(0.18, 0.36, land), index * mix(0.35, 0.75, land)));
    col = mix(col, float3(0.92, 0.88, 0.76), coast * 0.8);
    col *= 1.0 - 0.18 * length(p) * 0.5;
    return float4(grain(col, in.position, u.res, nt), 1.0);
}

// ======================================================================
// SHADER 15 — Suminagashi marbling
// ======================================================================
// Mathematical marbling (Jaffer & Lu): an ink drop of radius R at c pushes
// every point outward to c + d·sqrt(1 + R²/|d|²). Drops land in bursts of
// nine at one spot, alternating ink and clear water. Equal drops at one
// centre just nest, so a whole burst unwinds in a single step (its total
// area) and its rings follow from r² alone — ten bursts, back to front,
// compositing each one's ink, with no stored state.
constant int   S15_BURSTS = 10;
constant float S15_PER    = 9.0;           // drops per burst
constant float S15_PERIOD = 0.9;           // seconds between drops
constant float S15_R0     = 0.095;         // one drop's radius
constant float3 S15_WATER = float3(0.030, 0.038, 0.055);

static float3 s15_ink(float b, float k) {      // burst b, drop k (0 = first to land)
    if (glmod(k, 2.0) == 1.0) return S15_WATER;
    float c = glmod(b * 2.0 + floor(k * 0.5), 3.0);
    return c < 1.0 ? float3(0.86, 0.83, 0.76)               // rice-paper white
         : c < 2.0 ? float3(0.20, 0.30, 0.62)               // indigo
                   : float3(0.74, 0.25, 0.15);              // bengara red
}
// Burst n (0 = newest): scene[n] = (centre, total area, drops landed),
// scene[16 + n] = (newest drop's growth, burst id).
kernel void setup_fs15_marble(constant Uniforms& u [[buffer(0)]], device float4* scene [[buffer(1)]],
                              uint n [[thread_position_in_grid]]) {
    if (n >= uint(S15_BURSTS)) return;
    float t = u.time, aspect = u.res.x / u.res.y;
    float b = floor(t / (S15_PER * S15_PERIOD)) - float(n);
    float since = t / S15_PERIOD - b * S15_PER;             // drops landed so far
    float landed = min(floor(since) + 1.0, S15_PER);
    float grow = since < S15_PER ? 1.0 - pow(1.0 - saturate(fract(since) / 0.75), 3.0) : 1.0;
    // The pouring spot wanders, so each burst lands beside the last few and shoulders them aside.
    float2 c = float2(aspect * 0.62 * sin(b * 0.83 + 1.3), 0.62 * sin(b * 1.31))
             + (float2(hash12(float2(b, 3.7)), hash12(float2(b, 8.1))) - 0.5) * 0.3;
    scene[n] = float4(c, (landed - 1.0 + grow) * S15_R0 * S15_R0, landed);
    scene[16 + n] = float4(grow, b, 0.0, 0.0);
}
fragment float4 fs15_marble(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                            constant float4* scene [[buffer(1)]],
                            texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;
    float aspect = u.res.x / u.res.y;
    float t = u.time;

    // The water slowly turns, and the cursor drags the surface the way it moves.
    float2 q = rot(0.35 * sin(t * 0.06) * exp(-dot(p, p) * 0.7)) * p;
    float2 m = aspectCorrectedMouse(u.mouse, u.res);
    float2 vel = u.mouseV * float2(2.0 * aspect, 2.0) / max(u.dt, 1e-3);
    q -= u.mouseEffects * clamp(vel, -3.0, 3.0) * 0.05 * exp(-length_squared(p - m) * 20.0);

    float pix = 2.0 / u.res.y;
    float stretch = 1.0;                    // radial stretch picked up while unwinding
    float3 col = 0.0;
    float rem = 1.0;
    const float a0 = S15_R0 * S15_R0;       // one drop's area, in r² units

    // A click is the newest drop: it swells, then relaxes away.
    {
        float Rc = u.click * (1.0 - u.click) * 0.8;
        float2 cp = aspectCorrectedMouse(u.clickPos, u.res);
        float2 d = q - cp;
        float r = length(d) + 1e-5;
        float inside = smoothstep(Rc + pix, Rc - pix, r);
        col += inside * float3(0.95, 0.55, 0.30);
        rem = 1.0 - inside;
        q = cp + d * sqrt(max(1.0 - Rc * Rc / (r * r), 0.0));
    }

    for (int n = 0; n < S15_BURSTS && rem > 0.01; n++) {
        float4 B = scene[n];                                 // centre, total area, drops landed
        float2 c = B.xy;
        float A = B.z, landed = B.w;
        float grow = scene[16 + n].x, b = scene[16 + n].y;
        float2 d = q - c;
        float r2 = dot(d, d) + 1e-10;
        float r = sqrt(r2);
        float aa = pix * stretch;
        float inside = smoothstep(sqrt(A) + aa, sqrt(A) - aa, r);
        if (inside > 0.0) {
            // Rings by area: the newest drop is the centre disc, older ones
            // nest outward, one drop's area each.
            float x = (r2 - grow * a0) / a0;
            float k = x < 0.0 ? landed - 1.0 : landed - 2.0 - floor(x);
            float f = fract(x);
            float edge = aa * 2.0 * r / a0;                  // one pixel, in x units
            float3 ring = s15_ink(b, k);
            float3 other = s15_ink(b, k + 1.0);              // inks alternate with water
            float w = x < 0.0 ? 0.0 : 0.5 * saturate(1.0 - min(f, 1.0 - f) / max(edge, 1e-4));
            float3 ink = mix(ring, other, w);
            ink = mix(ink, S15_WATER, smoothstep(0.6, 1.0, float(n) / float(S15_BURSTS)));
            col += rem * inside * ink;
            rem *= 1.0 - inside;
        }
        float r0 = sqrt(max(r2 - A, 1e-10));                 // undo the burst
        stretch = min(stretch * r / r0, 60.0);
        q = c + d * (r0 / r);
    }
    col += rem * S15_WATER;
    col *= 1.0 - 0.2 * length(p) * 0.5;
    return float4(grain(col, in.position, u.res, nt), 1.0);
}

// ======================================================================
// SHADER 16 — Lava lamp wax
// ======================================================================
// Wax rides a convection cycle: blobs bulge out of a molten pool over the
// bulb, rise while hot (stretched by the climb), cool and linger near the top,
// then sink back and melt in, merging and splitting as their paths cross. The
// field is f = Σ r²/|d|² plus the pool's r²/dy². setup_fs16_lava places the
// wax once per frame and keeps its own clock in scene[63], so the Flow slider
// changes speed without the blobs jumping. The pixel loop sums f, its gradient
// and a field-weighted temperature in one pass; the dome normal comes from
// h = √(1 − 1/f), which is an exact hemisphere for a lone blob.
// opt = (flow, wax amount, blob size, glow); col0 solvent, col1 wax, col2 glow.
// scene[0] = (term count, clock), scene[1+k] = (centre, r², 1/stretch),
// scene[33+k].x = temperature, scene[63] = (whole seconds, tag, fraction).
constant int   S16_BLOBS = 14;                 // at full wax
constant float S16_TAG   = 16.0625;
constant float S16_W     = 2.0 * PI / 3600.0;  // every motion repeats on the hour-long clock wrap
kernel void setup_fs16_lava(constant Uniforms& u [[buffer(0)]], device float4* scene [[buffer(1)]],
                            uint i [[thread_position_in_grid]]) {
    // Clock as whole seconds + fraction, wrapped hourly: float stays exact for days.
    float4 st = scene[63];
    bool ok = st.y == S16_TAG;
    float lo = (ok ? st.z : 0.0) + u.dt * exp2((u.opt.x - 0.4) * 3.5);
    float hi = glmod((ok ? st.x : 0.0) + floor(lo), 3600.0);
    lo = fract(lo);
    float clock = hi + lo;
    threadgroup_barrier(mem_flags::mem_device);         // everyone has read scene[63]

    float waxN = mix(4.0, float(S16_BLOBS), u.opt.y);
    float size = mix(0.7, 1.4, u.opt.z);
    if (i == 0) {
        scene[63] = float4(hi, S16_TAG, lo, 0.0);
        scene[0] = float4(2.0 + ceil(waxN), clock, 0.0, 0.0);
    }
    if (i >= uint(2 + S16_BLOBS)) return;
    float aspect = u.res.x / u.res.y;
    float2 c; float r, st2 = 1.0, T = 1.0;
    if (i == 0) {                       // the heating coil: wax gathers at the cursor
        c = aspectCorrectedMouse(u.mouse, u.res);
        r = 0.085 * size * u.mouseEffects;
    } else if (i == 1) {                // a calved bubble rising from the click
        c = aspectCorrectedMouse(u.clickPos, u.res) + float2(0.0, (1.0 - u.click) * 1.1);
        r = 0.12 * size * sqrt(u.click);
    } else {
        float j = float(i - 2);
        float h1 = hash12(float2(j, 4.2)), h2 = hash12(float2(j, 8.1)), h3 = hash12(float2(j, 1.7));
        // One lap every 38–56 s: a brisk hot climb (40%), a slow cool sink (60%).
        float ph = fract(clock * (64.0 + floor(h1 * 31.0)) / 3600.0 + h2);
        float q = ph < 0.4 ? ph * 1.25 : 0.5 + (ph - 0.4) * (0.5 / 0.6);
        float s = 0.5 - 0.5 * cos(2.0 * PI * q);
        s = mix(s, s * s * (3.0 - 2.0 * s), 0.6);         // dwell in the pool and under the cap
        c.y = mix(-1.22, 0.45 + 0.6 * h3, s);
        c.x = (fract(j * 0.618034 + 0.13) * 2.0 - 1.0) * aspect * 0.8
            + 0.25 * sin(clock * S16_W * (5.0 + floor(h3 * 5.0)) + h1 * 6.28)
            + 0.05 * sin(4.0 * PI * q + j);
        float climb = abs(sin(2.0 * PI * q));
        T = 0.5 + 0.5 * cos(2.0 * PI * (q - 0.12));        // hottest just after leaving the pool
        st2 = 1.0 + climb * (q < 0.5 ? 0.45 : 0.2);         // stretched by the climb
        r = (0.10 + 0.075 * h2) * size * (0.9 + 0.15 * T) * saturate(waxN - j);
    }
    scene[1 + i]  = float4(c, r * r, 1.0 / st2);
    scene[33 + i] = float4(T, 0.0, 0.0, 0.0);
}
fragment float4 fs16_lava(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                          constant float4* scene [[buffer(1)]],
                          texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;
    float4 hd = scene[0];
    int n = int(hd.x);
    float glow = mix(0.25, 1.75, u.opt.w);

    // The pool: molten wax lying over the bulb, its surface slowly heaving.
    float py = p.y + 1.14 - 0.035 * sin(p.x * 2.3 + hd.y * S16_W * 120.0) - 0.02 * sin(p.x * 5.1 - hd.y * S16_W * 77.0);
    py = max(py, 0.02);
    float f = 0.028 / (py * py);
    float Tw = 0.7 * f;
    float2 g = float2(0.0, -2.0 * f / py);
    for (int k = 1; k <= n; k++) {
        float4 b = scene[k];
        float2 d = p - b.xy;
        d.y *= b.w;
        float inv = 1.0 / (dot(d, d) + 1e-4);
        float kk = b.z * inv;
        f += kk;
        Tw += kk * scene[32 + k].x;
        g -= (2.0 * kk * inv) * float2(d.x, d.y * b.w);
    }
    float T = Tw / f;

    // Edge AA from the analytic gradient: f's change across one pixel.
    float aa = length(g) * (1.5 / u.res.y) + 1e-4;
    float body = smoothstep(1.0 - aa, 1.0 + aa, f);

    // Lamp light: the bulb under the glass, fading upward.
    float bulb = exp(-(p.y + 1.0) * 1.25) * (1.0 - 0.1 * p.x * p.x);

    // Wax: dome normal, lit through from below; thin edges and hot wax glow.
    float h = sqrt(max(1.0 - 1.0 / f, 1e-3));
    float3 nrm = normalize(float3(g * (-0.07 / (h * f * f)), 1.0));
    float wrap = saturate((dot(nrm, float3(0.0, -0.8, 0.6)) + 0.5) / 1.5);
    float spec = saturate(dot(nrm, float3(-0.28, 0.34, 0.9)));            // soft sheen from the room, upper left
    spec *= spec; spec *= spec; spec *= spec; spec *= spec;
    float thin = (1.0 - h) * (1.0 - h);
    float3 wax = u.col1.rgb * (0.3 + 0.8 * wrap) * (0.55 + 0.6 * bulb + 0.3 * T);
    wax = mix(wax, u.col2.rgb, saturate(0.35 * T * T * glow));
    wax += u.col2.rgb * thin * (0.25 + 0.6 * T) * glow;
    wax += spec * 0.16;

    // Solvent: tinted by the bulb, with the wax's glow scattered around it.
    float3 liquid = u.col0.rgb * (0.22 + 0.95 * bulb * glow);
    liquid += u.col2.rgb * smoothstep(0.2, 1.0, f) * (0.06 + 0.22 * T) * glow;

    float3 col = mix(liquid, wax, body);
    col *= 1.25 - 0.11 * length(p);                     // exposure and vignette
    return float4(grain(col / (1.0 + 0.35 * col), in.position, u.res, nt), 1.0);
}

// ======================================================================
// SHADER 17 — Spiral galaxy
// ======================================================================
// Arms are a log-spiral density wave in closed form (rotating rigidly, as
// density waves do — no winding up over hours); one fast noise sample adds
// star-forming knots, and the background stars are one cell per layer.
static float3 s17_stars(float2 p, float t) {
    float3 s = 0.0;
    for (int l = 0; l < 2; l++) {
        float2 q = p * (16.0 + 22.0 * float(l)) + float(l) * 31.7;
        float2 id = floor(q);
        float h = hash12(id);
        if (h > 0.92) {
            float2 o = float2(hash12(id + 7.1), hash12(id + 3.3)) * 0.6 + 0.2;
            float d2 = length_squared(fract(q) - o);
            float tw = 0.7 + 0.3 * sin(t * 1.7 + h * 60.0);
            s += mix(float3(0.7, 0.8, 1.0), float3(1.0, 0.85, 0.65), fract(h * 37.0))
               * exp(-d2 * 900.0) * tw * (1.0 - 0.4 * float(l));
        }
    }
    return s;
}
fragment float4 fs17_galaxy(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                            texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;
    float t = u.time;

    // The cursor tilts and turns the disk.
    float2 mo = (u.mouse - 0.5) * u.mouseEffects;
    float2 q = rot(0.45 + mo.x * 1.4) * p * 0.62;
    q.y /= max(cos(0.85 + mo.y * 0.9), 0.2);
    float r = length(q);
    float spin = t * 0.025;
    float psi = 2.0 * (atan2(q.y, q.x) - spin) - log(r + 1e-3) * 4.4;

    float arm  = pow(0.5 + 0.5 * cos(psi), 3.0);
    float dust = pow(0.5 + 0.5 * cos(psi + 0.9), 10.0) * smoothstep(0.05, 0.25, r);
    float disk = exp(-r * 3.0);
    float2 qk = rot(spin + 0.6) * q;
    float knots = smoothstep(0.66, 0.9, 0.6 * vnoise(qk * 13.0, nt) + 0.4 * vnoise(rot(1.1) * qk * 29.0 + 5.0, nt))
                * smoothstep(0.3, 0.85, arm);

    float3 col = float3(0.42, 0.58, 1.0) * disk * (0.22 + 1.5 * arm);
    col += float3(1.0, 0.38, 0.62) * knots * disk * 2.6;
    col *= 1.0 - 0.75 * dust;
    col += float3(1.0, 0.82, 0.56) * (exp(-r * r * 60.0) * 2.2 + exp(-r * 9.0) * 0.45);   // bulge
    col += float3(0.14, 0.11, 0.24) * exp(-r * 1.3) * 0.3;                                // halo
    col += s17_stars(p, t) * saturate(1.0 - disk * 2.5);

    // Supernova: a flare with diffraction spikes, fading with the click.
    float2 d = p - aspectCorrectedMouse(u.clickPos, u.res);
    float2 ad = abs(d);
    col += u.click * float3(1.0, 0.92, 0.82) * (exp(-dot(d, d) * 900.0) * 4.0
         + (exp(-ad.x * 70.0 - ad.y * 2.5) + exp(-ad.y * 70.0 - ad.x * 2.5)) * 0.7);

    col *= 1.0 - 0.12 * length(p);
    return float4(grain(s_tonemap(col, 0.6, 0.9), in.position, u.res, nt), 1.0);
}

// ======================================================================
// SHADER 18 — Halftone tide
// ======================================================================
// Three rotated dot screens (R, G, B) over a rolling swell. Each pixel looks
// at one cell per screen and evaluates the swell at that cell's centre, so
// every dot is a clean disc and dots never need their neighbours.
static float s18_swell(float2 p, constant Uniforms& u, texture2d<float> nt, float shift) {
    float t = u.time;
    float v = 0.5 + 0.28 * sin(p.x * 1.7 + t * 0.5 + shift + 1.2 * sin(p.y * 1.3 - t * 0.29));
    v += 0.24 * (vnoise(p * 1.4 + float2(t * 0.05, -t * 0.035) + shift, nt) - 0.5);
    v += 0.55 * u.mouseEffects * exp(-length_squared(p - aspectCorrectedMouse(u.mouse, u.res)) * 7.0);
    float cd = length(p - aspectCorrectedMouse(u.clickPos, u.res)) - (1.0 - u.click) * 1.5;
    v += 0.6 * u.click * exp(-cd * cd * 40.0);
    return saturate(v);
}
fragment float4 fs18_halftone(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                              texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;
    const float cell = 1.0 / 24.0;
    float aa = 2.0 / (u.res.y * cell);                      // one pixel, in cell units

    float3 col = float3(0.022, 0.022, 0.028);
    for (int c = 0; c < 3; c++) {
        float a = 0.26 + 0.52 * float(c);                   // 15°, 45°, 75°
        float2x2 R = rot(a);
        float2 q = R * p / cell;
        float2 id = floor(q) + 0.5;
        float v = s18_swell(transpose(R) * (id * cell), u, nt, float(c) * 0.35);
        float dotMask = smoothstep(0.5 * sqrt(v) + aa, 0.5 * sqrt(v) - aa, length(q - id));
        col += (c == 0 ? float3(1.0, 0.22, 0.30) : c == 1 ? float3(0.15, 0.95, 0.55) : float3(0.22, 0.42, 1.0))
             * dotMask * 0.85;
    }
    col *= 1.0 - 0.15 * length(p) * 0.5;
    return float4(grain(col, in.position, u.res, nt), 1.0);
}

// ======================================================================
// SHADER 19 — Stained glass
// ======================================================================
// One 3×3 Voronoi search gives the nearest and second-nearest seeds; their
// distance gap is the lead came. Colour, texture and light are per pane.
// sin(2πx) to within ~5%, without a transcendental — plenty for a wobble.
static inline float2 s_psin(float2 x) { float2 s = fract(x) - 0.5; return -8.0 * s * (1.0 - 2.0 * abs(s)); }

constant float3 S19_PANES[6] = {
    float3(0.78, 0.06, 0.10), float3(0.07, 0.20, 0.78), float3(0.04, 0.55, 0.24),
    float3(0.92, 0.55, 0.06), float3(0.46, 0.10, 0.66), float3(0.70, 0.74, 0.66),
};
fragment float4 fs19_glass(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                           texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;
    const float scale = 4.2;
    float2 q = p * scale;
    float2 n = floor(q), f = fract(q);

    float d1 = 8.0, d2 = 8.0;
    float2 id = 0.0, seed = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 g = float2(float(i), float(j));
            float3 h3 = fract(float3((n + g).xyx) * float3(0.1031, 0.1030, 0.0973));
            h3 += dot(h3, h3.yzx + 33.33);
            float2 o = 0.5 + 0.38 * s_psin(u.time * 0.016 + fract((h3.xx + h3.yz) * h3.zy));
            float2 r = g + o - f;
            float d = dot(r, r);
            if (d < d1) { d2 = d1; d1 = d; id = n + g; seed = n + g + o; }
            else if (d < d2) { d2 = d; }
        }
    }
    float gap = sqrt(d2) - sqrt(d1);                        // 0 on a seam
    float px  = scale * 2.0 / u.res.y;
    float lead = 1.0 - smoothstep(0.06, 0.06 + 2.0 * px, gap);

    float h = hash12(id * 1.37 + 0.5);
    float3 pane = S19_PANES[int(h * 5.999)] * (0.7 + 0.55 * fract(h * 17.0));
    float streaks = vnoise(q * float2(6.0, 1.4) + id * 3.1, nt);     // cathedral-glass ripple

    // The sun behind the window sits at the cursor (or upper right).
    float aspect = u.res.x / u.res.y;
    float2 sun = mix(float2(0.55 * aspect, 0.5), aspectCorrectedMouse(u.mouse, u.res), u.mouseEffects);
    float light = 0.26 + 1.7 * exp(-length_squared(p - sun) * 2.2);
    // Click: a pulse of light runs pane to pane, keyed on each pane's seed.
    float cd = length(seed / scale - aspectCorrectedMouse(u.clickPos, u.res)) - (1.0 - u.click) * 2.2;
    light += 1.6 * u.click * exp(-cd * cd * 10.0);

    float3 col = pane * light * (0.82 + 0.35 * streaks);
    col *= 0.6 + 0.4 * smoothstep(0.0, 0.35, gap);          // darker toward the leading
    col = mix(col, float3(0.022, 0.022, 0.026), lead);
    col += float3(1.0, 0.85, 0.6) * exp(-length(p - sun) * 2.6) * 0.12;
    col *= 1.0 - 0.15 * length(p) * 0.5;
    return float4(grain(s_tonemap(col, 0.4, 0.95), in.position, u.res, nt), 1.0);
}

// ======================================================================
// SHADER 20 — Synchronous fireflies
// ======================================================================
// 480 instanced glow sprites summed into the accumulation texture. Fireflies
// between flashes collapse off-screen, so only the lit ones cost fragments.
// Flash trains (five pulses, then dark) drift in and out of step across the
// swarm, like Photinus carolinus.
struct FlyOut {
    float4 position [[position]];
    float2 local;                       // -1..1 across the sprite
    float  brightness [[flat]];
};
vertex FlyOut vs20_fly(uint vid [[vertex_id]], uint iid [[instance_id]],
                       constant Uniforms& u [[buffer(0)]]) {
    float i = float(iid);
    float aspect = u.res.x / u.res.y;
    float t = u.time;
    float h1 = hash12(float2(i, 1.7)), h2 = hash12(float2(i, 5.3));
    float h3 = hash12(float2(i, 9.1)), h4 = hash12(float2(i, 2.9));
    float depth = 0.35 + 0.65 * h3;                         // 1 = near

    // Home over the meadow (denser near the grass), slow wander and bob.
    float2 pos = float2((h1 * 2.0 - 1.0) * aspect * 1.08, mix(-0.92, 0.45, h2 * h2));
    pos.x += 0.22 * sin(t * (0.05 + 0.04 * h4) + h1 * 40.0) + 0.05 * sin(t * 0.33 + h2 * 20.0);
    pos.y += 0.07 * sin(t * (0.09 + 0.05 * h1) + h3 * 30.0) + 0.02 * sin(t * 1.1 + h4 * 50.0);
    float2 dm = aspectCorrectedMouse(u.mouse, u.res) - pos;     // drawn to the cursor
    pos += dm * 0.45 * u.mouseEffects * exp(-dot(dm, dm) * 3.0);

    // Five pulses over 2.2 s every 5.2 s; `sync` slowly pulls the phases together.
    float sync = smoothstep(0.15, 0.85, 0.5 + 0.5 * sin(t * 0.04));
    float tau = glmod(t + mix(h4, 0.0, sync) * 4.6 + h1 * 0.15, 4.6);
    float flash = tau < 2.6 ? pow(max(0.0, sin(tau * PI / 0.52)), 3.0) : 0.0;
    flash = max(flash, u.click * u.click);                  // click: the swarm answers at once

    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    float2 pp = pos + corner * (0.04 + 0.07 * depth);
    FlyOut o;
    o.position = flash < 0.01 ? float4(-2.0, -2.0, 0.0, 1.0) : float4(pp.x / aspect, pp.y, 0.0, 1.0);
    o.local = corner;
    o.brightness = flash * (0.35 + 0.65 * depth);
    return o;
}
fragment float fs20_fly(FlyOut in [[stage_in]]) {
    float d2 = dot(in.local, in.local);
    return in.brightness * (1.4 * exp(-d2 * 60.0) + 0.22 * exp(-d2 * 6.0));
}
fragment float4 fs20_fireflies(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                               texture2d<float> nt [[texture(0)]],
                               texture2d<float> glowTex [[texture(1)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;
    float t = u.time;
    float px = 2.0 / u.res.y;
    float glow = glowTex.read(uint2(in.position.xy)).r;

    float3 col = mix(float3(0.012, 0.022, 0.035), float3(0.035, 0.05, 0.085), smoothstep(-0.3, 1.0, p.y));
    // Distant tree line and a foreground of grass blades, both silhouettes.
    float tl = -0.12 + 0.2 * vnoise(float2(p.x * 2.0, 0.5), nt) + 0.07 * vnoise(float2(p.x * 9.0, 3.5), nt);
    col = mix(col, float3(0.006, 0.012, 0.012), smoothstep(tl + px, tl - px, p.y));
    col += float3(0.03, 0.045, 0.05) * smoothstep(-0.9, -0.35, p.y) * smoothstep(0.1, -0.5, p.y)
         * vnoise(p * float2(1.2, 3.0) + float2(t * 0.02, 0.0), nt);   // low mist
    float bx = p.x * 70.0 + 0.6 * sin(t * 0.7 + p.x * 3.0) * (p.y + 1.0);
    float top = -0.80 + 0.13 * hash12(float2(floor(bx), 2.0)) * (1.0 - 2.0 * abs(fract(bx) - 0.5));
    col = mix(col, float3(0.004, 0.008, 0.006), smoothstep(top + px, top - px, p.y));

    col += float3(0.62, 1.0, 0.22) * glow * 1.2 + float3(1.0, 1.0, 0.75) * saturate(glow - 0.6) * 0.8;
    return float4(grain(s_tonemap(col, 0.4, 0.95), in.position, u.res, nt), 1.0);
}

// ======================================================================
// SHADER 21 — Phosphor Lissajous
// ======================================================================
// A three-axis Lissajous knot tumbling in 3-D, drawn as 1024 instanced beam
// segments into the accumulation texture. The renderer fades that texture
// (120 ms half-life) instead of clearing it — the phosphor's persistence.
// Each segment adds the Gaussian beam integrated along its length (erf), so
// joints don't double up, scaled by 1/length: a slow beam burns brighter.
constant float S21_SEGMENTS = 1024.0;
constant float S21_SPAN     = 2.0 * 6.2831853;              // two passes of the figure

static float3 s21_beam(float s, constant Uniforms& u) {
    float t = u.time;
    float2 mo = (u.mouse - 0.5) * u.mouseEffects;
    float b = 2.0 + 0.5 * sin(t * 0.021) + mo.x * 1.2;       // cursor X: frequency ratio
    float c = 5.0 + 0.5 * sin(t * 0.013);
    float3 v = float3(sin(3.0 * s + t * 0.11), sin(b * s + 1.3 + mo.y * PI), sin(c * s + t * 0.07));
    v.xz = rot(t * 0.17) * v.xz;                             // slow tumble
    v.yz = rot(0.4 + 0.3 * sin(t * 0.05)) * v.yz;
    return v;
}
static inline float s21_erf(float x) { return tanh(1.2027 * x); }   // close enough for a glow

struct TraceOut {
    float4 position [[position]];
    float2 local;                      // (along, across) from the segment start, in p units
    float  len [[flat]];
    float  energy [[flat]];
};
vertex TraceOut vs21_trace(uint vid [[vertex_id]], uint iid [[instance_id]],
                           constant Uniforms& u [[buffer(0)]]) {
    float ds = S21_SPAN / S21_SEGMENTS;
    float3 A = s21_beam(float(iid) * ds, u), B = s21_beam(float(iid + 1) * ds, u);
    float2 a = A.xy * 0.8, b = B.xy * 0.8;
    float len = max(length(b - a), 1e-5);
    float2 dir = (b - a) / len, nrm = float2(-dir.y, dir.x);
    const float w = 0.03;                                    // covers the halo
    float along = (vid & 1) ? len + w : -w;
    float across = (vid & 2) ? w : -w;
    float2 pos = a + dir * along + nrm * across;

    TraceOut o;
    o.position = float4(pos.x * u.res.y / u.res.x, pos.y, 0.0, 1.0);
    o.local = float2(along, across);
    o.len = len;
    float depth = 0.55 + 0.45 * (0.5 + 0.25 * (A.z + B.z));  // near side brighter
    o.energy = u.dt * 2.2 * (ds / len) * depth * (1.0 + 4.0 * u.click);
    return o;
}
fragment float fs21_trace(TraceOut in [[stage_in]]) {
    float x = in.local.x, y = in.local.y;
    float core = exp(-y * y / (0.0035 * 0.0035)) * (s21_erf((in.len - x) / 0.0035) + s21_erf(x / 0.0035));
    float halo = exp(-y * y / (0.012 * 0.012)) * (s21_erf((in.len - x) / 0.012) + s21_erf(x / 0.012));
    return in.energy * (core * 0.0035 + halo * 0.012 * 0.3) * 160.0;
}
fragment float4 fs21_phosphor(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                              texture2d<float> nt [[texture(0)]],
                              texture2d<float> trace [[texture(1)]]) {
    // A little barrel distortion, read through the curved glass.
    float2 uv = in.position.xy / u.res;
    float2 c = uv - 0.5;
    float2 uvb = 0.5 + c * (1.0 + 0.07 * dot(c, c));
    float e = trace.sample(linearClamp, uvb).r;

    float2 g = uvb * float2(10.0, 8.0);                      // graticule
    float2 gp = abs(fract(g + 0.5) - 0.5) / fwidth(g);
    float grid = saturate(1.0 - min(gp.x, gp.y)) * 0.5;
    float2 cc = abs(uvb - 0.5) * float2(10.0, 8.0);
    float ticks = (min(cc.x, cc.y) < 0.06 ? 1.0 : 0.0) * (fract(max(cc.x, cc.y) * 5.0) < 0.12 ? 1.0 : 0.0);

    float3 col = float3(0.010, 0.022, 0.018) * (1.0 - 0.7 * dot(c, c) * 2.0);
    col += float3(0.30, 0.55, 0.40) * (grid * 0.12 + ticks * 0.12);
    col += float3(0.10, 0.85, 0.36) * (1.0 - exp(-e * 1.6)) + float3(0.75, 1.0, 0.82) * smoothstep(1.4, 3.5, e);
    col *= step(abs(uvb.x - 0.5), 0.5) * step(abs(uvb.y - 0.5), 0.5);   // bezel
    return float4(grain(col, in.position, u.res, nt), 1.0);
}

// ======================================================================
// SHADER 22 — Turing coral (Gray–Scott)
// ======================================================================
// State lives in an rg16Float texture at 1/3 of the drawable: R = U (feed),
// G = V (catalyst). The renderer runs ks22_step ~480×/s, ping-ponging two
// textures; fs22_turing only shades the latest one. Feed and kill rates drift
// across the screen and through time, so spots, worms and coral keep trading
// places instead of freezing into one finished pattern.
fragment float2 fs22_seed(VSOut in [[stage_in]]) {
    float v = step(0.97, hash12(floor(in.position.xy / 6.0)));
    return float2(1.0 - 0.5 * v, 0.25 * v);
}
// One step per compute dispatch: a chain of dependent dispatches costs far
// less than a chain of render passes (~40 µs of fixed overhead each on Apple
// GPUs). The repeat sampler wraps the toroidal 3×3 neighbourhood in hardware.
constexpr sampler s22_wrap(filter::nearest, address::repeat);
kernel void ks22_step(constant Uniforms& u [[buffer(0)]],
                      texture2d<float> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 sz = float2(dst.get_width(), dst.get_height());
    float2 uv = (float2(gid) + 0.5) / sz;
    float2 v = src.sample(s22_wrap, uv).rg;
    float2 lap = -v
        + 0.20 * (src.sample(s22_wrap, uv, int2(1, 0)).rg + src.sample(s22_wrap, uv, int2(-1, 0)).rg
                + src.sample(s22_wrap, uv, int2(0, 1)).rg + src.sample(s22_wrap, uv, int2(0, -1)).rg)
        + 0.05 * (src.sample(s22_wrap, uv, int2(1, 1)).rg + src.sample(s22_wrap, uv, int2(-1, -1)).rg
                + src.sample(s22_wrap, uv, int2(1, -1)).rg + src.sample(s22_wrap, uv, int2(-1, 1)).rg);
    int2 c = int2(gid);
    float F = 0.0545 + 0.007 * sin(uv.x * 4.0 + u.time * 0.021);
    float k = 0.0620 + 0.0016 * sin(uv.y * 5.0 - u.time * 0.017);
    float r = v.x * v.y * v.y;
    float2 n = saturate(v + float2(1.0 * lap.x - r + F * (1.0 - v.x),
                                   0.5 * lap.y + r - (F + k) * v.y));

    // The moving cursor drips catalyst; a click seeds a ring.
    float2 cell = float2(c);
    float md = length(cell - float2(u.mouse.x, 1.0 - u.mouse.y) * float2(sz));
    float moving = smoothstep(0.0002, 0.0015, length(u.mouseV));
    n.y = max(n.y, 0.35 * u.mouseEffects * moving * (1.0 - smoothstep(2.0, 3.5, md)));
    float cr = abs(length(cell - float2(u.clickPos.x, 1.0 - u.clickPos.y) * float2(sz)) - 24.0);
    n.y = max(n.y, 0.35 * step(0.96, u.click) * (1.0 - smoothstep(1.0, 2.5, cr)));
    dst.write(float4(n, 0.0, 0.0), gid);
}
fragment float4 fs22_turing(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                            texture2d<float> nt [[texture(0)]],
                            texture2d<float> state [[texture(1)]]) {
    float2 uv = in.position.xy / u.res;
    float2 tx = 1.0 / float2(state.get_width(), state.get_height());
    float V  = state.sample(linearClamp, uv).g;
    float Vr = state.sample(linearClamp, uv + float2(tx.x, 0)).g;
    float Vd = state.sample(linearClamp, uv + float2(0, tx.y)).g;
    float3 n = normalize(float3(V - Vr, Vd - V, 0.06));     // V read as height (uv y runs down)
    float diff = max(dot(n, normalize(float3(-0.5, 0.6, 0.75))), 0.0);
    float spec = pow(max(n.z * 0.95 + dot(n.xy, float2(-0.25, 0.3)), 0.0), 24.0);

    float body = smoothstep(0.10, 0.28, V);
    float3 coral = mix(float3(0.80, 0.22, 0.20), float3(1.0, 0.82, 0.62), smoothstep(0.24, 0.42, V));
    float3 sea = mix(float3(0.012, 0.05, 0.085), float3(0.02, 0.09, 0.13), uv.y);
    float3 col = mix(sea, coral * (0.35 + 0.85 * diff) + spec * 0.35, body);
    float2 p = uv * 2.0 - 1.0;
    col *= 1.0 - 0.18 * length(p) * 0.5;
    return float4(grain(col, in.position, u.res, nt), 1.0);
}

// ======================================================================
// SHADER 23 — Rain on glass
// ======================================================================
// A misted pane in front of defocused street lights. Drops live one per grid
// cell, so no pixel searches its neighbours: the grid itself scrolls down
// while each drop climbs its cell, so a drop clings, creeps, then lets go and
// runs (the stick-slip trick from Martijn Steinrucken's "Heartfelt"). Every
// drop is a small lens: it bends the lookup into the lights and sees them
// sharp, where the mist around it sees them wide and soft. A click's drop
// needs no stored state: the click impulse decays on a known curve, so its
// value is the drop's age.
// opt = (rain, drop size, mist, lights); col0 dusk, col1 lamps, col2 accent.
constant float S23_PERIOD = 22.0;           // seconds per cling-and-run cycle

// Shared by shaders 23–25.
// ±½ LSB of per-pixel white noise. grain() scales with brightness, so it leaves
// dark, smooth gradients (night sky, deep water) free to band in 8 bits.
static inline float3 s_dither(float3 col, float4 position, texture2d<float> nt) {
    return col + (nt.sample(noiseSampler, position.xy / 256.0).r - 0.5) / 255.0;
}
// A clock a speed slider can drive without anything jumping. A setup kernel
// keeps it in `scene` as (whole seconds, tag, fraction), wrapped hourly so
// float stays exact for days; every motion built on it repeats on the hour,
// as a multiple of S_HOUR. Returns (whole, fraction) advanced by `step`: all
// threads read, then one stores it back after a threadgroup_barrier.
constant float S_HOUR = 2.0 * PI / 3600.0;
static inline float2 s_tick(float4 st, float tag, float step) {
    bool ok = st.y == tag;
    float lo = (ok ? st.z : 0.0) + step;
    return float2(glmod((ok ? st.x : 0.0) + floor(lo), 3600.0), fract(lo));
}

struct S23Glass { float2 off; float mask; float trail; float dark; float spec; };

static inline float s23_saw(float b, float t) { return smoothstep(0.0, b, t) * smoothstep(1.0, b, t); }

// One drop of radius R seen from offset d: lens offset, mask, rim shade and glint.
static inline void s23_drop(float2 d, float R, float px, thread S23Glass& g) {
    if (R < 0.6 * px) return;
    float r2 = dot(d, d) / (R * R);
    if (r2 >= 1.0) return;
    float m = smoothstep(1.0, max(1.0 - 2.5 * px / R, 0.0), sqrt(r2));
    g.off  += d / R * (0.18 + 0.60 * r2) * m;                // a fisheye: the whole street, upside down
    g.mask  = max(g.mask, m);
    g.dark  = max(g.dark, m * r2 * r2 * r2 * r2);
    float2 hl = d / R - float2(-0.32, 0.40);
    g.spec += m * exp(-dot(hl, hl) * 18.0);
}
// The wavering line a clicked drop runs down from c, as x at height y.
static inline float s23_run(float y, float2 c, float w) {
    return c.x + 0.022 * (sin(y * 8.0 + w) - sin(c.y * 8.0 + w)) * smoothstep(0.0, 0.35, c.y - y);
}
// One layer of running drops: columns colW wide, cells cellH tall, t in cycles.
// rain = (amount, 1 = as designed; drop size). A cell holds a drop if its hash
// is under `fill`; the last few under it are small, so the slider grows drops
// in rather than popping them.
static void s23_slide(float2 p, float t, float colW, float cellH, float seed, float fill0, float2 rain, float px,
                      thread S23Glass& g) {
    float fill = min(fill0 * rain.x, 1.0);
    float2 q = float2(p.x / colW + seed * 7.31, p.y / cellH);
    float column = floor(q.x);
    q.y += t * 1.25 + hash12(float2(column, seed)) * 13.0;
    float h = hash12(float2(column, glmod(floor(q.y), 289.0)) + seed);
    if (h >= fill) return;
    float3 n = float3(fract(h * 57.0), fract(h / fill0), fract(h * 131.0));     // one hash, three digits of it
    float2 st = float2(fract(q.x) - 0.5, fract(q.y));
    // Climbing 0.66 of a cell at most as fast as the grid falls: it hangs still mid-cling and never creeps up.
    float y = (s23_saw(0.8, fract(t + n.z)) - 0.5) * 0.66 + 0.5;
    float R = colW * (0.11 + 0.12 * n.y) * rain.y * saturate((fill - h) / 0.06);
    if (st.y < y - 1.2 * R / cellH) return;                 // nothing hangs below a drop
    float xf = min(1.0, (0.5425 - 0.23 * rain.y) / 0.3125); // big drops keep clear of the column's edges
    float x = (n.x - 0.5) * 0.4;
    float wig = (0.5 - abs(x)) * (n.z - 0.5) * 0.45;
    if (abs(st.x - x * xf) > abs(wig) * xf + R / colW) return;      // drop, trail and beads all lie within R of the path
    float wy = p.y * 6.0 + n.z * 6.283;                     // the path is fixed on the glass
    x = (x + sin(wy + sin(wy * 1.7)) * wig) * xf;
    float2 d = float2((st.x - x) * colW, (st.y - y) * cellH);
    s23_drop(d * float2(1.0, 0.86), R, px, g);

    // The wiped trail above it mists over again towards the top of the cell.
    float above = smoothstep(-0.3 * R, 0.6 * R, d.y);
    float len = sqrt(smoothstep(1.0, y, st.y));
    float w = R * 0.72 * len;
    float tr = saturate((w - abs(d.x)) / (0.45 * w + px)) * above * len;
    g.trail = max(g.trail, tr);
    g.off.x += d.x * tr * 1.2;                              // a film of water still bends the light
    // ...and keeps a string of beads, fixed on the glass.
    float sp = 2.7 * R;
    float by = p.y / sp + n.x * 5.0;
    float bh = hash12(float2(floor(by), n.z * 91.0));
    s23_drop(float2(d.x + (bh - 0.5) * R * 0.5, (fract(by) - 0.5) * sp),
             R * (0.2 + 0.25 * bh) * len * above, px, g);
}
// Out-of-focus street lights through the pane. blur: 1 through mist, 0 through water.
// edge: inner radius of a disc's rim, as a fraction (small = soft). lights: their gain.
static float3 s23_lights(float2 uv, float blur, float edge, float lights, constant Uniforms& u,
                         texture2d<float> nt) {
    float t = u.time;
    float street = uv.y + 0.22;
    float3 dusk = u.col0.rgb * 0.125;
    float3 col = mix(dusk, dusk * 0.42, smoothstep(0.0, 1.3, uv.y));
    col += ((0.55 * u.col1.rgb + 0.45 * u.col2.rgb) * 0.27 + dusk * 0.3) * mix(1.0, lights, 0.6)
         * exp(-street * street * 3.6)                                      // the city's glow in the wet air
         * (0.35 + vnoise(uv * float2(0.8, 0.5) + float2(t * 0.004, 3.0), nt));
    col *= 0.3 + 0.7 * smoothstep(-1.3, -0.35, uv.y);                       // the dark street below
    float tight = mix(0.55, 1.0, blur);                     // a smaller disc carries the same light
    float gain = 0.66 * lights / (tight * tight);
    for (int l = 0; l < 2; l++) {
        float fl = float(l);
        float sc = 1.45 + 1.25 * fl;
        float2 q = uv * sc + float2(fl * 13.7 + t * 0.004 * (2.0 * fl - 1.0), fl * 5.3);
        float2 b = floor(q - 0.5);
        for (int k = 0; k < 4; k++) {
            float2 id = b + float2(float(k & 1), float(k >> 1));
            if (any(abs(q - id - 0.5) > 0.35 + 0.36 * tight)) continue;     // its light, wherever it sits in the cell, falls short
            float e = hash12(id * 1.31 + fl * 17.0);
            float sy = (id.y + 0.5 - fl * 5.3) / sc + 0.22; // lights gather at street level
            float thin = 1.0 + sy * sy * 5.0;
            if (e * thin > 0.22 * thin + 0.62) continue;
            float3 h = fract(e * float3(57.0, 131.0, 239.0));
            float r = (0.13 + 0.23 * h.x * h.x) * tight;
            float d2 = length_squared(q - id - 0.5 - (h.xy - 0.5) * 0.7);
            if (d2 >= r * r) continue;                      // most pixels: outside this light's disc
            float disc = smoothstep(r, r * edge, sqrt(d2));
            float3 tint = h.z < 0.54 ? u.col1.rgb                                   // sodium
                        : h.z < 0.76 ? u.col1.rgb * 0.4 + float3(0.6, 0.576, 0.5)   // warm white
                        : h.z < 0.89 ? u.col2.rgb                                   // tail light
                                     : 0.2 + 0.66 * (1.0 - u.col2.rgb);             // signal, its complement
            col += tint * disc * (gain - 0.06 * fl * lights) * (0.82 + 0.18 * sin(t * (0.25 + 0.4 * h.y) + e * 40.0));
        }
    }
    return col;
}
fragment float4 fs23_rain(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                          texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;
    float t = u.time, px = 2.0 / u.res.y;
    float tc = t / S23_PERIOD;
    float2 rain = float2(u.opt.x * 2.0, mix(0.6, 1.4, u.opt.y));

    S23Glass g = { float2(0.0), 0.0, 0.0, 0.0, 0.0 };
    s23_slide(p, tc, 0.21, 1.0, 0.0, 0.62, rain, px, g);
    s23_slide(p, tc * 1.13 + 0.4, 0.125, 0.62, 5.0, 0.5, rain, px, g);

    // A click lands one more drop: it clings a moment, then runs and thins away with
    // the click. click decays as 0.94^(60 t), so its value is the drop's age.
    float2 c0 = aspectCorrectedMouse(u.clickPos, u.res);
    if (u.click > 0.0 && abs(p.x - c0.x) < 0.12) {
        float age = -log(u.click) / 3.712;
        float run = max(age - 0.4, 0.0);
        float live = u.mouseEffects * smoothstep(0.002, 0.035, u.click);
        float w = hash12(u.clickPos * 37.0) * 6.283;
        float y = c0.y - 0.5 * run * run;
        float R = 0.05 * rain.y * (smoothstep(0.0, 0.14, age) + 0.3 * exp(-age * 7.0) * sin(age * 26.0)) * sqrt(live);
        s23_drop(float2(p.x - s23_run(y, c0, w), (p.y - y) * 0.86), R, px, g);
        float len = live * smoothstep(y - 0.01, y + 0.03, p.y) * smoothstep(c0.y + 0.02, c0.y - 0.02, p.y);
        float tw = 0.03 * rain.y * len;
        float tr = saturate((tw - abs(p.x - s23_run(p.y, c0, w))) / (0.45 * tw + px)) * len;
        g.trail = max(g.trail, tr);
    }

    // Condensation: small beads that land and slowly dry, wiped by every trail.
    {
        float2 q = p / 0.055;
        float2 id = floor(q);
        float3 n = fract(hash12(id * 1.37 + 5.0) * float3(57.0, 131.0, 1.0));
        float have = saturate((n.z - 1.0 + 0.6 * rain.x) / 0.06);       // more rain, more cells beaded
        float jit = min(0.4, 1.0 - 0.6 * rain.y);                       // bigger beads sit nearer their cell's middle
        float2 d = (fract(q) - 0.5 - (n.xy - 0.5) * jit) * 0.055;
        float size = fract(n.z * 239.0);
        float R = 0.055 * rain.y * (0.10 + 0.19 * size * size);         // at its fullest
        if (have > 0.0 && dot(d, d) < R * R)
            s23_drop(d, R * sqrt(s23_saw(0.04, fract(tc * 0.45 + n.z)) * have) * (1.0 - g.trail), px, g);
    }

    // The cursor is a warm palm: the mist clears around it. Past the slider's
    // middle the mist goes on thickening: wider, softer lights under a heavier veil.
    float2 m = aspectCorrectedMouse(u.mouse, u.res);
    float heavy = max(u.opt.z * 2.0 - 1.0, 0.0);
    float mist = (1.0 - 0.8 * u.mouseEffects * exp(-length_squared(p - m) * 5.0)) * (min(u.opt.z * 2.0, 1.0) + 0.35 * heavy);
    float blur = mist * (1.0 - max(g.mask, 0.75 * g.trail));

    // A drop shows the same wide view wherever it sits, so pull its lookup towards the middle.
    // Its fisheye shrinks the lights to points, so their rims go soft or they would crawl.
    float3 col = s23_lights(p * (1.0 - 0.3 * g.mask) - g.off, blur, mix(mix(0.86, 0.45, blur), 0.1, g.mask),
                            exp2((u.opt.w - 0.5) * 2.4), u, nt);
    col = col * (1.0 - 0.2 * blur) + (0.016 + u.col0.rgb * 0.03) * blur * (1.0 + 0.9 * heavy);   // light scattered in the mist
    col *= (1.0 + 0.6 * g.mask) * (1.0 - 0.45 * g.dark);                       // a drop gathers light; its rim loses it
    col += float3(0.75, 0.85, 1.0) * min(g.spec, 1.0) * 0.12;
    col *= 1.0 - 0.14 * length(p);
    return float4(s_dither(grain(s_tonemap(col, 0.5, 0.95), in.position, u.res, nt), in.position, nt), 1.0);
}

// ======================================================================
// SHADER 24 — Bioluminescent jellyfish
// ======================================================================
// Up to eight jellies. setup_fs24_jelly swims them once per frame (wander,
// pulse, the cursor's current, the click's flash) on its own clock, so the
// Tempo slider changes speed without a jump, and bins their bounding circles
// into 8×4 screen tiles: a pixel reads one bitmask and only visits jellies
// that can reach it. Inside, the bell is a pair of nested half-ellipses and
// every tentacle is a distance to a travelling sine.
// opt = (bloom, tempo, glow, snow); col0 water, col1 bell, col2 heart.
// Jelly i lives at slot s = 4i (+4 from the seventh on, stepping over the snow):
// scene[s] = (bounding circle xy, r²), [s+1] = (centre, axis),
// [s+2] = (radius, squeeze, phase, lag), [s+3] = (bell colour × light, tentacle length).
constant int   S24_MAX   = 8;
constant int   S24_SNOW  = 24;              // (each snow layer's sideways drift, light shaft drift)
constant int   S24_CLOCK = 25;              // the clock, as s_tick keeps it
constant int   S24_FALL  = 26;              // (each snow layer's fall, second light shaft drift)
constant int   S24_HEART = 36;              // scene[36 + i].xyz = jelly i's heart colour × light
constant int   S24_TILES = 44;              // scene[44 + k][j] = bitmask of jellies reaching tile 4k + j
constant float S24_TAG   = 24.0625;
constant float S24_RANK[8] = { 3.0, 5.0, 1.0, 4.0, 2.0, 0.0, 6.0, 7.0 };    // the order the bloom slider brings them in
constant float S24_RIM[7] = { 0.976, 0.784, 0.436, 0.0, -0.436, -0.784, -0.976 };   // where tentacles hang, across the rim

static inline int s24_slot(int i) { return 4 * i + (i >= 6 ? 4 : 0); }
// Turn a colour's hue about the grey axis (cs = cos and sin of the angle).
static inline float3 s24_hue(float3 v, float2 cs) {
    return v * cs.x + float3(v.z - v.y, v.x - v.z, v.y - v.x) * (cs.y * 0.57735) + dot(v, float3(1.0 / 3.0)) * (1.0 - cs.x);
}
// Two sines per axis: a single one would park every jelly at the edges.
static inline float2 s24_path(float c, float fi, float h1, float h2, float aspect) {
    float ka = round((0.017 + 0.010 * h1) / S_HOUR), kb = round((0.014 + 0.009 * h2) / S_HOUR);
    float a0 = fi * 2.4 + h2 * 3.0, b0 = fi * 1.7;
    return float2(aspect * (0.52 * sin(c * S_HOUR * ka + a0) + 0.34 * sin(c * S_HOUR * round(ka * 0.61) + a0 * 0.61 + fi)),
                  0.40 * sin(c * S_HOUR * kb + b0) + 0.26 * sin(c * S_HOUR * round(kb * 0.57) + b0 * 0.57 + fi * 4.0) + 0.16);
}
kernel void setup_fs24_jelly(constant Uniforms& u [[buffer(0)]], device float4* scene [[buffer(1)]],
                             uint i [[thread_position_in_grid]]) {
    float2 ck = s_tick(scene[S24_CLOCK], S24_TAG, u.dt * exp2((u.opt.y - 0.5) * 3.0));
    threadgroup_barrier(mem_flags::mem_device);         // everyone has read the clock
    float c = ck.x + ck.y, aspect = u.res.x / u.res.y;
    if (i == 0) {
        scene[S24_CLOCK] = float4(ck.x, S24_TAG, ck.y, 0.0);
        // Marine snow sways and sinks, and the light shafts wander, on the same clock.
        scene[S24_SNOW] = float4(0.7 * sin(c * S_HOUR * 26.0 + float3(0.0, 2.0, 4.0)), 17.0 * sin(c * S_HOUR));
        scene[S24_FALL] = float4(fmod(c * float3(2.0, 6.0, 12.0) * (128.0 / 3600.0), 128.0), 26.0 * sin(c * S_HOUR + 1.3));
    }
    if (i < uint(S24_MAX)) {
        float fi = float(i);
        float h1 = hash12(float2(fi, 3.7)), h2 = hash12(float2(fi, 6.1)), h3 = hash12(float2(fi, 9.4));
        float depth = i < 6 ? (fi + 1.0) / 6.0 : (i == 6 ? 0.55 : 0.38);     // 1 = nearest
        float R = mix(0.065, 0.20, depth * depth);

        float2 pos = s24_path(c, fi, h1, h2, aspect);
        float2 v = (s24_path(c + 2.0, fi, h1, h2, aspect) - pos) * 25.0;    // ~1 at cruising speed
        float2 axis = normalize(float2(v.x, v.y * 0.5 + 1.3));              // bell leads, mostly upward
        float ph = c * S_HOUR * 10.0 * round((0.75 + 0.35 * h3) / (10.0 * S_HOUR)) + h1 * 6.283;
        float squeeze = pow(0.5 + 0.5 * sin(ph), 2.0);
        pos += axis * R * 0.22 * sin(ph - 0.5);                             // each stroke is a small surge

        // The cursor is a current: it eases them aside and tips their bells.
        float2 dm = pos - aspectCorrectedMouse(u.mouse, u.res);
        float push = u.mouseEffects * exp(-dot(dm, dm) * 3.5);
        pos += dm * 0.55 * push;
        axis = normalize(axis + dm * push * 1.5);
        // A click is a flash that ripples outward, jelly to jelly.
        float w = length(pos - aspectCorrectedMouse(u.clickPos, u.res)) - (1.0 - u.click) * 2.6;
        float flash = u.mouseEffects * u.click * exp(-w * w * 4.0);

        // The bloom slider fades jellies in and out; glow is their light.
        float vis = saturate(mix(1.0, float(S24_MAX), u.opt.x) - S24_RANK[i]);
        float light = (0.6 + 0.8 * depth) * (1.0 + 2.5 * flash) * mix(0.4, 1.6, u.opt.z) * vis * vis * (3.0 - 2.0 * vis);
        // Each wears the bell and heart colours, or their hue-turned siblings, or something between.
        float3 bell  = mix(u.col1.rgb, mix(saturate(s24_hue(u.col1.rgb, float2(0.673, 0.740))), float3(1.0), 0.14), h2);
        float3 heart = mix(u.col2.rgb, mix(saturate(s24_hue(u.col2.rgb, float2(-0.990, 0.141))), float3(1.0), 0.33), fract(h2 * 7.3));

        float2 side = float2(axis.y, -axis.x);
        float lag = -0.05 / R * clamp(dot(v, side), -1.0, 1.0);             // tentacles trail a sideways drift
        float L = R * (3.6 + 1.8 * h3);
        // Everything drawn fits a box 2R above the rim, L below, 1.7R to each side, sheared by the lag.
        float2 ext = float2(1.7 * R + 0.5 * abs(lag) * L * L, 0.5 * (2.0 * R + L));
        int s = s24_slot(int(i));
        scene[s]     = float4(pos + axis * (R - 0.5 * L) + side * (0.5 * lag * L * L), vis > 0.0 ? dot(ext, ext) : 0.0, 0.0);
        scene[s + 1] = float4(pos, axis);
        scene[s + 2] = float4(R, squeeze, ph, lag);
        scene[s + 3] = float4(bell * light, L);
        scene[S24_HEART + i] = float4(heart * light, 0.0);
    }
    threadgroup_barrier(mem_flags::mem_device);         // every bounding circle is written
    if (i < 8) {                                        // four tiles each; row 0 is the top of the screen
        float4 masks = 0.0;
        for (int j = 0; j < 4; j++) {
            float2 lo = float2(aspect * (float(j) * 0.25 - 1.0), 0.5 - 0.5 * float(i >> 1));
            if (i & 1) lo.x += aspect;
            uint mask = 0;
            for (int k = 0; k < S24_MAX; k++) {
                float4 b = scene[s24_slot(k)];
                if (length_squared(b.xy - clamp(b.xy, lo, lo + float2(0.25 * aspect, 0.5))) < b.z) mask |= 1u << k;
            }
            masks[j] = float(mask);
        }
        scene[S24_TILES + i] = masks;
    }
}
static float3 s24_jelly(float2 p, float4 A, float4 B, float4 C, float3 heart, float px) {
    float2 d = p - A.xy;
    float R = B.x, sq = B.y;
    float2 l = float2(d.x * A.w - d.y * A.z, dot(d, A.zw));     // x across the bell, y along its axis
    float s = max(-l.y, 0.0);                               // distance trailed behind the bell
    float lx = l.x - B.w * s * s;                           // everything trailing lags a sideways drift
    float L = C.w;
    if (abs(lx) > R * 1.7 || l.y > R * 2.0 || s > L) return 0.0;

    float2 hd = float2(lx, l.y - 0.3 * R) / (R * 1.7);
    float halo = saturate(1.0 - dot(hd, hd));
    float light = 0.15 * halo * halo * halo, core = 0.0;    // glow in the water, gone by the box's edge

    float Rw = R * (1.0 - 0.20 * sq), Hh = R * (0.74 + 0.20 * sq);
    float aa = 3.0 * px / R;
    float2 e = float2(l.x / Rw, l.y / Hh);
    float lip = l.y / (Rw * 0.16);
    float ring = e.x * e.x + lip * lip;                     // the bell's opening, seen at a slant
    if (l.y > -0.2 * R && l.y < R * 1.1) {
        float rr = e.y >= 0.0 ? dot(e, e) : ring;           // dome above, the near lip below
        float ar = e.y >= 0.0 ? aa : 3.0 * px * length(float2(e.x, lip * 6.25)) / Rw;   // the lip's edge is 6× steeper
        float inside = smoothstep(1.0 + ar, 1.0 - ar, rr) * (0.55 + 0.45 * smoothstep(-0.5, 0.0, lip));
        float2 ei = float2(l.x / (Rw * 0.84), l.y / (Hh * 0.60));
        float ri = dot(ei, ei);
        float dome = step(0.0, e.y);
        float lon = clamp(e.x / sqrt(max(1.0 - e.y * e.y, 0.03)), -1.0, 1.0);
        float ribs = pow(0.5 + 0.5 * cos(asin(lon) * 8.0 + B.z * 0.1), 6.0) * (1.0 - e.y * e.y);
        float dots = pow(0.5 + 0.5 * cos(asin(clamp(e.x, -1.0, 1.0)) * 18.0 + B.z * 0.1), 3.0);
        light += inside * (0.16 + 0.55 * rr * rr * rr * dome                    // membrane, brighter at the limb
                         + 0.10 * smoothstep(0.9, 1.1, ri) * dome              // the thick of the bell
                         + 0.22 * exp(-(ri - 1.0) * (ri - 1.0) * 14.0) * dome  // its inner surface
                         + 0.16 * ribs * dome);
        light += inside * exp(-(ring - 1.0) * (ring - 1.0) * 9.0)
               * (0.10 + 0.60 * dots);                                          // the margin and its lights
        core += inside * exp(-(e.x * e.x * 5.0 + (e.y - 0.42) * (e.y - 0.42) * 9.0)) * (0.55 + 0.45 * sq);
    }

    float k = 2.4 / R;
    if (s > 0.0) {
        float sn = s / L;
        float sway = R * (0.03 + 0.32 * sn);
        float tw = max(px * 0.8, R * 0.013);
        float tx = lx - 0.5 * sway * sin(s * k * 0.45 - B.z * 0.5);     // one slow swing shared by all seven
        float tent = 0.0;
        for (int j = 0; j < 7; j++) {
            float fj = float(j);
            float x0 = Rw * 0.94 * S24_RIM[j] * (1.0 - 0.3 * sn);
            if (abs(tx - x0) > sway + 2.7 * tw) continue;              // this one never swings this far
            float dx = (tx - x0 - sway * sin(s * k * (0.78 + 0.07 * fj) - B.z + fj * 2.1)) / tw;
            tent += exp(-dx * dx) * (0.55 + 0.45 * fract(fj * 0.618));
        }
        light += tent * (1.0 - sn) * (1.0 - sn) * 0.5;
    }
    // Frilled oral arms, hanging from the heart of the bell.
    float sa = (0.3 * Hh - l.y) / (R * 2.1);
    if (sa > 0.0 && sa < 1.0 && abs(lx) < 0.7 * R) {
        float so = sa * R * 2.1;
        float arms = 0.0;
        for (int j = 0; j < 3; j++) {
            float fj = float(j) - 1.0;
            float xa = fj * Rw * 0.2 * (0.4 + 1.2 * sa) + R * 0.14 * sa * sin(so * k * 1.2 - B.z + fj * 2.6);
            float dx = (lx - xa) / (R * (0.02 + 0.075 * (1.0 - sa)));
            arms += exp(-dx * dx) * (0.72 + 0.28 * sin(so * 34.0 / R + fj * 3.0 + dx * 2.5));
        }
        core += arms * (1.0 - sa) * smoothstep(0.0, 0.12, sa) * 0.42;
    }
    return C.rgb * light + heart * core;
}
fragment float4 fs24_jelly(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                           constant float4* scene [[buffer(1)]],
                           texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;
    float px = 2.0 / u.res.y;
    float4 sway = scene[S24_SNOW], fall = scene[S24_FALL];
    float3 water = u.col0.rgb;

    // Deep water, a little surface light still filtering down.
    float3 col = water * mix(0.030, 0.112, smoothstep(-1.1, 1.2, p.y));
    float shaft = vnoise(float2(p.x * 2.1 + p.y * 0.55, sway.w), nt)
                * vnoise(float2(p.x * 4.7 + p.y * 1.20 + 7.0, fall.w), nt);
    col += (0.9 * water + 0.1) * 0.14 * shaft * smoothstep(-0.7, 1.0, p.y);

    // Marine snow, three depths, sinking; the cursor's current parts it. Each
    // cell's four random numbers are one gather of the noise texture.
    float snow = u.opt.w * 2.0;
    if (snow > 0.0) {
        float3 flake = mix(water, float3(1.0), 0.6) * (0.78 * snow);
        float2 dm = p - aspectCorrectedMouse(u.mouse, u.res);
        float2 part = dm * 0.35 * u.mouseEffects * exp(-dot(dm, dm) * 5.0);
        for (int l = 0; l < 3; l++) {
            float fl = float(l);
            float2 q = (p - part) * (6.0 + 7.0 * fl) + float2(sway[l] + fl * 7.3, fall[l]);
            float2 id = floor(q);
            float4 n = nt.gather(noiseSampler, (id * 2.0 + float2(fl * 38.0 + 1.0, 1.0)) / 256.0);
            if (n.w > 0.5) {
                float r = mix(0.11, 0.035, fl * 0.5) * (0.6 + 0.8 * n.z);
                float d2 = length_squared(fract(q) - 0.2 - 0.6 * n.xy) / (r * r);
                if (d2 < 7.0) col += flake * exp(-d2) * (0.055 + 0.075 * fl);
            }
        }
    }

    // Only the jellies whose bounding circles reach this pixel's tile.
    int2 tile = min(int2(in.position.xy / u.res * float2(8.0, 4.0)), int2(7, 3));
    int ti = tile.y * 8 + tile.x;
    uint reach = uint(scene[S24_TILES + (ti >> 2)][ti & 3]);
    while (reach != 0) {
        int i = int(ctz(reach)), s = s24_slot(i);
        reach &= reach - 1;
        float4 bound = scene[s];
        if (length_squared(p - bound.xy) < bound.z)
            col += s24_jelly(p, scene[s + 1], scene[s + 2], scene[s + 3], scene[S24_HEART + i].rgb, px);
    }

    // The click's flash, passing through the water itself.
    if (u.click > 0.0) {
        float w = length(p - aspectCorrectedMouse(u.clickPos, u.res)) - (1.0 - u.click) * 2.6;
        col += mix(water, u.col1.rgb, 0.5) * 0.06 * u.mouseEffects * u.click * exp(-w * w * 6.0);
    }

    col *= 1.12 - 0.18 * length(p);
    return float4(s_dither(grain(col / (1.0 + col * 0.45), in.position, u.res, nt), in.position, nt), 1.0);
}

// ======================================================================
// SHADER 25 — Sky lanterns
// ======================================================================
// Up to eighteen lanterns on a loop from the far shore to the top of the sky,
// far to near, plus up to four released by clicks, which keep their release
// point and time in `scene`. Water pixels mirror the lookup about the horizon
// and jitter it with stretched noise, so every flame drags a broken column of
// light across the lake; sky and lanterns are evaluated once either way. The
// kernel flies them on its own clock (the Rise slider changes speed without
// a jump) and bins their glows into 8×5 tiles of sky, so a pixel reads one
// bitmask instead of testing all twenty-two.
// opt = (lanterns, rise, ripple, glow); col0 sky, col1 horizon, col2 paper.
constant float S25_HORIZON = -0.30;         // p.y of the waterline
constant float S25_MAGIC   = 2525.0;
constant float S25_TAG     = 25.0625;
constant float S25_REACH   = 8.0;           // a lantern's glow ends this many half-widths out
constant int   S25_N       = 18;
constant int   S25_CLICKS  = 4;
constant int   S25_ALL     = 22;            // scene[i] = (centre, half-width, glow × lit), scene[22 + i] = (sin lean, cos lean, glow, lit)
constant int   S25_CLOCK   = 44;            // the clock, as s_tick keeps it
constant int   S25_STATE   = 48;            // scene[48 + k] = (release x, height now, release time, seed), scene[52] = ring header
constant int   S25_TILES   = 53;            // scene[53 + k][j] = bitmask of lanterns whose glow reaches tile 4k + j

// glow: how bright this lantern burns; lit: 0 before the flame catches and after it gutters, 1 between.
static inline void s25_place(device float4* scene, int slot, float2 c, float size, float glow, float lit, float lean,
                             float seed, constant Uniforms& u) {
    // The cursor is a breeze: lanterns lean and slide away from it.
    float2 dm = c - aspectCorrectedMouse(u.mouse, u.res);
    float push = u.mouseEffects * exp(-dot(dm, dm) * 4.0);
    c += dm * 0.4 * push;
    lean -= dm.x * push * 0.9;
    glow *= mix(0.4, 1.6, u.opt.w)
          * (0.93 + 0.07 * sin(u.time * 2.3 + seed * 50.0) * sin(u.time * 1.1 + seed * 20.0));  // the flame breathes
    scene[slot] = float4(c, lit > 0.0 ? size : 0.0, glow * lit);    // no size, no pixels
    scene[S25_ALL + slot] = float4(sin(lean), cos(lean), glow, lit);
}
kernel void setup_fs25_lanterns(constant Uniforms& u [[buffer(0)]], device float4* scene [[buffer(1)]],
                                uint i [[thread_position_in_grid]]) {
    float rise = exp2((u.opt.y - 0.5) * 2.6);
    float2 ck = s_tick(scene[S25_CLOCK], S25_TAG, u.dt * rise);
    threadgroup_barrier(mem_flags::mem_device);         // everyone has read the clock
    float c = ck.x + ck.y, t = u.time, aspect = u.res.x / u.res.y;
    if (i == 0) scene[S25_CLOCK] = float4(ck.x, S25_TAG, ck.y, 0.0);
    if (i < uint(S25_N)) {
        float fi = float(i);
        float near = (fi + 0.5) / float(S25_N);             // 1 = nearest, drawn last
        near *= near;
        float h1 = hash12(float2(fi, 2.3)), h2 = hash12(float2(fi, 7.7));
        float laps = round(3600.0 / (mix(170.0, 85.0, near) * (0.85 + 0.3 * h2)));     // whole laps an hour
        float turn = c * laps / 3600.0 + h1 + fi * 0.618;
        float a = fract(turn);
        float h3 = hash12(float2(fi, glmod(floor(turn), laps) + 4.9));      // a new launch spot each time round
        float lift = pow(a, 1.25);
        float size = mix(0.012, 0.074, near) * mix(1.0, 0.72, lift);
        float2 pos = float2((h3 * 2.0 - 1.0) * aspect * 0.98 + 0.28 * (lift - 0.4) * (0.4 + near)
                            + 0.02 * sin(c * S_HOUR * 120.0 + fi * 5.0),
                            S25_HORIZON + 0.015 + size * 1.5 + lift * 1.75 * mix(0.68, 1.0, near));
        // The lanterns slider lets them gutter out one by one, near and far in turn.
        float lit = smoothstep(0.0, 0.04, a) * smoothstep(1.0, 0.86, a)
                  * saturate(mix(4.0, float(S25_N), u.opt.x) - glmod(fi * 7.0, float(S25_N)));
        s25_place(scene, int(i), pos, size, 0.5 + 0.5 * near, lit, 0.05 * sin(c * S_HOUR * 155.0 + fi * 3.0) - 0.03, h1, u);
    } else if (i == 63) {                                   // one thread walks the click ring: no races
        float4 head = scene[S25_STATE + S25_CLICKS];
        if (head.w != S25_MAGIC) {
            head = float4(0.0, -1e4, 0.0, S25_MAGIC);
            for (int k = 0; k < S25_CLICKS; k++) scene[S25_STATE + k] = float4(0.0, 0.0, -1e4, 0.0);
        }
        float t0 = t + log(max(u.click, 1e-3)) / 3.712;     // click decays as 0.94^(60 t)
        if (u.click > 0.3 && abs(t0 - head.y) > 0.25) {
            head.x = glmod(head.x + 1.0, float(S25_CLICKS));
            head.y = t0;
            float2 at = aspectCorrectedMouse(u.clickPos, u.res);
            at.y = max(at.y, S25_HORIZON + 0.13);           // released from the water's edge at lowest
            scene[S25_STATE + int(head.x)] = float4(at, t0, hash12(at * 37.0 + fract(t0)));
        }
        scene[S25_STATE + S25_CLICKS] = head;
        for (int k = 0; k < S25_CLICKS; k++) {
            float4 s = scene[S25_STATE + k];
            float age = t - s.z;
            float lit = u.mouseEffects * smoothstep(0.0, 1.2, age) * smoothstep(62.0, 50.0, age);
            if (lit > 0.0) {                                // it climbs by integration, so Rise can change mid-flight
                s.y += u.dt * rise * 0.042 * (1.0 - exp(-age / 3.0));
                scene[S25_STATE + k] = s;
            }
            float2 pos = float2(s.x + 0.010 * age + 0.03 * sin(age * 0.33 + s.w * 6.283), s.y);
            s25_place(scene, S25_N + k, pos, 0.074 * mix(1.0, 0.62, saturate(age / 55.0)), 1.0, lit,
                      0.05 * sin(age * 0.4 + s.w * 9.0) - 0.03, s.w, u);
        }
    }
    threadgroup_barrier(mem_flags::mem_device);         // every lantern is placed
    if (i < 10) {                                       // four tiles each; the outer ones run on to infinity
        float4 masks = 0.0;
        for (int j = 0; j < 4; j++) {
            int tx = int(i & 1) * 4 + j, ty = int(i >> 1);
            float2 lo = float2(tx == 0 ? -1e9 : aspect * (float(tx) * 0.25 - 1.0), ty == 0 ? -1e9 : S25_HORIZON + 0.26 * float(ty));
            float2 hi = float2(tx == 7 ?  1e9 : aspect * (float(tx) * 0.25 - 0.75), ty == 4 ?  1e9 : S25_HORIZON + 0.26 * float(ty + 1));
            uint mask = 0;
            for (int k = 0; k < S25_ALL; k++) {
                float4 A = scene[k];
                float r = S25_REACH * A.z;
                if (A.z > 0.0 && all(A.xy + r > lo) && all(A.xy - r < hi)) mask |= 1u << k;
            }
            masks[j] = float(mask);
        }
        scene[S25_TILES + i] = masks;
    }
}
static float3 s25_sky(float2 p, float t, float px, constant Uniforms& u, texture2d<float> nt) {
    float h = p.y - S25_HORIZON;
    float3 sky = u.col0.rgb, glow = u.col1.rgb;
    float3 band = 0.33 * glow + 0.14 * sky;                 // the horizon: afterglow through the last of the sky
    float3 col = mix(band, 0.2 * sky + 0.1 * band, smoothstep(0.0, 0.55, h));
    col = mix(col, 0.065 * sky, smoothstep(0.25, 1.3, h));
    col += glow * (exp(-h * 7.0) * 0.275 + exp(-h * 26.0) * 0.2);           // the last of the afterglow
    float cl = vnoise(float2(p.x * 0.9 + t * 0.004, h * 7.0), nt)
             * vnoise(float2(p.x * 2.3 - t * 0.003, h * 16.0 + 3.0), nt);
    col += band * 0.75 * smoothstep(0.22, 0.6, cl) * exp(-h * 2.2);         // thin cloud bars
    // A few early stars, never finer than the pixel grid can hold steady.
    if (h > 0.35) {
        float2 q = p * 21.0;
        float2 id = floor(q);
        float sh = hash12(id);
        if (sh > 0.9) {
            float2 o = float2(hash12(id + 7.1), hash12(id + 3.3)) * 0.6 + 0.2;
            col += float3(0.8, 0.85, 1.0) * exp(-length_squared(fract(q) - o) * min(700.0, 0.0035 / (px * px)))
                 * smoothstep(0.35, 1.1, h) * (0.45 + 0.25 * sin(t * 1.3 + sh * 60.0));
        }
    }
    if (h > 0.13) return col;
    // The far shore (never taller than that), and the few lamps along it.
    float ridge = 0.03 + 0.075 * vnoise(float2(p.x * 1.3 + 4.0, 0.5), nt) + 0.018 * vnoise(float2(p.x * 6.0, 2.5), nt);
    col = mix(col, 0.058 * sky + 0.012 * glow, smoothstep(ridge + px, ridge - px, h) * 0.93);
    if (h < 0.05) {
        float lx = p.x * 16.0;
        float lh = hash12(float2(floor(lx), 8.3));
        if (lh > 0.62) {
            float2 ld = float2((fract(lx) - 0.2 - 0.6 * fract(lh * 57.0)) / 16.0, h - 0.006 - 0.012 * fract(lh * 131.0));
            col += mix(u.col2.rgb, sqrt(u.col2.rgb), 0.4) * exp(-dot(ld, ld) / (px * px * 2.5)) * (0.3 + 0.5 * fract(lh * 239.0));
        }
    }
    return col;
}
fragment float4 fs25_lanterns(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                              constant float4* scene [[buffer(1)]],
                              texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;
    float t = u.time, px = 2.0 / u.res.y, aspect = u.res.x / u.res.y;

    // Below the waterline, look up the mirror image through slow ripples that
    // bunch towards the horizon; the breeze roughens them under the cursor.
    float dep = S25_HORIZON - p.y;
    float2 sp = p;
    if (dep > 0.0) {
        float2 dm = p - aspectCorrectedMouse(u.mouse, u.res);
        float rough = u.opt.z * 2.0 * (1.0 + 2.5 * u.mouseEffects * exp(-dot(dm, dm) * 6.0));
        float v = log(dep + 0.03) * 9.0;                    // thin slivers, thinner far away
        float X = p.x * 0.9 / (dep + 0.22);
        float n = vnoise(float2(X, v + t * 0.14), nt) + 0.5 * vnoise(float2(X * 2.3 + 9.0, v * 2.7 - t * 0.21), nt) - 0.75;
        sp.y = S25_HORIZON + dep + n * (0.006 + 0.30 * dep) * rough;
        sp.x += n * 0.02 * rough;
    }

    float3 col = s25_sky(sp, t, px, u, nt);
    float3 paper = u.col2.rgb;
    float3 halo = mix(paper, paper * paper, 0.5);
    // Only the lanterns whose glow reaches this point's tile of sky, far to near.
    int2 tile = clamp(int2(floor(float2(sp.x / (2.0 * aspect) + 0.5, (sp.y - S25_HORIZON) / 1.3) * float2(8.0, 5.0))),
                      int2(0), int2(7, 4));
    int ti = tile.y * 8 + tile.x;
    uint reach = uint(scene[S25_TILES + (ti >> 2)][ti & 3]);
    while (reach != 0) {
        int i = int(ctz(reach));
        reach &= reach - 1;
        float4 A = scene[i];
        float2 d = (sp - A.xy) / A.z;
        float r2 = dot(d, d);
        if (r2 >= S25_REACH * S25_REACH) continue;
        col += halo * A.w * (0.30 * exp(-r2 * 0.32) + 0.07 * (exp(-r2 * 0.07) - 0.0113));   // glow in the haze, zero at its reach
        if (r2 < 4.0) {
            float4 B = scene[S25_ALL + i];
            float2 l = float2(d.x * B.y - d.y * B.x, d.x * B.x + d.y * B.y);
            float ty = l.y / 1.4;                           // -1 at the open base, 1 at the crown
            float ax = abs(l.x) / mix(0.62, 1.0, smoothstep(-1.0, 0.4, ty));
            float e = ax * ax * ax + pow(abs(ty), ty > 0.0 ? 3.5 : 9.0);
            float aa = 3.0 * px / A.z;
            float body = smoothstep(1.0 + aa, 1.0 - aa, e);
            float flame = exp(-(l.x * l.x * 1.6 + (ty + 0.85) * (ty + 0.85) * 2.2));
            float3 lamp = mix(0.8 * paper * paper * paper + float3(0.0, 0.0, 0.02), paper, flame)
                        + max(sqrt(paper), 0.25) * flame * flame * 1.3;      // the flame shows even through black paper
            lamp *= (1.0 - 0.22 * ax * ax) * (1.0 - 0.4 * smoothstep(0.1, 1.0, ty));     // round, and dimmer at the crown
            col = mix(col, lamp * (0.55 + 0.9 * B.z) * (0.08 + 0.92 * B.w), body * saturate(B.w * 12.0));
        }
    }

    if (dep > 0.0) {                                        // still water: dimmer, and darker close in
        col = col * mix(0.82, 0.42, smoothstep(0.0, 0.7, dep)) + 0.026 * u.col0.rgb;
    }
    col += (0.33 * u.col1.rgb + 0.14 * u.col0.rgb) * 0.2 * exp(-abs(dep) * 34.0);    // mist on the far shore
    col *= 1.0 - 0.14 * length(p);
    return float4(s_dither(grain(s_tonemap(col, 0.5, 0.95), in.position, u.res, nt), in.position, nt), 1.0);
}

// ======================================================================
// SHADER 26 — Moonlit sea
// ======================================================================
// A fixed eye a metre above open water, looking out to a low moon. The sea is
// fourteen directional swells summed in closed form with an analytic slope.
// Each swell fades out once it shrinks below a pixel, and the slope variance
// it takes with it widens the moon's highlight, so the glints near the eye
// blur into a smooth moon path toward the horizon instead of shimmering; once
// the rest are all sub-pixel the loop stops and adds their variance from a
// table. A click is a fish jumping: setup_fs26_sea casts the click onto the
// water and keeps its time, so the rings spread for fourteen seconds.
// opt = (swell, moon size, clouds, stars); col0 night sky, col1 moonlight,
// col2 halo. Every colour below is its default times (well / default well).
constant float S26_HZ  = 0.22;      // horizon, in p.y
constant float S26_F   = 1.6;       // focal length
constant float S26_EYE = 1.0;       // eye height above the water
constant float3 S26_NIGHT = float3(0.46, 0.67, 1.00);   // the default wells
constant float3 S26_MOON  = float3(1.00, 0.96, 0.88);
constant float3 S26_HALO  = float3(0.67, 0.79, 1.00);
constant float4 S26_WAVE[14] = {    // (heading x, heading z, wavenumber, angular speed)
    float4(0.19867, -0.98007, 0.55000, 0.97509), float4(0.67500, -0.73782, 0.77550, 1.15785),
    float4(-0.56222, -0.82699, 1.09345, 1.37487), float4(0.74027, -0.67231, 1.54177, 1.63257),
    float4(0.06365, -0.99797, 2.17390, 1.93857), float4(-0.23054, -0.97306, 3.06520, 2.30193),
    float4(0.82701, -0.56219, 4.32193, 2.73339), float4(-0.48596, -0.87398, 6.09392, 3.24572),
    float4(0.45167, -0.89219, 8.59242, 3.85407), float4(0.48961, -0.87194, 12.11531, 4.57646),
    float4(-0.50365, -0.86391, 17.08259, 5.43425), float4(0.81962, -0.57290, 24.08646, 6.45281),
    float4(-0.19190, -0.98141, 33.96190, 7.66229), float4(0.01845, -0.99983, 47.88629, 9.09846),
};
constant float S26_TAIL[14] = {     // Σ (a·k)² over swells i.. (slope variance ×2 still to come)
    0.0310395, 0.028854, 0.0266636, 0.0244684, 0.0222684, 0.0200635, 0.0178538,
    0.0156392, 0.0134197, 0.0111954, 0.00896615, 0.006732, 0.00449293, 0.00224894,
};

// scene[0] = (splash xz on the water, splash time, last frame's click), scene[1].x = tag
kernel void setup_fs26_sea(constant Uniforms& u [[buffer(0)]], device float4* scene [[buffer(1)]],
                           uint i [[thread_position_in_grid]]) {
    if (i != 0) return;
    float4 s = scene[1].x == 2626.0 ? scene[0] : float4(0.0, 0.0, -1e4, 0.0);
    if (u.click > s.w + 0.01) {                      // a new click (click only ever decays otherwise)
        float2 c = aspectCorrectedMouse(u.clickPos, u.res);
        float dy = min(c.y - S26_HZ, -0.1);          // a click in the sky lands out near the horizon
        s.xy = float2(c.x, S26_F) * (S26_EYE / -dy);
        s.z = u.time;
    }
    s.w = u.click;
    scene[0] = s;
    scene[1] = float4(2626.0, 0.0, 0.0, 0.0);
}
// Height and slope (h, dh/dx, dh/dz) at unit swell; `lost` gathers the slope
// variance of everything filtered out below the pixel footprint fp.
static float3 s26_waves(float2 x, float t, float fp, thread float& lost) {
    float3 w = 0.0;
    float a = 0.085;
    lost = 0.0;
    for (int i = 0; i < 14; i++) {
        float4 c = S26_WAVE[i];
        float kf = c.z * fp;
        if (kf > 3.7) { lost += S26_TAIL[i]; break; }        // this and every finer swell: sub-pixel
        float f = exp(-0.5 * kf * kf);
        float ph = c.z * dot(c.xy, x) - c.w * t + float(i) * 1.93;
        float A = a * f, cp, sp = sincos(ph, cp);
        w.x  += A * sp;
        w.yz += A * c.z * cp * c.xy;
        lost += (1.0 - f * f) * a * a * c.z * c.z;
        a *= 0.71;
    }
    lost *= 0.5;
    return w;
}
static float3 s26_sky(float3 d, float3 m, float3 horizon, float3 halo) {
    float3 c = mix(horizon, horizon * float3(0.182, 0.225, 0.375), sqrt(saturate(d.y * 2.5)));
    float lc = log2(max(dot(d, m), 1e-4));
    return c + halo * (0.06 * exp2(3.0 * lc) + 0.16 * exp2(14.0 * lc) + 0.22 * exp2(220.0 * lc));
}
fragment float4 fs26_sea(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                         constant float4* scene [[buffer(1)]],
                         texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;
    float t = u.time, me = u.mouseEffects;
    float px = 2.0 / u.res.y;
    float3 horizon = float3(0.055, 0.080, 0.120) * u.col0.rgb / S26_NIGHT;
    float3 moonC   = u.col1.rgb / S26_MOON;
    float3 halo    = float3(0.32, 0.38, 0.48) * u.col2.rgb / S26_HALO;
    float moonR = exp2((u.opt.y - 0.5) * 1.4);           // moon size, 0.62–1.6×

    // The cursor carries the moon along the horizon and lifts or lowers it.
    float3 m = normalize(float3(mix(0.32, (u.mouse.x - 0.5) * 1.6, me), mix(0.14, 0.06 + 0.2 * u.mouse.y, me), 1.0));
    float3 d = normalize(float3(p.x, p.y - S26_HZ, S26_F));
    float3 col;
    if (d.y > 0.0) {
        col = s26_sky(d, m, horizon, halo);
        float cm = dot(d, m);
        // Thin stratus, silvered near the moon; the Clouds slider lowers the
        // threshold and, past its default, lets the deck climb the sky.
        float cover = u.opt.z;
        float top = 0.5 + 1.6 * max(cover - 0.5, 0.0);
        float band = smoothstep(0.02, 0.12, d.y) * smoothstep(top, 0.2, d.y);
        float cl = 0.0;
        if (band * cover > 0.0) {
            float lo = mix(0.9, 0.1, cover);
            cl = vnoise(float2(p.x * 1.1 + t * 0.006, p.y * 7.0), nt) * 0.6
               + vnoise(float2(p.x * 2.6 - t * 0.004, p.y * 15.0) + 5.3, nt) * 0.4;
            cl = smoothstep(lo, lo + 0.35, cl) * band;
            col = mix(col, horizon * float3(1.27, 1.06, 0.92) + halo * float3(1.56, 1.45, 1.25) * pow(saturate(cm), 60.0), cl * 0.55);
        }

        // Stars: one candidate per cell, a pixel or so across, slowly breathing.
        float2 g = p * 60.0, ci = floor(g);
        float h = hash12(ci);
        if (h > 1.0 - 0.3 * u.opt.w) {
            float2 sp = ci + 0.15 + 0.7 * hash22(ci + 3.1);
            float sd = length(g - sp) / (60.0 * px);
            float star = exp(-sd * sd * 0.8) * (0.15 + 0.85 * pow(fract(h * 13.7), 4.0))
                       * (0.75 + 0.25 * sin(t * (0.4 + h) + h * 40.0));
            star *= smoothstep(0.02, 0.2, d.y) * smoothstep(0.985, 0.94, cm) * (1.0 - cl);
            col += star * float3(0.75, 0.82, 1.0) * 0.9;
        }

        // The moon, with faint maria.
        float rm = 0.03 * moonR;
        float th = sqrt(max(2.0 * (1.0 - cm), 0.0));
        if (th < rm + px) {
            float disk = smoothstep(rm + px / S26_F, rm - px / S26_F, th);
            float2 q = (d.xy / d.z - m.xy / m.z) / rm;
            float mare = vnoise(q * 1.7 + 3.0, nt) * 0.65 + vnoise(q * 3.9 + 9.0, nt) * 0.35;
            float3 moon = float3(1.0, 0.96, 0.88) * moonC * (2.4 - 0.8 * smoothstep(0.45, 0.7, mare)) * (1.0 - 0.25 * dot(q, q));
            col = mix(col, moon, disk * (1.0 - 0.6 * cl));
        }
    } else {
        float tt = S26_EYE / -d.y;
        float2 x = tt * d.xz;
        float fp = tt * px / (S26_F * sqrt(-d.y));            // pixel footprint on the water
        float swell = exp2((u.opt.x - 0.5) * 2.0);            // 0.5–2× the default sea state
        float lost;
        float3 w = s26_waves(x, t, fp, lost) * swell;
        lost *= swell * swell;

        // A fish jumped: a train of rings rides outward and settles.
        float4 s = scene[0];
        float age = t - s.z, glint = 0.0;
        if (age < 14.0 && me > 0.0) {
            float2 dv = x - s.xy;
            float r = length(dv) + 1e-4;
            const float k = 11.0;
            float x0 = r - 0.32 * age;
            float env = exp(-x0 * x0 / (0.02 + 0.06 * age)) * exp(-0.28 * age) * smoothstep(0.0, 0.3, age)
                      + 1.5 * exp(-r * r * 60.0) * exp(-2.0 * age);   // the splash itself
            float f = exp(-0.5 * k * k * fp * fp);
            float A = 0.022 * env;
            w.x  += A * f * sin(k * x0);
            w.yz += A * f * k * cos(k * x0) * dv / r;
            lost += 0.5 * (1.0 - f * f) * A * A * k * k;
            glint = min(env, 1.0) * f * pow(max(sin(k * x0 + 0.7), 0.0), 6.0);   // crests catch the moon
        }

        float3 n = normalize(float3(-w.y, 1.0, -w.z));
        float3 r = reflect(d, n);
        r.y = abs(r.y);
        float c5 = 1.0 - saturate(-dot(d, n)), c2 = c5 * c5;
        float fres = 0.02 + 0.98 * c2 * c2 * c5;
        float s2 = 0.0025 * moonR * moonR + 4.0 * lost;      // highlight lobe: moon disc, capillary ripples, unresolved swell
        float spec = exp(-(1.0 - dot(r, m)) / s2) * (0.0035 * moonR * moonR / s2);
        float fl = saturate(dot(n, m) * 2.5);
        col = horizon * float3(0.055, 0.112, 0.117)
            + fres * (s26_sky(r, m, horizon, halo) + float3(1.0, 0.95, 0.85) * moonC * spec * 9.0)
            + halo * float3(0.156, 0.171, 0.177) * fl * fl                // moonlight on the facets
            + halo * float3(0.206, 0.189, 0.175) * glint;
        col = mix(s26_sky(normalize(float3(d.x, 0.0, d.z)), m, horizon, halo), col, exp(-tt * 0.025));  // haze to the horizon
    }
    col *= 1.0 - 0.18 * length(p) * 0.5;
    return float4(grain(s_tonemap(col * 1.25, 0.6, 0.95), in.position, u.res, nt), 1.0);
}

// ======================================================================
// SHADER 27 — Zen garden (karesansui)
// ======================================================================
// Raked sand as a height field h = cos(2π·φ/S) of a "rake phase" φ: straight
// furrows φ ≈ y out in the open, and the level sets of a smooth union of
// distances around the stones, so a group shares its rings. Gradients are
// analytic, so the low sun picks out every furrow without derivatives.
// setup_fs27_zen keeps the cursor's recent path (a ring of points, each
// stamped with its time) and the pebbles clicks have placed; the rake's tines
// comb grooves along that path which heal back over half a minute.
// opt = (relief, sun height, leaf shade, heal time); col0 gravel, col1 stone,
// col2 sunlight.
constant float S27_S    = 0.046;    // rake tine spacing
constant float S27_W    = 2.6 * S27_S;  // half-width of the cursor's rake
constant int   S27_PATH = 32;       // path ring: scene[26 .. 57]
static inline float s27_heal(constant Uniforms& u) { return 36.0 * exp2((u.opt.w - 0.5) * 4.0); }   // 9–144 s
constant int   S27_P0   = 26;
constant int   S27_PEB  = 58;       // pebbles: scene[58 .. 61]; scene[62].x = newest pebble
constant float S27_TAG  = 2727.0;   // scene[63] = (tag, -, last frame's click, newest path point)

kernel void setup_fs27_zen(constant Uniforms& u [[buffer(0)]], device float4* scene [[buffer(1)]],
                           uint i [[thread_position_in_grid]]) {
    if (i != 0) return;
    float4 hd = scene[63];
    if (hd.x != S27_TAG) {                           // first run, or another shader used the buffer
        hd = float4(S27_TAG, 0.0, 0.0, 0.0);
        for (int k = 0; k < S27_PATH; k++) scene[S27_P0 + k] = 0.0;
        for (int k = 0; k < 4; k++) scene[S27_PEB + k] = 0.0;
        scene[62] = 0.0;
    }
    int head = int(hd.w);
    float4 last = scene[S27_P0 + head];
    float2 m = aspectCorrectedMouse(u.mouse, u.res);
    if (u.mouseEffects > 0.5 && (last.w != S27_TAG + float(head) || distance(m, last.xy) > 0.04)) {
        head = (head + 1) % S27_PATH;
        scene[S27_P0 + head] = float4(m, u.time, S27_TAG + float(head));
        hd.w = float(head);
    }
    if (u.click > hd.z + 0.01) {                     // a new click: set down a pebble
        int k = (int(scene[62].x) + 1) % 4;
        scene[62].x = float(k);
        scene[S27_PEB + k] = float4(aspectCorrectedMouse(u.clickPos, u.res), u.time, S27_TAG);
    }
    hd.z = u.click;
    scene[63] = hd;
    // Bounds of the still-visible grooves for each run of 8 segments
    // (scene[2..5], redone every frame), so most pixels skip most of the path.
    // Segment k runs from the point k steps back to the one k−1 back (k = 0: to the cursor).
    float4 bb[4] = { float4(m, m), float4(1e3, 1e3, -1e3, -1e3), float4(1e3, 1e3, -1e3, -1e3), float4(1e3, 1e3, -1e3, -1e3) };
    float heal = s27_heal(u);
    for (int k = 0; k < S27_PATH; k++) {
        int ix = (head - k + S27_PATH) % S27_PATH;
        float4 q = scene[S27_P0 + ix];
        if (q.w != S27_TAG + float(ix) || u.time - q.z > heal) continue;
        int c0 = k / 8, c1 = min((k + 1) / 8, 3);
        bb[c0] = float4(min(bb[c0].xy, q.xy), max(bb[c0].zw, q.xy));
        bb[c1] = float4(min(bb[c1].xy, q.xy), max(bb[c1].zw, q.xy));
    }
    for (int c = 0; c < 4; c++) scene[2 + c] = bb[c] + float4(-1.0, -1.0, 1.0, 1.0) * S27_W;
}
constant float4 S27_SHAPE[7] = {                   // per-island outline phases (cos φ₁, sin φ₁, cos φ₂, sin φ₂)
    float4(1.0000, 0.0000, 1.0000, 0.0000),   float4(0.2675, 0.9636, -0.9710, 0.2392),
    float4(-0.8569, 0.5155, 0.8855, -0.4646), float4(-0.7259, -0.6878, -0.7486, 0.6630),
    float4(0.4685, -0.8835, 0.5683, -0.8228), float4(0.9766, 0.2151, -0.3549, 0.9349),
    float4(0.0540, 0.9985, 0.1209, -0.9927),
};
// Polynomial smooth min; its gradient is exactly the h-blend of the two.
static float s27_smin(float a, float b, float k, thread float2& ga, float2 gb) {
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    ga = mix(gb, ga, h);
    return mix(b, a, h) - k * h * (1.0 - h);
}
fragment float4 fs27_zen(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                         constant float4* scene [[buffer(1)]],
                         texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;
    float t = u.time, aspect = u.res.x / u.res.y;
    float px = 2.0 / u.res.y;
    const float TAU = 2.0 * PI;
    // Sun height: 14°–42°, 24° by default; shadows stretch as 1/tan.
    float elev = 0.4241 * exp2((u.opt.y - 0.5) * 1.6);
    const float2 away = float2(0.8804, -0.4742);          // the shadows' heading
    float3 L = float3(-away * cos(elev), sin(elev));
    float lenS = 0.4512 / tan(elev);

    // Open sand: long furrows with a slow, breathing sway.
    float w1 = 0.9 * p.x + 0.7 + 0.5 * sin(t * 0.021), w2 = 2.3 * p.x - t * 0.017;
    float phiP = p.y + 0.035 * sin(w1) + 0.012 * sin(w2);
    float2 gP = float2(0.035 * 0.9 * cos(w1) + 0.012 * 2.3 * cos(w2), 1.0);

    // Islands: three set stones and up to four placed pebbles. F = smooth union
    // of (distance past the island's edge − its ring band); F < 0 is ringed sand.
    float F = 1e3; float2 gF = float2(0.0, 1.0);
    float stoneD = 1e3; float2 stoneV = 0.0; float stoneR = 1.0, stoneId = 0.0;
    float shadow = 0.0, placed = -1e4, pw = 0.0;   // the newest-weighted pebble ring band here: when, and how much
    for (int j = 0; j < 7; j++) {
        float2 c; float R, rings, tz = -1e4;
        if (j == 0)      { c = float2(-0.50 * aspect,  0.22); R = 0.165; rings = 6.0; }
        else if (j == 1) { c = float2(-0.30 * aspect,  0.00); R = 0.080; rings = 5.0; }
        else if (j == 2) { c = float2( 0.52 * aspect, -0.36); R = 0.120; rings = 6.0; }
        else {
            float4 pb = scene[S27_PEB + j - 3];
            if (pb.w != S27_TAG) continue;
            float age = t - pb.z;
            c = pb.xy; tz = pb.z;
            R = (0.035 + 0.02 * hash12(float2(pb.z, 1.7))) * smoothstep(0.0, 0.35, age);
            rings = 3.0 * smoothstep(0.2, 4.0, age);           // the rake circles it, ring by ring
        }
        // Outline R·(1 + 0.10 sin(2θ+φ₁) + 0.05 sin(3θ+φ₂)), multiple angles
        // expanded from cos θ, sin θ so the loop needs no trig.
        float2 v = p - c;
        float r = length(v) + 1e-5;
        float cs = v.x / r, sn = v.y / r;
        float s2 = 2.0 * sn * cs, c2 = cs * cs - sn * sn;
        float s3 = sn * (3.0 - 4.0 * sn * sn), c3 = cs * (4.0 * cs * cs - 3.0);
        float4 ph = S27_SHAPE[j];
        float edge  = R * (1.0 + 0.10 * (s2 * ph.x + c2 * ph.y) + 0.05 * (s3 * ph.z + c3 * ph.w));
        float dEdge = R * (0.20 * (c2 * ph.x - s2 * ph.y) + 0.15 * (c3 * ph.z - s3 * ph.w));   // d edge / dθ
        float dd = r - edge;
        float2 g = float2(cs, sn) - dEdge / r * float2(-sn, cs);
        if (dd < stoneD) { stoneD = dd; stoneV = v; stoneR = edge; stoneId = float(j); }
        float f = dd - rings * S27_S;
        float wj = smoothstep(0.5 * S27_S, -0.5 * S27_S, f);
        if (tz > -1e3 && wj > pw) { pw = wj; placed = tz; }
        F = s27_smin(f, F, 0.12, gF, g);
        // A long soft shadow thrown away from the low sun.
        float2 sv = v - away * R * (1.9 * lenS - 0.85);
        float2 sl = float2(dot(sv, away), dot(sv, float2(-away.y, away.x))) / (max(R, 1e-3) * float2(1.9 * lenS, 1.0));
        shadow = max(shadow, max(smoothstep(1.0, 0.5, length(sl)), 0.6 * smoothstep(0.035, 0.0, dd)) * step(1e-3, R));
    }
    // h = cos of the phase: the rings below F = 0 meet the open furrows at a ridge.
    float wz = smoothstep(0.2 * S27_S, -0.2 * S27_S, F);
    float h  = mix(cos(TAU * phiP / S27_S), cos(TAU * F / S27_S), wz);
    float2 g = mix(-sin(TAU * phiP / S27_S) * gP, -sin(TAU * F / S27_S) * gF, wz) * (TAU / S27_S);

    // The rake: the cursor's path, oldest segment first so newer passes comb over
    // older ones. Grooves made before a pebble landed are smoothed under its rings.
    const float h0 = h; const float2 g0 = g;
    if (u.mouseEffects > 0.0) {
        int head = int(scene[63].w);
        float2 m = aspectCorrectedMouse(u.mouse, u.res);
        float heal = s27_heal(u);
        for (int c = 3; c >= 0; c--) {
            float4 bb = scene[2 + c];
            if (any(p < bb.xy) || any(p > bb.zw)) continue;
            for (int k = c * 8 + 7; k >= c * 8; k--) {
                int ia = (head - k + S27_PATH) % S27_PATH, ib = (ia + 1) % S27_PATH;
                float4 a = scene[S27_P0 + ia];
                float4 b = k == 0 ? float4(m, t, 0.0) : scene[S27_P0 + ib];
                if (a.w != S27_TAG + float(ia) || (k > 0 && b.w != S27_TAG + float(ib))) continue;
                float2 ab = b.xy - a.xy, ap = p - a.xy;
                float ab2 = dot(ab, ab);
                float l = dot(ap, ab) / max(ab2, 1e-8);
                if (l < 0.0) continue;               // flat start, round end: the older segment's cap fills each bend
                l = min(l, 1.0);
                float2 dv = ap - ab * l;
                float dist = length(dv) + 1e-5;
                if (dist > S27_W) continue;
                float made = mix(a.z, b.z, l), age = t - made;
                float cover = smoothstep(S27_W, S27_W - 0.5 * S27_S, dist)
                            * smoothstep(0.0, 1e-4, ab2)                         // a resting rake leaves no mark
                            * (made > placed ? 1.0 : 1.0 - pw);
                float fresh = (1.0 - smoothstep(2.0, heal, age))                // heals
                            * saturate((float(S27_PATH - 1 - k) + l) / 5.0);    // the ring's tail, smooth along the path
                // Each pass replaces what it covers with its own half-healed furrows,
                // so overlapping neighbours at a joint don't double up.
                float ph = TAU * dist / S27_S;
                h = mix(h, mix(h0, cos(ph), fresh), cover);
                g = mix(g, mix(g0, -sin(ph) * (TAU / S27_S) * dv / dist, fresh), cover);
            }
        }
    }

    // Light: a low late-afternoon sun from the upper left, a cool sky above.
    float3 n = normalize(float3(-g * (0.003 * exp2((u.opt.x - 0.5) * 2.0)), 1.0));   // relief 0.5–2×
    // Dappled shade from an unseen maple at the top right, swaying slowly.
    float shade = min(1.4 * u.opt.z, 0.95);
    float canopy = shade * smoothstep(0.1 - (u.opt.z - 0.5) * 0.8, 1.2, p.x / aspect * 0.7 + p.y * 0.8);
    float dapple = 1.0;
    if (canopy > 0.0) {
        float2 lp = p * 2.6 + float2(0.05 * sin(t * 0.13), 0.04 * sin(t * 0.17 + 1.0));
        float leaf = vnoise(lp, nt) * 0.55 + vnoise(lp * 2.3 + 4.1, nt) * 0.3 + vnoise(lp * 5.1 + 8.7, nt) * 0.15;
        dapple = 1.0 - smoothstep(0.42, 0.58, leaf) * canopy;
    }
    float3 sun = u.col2.rgb * 1.7;
    float diff = max(dot(n, L), 0.0);
    float3 sand = u.col0.rgb * (0.97 + 0.06 * vnoise(p * 140.0, nt));
    float3 col = sand * (sun * diff * dapple * (1.0 - 0.7 * shadow)
                       + float3(0.40, 0.46, 0.58) * 0.42 * (0.88 + 0.12 * h) * (1.0 - 0.3 * shadow));

    // Stones: weathered granite domes with a moss collar.
    float body = smoothstep(px * 1.2, -px * 1.2, stoneD);
    if (body > 0.0) {
        float rho = saturate(length(stoneV) / stoneR);
        float2 q = stoneV / stoneR * 3.0 + stoneId * 7.3;
        float tex = vnoise(q, nt) * 0.6 + vnoise(q * 2.7, nt) * 0.4;
        float speck = vnoise(q * 11.0, nt);
        float2 bump = float2(vnoise(q * 1.6 + 0.3, nt), vnoise(q * 1.6 + 5.1, nt)) - 0.5;
        float3 sn = normalize(float3(stoneV / stoneR + bump * 0.35, sqrt(max(1.0 - rho * rho, 0.0)) + 0.2));
        float3 rock = mix(float3(0.30, 0.30, 0.29), float3(0.52, 0.50, 0.46), tex) * (0.85 + 0.3 * speck);
        rock = mix(rock, float3(0.22, 0.27, 0.13), smoothstep(0.75, 1.0, rho) * smoothstep(0.4, 0.65, tex) * 0.7);
        rock *= u.col1.rgb / float3(0.52, 0.50, 0.46);       // tinted by the STONE well (its default is the light tone)
        float sd = saturate(dot(sn, L) * 0.85 + 0.15);
        float sp = pow(max(dot(reflect(-L, sn), float3(0, 0, 1)), 0.0), 10.0);
        float3 sc = rock * (sun * sd * dapple + float3(0.40, 0.46, 0.58) * (0.25 + 0.35 * sn.z))
                  + sun * float3(0.035, 0.0375, 0.0396) * sp * dapple;
        col = mix(col, sc, body);
    }
    col *= 1.0 - 0.22 * length(p) * 0.5;
    return float4(grain(s_tonemap(col, 0.45, 1.0), in.position, u.res, nt), 1.0);
}
