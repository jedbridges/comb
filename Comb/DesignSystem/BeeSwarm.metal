#include <metal_stdlib>
using namespace metal;

// The welcome screen's swarm: a handful of glowing points wandering the way
// bees do, computed per pixel on the GPU.
//
// A bee's flight is loops with jitter: it circles an area of interest while
// its whole orbit drifts. Each bee here is two low-frequency sinusoids with
// irrational frequency ratios (so the path never visibly repeats) carrying a
// small high-frequency wobble (the buzz). Everything derives from the bee's
// index, so the swarm needs no state and no CPU work per frame.

static float hash(float n) {
    return fract(sin(n) * 43758.5453123);
}

static float2 beePosition(float index, float time, float2 size) {
    float seedA = hash(index * 7.13);
    float seedB = hash(index * 13.7);

    // Slow orbit. Frequencies land in ~0.11...0.26 rad/s, phase per bee, and
    // the x/y ratio is kept irrational-ish so loops precess instead of
    // repeating.
    float2 orbitFrequency = float2(0.11 + seedA * 0.09, 0.13 + seedB * 0.13);
    float2 orbitPhase = float2(seedA, seedB) * 6.28318;
    float2 orbit = float2(
        sin(time * orbitFrequency.x + orbitPhase.x),
        sin(time * orbitFrequency.y + orbitPhase.y)
    );

    // Each bee patrols its own patch of the screen rather than all sharing
    // the centre.
    float2 home = float2(0.2 + seedA * 0.6, 0.15 + seedB * 0.6);
    float2 range = float2(0.16 + seedB * 0.1, 0.12 + seedA * 0.1);

    // The buzz: a fast, small wobble layered on the drift.
    float2 wobble = 0.008 * float2(
        sin(time * (5.0 + seedA * 3.0) + orbitPhase.y * 3.0),
        cos(time * (6.0 + seedB * 2.0) + orbitPhase.x * 2.0)
    );

    return (home + orbit * range + wobble) * size;
}

[[ stitchable ]] half4 beeSwarm(
    float2 position,
    half4 currentColor,
    float2 size,
    float time,
    float intensity
) {
    const int beeCount = 7;
    float glow = 0.0;

    for (int i = 0; i < beeCount; i++) {
        float2 bee = beePosition(float(i) + 1.0, time, size);
        float distanceToBee = length(position - bee);

        // A tight bright core inside a soft halo, so each dot reads as a
        // point of light rather than a blurry blob.
        glow += exp(-distanceToBee * distanceToBee / 18.0);
        glow += 0.35 * exp(-distanceToBee * distanceToBee / 220.0);
    }

    glow = min(glow, 1.0) * intensity;

    // Brand chartreuse, premultiplied. The layer beneath is the gradient;
    // the swarm only ever adds light.
    return half4(half3(0.843, 0.843, 0.0) * glow, half(glow));
}
