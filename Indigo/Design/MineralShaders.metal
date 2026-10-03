#include <metal_stdlib>
using namespace metal;

/// The wordmark's ground: green metal, lit in soft vertical bands that drift
/// sideways. Two waves of unequal length, one bent a little by height, so the
/// bands never settle into stripes.
///
/// `time` is wrapped by the caller: float32 time loses the precision the waves
/// need long before a session ends, and the sheen would freeze.
[[ stitchable ]] half4 mineralSheen(float2 position, half4 source, float2 size, float time) {
    float u = position.x / max(size.x, 1.0);
    float v = position.y / max(size.y, 1.0);
    float a = sin(u * 8.5 - time * 0.9 + sin(v * 2.2 + time * 0.35) * 0.55);
    float b = sin(u * 3.7 + time * 0.5 + 1.7);
    float light = smoothstep(0.08, 0.96, clamp(0.5 + 0.32 * a + 0.24 * b, 0.0, 1.0));

    float3 deep = float3(0.22, 0.38, 0.21);
    float3 mid  = float3(0.47, 0.64, 0.42);
    float3 high = float3(0.87, 0.95, 0.81);
    float3 colour = light < 0.5 ? mix(deep, mid, light * 2.0) : mix(mid, high, (light - 0.5) * 2.0);
    // A little darker at the top and bottom edges, as pressed metal is.
    colour *= 0.9 + 0.1 * sin(v * M_PI_F);
    return half4(half3(colour), 1.0) * source.a;
}
