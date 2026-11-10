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
// Eight wax blobs plus a calved bubble and the cursor's heat, field
// f = Σ r²/d². setup_fs16_lava places them once per frame; the pixel loop is
// pure arithmetic, and the field's gradient is summed in the same loop so the
// glossy dome normal costs no extra field evaluations.
kernel void setup_fs16_lava(constant Uniforms& u [[buffer(0)]], device float4* scene [[buffer(1)]],
                            uint i [[thread_position_in_grid]]) {
    if (i >= 10) return;
    float fi = float(i), t = u.time, aspect = u.res.x / u.res.y;
    float h1 = hash12(float2(fi, 4.2)), h2 = hash12(float2(fi, 8.1));
    float2 c = float2(aspect * 0.62 * sin(t * (0.031 + 0.02 * h1) + fi * 2.4),
                      1.2 * sin(t * (0.045 + 0.035 * h2) + fi * 1.3));
    float r = 0.12 + 0.09 * h1;
    if (i == 8) {                       // a calved bubble rising from the click
        c = aspectCorrectedMouse(u.clickPos, u.res) + float2(0.0, (1.0 - u.click) * 1.1);
        r = 0.13 * sqrt(u.click);
    } else if (i == 9) {                // the heating coil: wax gathers at the cursor
        c = aspectCorrectedMouse(u.mouse, u.res);
        r = 0.09 * u.mouseEffects;
    }
    scene[i] = float4(c, r * r, 0.0);
}
fragment float4 fs16_lava(VSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                          constant float4* scene [[buffer(1)]],
                          texture2d<float> nt [[texture(0)]]) {
    float2 fc = fragCoordFromPosition(in.position, u.res);
    float2 p  = (fc * 2.0 - u.res) / u.res.y;

    float f = 0.0;
    float2 g = 0.0;
    for (int i = 0; i < 10; i++) {
        float2 d = p - scene[i].xy;
        float d2 = dot(d, d) + 1e-4;
        float k = scene[i].z / d2;
        f += k;
        g -= 2.0 * k * d / d2;
    }

    float aa = max(fwidth(f), 1e-4);
    float body = smoothstep(1.0 - aa, 1.0 + aa, f);
    float3 n = normalize(float3(-g * 0.05, 1.0));
    float3 L = normalize(float3(-0.35, -0.6, 0.7));        // the lamp's bulb sits below
    float diff = max(dot(n, L), 0.0);
    float spec = pow(max(dot(reflect(-L, n), float3(0, 0, 1)), 0.0), 30.0);
    float rim  = pow(1.0 - n.z, 1.5);
    float heat = smoothstep(1.1, -1.1, p.y);

    float3 wax = mix(float3(0.95, 0.28, 0.04), float3(1.0, 0.70, 0.22), saturate(f - 1.0) * 0.35 + heat * 0.35);
    wax = wax * (0.45 + 0.75 * diff) + float3(1.0, 0.9, 0.7) * spec * 0.5 + float3(1.0, 0.45, 0.1) * rim * 0.6;

    float3 liquid = mix(float3(0.10, 0.012, 0.05), float3(0.32, 0.03, 0.10), heat);
    liquid += float3(0.9, 0.25, 0.06) * smoothstep(0.25, 1.0, f) * 0.3;   // glow scattered by the solvent
    float3 col = mix(liquid, wax, body);
    col *= 1.0 - 0.25 * length(p) * 0.5;
    return float4(grain(s_tonemap(col, 0.35, 0.95), in.position, u.res, nt), 1.0);
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
