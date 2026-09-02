#include <metal_stdlib>
using namespace metal;

// A hash with no grain of its own.
//
// The obvious two-line one has structure along the axes, and at grain scale
// that structure is what you actually see: fine vertical striping laid over
// the whole field, easily mistaken for banding in the gradient. This one
// mixes all three components before folding, and leaves none.
static float ihash(float2 p) {
    float3 q = fract(float3(p.x, p.y, p.x) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

static float inoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(ihash(i), ihash(i + float2(1, 0)), f.x),
               mix(ihash(i + float2(0, 1)), ihash(i + 1.0), f.x), f.y);
}

// Four octaves, not six. The extra two are what turned the field to smoke:
// each one adds finer filaments, and past a point the picture is all wisp and
// no shape. Fewer, larger octaves keep it as rounded masses — the lava lamp
// rather than the smoke.
static float ifbm(float2 p) {
    float value = 0.0, amplitude = 0.5, total = 0.0;
    for (int octave = 0; octave < 4; octave++) {
        value += amplitude * inoise(p);
        total += amplitude;
        p = p * 2.03 + float2(19.1, 7.7);
        amplitude *= 0.5;
    }
    // Divided through by the amplitudes actually summed, so the result sits in
    // 0…1 around a half however many octaves are used. Without it the octave
    // count and the contrast below are secretly coupled: dropping from six to
    // four narrows the range, every value lands under the middle, and the
    // whole field collapses to the dark end of the ramp.
    return value / max(total, 0.0001);
}

// One continuous field of slow blobs, drifting right to left, read through a
// row of vertical strips that each displace it.
//
// The strips shift the field up or down and zoom it in or out — they are
// windows onto the same lamp held at different heights and distances. The
// travel is the other axis entirely and belongs to the field, not the strips,
// so the blobs cross behind a fixed grille rather than sliding along it.
[[ stitchable ]] half4 exploreOffsetField(float2 position, half4 source,
                                           float2 size, float time, float seed) {
    float2 uv = position / max(size, float2(1.0));

    const float bars = 19.0;
    // A blob is this many points across, whatever shape the pane happens to be.
    //
    // Not a fraction of the pane, which is the trap: this view grows taller
    // with the size of the listener's crate, so a field measured against its
    // own height stretches to a couple of enormous smears for anybody who has
    // saved a lot — the same shader, at a scale set by an unrelated number.
    const float pointsPerBlob = 760.0;
    // How far a strip may lift the field, and how far it may zoom it. Both are
    // per strip and fixed — it is the field that moves, not these.
    //
    // The lift is deliberately small. A strip is meant to nudge the picture,
    // not to cut it loose: shifted far enough that neighbours no longer rhyme,
    // the grille stops reading as one scene seen through slats and starts
    // reading as twenty unrelated pictures hung in a row.
    const float verticalShift = 0.46;
    const float scaleSpread = 0.30;
    const float warpIntensity = 1.50;  // unused by the two-level warp below

    float barIndex = floor(uv.x * bars);
    float withinBar = fract(uv.x * bars);
    float lift = ihash(float2(barIndex + 3.7, seed * 0.013));
    float zoom = ihash(float2(barIndex + 91.3, seed * 0.029));

    // Straight from the pixel, divided by a fixed length. Both axes get the
    // same divisor, so a blob is as round as it is tall without any need to
    // reason about the pane's proportions.
    float2 p = position / pointsPerBlob;

    // Stated in points per second, so the drift is the same speed on any pane.
    // Added, not subtracted: the sample point advancing to the right is the
    // picture travelling to the left.
    const float driftPointsPerSecond = 26.0;
    float travel = time * driftPointsPerSecond / pointsPerBlob;
    float evolve = time * 0.0022;

    // Two readings of the same strip: one that travels and one that does not.
    float2 grainAnchor = p;
    p.x += travel;
    p.y += (lift - 0.5) * verticalShift;
    grainAnchor.y += (lift - 0.5) * verticalShift;

    // Zoom about the middle of the pane rather than the origin, so a strip
    // scales the picture in place instead of also flinging it sideways.
    float2 middle = size * 0.5 / pointsPerBlob;
    float stretch = 1.0 + (zoom - 0.5) * scaleSpread;
    p = middle + (p - middle) * stretch;
    grainAnchor = middle + (grainAnchor - middle) * stretch;

    // A single large field, warped twice.
    //
    // Seen without the strips over it, the reference is not a pattern at all:
    // it is two or three big shapes across the whole frame — an S-curve, a
    // lens, a slow swirl — with nothing repeating anywhere in it. The rhythm
    // that seemed to be in it was the strips chopping it up.
    //
    // Which is why the lattice of rings had to go. Regular geometry can be
    // dressed up with noise but it stays regular underneath, and against this
    // it read as wallpaper. Feeding the field back through itself twice is
    // what produces curl at every size at once: the swirls and hooks are the
    // warp folding the warp, and there is no way to that from a grid.
    float2 first = float2(ifbm(p + float2(evolve, 0.0)),
                          ifbm(p + float2(5.2, 1.3)));
    float2 second = float2(ifbm(p + 2.60 * first + float2(1.7, 9.2) + evolve * 1.30),
                           ifbm(p + 2.60 * first + float2(8.3, 2.8) - evolve * 0.90));
    float value = ifbm(p + 2.60 * second);

    // fbm sits close to its average; this opens it out to use the whole ramp
    // without hardening the edges, which would cost the shapes their liquid
    // look.
    value = clamp((value - 0.5) * 2.30 + 0.5, 0.0, 1.0);

    const half3 white = half3(1.0);
    const half3 cyan = half3(0.090, 0.902, 0.863);
    const half3 green = half3(0.302, 1.000, 0.733);
    const half3 blue = half3(0.208, 0.525, 1.000);
    half3 color = mix(blue, cyan, half(smoothstep(0.04, 0.34, value)));
    color = mix(color, green, half(smoothstep(0.38, 0.63, value)));
    color = mix(color, white, half(smoothstep(0.68, 0.96, value)));

    // Strips are cut, not blended: the seam is the point, so it stays hard.
    color *= half(0.974 + 0.046 * lift);
    // A hair of lift at the very edge, so a seam between two dark strips does
    // not read as a crack in the render.
    float edge = min(withinBar, 1.0 - withinBar);
    color += half3(half(smoothstep(0.05, 0.0, edge) * 0.026));

    // Grain belongs to the layer, but not to its travel.
    //
    // Sampled off the pixel it sits above everything like dust on the glass,
    // unmoved by any of this, which is what makes it read as an artefact of
    // the display rather than as part of the picture. Sampled off the
    // travelling coordinate it goes the other way and swims, which at grain
    // scale is a shimmer rather than a texture.
    //
    // So it takes the strip's own lift and zoom — it is bedded into the layer
    // and breaks at the seams with everything else — but not the drift. The
    // texture sits still while the picture moves through it.
    float g = ihash(grainAnchor * pointsPerBlob * 1.15 + float2(seed, seed * 0.37)) - 0.5;
    g = sign(g) * pow(abs(g) * 2.0, 0.42) * 0.5;
    color += half3(half(g * 0.150));

    return half4(clamp(color, half3(0.0), half3(1.0)), 1.0);
}
