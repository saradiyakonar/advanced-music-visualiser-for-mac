/// Metal source, compiled at runtime (the `metal` compiler ships only with Xcode).
/// One full-screen pass: background, two-colour glow behind the cover, a soft rippling
/// screen-edge glow (Lumn-style), and the album cover with tilt and glitch.
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 colours[4];    // album palette, most dominant first
        float colourCount;
        float2 resolution;
        float time;           // seconds, wrapped
        float flow;           // 0..1, beat-pushed drift of the colour blend
        float coverScale;
        float glowScale;
        float glowOpacity;
        float edgeEnergy;     // 0..1, how much the edge glow swells right now
        float glitch;
        float slices;
        float serial;
        float dim;
        float tilt;
        float coverHalf;      // cover half-side as a fraction of the shorter dimension
        float coverVisible;   // 0 in lyrics mode
        float impact;
        float impactProgress;
        float2 pointer;
    };

    struct VOut { float4 position [[position]]; };

    vertex VOut vmain(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }

    float sdRoundRect(float2 p, float2 halfSize, float r) {
        float2 q = abs(p) - halfSize + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    float hash11(float n) { return fract(sin(n * 127.1) * 43758.5453); }

    float3 screenBlend(float3 a, float3 b) { return 1.0 - (1.0 - a) * (1.0 - b); }

    // Smooth, looping 1D "blob" noise around the screen perimeter (s in 0..1).
    float ripple(float s, float t) {
        float tau = 2.0 * M_PI_F;
        return 0.50 * sin(s * tau * 3.0 + t * 0.70)
             + 0.30 * sin(s * tau * 5.0 - t * 1.10 + 1.3)
             + 0.20 * sin(s * tau * 8.0 + t * 1.70 + 2.1);
    }

    // The album colours laid around the perimeter (s in 0..1, wraps), blending smoothly
    // and drifting over time and with each beat. The dominant colour gets the widest band.
    float3 edgeColour(constant Uniforms& u, float s) {
        int n = int(clamp(u.colourCount, 1.0, 4.0));
        // Each colour appears once around the screen and the ring keeps rotating
        // (a full turn every ~20 s), nudged along by every beat.
        float x = fract(s + u.time * 0.05 + u.flow * 0.5) * float(n);
        int i = int(floor(x)) % n;
        int j = (i + 1) % n;
        float f = fract(x);
        f = smoothstep(0.25, 0.9, f);                    // hold each colour, then blend
        return mix(u.colours[i].rgb, u.colours[j].rgb, f);
    }

    fragment float4 fmain(VOut in [[stage_in]],
                          constant Uniforms& u [[buffer(0)]],
                          texture2d<float> cover [[texture(0)]],
                          texture2d<float> blurred [[texture(1)]],
                          sampler s [[sampler(0)]]) {
        float2 res = u.resolution;
        float minDim = min(res.x, res.y);
        float2 xy = in.position.xy;
        float2 p = xy - res * 0.5;                       // pixels from centre, y down
        float perim = atan2(p.y, p.x) / (2.0 * M_PI_F) + 0.5;

        float3 col = float3(5.0, 3.0, 10.0) / 255.0;    // #05030a

        // Cover-fill preserves the artwork's proportions on landscape AND portrait displays.
        // Sharp details live at the sides; a soft, dark centre leaves room for the words.
        float2 artUV = p / max(res.x, res.y);
        float zoom = 1.08 + 0.025 * sin(u.time * 0.12) + u.impact * 0.09;
        artUV = artUV / zoom + 0.5;
        artUV += 0.018 * float2(sin(u.time * 0.08), cos(u.time * 0.065)) + u.pointer * 0.018;
        float3 softArt = blurred.sample(s, artUV).rgb;
        float3 detailArt = cover.sample(s, artUV).rgb;
        float centre = exp(-dot(p / (res * float2(0.32, 0.48)), p / (res * float2(0.32, 0.48))));
        float vignette = 1.0 - 0.48 * length(p / (res * 0.5));
        if (u.coverVisible < 0.5) {
            float detail = (1.0 - centre) * 0.68;
            col = mix(softArt, detailArt, detail) * (0.64 - centre * 0.39) * vignette * u.dim;
            col += softArt * u.impact * (0.28 - centre * 0.2);
        } else {
            col += softArt * (0.12 + 0.14 * u.impact) * vignette * u.dim;
        }

        // An expanding pressure wave follows a big hit independently of subsequent kicks.
        float radius = length(p / minDim);
        float waveRadius = 0.15 + u.impactProgress * 1.5;
        float wave = exp(-pow((radius - waveRadius) / (0.025 + u.impactProgress * 0.08), 2.0));
        float halo = exp(-abs(radius - waveRadius) * 8.0);
        float3 impactColour = mix(edgeColour(u, perim + 0.2), float3(1.0), 0.18);
        col += impactColour * (wave * 0.7 + halo * 0.22) * u.impact * u.dim;

        // Glow behind the cover, blending the two album colours around it.
        float halfC = u.coverHalf * minDim * u.coverScale;
        if (u.coverVisible > 0.5) {
            float dGlow = sdRoundRect(p, float2(halfC), 0.08 * minDim);
            float glowR = 0.09 * minDim * u.glowScale;
            float glow = u.glowOpacity * exp(-max(dGlow, 0.0) / glowR) * u.dim;
            col += edgeColour(u, perim + 0.25) * glow;
        }

        // Screen-edge glow: thick soft light whose inner edge ripples and swells with the music.
        float dEdge = min(min(xy.x, res.x - xy.x), min(xy.y, res.y - xy.y));
        float base = 0.035 * minDim;
        float thickness = base * (1.0 + 0.45 * ripple(perim, u.time)) * (0.8 + 1.6 * u.edgeEnergy);
        thickness = max(thickness, 2.0);
        float body = pow(clamp(1.0 - dEdge / thickness, 0.0, 1.0), 1.6);
        float haze = exp(-dEdge / (thickness * 0.9)) * 0.35;
        float core = exp(-dEdge / (thickness * 0.12));
        float3 ec = edgeColour(u, perim);
        float3 edge = mix(ec, float3(1.0), core * 0.45);   // whiter right at the screen edge
        float breathe = 0.9 + 0.1 * sin(u.time * 1.6);   // light pulse even between beats
        float edgeA = clamp((body + haze) * (0.55 + 0.45 * u.edgeEnergy) * breathe, 0.0, 1.0) * u.dim;
        col = mix(col, edge, edgeA);

        // Album cover, tilted by the beat.
        if (u.coverVisible > 0.5) {
            float c = cos(-u.tilt), sn = sin(-u.tilt);
            float2 cp = p - u.pointer * minDim * 0.012;
            float2 pr = float2(c * cp.x - sn * cp.y, sn * cp.x + c * cp.y);
            float dCover = sdRoundRect(pr, float2(halfC), 0.015 * minDim);
            if (dCover < 1.0) {
                float2 uv = pr / (2.0 * halfC) + 0.5;
                float g = u.glitch;
                if (u.slices > 0.5) {
                    for (int i = 0; i < 2; i++) {
                        float y = hash11(u.serial * 3.0 + float(i) * 17.0) * 0.85 + 0.05;
                        if (abs(uv.y - y) < 0.0125) { uv.x += (i == 0 ? 1.0 : -1.0) * 0.04 * g; }
                    }
                }
                float3 baseCol = cover.sample(s, uv).rgb;
                if (g > 0.0) {
                    float off = 0.012 * g;
                    float3 red = cover.sample(s, uv + float2(-off, off * 0.3)).rgb * float3(1.0, 0.0, 0.3);
                    float3 cyan = cover.sample(s, uv + float2(off, -off * 0.3)).rgb * float3(0.0, 0.9, 1.0);
                    baseCol = screenBlend(baseCol, red * g * 0.8);
                    baseCol = screenBlend(baseCol, cyan * g * 0.8);
                }
                float a = 1.0 - smoothstep(-1.0, 1.0, dCover);
                col = mix(col, baseCol * u.dim, a);
            }
        }
        return float4(col, 1.0);
    }
    """
}
