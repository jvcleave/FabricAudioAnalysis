#include <metal_stdlib>
using namespace metal;

// Adapted from MESS Audio3DWaveformVisualizerFilter.metal. The source node
// supplies ordered, downsampled history rows, so no ring lookup is needed here.
struct AudioWaveformUniforms
{
    float4 viewport;
    float4 grid;
    float4 waveform;
    float4 angles;
    float4 color;
};

struct AudioWaveformVertexOut
{
    float4 position [[position]];
    float2 lineCoordinates;
    float segmentLength;
    float rowBrightness;
    float depthBrightness;
};

static float2 stripCorner(uint index)
{
    switch (index)
    {
        case 0: return float2(0, -1);
        case 1: return float2(1, -1);
        case 2: return float2(0, 1);
        case 3: return float2(1, -1);
        case 4: return float2(1, 1);
        default: return float2(0, 1);
    }
}

static float3 rotateWaveformPoint(float3 point, float angleX, float angleY)
{
    float cosineY = cos(angleY);
    float sineY = sin(angleY);
    float3 rotatedY = float3(
        cosineY * point.x - sineY * point.z,
        point.y,
        sineY * point.x + cosineY * point.z
    );
    float cosineX = cos(angleX);
    float sineX = sin(angleX);
    return float3(
        rotatedY.x,
        cosineX * rotatedY.y - sineX * rotatedY.z,
        sineX * rotatedY.y + cosineX * rotatedY.z
    );
}

static float2 projectWaveformPoint(float3 point, float scale)
{
    float perspective = 1 / max(0.45, 2.8 + point.z);
    return float2(0.5, 0.58) + point.xy * scale * perspective;
}

vertex AudioWaveformVertexOut audio3DWaveformVertex(
    uint vertexID [[vertex_id]],
    constant AudioWaveformUniforms &uniforms [[buffer(0)]],
    device const float *history [[buffer(1)]]
)
{
    uint samplesPerRow = uint(uniforms.grid.x);
    uint visibleRows = uint(uniforms.grid.y);
    uint firstVisibleRow = uint(uniforms.grid.z);
    uint segmentCount = samplesPerRow - 1;
    uint cornerIndex = vertexID % 6;
    uint segmentIndex = (vertexID / 6) % segmentCount;
    uint visibleRowIndex = (vertexID / 6) / segmentCount;
    uint rowIndex = firstVisibleRow + visibleRowIndex;

    float widthDenominator = max(1.0, float(segmentCount));
    float depthMix = float(visibleRowIndex) / max(1.0, float(visibleRows - 1));
    float z = (depthMix - 0.5) * uniforms.grid.w;
    float startX = float(segmentIndex) / widthDenominator - 0.5;
    float endX = float(segmentIndex + 1) / widthDenominator - 0.5;
    uint startSampleIndex = rowIndex * samplesPerRow + segmentIndex;
    float3 startPoint = float3(startX, -history[startSampleIndex] * uniforms.waveform.x, z);
    float3 endPoint = float3(endX, -history[startSampleIndex + 1] * uniforms.waveform.x, z);
    float3 rotatedStart = rotateWaveformPoint(startPoint, uniforms.angles.x, uniforms.angles.y);
    float3 rotatedEnd = rotateWaveformPoint(endPoint, uniforms.angles.x, uniforms.angles.y);
    float2 projectedStart = projectWaveformPoint(rotatedStart, uniforms.waveform.z);
    float2 projectedEnd = projectWaveformPoint(rotatedEnd, uniforms.waveform.z);

    float2 viewport = max(uniforms.viewport.xy, float2(1));
    float2 startPixel = projectedStart * viewport;
    float2 segment = (projectedEnd - projectedStart) * viewport;
    float segmentLength = max(length(segment), 0.001);
    float2 tangent = segment / segmentLength;
    float2 normal = float2(-tangent.y, tangent.x);
    float lineRadius = max(uniforms.waveform.y, 0.25);
    float outerRadius = lineRadius + 1;
    float2 corner = stripCorner(cornerIndex);
    float along = mix(-outerRadius, segmentLength + outerRadius, corner.x);
    float2 pixelPosition = startPixel + tangent * along + normal * corner.y * outerRadius;
    float2 position = pixelPosition / viewport;

    float fadeExponent = max(0.0, uniforms.waveform.w) * 3;
    float brightness = fadeExponent > 0.0001
        ? max(0.03, pow(max(depthMix, 0.001), fadeExponent))
        : 1;
    float averageDepth = (rotatedStart.z + rotatedEnd.z) * 0.5;

    AudioWaveformVertexOut output;
    output.position = float4(position.x * 2 - 1, 1 - position.y * 2, 0, 1);
    output.lineCoordinates = float2(along, corner.y * outerRadius);
    output.segmentLength = segmentLength;
    output.rowBrightness = brightness;
    output.depthBrightness = clamp(2.1 / max(0.45, 2.8 + averageDepth), 0.2, 1.3);
    return output;
}

fragment float4 audio3DWaveformFragment(
    AudioWaveformVertexOut input [[stage_in]],
    constant AudioWaveformUniforms &uniforms [[buffer(0)]]
)
{
    float alongDistance = max(max(-input.lineCoordinates.x,
                                  input.lineCoordinates.x - input.segmentLength), 0.0);
    float distanceToLine = length(float2(alongDistance, input.lineCoordinates.y));
    float radius = max(uniforms.waveform.y, 0.25);
    float alpha = 1 - smoothstep(radius, max(radius + 0.75, radius * 1.8), distanceToLine);
    alpha *= input.rowBrightness * uniforms.color.a;
    if (alpha <= 0.001)
    {
        discard_fragment();
    }
    float3 depthTint = mix(float3(0.55), float3(1),
                           clamp(input.depthBrightness * 0.8, 0.0, 1.0));
    return float4(uniforms.color.rgb * depthTint * input.rowBrightness,
                  clamp(alpha, 0.0, 1.0));
}
