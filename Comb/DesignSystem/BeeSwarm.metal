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

static float2 beePosition(float index, float time, float2 size, float2 hive) {
    float seedA = hash(index * 7.13);
    float seedB = hash(index * 13.7);
    float seedC = hash(index * 3.71);

    // Each bee holds its own elliptical orbit around the mark. The two
    // frequencies differ per bee and never divide evenly, so a path precesses
    // instead of retracing itself, which is what stops the swarm reading as a
    // carousel.
    float2 orbitFrequency = float2(0.13 + seedA * 0.14, 0.15 + seedB * 0.16);
    float2 orbitPhase = float2(seedA, seedB) * 6.28318;
    float2 orbit = float2(
        sin(time * orbitFrequency.x + orbitPhase.x),
        cos(time * orbitFrequency.y + orbitPhase.y)
    );

    // Radii in points, not screen fractions: the swarm should sit the same
    // distance off the mark regardless of how tall the phone is. The spread
    // keeps some bees close in and some ranging wide.
    float2 radius = float2(70.0 + seedC * 90.0, 55.0 + seedA * 75.0);

    // A slow drift of the whole orbit, so bees do not sit on fixed rails.
    float2 drift = 18.0 * float2(
        sin(time * 0.07 + seedB * 6.28318),
        cos(time * 0.09 + seedC * 6.28318)
    );

    // The buzz: a fast, small wobble layered on the drift.
    float2 wobble = 3.0 * float2(
        sin(time * (5.0 + seedA * 3.0) + orbitPhase.y * 3.0),
        cos(time * (6.0 + seedB * 2.0) + orbitPhase.x * 2.0)
    );

    return hive * size + orbit * radius + drift + wobble;
}

[[ stitchable ]] half4 beeSwarm(
    float2 position,
    half4 currentColor,
    float2 size,
    float time,
    float intensity,
    float2 hive
) {
    const int beeCount = 12;
    float glow = 0.0;

    for (int i = 0; i < beeCount; i++) {
        float2 bee = beePosition(float(i) + 1.0, time, size, hive);
        float distanceToBee = length(position - bee);

        // A tight bright core inside a soft halo. Both are tighter than the
        // first pass: the wide halo read as a lens flare rather than an
        // insect, and shrinking it is most of what makes these look like bees.
        glow += 0.9 * exp(-distanceToBee * distanceToBee / 7.0);
        glow += 0.16 * exp(-distanceToBee * distanceToBee / 90.0);
    }

    glow = min(glow, 1.0) * intensity;

    // Brand chartreuse, premultiplied. The layer beneath is the gradient;
    // the swarm only ever adds light.
    return half4(half3(0.843, 0.843, 0.0) * glow, half(glow));
}
