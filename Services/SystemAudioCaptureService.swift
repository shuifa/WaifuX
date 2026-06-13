import Foundation
import Accelerate
import Combine
import ScreenCaptureKit
import AVFoundation

// MARK: - 系统音频捕获服务
//
// 使用 ScreenCaptureKit 捕获系统音频输出，
// 经 vDSP FFT 转换为频谱数据。
//
// ═══════════════════════════════════════════════════════════
// 捕获方式：
//   ScreenCaptureKit (SCStream)
//   → 捕获系统全局音频输出（Spotify/浏览器/游戏等一切声音）
//   → 无需虚拟环回驱动
//   → 需要屏幕录制权限（首次启用时系统弹窗）
//
// 性能优化：
//   - 仅在可视化启用时才启动 SCStream
//   - 音频处理在后台串行队列执行
//   - 平滑系数避免视觉闪烁
// ═══════════════════════════════════════════════════════════

@MainActor
public final class SystemAudioCaptureService: NSObject, ObservableObject {
    public static let shared = SystemAudioCaptureService()

    // MARK: - 频谱数据

    /// 16 频段频谱（0~1）
    @Published public private(set) var spectrum16: [Float] = .init(repeating: 0, count: 16)
    /// 32 频段频谱（0~1）
    @Published public private(set) var spectrum32: [Float] = .init(repeating: 0, count: 32)
    /// 64 频段频谱（0~1）
    @Published public private(set) var spectrum64: [Float] = .init(repeating: 0, count: 64)

    /// 是否正在捕获音频
    @Published public private(set) var isRunning = false

    /// 当前音频能量级别
    @Published public private(set) var averageEnergy: Float = 0

    // MARK: - 私有状态

    private var stream: SCStream?
    private let fftSize: Int = 2048
    private let fftSizeLog2: Int = 11

    /// 平滑系数（0~1，越大越敏感）
    private let smoothFactor: Float = 0.30

    /// 缓存上一帧的频谱值用于平滑
    private var lastSpectrum16: [Float] = .init(repeating: 0, count: 16)
    private var lastSpectrum32: [Float] = .init(repeating: 0, count: 32)
    private var lastSpectrum64: [Float] = .init(repeating: 0, count: 64)

    /// FFT 处理队列
    private let fftQueue = DispatchQueue(label: "com.waifux.audio-fft", qos: .userInitiated)

    /// 权限是否已获取
    @Published public private(set) var isAuthorized = false

    // MARK: - FFT 缓存（避免每帧重建）

    nonisolated(unsafe) private var fftSetup: FFTSetup?
    nonisolated(unsafe) private var hannWindow: [Float] = []

    /// UI 更新节流（~30fps）
    nonisolated(unsafe) private var lastUIUpdateTime: UInt64 = 0
    nonisolated(unsafe) private static let uiUpdateIntervalNs: UInt64 = 33_000_000 // ~30fps

    private override init() {
        super.init()
    }

    // MARK: - 启停控制

    /// 启动音频捕获
    public func start() {
        guard !isRunning else { return }

        Task {
            await requestPermissionAndStart()
        }
    }

    /// 停止音频捕获并释放资源
    public func stop() {
        guard isRunning else { return }

        stream?.stopCapture()
        stream = nil
        isRunning = false
        resetSpectrum()
        print("[AudioCapture] ScreenCaptureKit 音频捕获已停止")
    }

    private func resetSpectrum() {
        lastSpectrum16 = .init(repeating: 0, count: 16)
        lastSpectrum32 = .init(repeating: 0, count: 32)
        lastSpectrum64 = .init(repeating: 0, count: 64)
        spectrum16 = .init(repeating: 0, count: 16)
        spectrum32 = .init(repeating: 0, count: 32)
        spectrum64 = .init(repeating: 0, count: 64)
        averageEnergy = 0
    }

    // MARK: - 权限与启动

    private func requestPermissionAndStart() async {
        // 检查是否已有屏幕录制权限
        let hasPermission = CGPreflightScreenCaptureAccess()
        if !hasPermission {
            // 请求权限（会在主线程弹出系统授权对话框）
            let granted = await MainActor.run {
                CGRequestScreenCaptureAccess()
            }
            guard granted else {
                print("[AudioCapture] 屏幕录制权限被拒绝")
                isAuthorized = false
                return
            }
            isAuthorized = true
        }

        await startSCStream()
    }

    private func startSCStream() async {
        // 预创建 FFT 资源（避免每帧分配）
        if fftSetup == nil {
            fftSetup = vDSP_create_fftsetup(vDSP_Length(fftSizeLog2), FFTRadix(kFFTRadix2))
        }
        if hannWindow.isEmpty {
            hannWindow = [Float](repeating: 0, count: fftSize)
            vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        }

        do {
            // 获取可捕获的内容（显示器列表）
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            guard let display = content.displays.first else {
                print("[AudioCapture] 找不到可捕获的显示器")
                return
            }

            // 创建内容过滤器：捕获整个显示器（不含窗口），仅用于获取音频
            let filter = SCContentFilter(display: display, including: [])

            // 配置：仅音频
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = false
            config.showsCursor = false
            config.width = 1
            config.height = 1
            config.minimumFrameInterval = CMTime(value: 1, timescale: 10)

            // 创建 stream
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            self.stream = stream

            // 添加音频输出接收器
            try stream.addStreamOutput(self, type: SCStreamOutputType.audio, sampleHandlerQueue: fftQueue)

            // 启动捕获
            try await stream.startCapture()

            self.isRunning = true
            self.isAuthorized = true
            print("[AudioCapture] ScreenCaptureKit 系统音频环回已启动 (display=\(display.width)x\(display.height))")

        } catch {
            print("[AudioCapture] ScreenCaptureKit 启动失败: \(error.localizedDescription)")
            self.stream = nil
            self.isRunning = false
        }
    }
}

// MARK: - SCStreamOutput

extension SystemAudioCaptureService: SCStreamOutput {

    nonisolated public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio,
              let blockBuffer = sampleBuffer.dataBuffer,
              let audioFormat = sampleBuffer.formatDescription,
              audioFormat.mediaType == .audio
        else { return }

        // 获取音频数据
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let data = dataPointer, length > fftSize * MemoryLayout<Float>.size else { return }

        // 获取音频格式信息
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)
        let channels = Int(asbd?.pointee.mChannelsPerFrame ?? 2)
        let frameLength = length / (MemoryLayout<Float>.size * channels)

        guard frameLength >= fftSize else { return }

        // 混音到单声道并提取样本
        let floatPtr = UnsafeRawPointer(data).assumingMemoryBound(to: Float.self)
        let samples = UnsafeBufferPointer(start: floatPtr, count: frameLength * channels)
        var monoData = [Float](repeating: 0, count: fftSize)
        for i in 0..<fftSize {
            var sum: Float = 0
            for ch in 0..<channels {
                let idx = i * channels + ch
                if idx < samples.count {
                    sum += samples[idx]
                }
            }
            monoData[i] = sum / Float(channels)
        }

        // 在后台队列执行 FFT（此方法运行在 sampleHandlerQueue 上，已经是后台）
        performFFT(samples: monoData)
    }
}

// MARK: - FFT 处理

extension SystemAudioCaptureService {

    /// 非主线程 FFT 计算（纯数学运算，不涉及 UI）
    nonisolated private func performFFT(samples: [Float]) {
        guard let fftSetup = fftSetup else { return }
        guard hannWindow.count == fftSize else { return }

        var realPart = [Float](repeating: 0, count: fftSize / 2)
        var imagPart = [Float](repeating: 0, count: fftSize / 2)

        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        var scalar: Float = 1.0 / Float(fftSize)

        realPart.withUnsafeMutableBufferPointer { realBuf in
        imagPart.withUnsafeMutableBufferPointer { imagBuf in
            var splitComplex = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)

            // 使用缓存的 Hann 窗
            var windowedSamples = [Float](repeating: 0, count: fftSize)
            vDSP_vmul(samples, 1, hannWindow, 1, &windowedSamples, 1, vDSP_Length(fftSize))

            windowedSamples.withUnsafeMutableBufferPointer { ptr in
                ptr.baseAddress?.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                    vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                }
            }

            vDSP_fft_zrip(fftSetup, &splitComplex, 1, vDSP_Length(fftSizeLog2), FFTDirection(kFFTDirection_Forward))
            vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
        }
        }

        vDSP_vsmul(magnitudes, 1, &scalar, &magnitudes, 1, vDSP_Length(fftSize / 2))

        // dB 映射
        var dbValues = [Float](repeating: 0, count: fftSize / 2)
        for i in 0..<(fftSize / 2) {
            let mag = magnitudes[i]
            dbValues[i] = mag > 0 ? max(0, min(1, 20 * log10(mag * 10) / 80 + 0.5)) : 0
        }

        let new16 = downsample(dbValues, targetCount: 16)
        let new32 = downsample(dbValues, targetCount: 32)
        let new64 = downsample(dbValues, targetCount: 64)

        // UI 更新节流（~30fps，避免每帧音频都向主线程派发）
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastUIUpdateTime >= SystemAudioCaptureService.uiUpdateIntervalNs else { return }
        lastUIUpdateTime = now

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.spectrum16 = self.smooth(new16, last: self.lastSpectrum16)
            self.spectrum32 = self.smooth(new32, last: self.lastSpectrum32)
            self.spectrum64 = self.smooth(new64, last: self.lastSpectrum64)
            self.lastSpectrum16 = self.spectrum16
            self.lastSpectrum32 = self.spectrum32
            self.lastSpectrum64 = self.spectrum64
            let sum = self.spectrum16.reduce(0, +)
            self.averageEnergy = sum / Float(self.spectrum16.count)
        }
    }

    nonisolated private func downsample(_ data: [Float], targetCount: Int) -> [Float] {
        guard targetCount > 0, data.count >= targetCount else { return data }
        var result = [Float](repeating: 0, count: targetCount)
        let binSize = data.count / targetCount
        for i in 0..<targetCount {
            let start = i * binSize
            let end = min(start + binSize, data.count)
            guard start < end else { continue }
            var sum: Float = 0
            for j in start..<end { sum += data[j] }
            result[i] = sum / Float(end - start)
        }
        return result
    }

    nonisolated private func smooth(_ new: [Float], last: [Float]) -> [Float] {
        guard new.count == last.count else { return new }
        return zip(new, last).map { n, l in
            l + (n - l) * smoothFactor
        }
    }
}
