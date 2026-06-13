//
//  LiquidGlassClockShaders.metal
//  WaifuX
//
//  Metal 着色器 — 液态玻璃时钟渲染
//
//  包含：
//    • vertexShader        — 全屏四边形顶点
//    • glassBackground     — 液态玻璃背景（渐变 + 辉光）
//    • clockDigit          — 数字渲染（SDF / 纹理）
//    • compositeWithGlow   — 最终合成（含发光效果）
//
//  ═══════════════════════════════════════════════════════════
//  使用方式：
//  编译后由 LiquidGlassMetalRenderer 加载。
//  如用 XcodeGen，需在 project.yml 的 sources 中添加 Metal/ 路径；
//  或保持内嵌字符串编译方式（见 LiquidGlassMetalRenderer 中的
//  embeddedShaderSource）。
//  ═══════════════════════════════════════════════════════════

#include <metal_stdlib>
using namespace metal;

// MARK: - 常量

// constant float PI = 3.14159265358979323846;

// MARK: - 顶点结构

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct GlassUniforms {
    float2 resolution;      // 渲染分辨率
    float2 clockCenter;     // 时钟中心位置（归一化 0~1）
    float time;             // 时间（秒，用于动画）
    float4 accentColor;     // 强调色 RGBA
    float4 bgColor;         // 背景色 RGBA
    float glassIntensity;   // 玻璃强度 0~1
    float cornerRadius;     // 圆角（归一化）
    float glowIntensity;    // 发光强度 0~1
};

struct DigitUniforms {
    float2 resolution;
    float4 textColor;
    float4 glowColor;
    float glowRadius;
    float digitCount;       // 数字位数（预留）
};

// MARK: - 顶点着色器

vertex VertexOut vertexClockShader(
    uint vertexID [[vertex_id]],
    constant float4 *vertices [[buffer(0)]]
) {
    VertexOut out;
    float4 pos = vertices[vertexID];
    out.position = float4(pos.xy, 0.0, 1.0);
    out.uv = pos.zw;
    return out;
}

// MARK: - 圆角矩形 SDF

float roundedRectSDF(float2 uv, float2 size, float radius) {
    float2 d = abs(uv) - size + radius;
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - radius;
}

// MARK: - 液态玻璃背景

fragment float4 glassBackground(
    VertexOut in [[stage_in]],
    constant GlassUniforms &uniforms [[buffer(0)]]
) {
    float2 uv = in.uv;
    float2 res = uniforms.resolution;

    // 宽高比修正
    float aspect = res.x / res.y;
    float2 suv = uv;
    suv.x *= aspect;

    // ── 背景基础层 ──
    float4 bg = uniforms.bgColor;

    // ── 环境光晕 ──
    float2 center = uniforms.clockCenter;
    center.x *= aspect;

    // 主光晕（强调色）
    float distToCenter = distance(suv, center);
    float halo = 1.0 - smoothstep(0.0, 0.8, distToCenter);
    float4 haloColor = uniforms.accentColor * halo * 0.15 * uniforms.glassIntensity;

    // 次级光晕
    float2 subCenter1 = center + float2(-0.15, -0.1);
    float subHalo1 = 1.0 - smoothstep(0.0, 0.6, distance(suv, subCenter1));
    float4 subColor1 = uniforms.accentColor * subHalo1 * 0.08 * uniforms.glassIntensity;

    float2 subCenter2 = center + float2(0.12, 0.08);
    float subHalo2 = 1.0 - smoothstep(0.0, 0.5, distance(suv, subCenter2));
    float4 subColor2 = float4(1.0, 1.0, 1.0, 1.0) * subHalo2 * 0.05 * uniforms.glassIntensity;

    // ── 玻璃表面纹理（微噪点） ──
    float noise = fract(sin(dot(uv * 1000.0, float2(12.9898, 78.233))) * 43758.5453);
    float grain = (noise - 0.5) * 0.02 * uniforms.glassIntensity;

    // ── 圆角遮罩 ──
    float2 cardSize = float2(0.45 * aspect, 0.35);
    float radius = uniforms.cornerRadius * min(cardSize.x, cardSize.y);
    float sdf = roundedRectSDF(suv - center, cardSize, radius);
    float mask = 1.0 - smoothstep(0.0, 0.002, sdf);

    // ── 玻璃边框高光 ──
    float borderWidth = 0.002;
    float borderSDF = abs(sdf) - borderWidth;
    float border = 1.0 - smoothstep(0.0, 0.001, borderSDF);
    float4 borderColor = uniforms.accentColor * 0.3 * mask;

    // ── 顶部高光条 ──
    float2 topHighlightUV = suv - center;
    float topHighlight = 1.0 - smoothstep(0.0, 0.02, abs(topHighlightUV.y + cardSize.y - 0.02));
    topHighlight *= 1.0 - smoothstep(0.0, 0.3, abs(topHighlightUV.x));
    topHighlight *= mask * 0.3 * uniforms.glassIntensity;

    // ── 合成 ──
    float4 finalColor = bg + haloColor + subColor1 + subColor2 + grain;
    finalColor += borderColor * border;
    finalColor += float4(1.0, 1.0, 1.0, 1.0) * topHighlight;

    // 应用圆角遮罩
    finalColor.a = mask * uniforms.glassIntensity;

    return finalColor;
}

// MARK: - 辉光合成

fragment float4 compositeWithGlow(
    VertexOut in [[stage_in]],
    texture2d<float> sourceTexture [[texture(0)]],
    constant DigitUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float4 color = sourceTexture.sample(s, uv);

    // 简单辉光效果：水平 + 垂直模糊采样
    float2 texelSize = 1.0 / uniforms.resolution;
    float radius = uniforms.glowRadius;

    float4 glow = float4(0.0);
    int samples = 0;

    // 8 方向采样
    const float2 offsets[8] = {
        float2(-1, -1), float2(0, -1), float2(1, -1),
        float2(-1,  0),                float2(1,  0),
        float2(-1,  1), float2(0,  1), float2(1,  1)
    };

    for (int i = 0; i < 8; i++) {
        float2 sampleUV = uv + offsets[i] * texelSize * radius;
        glow += sourceTexture.sample(s, sampleUV);
        samples++;
    }
    glow /= samples;

    // 辉光只增强亮部
    float luminance = dot(glow.rgb, float3(0.299, 0.587, 0.114));
    float glowFactor = luminance * uniforms.glowColor.a * 0.5;

    float4 result = color + glow * glowFactor;
    result.a = color.a;

    return result;
}
