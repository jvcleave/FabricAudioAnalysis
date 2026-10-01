#include <metal_stdlib>
using namespace metal;

struct WaveformTrailUniforms {
    float4 color;
    float4 shape; // amplitude, thickness, glow, playhead flash
    uint4 dimensions; // width, height, samples per row, row count
};

kernel void fabricWaveformTrail(
    texture2d<float, access::write> output [[texture(0)]],
    constant WaveformTrailUniforms &uniforms [[buffer(0)]],
    device const float *waveform [[buffer(1)]],
    device const float *columns [[buffer(2)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= uniforms.dimensions.x || position.y >= uniforms.dimensions.y) return;
    float2 uv = (float2(position) + 0.5) / float2(uniforms.dimensions.xy);
    float3 result = mix(float3(0.012, 0.02, 0.045), float3(0.025, 0.055, 0.09), uv.y);
    float gridX = 1.0 - smoothstep(0.0, 0.025, abs(fract(uv.x * 16.0 + 0.5) - 0.5));
    float gridY = 1.0 - smoothstep(0.0, 0.02, abs(fract(uv.y * 6.0 + 0.5) - 0.5));
    result += float3(0.025, 0.04, 0.065) * max(gridX, gridY);
    uint rowCount = uniforms.dimensions.w;
    uint samplesPerRow = uniforms.dimensions.z;
    float thickness = clamp(uniforms.shape.y, 0.001, 0.03);
    float glow = clamp(uniforms.shape.z, 0.0, 3.0);
    uint layers = min(rowCount, 8u);
    for (int layer = int(layers) - 1; layer >= 0; --layer) {
        uint row = rowCount - 1 - min(uint(layer) * 3, rowCount - 1);
        float depth = float(layer);
        float localX = (uv.x - 0.5) / (1.0 - depth * 0.022) + 0.5;
        if (localX < 0.0 || localX > 1.0) continue;
        float samplePosition = localX * float(samplesPerRow - 1);
        uint sampleIndex = min(uint(samplePosition), samplesPerRow - 2);
        float sample = mix(waveform[row * samplesPerRow + sampleIndex], waveform[row * samplesPerRow + sampleIndex + 1], fract(samplePosition));
        float baseline = 0.64 - depth * 0.045;
        float sampleY = baseline - sample * clamp(uniforms.shape.x, 0.0, 0.5) * (1.0 - depth * 0.065);
        float distance = abs(uv.y - sampleY);
        float line = 1.0 - smoothstep(thickness * 0.35, thickness * 1.5, distance);
        float halo = exp(-distance / max(thickness * (2.0 + glow * 2.0), 0.001));
        float opacity = layer == 0 ? 1.0 : pow(0.72, depth) * 0.33;
        float3 lineColor = mix(uniforms.color.rgb, float3(0.72, 0.82, 1.0), depth * 0.045);
        result += lineColor * halo * glow * 0.12 * opacity;
        result = mix(result, lineColor, line * opacity);
    }
    float marker = 0.0;
    for (int offset = -3; offset <= 3; ++offset) {
        int column = clamp(int(position.x) + offset, 0, int(uniforms.dimensions.x) - 1);
        marker = max(marker, columns[column] * (1.0 - abs(float(offset)) / 4.0));
    }
    float markerFalloff = exp(-pow((uv.y - 0.64) * 3.5, 2.0));
    result += float3(1.0, 0.44, 0.12) * marker * markerFalloff * 0.72;
    float playheadDistance = abs(uv.x - 0.5) * float(uniforms.dimensions.x);
    float playhead = 1.0 - smoothstep(0.7, 1.9, playheadDistance);
    float3 playheadColor = mix(float3(0.65, 0.75, 0.88), float3(1.0, 0.055, 0.025), uniforms.shape.w);
    result = mix(result, playheadColor, playhead * 0.82);
    output.write(float4(clamp(result, 0.0, 1.0), 1.0), position);
}
