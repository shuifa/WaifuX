import Foundation
import Metal
import MetalKit
import AppKit
import SwiftUI

// MARK: - 液态玻璃时钟 Metal 渲染器
//
// 使用 Metal 着色器渲染时钟背景的液态玻璃效果。
// 文本层由外层 SwiftUI/CoreText 叠加，Metal 负责视觉效果。
//
// ═══════════════════════════════════════════════════════════
// 架构说明：
//   本渲染器管理 MTLDevice → MTLCommandQueue → MTKView 管线。
//   着色器代码以内嵌字符串方式编译（无需 .metal 文件参与 Xcode 构建），
//   与 AnimeVideoEnhancer 模式一致。
//
// 未来自定义参数扩展口（已预留）：
//   - metalShaderEffect: 切换不同着色器效果 ("glass"|"glow"|"frost")
//   - metalShaderIntensity: 着色器效果强度
//   - digitAnimation: 数字切换动效 ("opacity"|"slide"|"flip")
// ═══════════════════════════════════════════════════════════

@MainActor
public final class LiquidGlassMetalRenderer: NSObject {
    // MARK: - 单例

    public static let shared = LiquidGlassMetalRenderer()

    // MARK: - Metal 对象

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var library: MTLLibrary?

    /// 玻璃背景渲染管线
    private var glassPipelineState: MTLRenderPipelineState?
    /// 辉光合成管线（预留）
    private var glowPipelineState: MTLRenderPipelineState?

    /// 全屏四边形顶点
    private var vertexBuffer: MTLBuffer?

    /// Metal 着色器 uniform 结构体（与 .metal 文件中的 GlassUniforms 对应）
    private struct GlassUniforms {
        var resolution: SIMD2<Float>
        var clockCenter: SIMD2<Float>
        var time: Float
        var accentColor: SIMD4<Float>
        var bgColor: SIMD4<Float>
        var glassIntensity: Float
        var cornerRadius: Float
        var glowIntensity: Float
    }

    /// 顶点数据（位置 xy + 纹理 uv）
    private let vertices: [Float] = [
        -1.0, -1.0, 0.0, 1.0,
         1.0, -1.0, 1.0, 1.0,
        -1.0,  1.0, 0.0, 0.0,
         1.0,  1.0, 1.0, 0.0
    ]

    // MARK: - 初始化

    private override init() {
        super.init()
        setupMetal()
    }

    // MARK: - 设置 Metal

    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[LiquidGlassMetal] Metal 不可用")
            return
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue()

        // 创建顶点缓冲区
        let dataSize = vertices.count * MemoryLayout<Float>.size
        self.vertexBuffer = device.makeBuffer(bytes: vertices, length: dataSize, options: [])

        // 编译着色器
        compileShaders(device: device)
    }

    // MARK: - 着色器编译

    /// 内嵌 Metal 着色器源码
    /// 如需修改着色器逻辑，请同时更新 Metal/LiquidGlassClockShaders.metal
    private var embeddedShaderSource: String {
        """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
        };

        struct GlassUniforms {
            float2 resolution;
            float2 clockCenter;
            float time;
            float4 accentColor;
            float4 bgColor;
            float glassIntensity;
            float cornerRadius;
            float glowIntensity;
        };

        struct DigitUniforms {
            float2 resolution;
            float4 textColor;
            float4 glowColor;
            float glowRadius;
            float digitCount;
        };

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

        float roundedRectSDF(float2 uv, float2 size, float radius) {
            float2 d = abs(uv) - size + radius;
            return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - radius;
        }

        fragment float4 glassBackground(
            VertexOut in [[stage_in]],
            constant GlassUniforms &uniforms [[buffer(0)]]
        ) {
            float2 uv = in.uv;
            float2 res = uniforms.resolution;
            float aspect = res.x / res.y;
            float2 suv = uv;
            suv.x *= aspect;

            float4 bg = uniforms.bgColor;

            float2 center = uniforms.clockCenter;
            center.x *= aspect;

            float distToCenter = distance(suv, center);
            float halo = 1.0 - smoothstep(0.0, 0.8, distToCenter);
            float4 haloColor = uniforms.accentColor * halo * 0.15 * uniforms.glassIntensity;

            float2 subCenter1 = center + float2(-0.15, -0.1);
            float subHalo1 = 1.0 - smoothstep(0.0, 0.6, distance(suv, subCenter1));
            float4 subColor1 = uniforms.accentColor * subHalo1 * 0.08 * uniforms.glassIntensity;

            float2 subCenter2 = center + float2(0.12, 0.08);
            float subHalo2 = 1.0 - smoothstep(0.0, 0.5, distance(suv, subCenter2));
            float4 subColor2 = float4(1.0, 1.0, 1.0, 1.0) * subHalo2 * 0.05 * uniforms.glassIntensity;

            float noise = fract(sin(dot(uv * 1000.0, float2(12.9898, 78.233))) * 43758.5453);
            float grain = (noise - 0.5) * 0.02 * uniforms.glassIntensity;

            float2 cardSize = float2(0.45 * aspect, 0.35);
            float radius = uniforms.cornerRadius * min(cardSize.x, cardSize.y);
            float sdf = roundedRectSDF(suv - center, cardSize, radius);
            float mask = 1.0 - smoothstep(0.0, 0.002, sdf);

            float borderWidth = 0.002;
            float borderSDF = abs(sdf) - borderWidth;
            float border = 1.0 - smoothstep(0.0, 0.001, borderSDF);
            float4 borderColor = uniforms.accentColor * 0.3 * mask;

            float2 topHighlightUV = suv - center;
            float topHighlight = 1.0 - smoothstep(0.0, 0.02, abs(topHighlightUV.y + cardSize.y - 0.02));
            topHighlight *= 1.0 - smoothstep(0.0, 0.3, abs(topHighlightUV.x));
            topHighlight *= mask * 0.3 * uniforms.glassIntensity;

            float4 finalColor = bg + haloColor + subColor1 + subColor2 + grain;
            finalColor += borderColor * border;
            finalColor += float4(1.0, 1.0, 1.0, 1.0) * topHighlight;
            finalColor.a = mask * uniforms.glassIntensity;

            return finalColor;
        }

        fragment float4 compositeWithGlow(
            VertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]],
            constant DigitUniforms &uniforms [[buffer(0)]]
        ) {
            constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
            float2 uv = in.uv;
            float4 color = sourceTexture.sample(s, uv);
            float2 texelSize = 1.0 / uniforms.resolution;
            float radius = uniforms.glowRadius;

            float4 glow = float4(0.0);
            int samples = 0;
            const float2 offsets[8] = {
                float2(-1,-1), float2(0,-1), float2(1,-1),
                float2(-1, 0),                float2(1, 0),
                float2(-1, 1), float2(0, 1), float2(1, 1)
            };
            for (int i = 0; i < 8; i++) {
                float2 sampleUV = uv + offsets[i] * texelSize * radius;
                glow += sourceTexture.sample(s, sampleUV);
                samples++;
            }
            glow /= samples;

            float luminance = dot(glow.rgb, float3(0.299, 0.587, 0.114));
            float glowFactor = luminance * uniforms.glowColor.a * 0.5;
            float4 result = color + glow * glowFactor;
            result.a = color.a;
            return result;
        }
        """
    }

    private func compileShaders(device: MTLDevice) {
        do {
            library = try device.makeLibrary(source: embeddedShaderSource, options: nil)

            // 玻璃背景管线
            let glassVertexFn = library?.makeFunction(name: "vertexClockShader")
            let glassFragmentFn = library?.makeFunction(name: "glassBackground")

            let glassDesc = MTLRenderPipelineDescriptor()
            glassDesc.vertexFunction = glassVertexFn
            glassDesc.fragmentFunction = glassFragmentFn
            glassDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            glassDesc.colorAttachments[0].isBlendingEnabled = true
            glassDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            glassDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            glassDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            glassDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            glassPipelineState = try device.makeRenderPipelineState(descriptor: glassDesc)

            // 辉光合成管线（预留）
            let glowVertexFn = library?.makeFunction(name: "vertexClockShader")
            let glowFragmentFn = library?.makeFunction(name: "compositeWithGlow")

            let glowDesc = MTLRenderPipelineDescriptor()
            glowDesc.vertexFunction = glowVertexFn
            glowDesc.fragmentFunction = glowFragmentFn
            glowDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            glowDesc.colorAttachments[0].isBlendingEnabled = true
            glowDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            glowDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha

            glowPipelineState = try device.makeRenderPipelineState(descriptor: glowDesc)

            print("[LiquidGlassMetal] 着色器编译成功")

        } catch {
            print("[LiquidGlassMetal] 着色器编译失败: \(error)")
        }
    }

    // MARK: - MTKView 配置

    /// 创建一个配置好的 MTKView 用于渲染时钟玻璃背景
    /// ⚡ 性能优化：preferredFramesPerSecond=1，时钟每秒只需更新一次
    public func makeClockView(config: LiquidGlassClockConfiguration) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = device
        mtkView.delegate = self
        mtkView.framebufferOnly = false
        mtkView.clearColor = MTLClearColorMake(0, 0, 0, 0)
        // mtkView.isOpaque 是 get-only，默认 false
        mtkView.enableSetNeedsDisplay = false       // 手动触发重绘
        mtkView.isPaused = true                     // 初始暂停，由外层控制
        mtkView.preferredFramesPerSecond = 1        // 钟只需 1fps

        // 存储配置
        currentConfig = config

        return mtkView
    }

    /// 更新 MTKView 的渲染配置
    public func updateConfig(_ config: LiquidGlassClockConfiguration) {
        currentConfig = config
    }

    /// 手动触发一次重绘（由时钟每秒定时器驱动）
    public func requestRedraw(view: MTKView) {
        guard !view.isPaused else { return }
        view.draw()
    }

    /// 暂停/恢复渲染（跟随视频壁纸暂停状态）
    public func setPaused(_ paused: Bool, view: MTKView? = nil) {
        if let view = view {
            view.isPaused = paused
        }
    }

    // MARK: - 内部状态

    private var currentConfig: LiquidGlassClockConfiguration = .init()
    private var startTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    /// 缓存上一分钟的整数，避免不必要的重绘
    private var lastMinuteValue: Int = -1

    /// 检查时间是否发生变化（仅每分钟/秒变化时重绘）
    public func shouldRedraw() -> Bool {
        let now = Date()
        let minute = Calendar.current.component(.minute, from: now)
        guard minute != lastMinuteValue else { return false }
        lastMinuteValue = minute
        return true
    }
}

// MARK: - MTKViewDelegate

extension LiquidGlassMetalRenderer: MTKViewDelegate {

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 当视图大小变化时重新设置
    }

    public func draw(in view: MTKView) {
        // ⚡ 性能：时间没变化时跳过渲染（时钟内容不变无需重绘）
        guard shouldRedraw() else { return }

        guard let _ = device,
              let commandQueue = commandQueue,
              let pipelineState = glassPipelineState,
              let vertexBuffer = vertexBuffer,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor
        else { return }

        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        // 配置 uniforms
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let viewSize = view.drawableSize
        let config = currentConfig
        let nsColor = NSColor(config.accentColor).usingColorSpace(.sRGB) ?? NSColor.systemPurple

        let alpha = Float(nsColor.alphaComponent)
        let accentColor = SIMD4<Float>(
            Float(nsColor.redComponent),
            Float(nsColor.greenComponent),
            Float(nsColor.blueComponent),
            alpha
        )
        let bgColor = SIMD4<Float>(0.07, 0.07, 0.09, 0.0)
        let cornerRadius = Float(config.cornerRadius / min(viewSize.width, viewSize.height) * 2)

        var uniforms = GlassUniforms(
            resolution: SIMD2<Float>(Float(viewSize.width), Float(viewSize.height)),
            clockCenter: SIMD2<Float>(0.5, 0.5),
            time: Float(elapsed),
            accentColor: accentColor,
            bgColor: bgColor,
            glassIntensity: Float(config.opacity * config.metalShaderIntensity),
            cornerRadius: cornerRadius,
            glowIntensity: Float(config.metalShaderIntensity)
        )

        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GlassUniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - MTKView SwiftUI 桥接

/// 将 MTKView 封装为 SwiftUI View
public struct LiquidGlassMetalClockView: NSViewRepresentable {
    let config: LiquidGlassClockConfiguration
    /// 注册 MTKView 引用的回调（供 OverlayManager 暂停/恢复）
    var viewRegistry: ((MTKView) -> Void)? = nil

    public init(config: LiquidGlassClockConfiguration, viewRegistry: ((MTKView) -> Void)? = nil) {
        self.config = config
        self.viewRegistry = viewRegistry
    }

    public func makeNSView(context: Context) -> MTKView {
        let renderer = LiquidGlassMetalRenderer.shared
        renderer.updateConfig(config)
        let mtkView = renderer.makeClockView(config: config)
        // 注册 MTKView 引用到管理器
        viewRegistry?(mtkView)
        return mtkView
    }

    public func updateNSView(_ nsView: MTKView, context: Context) {
        LiquidGlassMetalRenderer.shared.updateConfig(config)
    }
}
