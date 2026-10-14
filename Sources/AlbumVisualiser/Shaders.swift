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
        float4 style; // scene, bloom, atmosphere, stardust
        float4 bands; // bass, mid, treble, halo enabled
        float4 sceneMix;
        float4 rhythm; // sustained pace, beat pulse, drop envelope, waves enabled
        float4 themesA; // storm, fire, water, stars
        float4 themesB; // warmth, drift, audio buildup, drop progress
        float4 sceneMixExtra; // lasers, tunnel, nebula
        float4 performance; // lyric accent, burst progress, party, accent seed
        float4 themesExtra; // snow, flowers, rain, celebration
        float4 laser; // beat sweep, fan opening, crossed beams, overhead curtain
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

    float heartShape(float2 p) {
        p.y = -p.y + 0.18;
        float a = dot(p, p) - 1.0;
        float shape = a * a * a - p.x * p.x * p.y * p.y * p.y;
        float aa = max(fwidth(shape), 0.015);
        return 1.0 - smoothstep(-aa, aa, shape);
    }

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
        float zoom = 1.08 + 0.025 * sin(u.time * 0.12) + u.impact * 0.09 + u.rhythm.y * 0.035 + u.rhythm.z * 0.07;
        artUV = artUV / zoom + 0.5;
        artUV += 0.018 * float2(sin(u.time * 0.08), cos(u.time * 0.065)) + u.pointer * 0.018;
        float3 softArt = blurred.sample(s, artUV).rgb;
        float3 detailArt = cover.sample(s, artUV).rgb;
        float centre = exp(-dot(p / (res * float2(0.32, 0.48)), p / (res * float2(0.32, 0.48))));
        float vignette = 1.0 - 0.48 * length(p / (res * 0.5));
        if (u.coverVisible < 0.5) {
            float detail = (1.0 - centre) * 0.68;
            col = mix(softArt, detailArt, detail) * (0.64 - centre * 0.39) * vignette * u.dim * (0.25 + u.style.z);
            col += softArt * u.impact * (0.28 - centre * 0.2);
        } else {
            col += softArt * (0.12 + 0.14 * u.impact) * vignette * u.dim * (0.25 + u.style.z);
        }

        float2 q = p / minDim;
        q /= 1.0 + u.rhythm.y * 0.055 + u.rhythm.z * 0.1;
        q *= 1.0 + u.themesB.z * 0.12;
        float centreMask = u.coverVisible > 0.5 ? 1.0 : 1.0 - centre * 0.83;
        float3 scenery = float3(0.0);
        // AURA: three wide ribbons, pulled by bass and the pointer.
        if (u.sceneMix.x > 0.001) {
            for (int j = 0; j < 3; j++) {
                float fj = float(j);
                float curve = sin(q.x * 3.0 + u.time * 0.25 + fj * 2.1) * 0.27;
                curve += sin(q.x * 6.0 - u.time * 0.18 + fj) * 0.07;
                float d = abs(q.y - curve - (fj - 1.0) * 0.24 + u.pointer.y * 0.04);
                float ribbon = exp(-d * (14.0 - u.bands.x * 4.0));
                scenery += edgeColour(u, fj / 3.0 + q.x * 0.1) * ribbon * (0.16 + u.bands.y * 0.2) * u.sceneMix.x;
            }
        }
        // ORBIT: fine tilted ellipses and soft orbital wakes.
        if (u.sceneMix.y > 0.001) {
            for (int j = 0; j < 3; j++) {
                float fj = float(j), angle = fj * 1.047 + u.time * 0.05;
                float2 orbit = float2(cos(angle) * q.x - sin(angle) * q.y,
                                     sin(angle) * q.x + cos(angle) * q.y);
                orbit.y *= 1.55;
                float orbitRadius = 0.48 + fj * 0.075 + u.bands.x * 0.03;
                float d = abs(length(orbit) - orbitRadius);
                float arc = 0.5 + 0.5 * sin(atan2(orbit.y, orbit.x) * 2.0 + u.time * 0.4 + fj);
                float light = exp(-d * 420.0) * 0.65 + exp(-d * 32.0) * 0.13;
                scenery += edgeColour(u, perim + fj / 3.0) * light * (0.35 + arc) * u.sceneMix.y;
            }
        }
        // PRISM: mirror-fold the real artwork into a slowly travelling tunnel.
        if (u.sceneMix.z > 0.001) {
            float angle = atan2(q.y, q.x) + u.time * 0.035;
            float sector = M_PI_F / 3.0;
            float folded = abs(fract(angle / sector) - 0.5) * sector;
            float r = length(q);
            float depth = r * 1.7 - u.time * 0.035;
            float2 uv = float2(cos(folded), sin(folded)) * depth;
            uv = abs(fract(uv + 0.5) * 2.0 - 1.0);
            float3 prismArt = cover.sample(s, uv).rgb;
            float contour = pow(0.5 + 0.5 * cos(r * 28.0 - u.time * 0.7), 12.0);
            scenery += (prismArt * 0.48 + edgeColour(u, perim) * contour * 0.12) * u.sceneMix.z;
        }
        // LASERS: paired stage heads. Beats move the heads; eight-beat phrases change the rig.
        if (u.sceneMixExtra.x > 0.001) {
            float hit = clamp(u.rhythm.y, 0.0, 1.0);
            float drop = clamp(max(u.rhythm.z, u.impact), 0.0, 1.0);
            float fanMix = max(0.0, 1.0 - u.laser.z - u.laser.w);
            float spread = u.laser.y + hit * 0.25 + drop * 0.6;
            for (int side = 0; side < 2; side++) {
                float sign = side == 0 ? -1.0 : 1.0;
                for (int j = 0; j < 7; j++) {
                    float fj = float(j), lane = (fj - 3.0) / 3.0;
                    float2 origin = float2(sign * (0.62 + drop * 0.16), 0.57);
                    // Fans open from opposite corners, cross through centre, then become a ceiling curtain.
                    float fanAngle = -sign * 0.42 + lane * spread * 0.65 + u.laser.x * sign;
                    float crossAngle = -sign * 0.7 + lane * 0.12 + u.laser.x * 0.8;
                    float curtainAngle = 0.1 * lane + u.laser.x * 0.7;
                    float angle = fanAngle * fanMix + crossAngle * u.laser.z + curtainAngle * u.laser.w;
                    origin = mix(origin, float2(sign * (0.15 + (fj / 6.0) * 0.95), -0.65), u.laser.w);
                    float2 direction = float2(sin(angle), -cos(angle));
                    direction = mix(direction, float2(sin(angle), cos(angle)), u.laser.w);
                    direction = normalize(direction);
                    float2 beam = q - origin;
                    float along = dot(beam, direction);
                    float d = abs(beam.x * direction.y - beam.y * direction.x);
                    float core = exp(-d * 750.0);
                    float haze = exp(-d * (40.0 - drop * 15.0)) * 0.19;
                    float gate = smoothstep(-0.02, 0.03, along);
                    float chase = 0.65 + 0.35 * cos(fj * 0.9 + u.laser.x * 5.0);
                    float brightness = 0.16 + hit * 1.3 + u.bands.x * 0.22 + drop * 0.85;
                    float3 colour = edgeColour(u, fj / 9.0 + float(side) * 0.35 + u.laser.x * 0.13);
                    colour = mix(colour, float3(0.85, 0.95, 1.0), core * hit * 0.28);
                    scenery += colour * (core + haze) * gate * chase * brightness * u.sceneMixExtra.x;
                }
            }
        }
        // TUNNEL: nested perspective rings accelerate and expand on kicks.
        if (u.sceneMixExtra.y > 0.001) {
            float2 tunnelQ = q - u.pointer * 0.035;
            float radius = length(tunnelQ);
            float angle = atan2(tunnelQ.y, tunnelQ.x);
            for (int j = 0; j < 8; j++) {
                float travel = fract(float(j) / 8.0 + u.time * 0.13);
                float ringRadius = 0.035 + travel * travel * 1.25 + u.rhythm.y * 0.045;
                float polygon = 1.0 + 0.035 * cos(angle * 6.0 + u.time * 0.3);
                float d = abs(radius * polygon - ringRadius);
                float ring = exp(-d * (240.0 - travel * 110.0));
                scenery += edgeColour(u, travel + angle / (2.0 * M_PI_F)) * ring * sin(travel * M_PI_F)
                         * (0.35 + u.rhythm.y * 0.65) * u.sceneMixExtra.y;
            }
        }
        // NEBULA: layered, billowing colour fields with bright particle pockets.
        if (u.sceneMixExtra.z > 0.001) {
            float2 n = q * 3.0;
            for (int j = 0; j < 4; j++) {
                float fj = float(j);
                float cloud = sin(n.x * 1.7 + sin(n.y * 1.9 + u.time * 0.18 + fj));
                cloud *= cos(n.y * 1.3 - u.time * 0.15 + fj * 1.7);
                float haze = pow(max(0.0, cloud * 0.5 + 0.5), 3.0);
                scenery += edgeColour(u, fj * 0.23 + q.x * 0.08) * haze * (0.12 + u.rhythm.y * 0.15) * u.sceneMixExtra.z;
                n = float2(n.x * 0.8 - n.y * 0.6, n.x * 0.6 + n.y * 0.8) + 1.3;
            }
        }
        col += scenery * centreMask * u.style.z * u.dim * (1.0 + u.rhythm.y * 0.8 + u.rhythm.z);

        // Fast passages reveal travelling radial ripples; drops open a broad colour burst.
        float radial = length(q);
        float ripples = pow(0.5 + 0.5 * sin(radial * 38.0 - u.time * 3.5), 8.0);
        float burst = exp(-radial * 1.8) * u.rhythm.z;
        col += edgeColour(u, perim + radial * 0.2) * centreMask * u.style.z * u.dim
             * (ripples * u.rhythm.x * (0.06 + u.rhythm.y * 0.24) * u.rhythm.w + burst * 0.38);

        // Phrase scenes stay behind the artwork and preserve the lyric centre's contrast.
        float3 lyricLight = float3(0.0);
        float pulse = clamp(u.rhythm.y + u.impact * 0.5, 0.0, 1.0);
        if (u.themesA.x > 0.001) {
            // Branching geometric lightning: a single illuminated strike with a rolling afterglow.
            float strike = u.performance.x * exp(-u.performance.y * 7.0);
            float lightning = 0.0, haze = 0.0;
            for (int side = 0; side < 2; side++) {
                float sign = side == 0 ? -1.0 : 1.0;
                float seed = u.performance.w * 17.0 + float(side) * 31.0;
                float y = q.y + 0.65;
                float segment = y * 16.0, node = floor(segment);
                float jag = (mix(hash11(node + seed), hash11(node + 1.0 + seed), fract(segment)) - 0.5) * 0.14;
                float path = sign * (0.47 + y * 0.09) + jag;
                float d = abs(q.x - path);
                float trunk = exp(-d * 550.0);
                haze += exp(-d * 45.0) * 0.35;
                for (int branch = 0; branch < 3; branch++) {
                    float split = 0.25 + float(branch) * 0.28;
                    float by = y - split;
                    float branchD = abs(q.x - path - sign * by * (0.5 + float(branch) * 0.12));
                    trunk += exp(-branchD * 620.0) * 0.65 * step(0.0, by) * (1.0 - smoothstep(0.1, 0.32, by));
                }
                lightning += trunk * (1.0 - smoothstep(1.1, 1.4, y));
            }
            float cloud = exp(-pow((q.y + 0.35 + sin(q.x * 5.0 + u.time * 0.3) * 0.09) * 6.0, 2.0));
            float thunder = exp(-pow((length(q) - 0.2 - u.performance.y * 1.5) * 14.0, 2.0)) * u.performance.x;
            lyricLight += (float3(0.8, 0.88, 1.0) * lightning * strike * 3.0
                         + float3(0.3, 0.45, 1.0) * (haze * strike + cloud * 0.14 + thunder * 0.2)) * u.themesA.x;
        }
        if (u.themesA.y > 0.001) {
            float heat = sin(q.x * 14.0 + sin(q.y * 9.0 + u.time) * 2.0 - u.time * 1.5);
            float flame = exp(-abs(q.y - 0.48 + (heat * 0.5 + 0.5) * (0.12 + pulse * 0.12)) * 10.0);
            float2 emberUV = q * float2(24.0, 12.0) + float2(0.2 * sin(u.time), u.time * 0.8);
            float seed = hash11(floor(emberUV.x) + floor(emberUV.y) * 79.0);
            float ember = exp(-dot(fract(emberUV) - 0.5, fract(emberUV) - 0.5) * 360.0) * step(0.82, seed);
            lyricLight += (float3(1.0, 0.19, 0.035) * flame * 0.35 + float3(1.0, 0.55, 0.14) * ember * 0.65) * u.themesA.y;
        }
        if (u.themesA.z > 0.001) {
            float swell = sin(q.x * 9.0 + u.time * 0.65) * (0.05 + pulse * 0.04);
            float water = pow(0.5 + 0.5 * sin((q.y + swell) * 36.0 + u.time * 0.8), 10.0);
            float shimmer = 0.5 + 0.5 * sin(q.x * 17.0 - u.time * 0.4);
            lyricLight += float3(0.08, 0.52, 0.85) * water * (0.12 + shimmer * 0.16 + pulse * 0.12) * u.themesA.z;
        }
        if (u.themesA.w > 0.001 || u.themesB.y > 0.001) {
            float drift = u.themesB.y;
            float2 skyUV = q * (18.0 - pulse * 1.2) + float2(u.time * 0.05, u.time * (0.08 + drift * 0.15));
            float2 cell = floor(skyUV);
            float seed = hash11(cell.x * 23.7 + cell.y * 111.3);
            float2 point = fract(skyUV) - float2(hash11(seed * 61.0), hash11(seed * 97.0));
            float stars = exp(-dot(point, point) * 650.0) * step(0.65, seed);
            float glow = exp(-dot(point, point) * 36.0) * step(0.92, seed);
            lyricLight += float3(0.62, 0.72, 1.0) * (stars * 0.7 + glow * 0.14) * u.themesA.w;
            lyricLight += float3(0.43, 0.36, 0.58) * (stars * 0.3 + glow * 0.08) * drift;
        }
        if (u.themesB.x > 0.001) {
            float burst = u.performance.y;
            for (int j = 0; j < 16; j++) {
                float fj = float(j), seed = hash11(fj * 13.7 + u.performance.w);
                float angle = fj * 2.39996 + seed * 0.5;
                float distance = 0.14 + burst * (0.45 + seed * 0.65);
                float2 origin = float2(cos(angle), sin(angle)) * distance;
                origin.y -= burst * burst * 0.18;
                float size = (0.026 + seed * 0.023) * (1.0 + burst * 0.35);
                float2 hp = (q - origin) / size;
                float turn = sin(fj) * 0.28;
                hp = float2(hp.x * cos(turn) - hp.y * sin(turn), hp.x * sin(turn) + hp.y * cos(turn));
                float heart = heartShape(hp);
                float3 pink = mix(float3(1.0, 0.055, 0.23), float3(1.0, 0.55, 0.72), seed);
                lyricLight += pink * heart * u.performance.x * 1.7 * u.themesB.x;
            }
        }
        if (u.themesExtra.x > 0.001 || u.themesExtra.y > 0.001) {
            for (int j = 0; j < 18; j++) {
                float fj = float(j), seed = hash11(fj * 29.3);
                float2 origin = float2((seed - 0.5) * 2.4, fract(hash11(fj * 83.1) + u.time * 0.06) * 1.5 - 0.75);
                origin.x += sin(u.time * 0.3 + fj) * 0.05;
                float2 flake = (q - origin) / (0.018 + seed * 0.018);
                float radius = length(flake), angle = atan2(flake.y, flake.x) + u.time * 0.1;
                float snow = exp(-abs(sin(angle * 3.0)) * radius * 13.0) * (1.0 - smoothstep(0.8, 1.1, radius));
                float petal = 1.0 - smoothstep(0.65, 0.8, radius - 0.22 * cos(angle * 5.0));
                lyricLight += float3(0.65, 0.87, 1.0) * snow * u.themesExtra.x * 0.85;
                lyricLight += mix(float3(1.0, 0.15, 0.44), float3(1.0, 0.72, 0.34), seed) * petal * u.themesExtra.y * 0.85;
            }
        }
        if (u.themesExtra.z > 0.001) {
            float2 rainUV = float2(q.x + q.y * 0.12, q.y) * float2(70.0, 8.0) + float2(0.0, -u.time * 2.5);
            float seed = hash11(floor(rainUV.x) * 73.0);
            float streak = exp(-abs(fract(rainUV.x) - 0.5) * 70.0)
                         * smoothstep(0.1, 0.9, fract(rainUV.y + seed)) * step(0.35, seed);
            lyricLight += float3(0.3, 0.6, 0.95) * streak * 0.65 * u.themesExtra.z;
        }
        // Celebration lyrics and Party-mode drops scatter geometric confetti, without emoji.
        float celebration = max(u.themesExtra.w * u.performance.x, u.performance.z * max(u.rhythm.z, u.impact));
        if (celebration > 0.001) {
            for (int j = 0; j < 24; j++) {
                float fj = float(j), seed = hash11(fj * 17.3);
                float angle = fj * 2.39996;
                float travel = u.themesExtra.w > 0.01 ? u.performance.y : (u.rhythm.z > u.impact ? u.themesB.w : u.impactProgress);
                float2 origin = float2(cos(angle), sin(angle)) * (0.25 + travel * (0.6 + seed));
                float2 cp = q - origin;
                float turn = u.time + fj;
                cp = float2(cp.x * cos(turn) - cp.y * sin(turn), cp.x * sin(turn) + cp.y * cos(turn));
                float piece = (1.0 - smoothstep(0.005, 0.008, abs(cp.x))) * (1.0 - smoothstep(0.015, 0.018, abs(cp.y)));
                lyricLight += edgeColour(u, seed) * piece * celebration * 1.7;
            }
        }
        col += lyricLight * centreMask * u.style.z * u.dim * (1.25 + u.performance.z * 0.5);

        // A sparse procedural dust field: one sample per pixel, independent of particle count.
        float2 dustUV = q * (34.0 + u.themesB.z * 5.0) + float2(u.time * 0.12, -u.time * 0.2) + u.pointer * 0.2;
        float2 cell = floor(dustUV);
        float seed = hash11(cell.x * 71.3 + cell.y * 139.7);
        float2 star = float2(hash11(seed * 113.0), hash11(seed * 293.0)) * 0.6 + 0.2;
        float distance = length(fract(dustUV) - star);
        float dust = exp(-distance * distance * 1900.0) + exp(-distance * distance * 90.0) * 0.12;
        float twinkle = 0.6 + 0.4 * sin(u.time * 0.8 + seed * 31.0);
        col += mix(edgeColour(u, seed), float3(1.0), 0.45) * dust * twinkle
             * step(seed, u.style.w * 0.24) * (0.35 + u.bands.z) * centreMask * u.dim;

        // Three concentric band traces. These are bass/mid/treble meters, not a fake FFT.
        if (u.bands.w > 0.5) {
            float angle = atan2(q.y, q.x);
            for (int j = 0; j < 3; j++) {
                float band = u.bands[j], fj = float(j);
                float radius = max(0.34, u.coverHalf * 1.48) + fj * 0.026;
                radius += band * 0.025 * (0.5 + 0.5 * sin(angle * (6.0 + fj * 4.0) + u.time));
                float line = exp(-abs(length(q) - radius) * 550.0);
                float arcs = smoothstep(-0.6, 0.2, sin(angle * 3.0 + fj * 1.5 + u.time * 0.12));
                col += edgeColour(u, fj / 3.0 + perim * 0.2) * line * arcs
                     * (0.12 + band * 0.65) * centreMask * u.style.y * u.dim;
            }
        }

        // An expanding pressure wave follows a big hit independently of subsequent kicks.
        float radius = length(p / minDim);
        float waveRadius = 0.15 + u.impactProgress * 1.5;
        float wave = exp(-pow((radius - waveRadius) / (0.025 + u.impactProgress * 0.08), 2.0));
        float halo = exp(-abs(radius - waveRadius) * 8.0);
        float3 impactColour = mix(edgeColour(u, perim + 0.2), float3(1.0), 0.18);
        col += impactColour * (wave * 0.7 + halo * 0.22) * u.impact * u.dim * u.style.y;

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
        col = mix(col, edge, clamp(edgeA * u.style.y * 0.7, 0.0, 1.0));

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
