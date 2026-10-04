#include <metal_stdlib>
using namespace metal;

static float ihash(float2 p) {
    float3 q = fract(float3(p.x, p.y, p.x) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

// Broad, bent wavefronts: the field has a gesture before it is cut into strips.
// Unequal wavelengths and a slow cross-current keep it from becoming a grid.
static float exploreWave(float2 p, float phase) {
    float bend = sin(p.y * 1.65 + sin(p.x * 1.12 + phase) * 1.8);
    float sweep = p.x * 2.3 + p.y * 1.15 + bend * 2.15;
    float cross = cos(p.y * 2.05 - p.x * 0.72 + phase * 0.6);
    return sin(sweep + cross * 1.25) * 0.72
         + sin(p.y * 2.8 - p.x * 1.35 + bend * 0.8) * 0.28;
}

/// `origin` is where this slice of the field sits in the whole of it.
///
/// The field is drawn in slices rather than as one layer, because one layer is
/// one Metal texture and the page it covers outgrew what a texture can be: a
/// crate large enough to make the canvas 16,604 points tall asked for a
/// 1854x16604 BGRA8Unorm and got `unable to create texture`, which draws
/// nothing at all. 16,384 is the limit on Apple silicon, and a texture that
/// size is 120MB for a background besides.
///
/// Every slice is handed the full `size` and its own offset, so `position` can
/// be read back into the coordinates of the whole field. Without that each
/// slice would start the pattern again at its top edge and the seams would be
/// visible as hard steps across the page.
[[ stitchable ]] half4 exploreOffsetField(float2 position, half4 source,
                                          float2 size, float time, float seed,
                                          float2 origin) {
    float2 place = position + origin;
    // Fixed point scale keeps the shapes consistent as the crate grows taller.
    const float scale = 430.0;
    float stripWidth = clamp(size.x / 15.0, 48.0, 86.0);
    float strip = floor(place.x / stripWidth);
    float lift = ihash(float2(strip + 3.7, seed * 0.013));
    float2 p = place / scale;

    // How fast the whole field moves. The only number to turn for that.
    //
    // Six separate coefficients below set the *rhythms* — how the breath, the
    // stagger and the drift relate to each other — and none of them should be
    // touched to change pace, because moving one moves the field's character
    // rather than its speed. They all read this clock instead, so halving it
    // halves everything and keeps the relationships intact.
    const float pace = 0.25;
    float t = time * pace;

    // Shared slow waves keep adjacent bars related while each cut stays crisp.
    // Scale breathes within ±8%; alternating bars add a deeper stagger.
    float rhythm = strip * 0.58 + seed * 0.017;
    float zoom = 1.0 + 0.08 * sin(rhythm + t * 0.22);
    float verticalOffset = 0.15 * sin(rhythm * 0.87 - t * 0.19);
    float alternating = fmod(strip, 2.0);
    verticalOffset += alternating * (0.19 + 0.05 * sin(t * 0.17 + seed * 0.01));

    // The zoom is horizontal only, and the vertical breath is a fixed size.
    //
    // This used to scale both axes about a point fixed at the top of the page
    // (`anchor.y = 1.0`), which turns distance from that point into speed: a
    // pixel 16,000 down moved about seventy times as far per second as one
    // near the top, so the field visibly accelerated as you scrolled. The
    // anchor was fixed so that adding crate items could not shift the pattern
    // — that still holds, because `strip` and the breath below depend on
    // neither the page's height nor where this slice sits in it.
    //
    // Anchoring vertically to the pixel itself leaves the horizontal scaling
    // intact — the cuts stay where they are, since `strip` was taken from
    // `place.x` before this — and moves the vertical motion into a term whose
    // amplitude is the same everywhere.
    float2 anchor = float2((strip + 0.5) * stripWidth / scale, p.y);
    p = anchor + (p - anchor) / zoom;
    // Sized to what the middle of a tall page used to travel, so the field as
    // a whole reads as it did rather than as the top of it did. One number to
    // turn if it wants to be calmer or busier.
    const float breath = 1.45;
    p.y += breath * sin(rhythm + t * 0.22);
    p.y += verticalOffset;
    p += float2(seed * 0.007, seed * 0.003);
    const float motionSpeed = 4.0;
    p.x += t * 0.018 * motionSpeed;
    float wave = exploreWave(p, t * 0.008 * motionSpeed);
    float value = smoothstep(-0.85, 0.85, wave);

    // Two palettes for the same four steps: the field's blues, and a warm one
    // -- red, orange, yellow -- that morphs in where a slow, broad wave of
    // warmth rises and drifts across the page. The page opens in its blues;
    // the warmth fades in over its first ninety seconds, then wanders (about
    // 3.5 minutes a pass). Where it is neither, the two mix briefly.
    const half3 blue = half3(0.157, 0.392, 0.941);
    const half3 turquoise = half3(0.216, 0.847, 0.816);
    const half3 mint = half3(0.573, 0.957, 0.816);
    const half3 paper = half3(0.949, 0.961, 0.937);
    const half3 red = half3(0.70, 0.13, 0.10);
    const half3 orange = half3(0.96, 0.46, 0.13);
    const half3 yellow = half3(0.98, 0.82, 0.30);
    const half3 warmPaper = half3(0.97, 0.95, 0.90);
    float2 broad = place / scale;
    float warmWave = 0.5 + 0.5 * sin(broad.x * 0.9 + broad.y * 0.35 - time * 0.03);
    float warmth = smoothstep(0.0, 90.0, time) * smoothstep(0.3, 0.7, warmWave);
    half w = half(warmth);
    half3 deep = mix(blue, red, w);
    half3 midTone = mix(turquoise, orange, w);
    half3 light = mix(mint, yellow, w);
    half3 sheet = mix(paper, warmPaper, w);
    half3 color = mix(deep, midTone, half(smoothstep(0.12, 0.49, value)));
    color = mix(color, light, half(smoothstep(0.44, 0.68, value)));
    color = mix(color, sheet, half(smoothstep(0.65, 0.88, value)));

    // Hard cuts in the image create the bars; no lines or translucent overlays.
    color *= half(0.98 + lift * 0.04);

    // Stationary fine grain avoids sparkling during the slow movement.
    float grain = ihash(floor(place * 1.7) + float2(seed, seed * 0.37)) - 0.5;
    color += half3(half(grain * 0.095));
    return half4(clamp(color, half3(0.0), half3(1.0)), 1.0);
}

// A continuous field across the player that turns through green, blue, red
// and gold. Sound expands its wavefronts; a restrained luminance keeps the
// transport text legible.
[[ stitchable ]] half4 playerFlowField(float2 position, half4 source,
                                      float2 origin, float time, float energy,
                                      float noiseBoost) {
    // Sample one window-wide field. SwiftUI supplies each surface's global
    // origin, so the header, sidebar and player reveal adjacent parts of the
    // same pattern instead of restarting it in local coordinates.
    float2 canvasPosition = position + origin;
    float2 p = float2(canvasPosition.x / 340.0, canvasPosition.y / 340.0 * 0.65);
    // Sampling upward carries the visible field down through the player.
    p.y -= time * 0.075;
    p.y += energy * 0.28;
    float wave = exploreWave(p, time * 0.032);
    float field = smoothstep(-0.9, 0.95, wave);
    float glow = 0.22 + field * 0.44 + energy * 0.16;

    // The field turns slowly through green, blue, red and gold and back to
    // green, 128 seconds to each, and its light rises and falls on a cycle of
    // its own. Both periods divide the 4,096 seconds the caller wraps `time`
    // at, so the wrap is never a jump: colours 512s, light 128s, a quarter
    // turn apart. Each colour is a dark base and the bright it rises to; gold
    // is the field's original.
    const half3 lows[4] = { half3(0.05, 0.10, 0.055), half3(0.04, 0.06, 0.13),
                            half3(0.12, 0.03, 0.03), half3(0.10, 0.07, 0.012) };
    const half3 highs[4] = { half3(0.40, 0.62, 0.38), half3(0.36, 0.52, 0.86),
                             half3(0.88, 0.34, 0.28), half3(0.95, 0.64, 0.075) };
    float cycle = fract(time / 512.0) * 4.0;
    int from = int(floor(cycle)) % 4;
    int to = (from + 1) % 4;
    half blend = half(smoothstep(0.0, 1.0, fract(cycle)));
    half3 low = mix(lows[from], lows[to], blend);
    half3 high = mix(highs[from], highs[to], blend);
    const float turn = 6.2831853;
    float light = 1.0 + 0.15 * sin(time * turn / 128.0 + 1.5707963);
    half3 color = mix(low, high, half(field));
    color *= half(glow * light);
    color += half( (ihash(floor(canvasPosition * 1.5)) - 0.5)
                  * 0.018 * noiseBoost );
    return half4(clamp(color, half3(0), half3(1)), 1);
}
