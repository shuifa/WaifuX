import Foundation
import AppKit

/// 线程安全的多线程下载进度跟踪
private actor DownloadProgressTracker {
    private var received: Int64 = 0
    private var lastReported: Double = 0
    private let total: Int64
    private let handler: @Sendable (Double) -> Void

    init(total: Int64, handler: @escaping @Sendable (Double) -> Void) {
        self.total = total
        self.handler = handler
    }

    func add(_ bytes: Int64) {
        received += bytes
        let progress = Double(received) / Double(total)
        if progress - lastReported >= 0.01 || received >= total {
            lastReported = progress
            handler(min(progress, 1.0))
        }
    }
}

/// GitHub Commit 信息
struct GitHubCommit: Codable {
    let sha: String
    let commit: CommitDetails

    struct CommitDetails: Codable {
        let message: String
        let author: AuthorInfo

        struct AuthorInfo: Codable {
            let name: String
            let date: String
        }
    }

    /// 格式化的 commit message（第一行）
    var shortMessage: String {
        let lines = commit.message.components(separatedBy: .newlines)
        return lines.first ?? commit.message
    }

    /// 完整的 commit message
    var fullMessage: String {
        commit.message
    }

    /// 短 SHA（7位）
    var shortSHA: String {
        String(sha.prefix(7))
    }
}

/// GitHub Release 信息
struct GitHubRelease: Codable {
    let tagName: String
    let name: String
    let body: String?
    let htmlUrl: String
    let publishedAt: String
    let prerelease: Bool
    let draft: Bool
    let targetCommitish: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
        case publishedAt = "published_at"
        case prerelease
        case draft
        case targetCommitish = "target_commitish"
    }

    /// 版本号（去掉 v 前缀）
    var version: String {
        tagName.replacingOccurrences(of: "v", with: "", options: .anchored)
    }

    /// 短 SHA（7位）
    var shortSHA: String {
        String(targetCommitish.prefix(7))
    }
}

/// 更新检查结果
enum UpdateCheckResult {
    case noUpdate(current: String)
    case updateAvailable(current: String, latest: GitHubRelease, commit: GitHubCommit?)
    case error(String)
}

/// GitHub 更新检测服务
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var isChecking = false
    @Published var lastCheckDate: Date?
    @Published var currentRelease: GitHubRelease?
    @Published var currentCommit: GitHubCommit?

    // GitHub 仓库配置
    private let owner = "jipika"
    private let repo = "WaifuX"
    private let apiURL = "https://api.github.com/repos/jipika/WaifuX/releases/latest"

    // UserDefaults keys
    private let lastCheckKey = "update_checker_last_check"
    private let cachedReleaseKey = "update_checker_cached_release"
    private let cachedCommitKey = "update_checker_cached_commit"
    private let cachedReleaseEtagKey = "update_checker_cached_release_etag"
    private let rateLimitUntilKey = "update_checker_rate_limit_until"
    /// 自动检查专用时间戳（与 lastCheckKey 区分：手动检查不应被自动检查节流）
    private let lastAutoCheckKey = "update_checker_last_auto_check"

    // 最小检查间隔（秒）- 5分钟（仅限制手动重复点击）
    private let minCheckInterval: TimeInterval = 300
    // 自动检查最小间隔（秒）- 24小时
    private let autoCheckInterval: TimeInterval = 86_400
    // 遇到 403 后的最小冷却时间（秒）- 15分钟（实际取 max(响应头 reset, 此值)）
    private let rateLimitCooldown: TimeInterval = 900

    /// 更新检查专用 URLSession（独立于 NetworkService，以便精确控制 ETag/304/响应头）
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        // 显式禁用 URLCache：由 ETag 条件请求精确控制新鲜度，避免共享缓存返回 60s 旧 release
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = true
        applyProxy(to: config)
        return URLSession(configuration: config)
    }()

    /// 将用户配置的代理应用到指定 session 配置（与 UpdateManager 下载逻辑一致）
    private func applyProxy(to config: URLSessionConfiguration) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "proxy_enabled"),
              let host = defaults.string(forKey: "proxy_host"), !host.isEmpty,
              let portStr = defaults.string(forKey: "proxy_port"),
              let port = Int(portStr), port > 0 else {
            return
        }
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable: true,
            kCFNetworkProxiesHTTPProxy: host,
            kCFNetworkProxiesHTTPPort: port,
            kCFNetworkProxiesHTTPSEnable: true,
            kCFNetworkProxiesHTTPSProxy: host,
            kCFNetworkProxiesHTTPSPort: port
        ]
    }

    private init() {
        // ⚠️ 不在 init 中读 UserDefaults，避免 _CFXPreferences 递归栈溢出
        // 缓存的检查结果通过 restoreCachedState() 延迟恢复
    }

    /// 延迟恢复缓存的更新检查状态（必须在 applicationDidFinishLaunching 中调用）
    func restoreCachedState() {
        if let date = UserDefaults.standard.object(forKey: lastCheckKey) as? Date {
            lastCheckDate = date
        }
        if let data = UserDefaults.standard.data(forKey: cachedReleaseKey) {
            currentRelease = try? JSONDecoder().decode(GitHubRelease.self, from: data)
        }
        if let data = UserDefaults.standard.data(forKey: cachedCommitKey) {
            currentCommit = try? JSONDecoder().decode(GitHubCommit.self, from: data)
        }
    }

    /// 判断是否应执行自动检查（距上次自动检查超过 24 小时）
    /// - Parameter force: 自动检查恒为 false；此方法仅约束自动检查频率
    func shouldAutoCheck() -> Bool {
        guard let lastAuto = UserDefaults.standard.object(forKey: lastAutoCheckKey) as? Date else {
            return true // 从未自动检查过
        }
        return Date().timeIntervalSince(lastAuto) >= autoCheckInterval
    }

    /// 标记本次自动检查已执行（仅自动检查路径调用）
    func markAutoCheckDone() {
        UserDefaults.standard.set(Date(), forKey: lastAutoCheckKey)
    }

    /// 获取当前应用版本
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    /// 获取构建号
    var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// 完整版本字符串
    var fullVersionString: String {
        "\(currentVersion) (\(buildNumber))"
    }

    /// 检查更新
    /// - Parameter force: 是否强制检查，忽略手动检查的 5 分钟间隔限制
    ///   - 注意：force 仅跳过「手动检查过于频繁」的节流；速率限制冷却期对任何调用都生效，
    ///     避免 force=true 反复发请求触发 403 重置冷却的死循环。
    func checkForUpdates(force: Bool = false) async -> UpdateCheckResult {
        isChecking = true
        defer { isChecking = false }

        // 速率限制冷却期：无论 force 与否都生效，避免 force=true 反复 403 重置冷却
        if let rateLimitUntil = UserDefaults.standard.object(forKey: rateLimitUntilKey) as? Date,
           Date() < rateLimitUntil {
            return .error(rateLimitMessage(until: rateLimitUntil))
        }

        // 手动检查过于频繁节流（仅 force=false 时生效）
        if !force, let lastCheck = lastCheckDate {
            let elapsed = Date().timeIntervalSince(lastCheck)
            if elapsed < minCheckInterval {
                let remaining = Int(minCheckInterval - elapsed)
                let minutes = remaining / 60
                let seconds = remaining % 60
                if minutes > 0 {
                    return .error("检查过于频繁，请\(minutes)分\(seconds)秒后再试")
                } else {
                    return .error("检查过于频繁，请\(seconds)秒后再试")
                }
            }
        }

        guard let url = URL(string: apiURL) else {
            return .error("无效的 API URL")
        }

        var request = URLRequest(url: url)
        // 显式禁用 URLCache：由 ETag 精确控制，避免共享缓存返回 60s 旧 release
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("WaifuX-App/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        // ETag 条件请求：命中 304 时不消耗 API 配额（GitHub 官方明确）
        if let etag = UserDefaults.standard.string(forKey: cachedReleaseEtagKey), !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .error("无效的响应")
            }

            // 403 速率限制：解析 X-RateLimit-Reset 精确冷却
            if httpResponse.statusCode == 403 {
                let cooldownUntil = computeRateLimitReset(httpResponse: httpResponse)
                UserDefaults.standard.set(cooldownUntil, forKey: rateLimitUntilKey)
                return .error(rateLimitMessage(until: cooldownUntil))
            }

            // 304 Not Modified：内容未变，用已缓存的 release 做版本比较（不消耗配额）
            // 必须在 200...299 校验之前处理，因为 304 不属于 2xx
            if httpResponse.statusCode == 304 {
                if let cached = currentRelease {
                    lastCheckDate = Date()
                    UserDefaults.standard.set(lastCheckDate, forKey: lastCheckKey)
                    if isReleaseNewer(cached, than: currentVersion) {
                        // commit 按需获取，此处不消耗配额
                        return .updateAvailable(current: currentVersion, latest: cached, commit: currentCommit)
                    } else {
                        return .noUpdate(current: currentVersion)
                    }
                }
                // 304 但无本地缓存：保守返回无更新，不发额外请求避免消耗配额
                return .noUpdate(current: currentVersion)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                return .error("检查失败: HTTP \(httpResponse.statusCode)")
            }

            // 清除冷却期（请求成功，说明限流已解除）
            UserDefaults.standard.removeObject(forKey: rateLimitUntilKey)

            // 200：解析新 release
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

            // 过滤掉草稿和预发布版本
            guard !release.draft, !release.prerelease else {
                return .noUpdate(current: currentVersion)
            }

            // 缓存 release 与 ETag（ETag 从响应头读取）
            currentRelease = release
            lastCheckDate = Date()
            cacheResult(release: release, commit: currentCommit, etag: httpResponse.value(forHTTPHeaderField: "ETag"))

            // commit 改为按需获取（仅 release.body 为空且用户查看详情时），此处不再每次检查都拉取
            // 比较版本号
            if isReleaseNewer(release, than: currentVersion) {
                return .updateAvailable(current: currentVersion, latest: release, commit: currentCommit)
            } else {
                return .noUpdate(current: currentVersion)
            }

        } catch let decodingError as DecodingError {
            return .error("解析响应失败: \(decodingError.localizedDescription)")
        } catch {
            return .error("检查失败: \(error.localizedDescription)")
        }
    }

    /// 根据响应头计算速率限制解除时间
    /// 优先用 X-RateLimit-Reset（Unix 秒），取 max(响应头 reset, now+最小冷却) 防止过短
    private func computeRateLimitReset(httpResponse: HTTPURLResponse) -> Date {
        let minCooldown = Date().addingTimeInterval(rateLimitCooldown)
        if let resetStr = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let resetEpoch = TimeInterval(resetStr) {
            let resetDate = Date(timeIntervalSince1970: resetEpoch)
            return max(resetDate, minCooldown)
        }
        return minCooldown
    }

    /// 生成速率限制提示文案，含精确解除时间
    private func rateLimitMessage(until: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let remaining = Int(until.timeIntervalSince(Date()))
        let minutes = max(0, remaining / 60)
        return "GitHub API 速率限制，将在 \(formatter.string(from: until)) 解除（约\(minutes)分钟后）"
    }

    /// 按需获取 commit 信息（仅当 release.body 为空时调用，避免每次检查都消耗配额）
    /// - Parameter release: 已确认有更新的 release
    /// - Returns: commit 信息；获取失败返回 nil
    func fetchCommitIfNeeded(for release: GitHubRelease) async -> GitHubCommit? {
        // release body 非空时不需要 commit 作为 fallback
        if let body = release.body, !body.isEmpty {
            return currentCommit
        }

        let commitURL = "https://api.github.com/repos/\(owner)/\(repo)/commits/\(release.targetCommitish)"
        guard let url = URL(string: commitURL) else {
            return currentCommit
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("WaifuX-App/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return currentCommit
            }
            let commit = try JSONDecoder().decode(GitHubCommit.self, from: data)
            currentCommit = commit
            if let data = try? JSONEncoder().encode(commit) {
                UserDefaults.standard.set(data, forKey: cachedCommitKey)
            }
            return commit
        } catch {
            print("[UpdateChecker] fetchCommitIfNeeded failed: \(error)")
            return currentCommit
        }
    }

    /// 打开下载页面
    func openDownloadPage(for release: GitHubRelease? = nil) {
        let urlString: String
        if let release = release ?? currentRelease {
            urlString = release.htmlUrl
        } else {
            urlString = "https://github.com/\(owner)/\(repo)/releases"
        }

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// 打开项目主页
    func openProjectPage() {
        if let url = URL(string: "https://github.com/\(owner)/\(repo)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 格式化上次检查时间
    func formattedLastCheckDate() -> String {
        guard let date = lastCheckDate else {
            return "从未检查"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "上次检查: \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    // MARK: - Private

    private func cacheResult(release: GitHubRelease, commit: GitHubCommit?, etag: String?) {
        UserDefaults.standard.set(lastCheckDate, forKey: lastCheckKey)
        if let data = try? JSONEncoder().encode(release) {
            UserDefaults.standard.set(data, forKey: cachedReleaseKey)
        }
        if let commit = commit, let data = try? JSONEncoder().encode(commit) {
            UserDefaults.standard.set(data, forKey: cachedCommitKey)
        }
        // 缓存 ETag 用于下次条件请求（304 不消耗配额）
        if let etag = etag, !etag.isEmpty {
            UserDefaults.standard.set(etag, forKey: cachedReleaseEtagKey)
        }
    }

    /// 比较版本号
    /// - Returns: true 如果 version1 比 version2 新
    private func isVersion(_ version1: String, newerThan version2: String) -> Bool {
        let components1 = version1.split(separator: ".").compactMap { Int($0) }
        let components2 = version2.split(separator: ".").compactMap { Int($0) }

        let maxLength = max(components1.count, components2.count)

        for i in 0..<maxLength {
            let v1 = i < components1.count ? components1[i] : 0
            let v2 = i < components2.count ? components2[i] : 0

            if v1 > v2 {
                return true
            } else if v1 < v2 {
                return false
            }
        }

        return false // 版本相同
    }

    /// 判断 GitHub Release 是否比本地版本新
    /// 支持语义化版本号比较（如 38.0.11 vs 38.0.12）
    private func isReleaseNewer(_ release: GitHubRelease, than localVersion: String) -> Bool {
        // 直接使用语义化版本比较
        return isVersion(release.version, newerThan: localVersion)
    }
}
/// 自动更新管理器 - 处理下载和安装（参考 AltTab 实现）
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    // MARK: - 发布的状态
    @Published var state: UpdateState = .idle
    @Published var progress: Double = 0

    enum UpdateState: Equatable {
        case idle
        case checking
        case downloading(Double)
        case downloaded(URL)
        case installing
        case completed
        case error(String)

        var isIdle: Bool {
            if case .idle = self { return true }
            return false
        }

        var isDownloading: Bool {
            if case .downloading = self { return true }
            return false
        }

        var isDownloaded: Bool {
            if case .downloaded = self { return true }
            return false
        }

        var isInstalling: Bool {
            if case .installing = self { return true }
            return false
        }

        var progressValue: Double {
            switch self {
            case .downloading(let p): return p
            case .downloaded: return 1.0
            default: return 0
            }
        }
    }

    // MARK: - 配置
    private let owner = "jipika"
    private let repo = "WaifuX"

    private init() {}

    // MARK: - 下载更新

    func downloadUpdate(version: String) async {
        guard !state.isDownloading else {
            print("[UpdateManager] Download already in progress")
            return
        }

        // 强制重置状态，防止进度条跳变
        progress = 0
        state = .downloading(0)

        // 尝试多个可能的下载链接格式
        let possibleURLs = [
            "https://github.com/\(owner)/\(repo)/releases/download/v\(version)/WaifuX-\(version).dmg",
            "https://github.com/\(owner)/\(repo)/releases/download/v\(version)/WaifuX.dmg",
            "https://github.com/\(owner)/\(repo)/releases/latest/download/WaifuX.dmg"
        ]

        print("[UpdateManager] Starting download for version: \(version)")

        for (index, urlString) in possibleURLs.enumerated() {
            print("[UpdateManager] Trying URL [\(index)]: \(urlString)")

            guard let url = URL(string: urlString) else {
                continue
            }

            do {
                try await downloadFromURL(url, version: version)
                return // 下载成功
            } catch {
                print("[UpdateManager] URL [\(index)] failed: \(error)")
                continue // 尝试下一个链接
            }
        }

        state = .error("所有下载链接都失败了")
    }

    private func downloadFromURL(_ url: URL, version: String) async throws {
        print("[UpdateManager] Downloading from: \(url.absoluteString)")

        // 创建最终下载路径
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("WaifuX_\(version)_update.dmg")

        // 清理已存在的临时文件
        if FileManager.default.fileExists(atPath: tempFile.path) {
            try? FileManager.default.removeItem(at: tempFile)
        }

        // 配置 URLSession：提高并发连接数以充分利用多线程下载
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        config.httpMaximumConnectionsPerHost = 8
        // 应用用户代理配置
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "proxy_enabled"),
           let host = defaults.string(forKey: "proxy_host"), !host.isEmpty,
           let portStr = defaults.string(forKey: "proxy_port"),
           let port = Int(portStr), port > 0 {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable: true,
                kCFNetworkProxiesHTTPProxy: host,
                kCFNetworkProxiesHTTPPort: port,
                kCFNetworkProxiesHTTPSEnable: true,
                kCFNetworkProxiesHTTPSProxy: host,
                kCFNetworkProxiesHTTPSPort: port
            ]
        }
        let session = URLSession(configuration: config)

        var request = URLRequest(url: url)
        request.setValue("WaifuX-App/\(UpdateChecker.shared.currentVersion)", forHTTPHeaderField: "User-Agent")

        // 先尝试多线程并行下载，失败则回退到单线程
        let (downloadedFileURL, response): (URL, URLResponse)
        do {
            print("[UpdateManager] Attempting parallel chunked download...")
            (downloadedFileURL, response) = try await downloadParallelWithProgress(session: session, request: request) { [weak self] p in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    guard case .downloading = self.state else { return }
                    guard p > self.progress else { return }
                    self.progress = p
                    self.state = .downloading(p)
                }
            }
            print("[UpdateManager] Parallel download succeeded")
        } catch {
            print("[UpdateManager] Parallel download failed: \(error.localizedDescription), falling back to single connection")
            (downloadedFileURL, response) = try await downloadWithProgress(session: session, request: request) { [weak self] p in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    guard case .downloading = self.state else { return }
                    guard p > self.progress else { return }
                    self.progress = p
                    self.state = .downloading(p)
                }
            }
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        print("[UpdateManager] HTTP Status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        // 移动到最终路径（如果路径不同）
        if downloadedFileURL != tempFile {
            // 如果目标已存在，先删除
            if FileManager.default.fileExists(atPath: tempFile.path) {
                try? FileManager.default.removeItem(at: tempFile)
            }
            try FileManager.default.moveItem(at: downloadedFileURL, to: tempFile)
        }

        await MainActor.run {
            progress = 1.0
            state = .downloaded(tempFile)
        }

        print("[UpdateManager] Downloaded to: \(tempFile.path)")
    }

    // MARK: - 安装更新

    func installUpdate() {
        guard case .downloaded(let dmgPath) = state else {
            print("[UpdateManager] No downloaded file to install")
            return
        }

        state = .installing

        // 创建 AppleScript 安装脚本（参考 AltTab 方式）
        let script = createAppleScript(dmgPath: dmgPath.path)

        var errorInfo: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            state = .error("无法创建安装脚本")
            return
        }

        // 执行安装脚本
        appleScript.executeAndReturnError(&errorInfo)

        if let error = errorInfo {
            print("[UpdateManager] Install script error: \(error)")
            // 错误可能是正常的，因为脚本会杀掉当前进程
        }

        // 延迟后退出
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - 辅助方法

    func reset() {
        state = .idle
        progress = 0
    }

    // MARK: - 私有方法

    /// 小文件阈值：小于此值的文件直接走单线程，避免分片 overhead
    private static let parallelDownloadMinSize: Int64 = 20 * 1024 * 1024 // 20MB

    /// 多线程分片并行下载，利用 HTTP Range 请求加速
    /// GitHub/S3 CDN 通常支持 Range，6-8 个并发可显著提升下载速度
    /// ⚠️ 小文件（< 20MB）直接 throw 回退到单线程，避免分片 overhead 反而更慢
    private func downloadParallelWithProgress(
        session: URLSession,
        request: URLRequest,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> (URL, URLResponse) {
        // 1. HEAD 请求获取文件大小并确认服务器支持 Range
        var headRequest = request
        headRequest.httpMethod = "HEAD"
        let (_, headResponse) = try await session.data(for: headRequest)

        guard let httpResponse = headResponse as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let totalSize = headResponse.expectedContentLength
        guard totalSize > 0 else {
            throw URLError(.badServerResponse)
        }

        let acceptRanges = httpResponse.value(forHTTPHeaderField: "Accept-Ranges")
        guard acceptRanges?.lowercased() == "bytes" else {
            throw URLError(.unsupportedURL)
        }

        // ⚡ 关键优化：小文件直接回退单线程，避免分片 overhead
        guard totalSize >= Self.parallelDownloadMinSize else {
            print("[UpdateManager] File size \(String(format: "%.1f", Double(totalSize) / (1024 * 1024)))MB < 20MB, skipping parallel download")
            throw URLError(.unsupportedURL)
        }

        // 2. 分片配置：最多 6 个并发，每个 chunk 至少 2MB
        // 提高 minChunkSize 避免小文件产生过多分片
        let minChunkSize: Int64 = 2 * 1024 * 1024
        let preferredChunkCount = 6
        let chunkCount = max(1, min(preferredChunkCount, Int(totalSize / minChunkSize)))
        let chunkSize = Int(totalSize) / chunkCount

        let tempDir = FileManager.default.temporaryDirectory
        let finalFile = tempDir.appendingPathComponent("WaifuX_update_\(UUID().uuidString).dmg")
        FileManager.default.createFile(atPath: finalFile.path, contents: nil)

        let progress = DownloadProgressTracker(total: totalSize, handler: progressHandler)

        // 3. 并发下载每个 chunk
        // ⚡ 优化：小 chunk（< 10MB）直接下载到内存，避免临时文件 I/O
        let memoryChunkThreshold: Int64 = 10 * 1024 * 1024

        struct ChunkInfo {
            let index: Int
            let data: Data?       // 内存中的数据（小 chunk）
            let file: URL?        // 临时文件（大 chunk）
            let startOffset: Int64
        }

        let chunks = try await withThrowingTaskGroup(of: ChunkInfo.self) { group -> [ChunkInfo] in
            for i in 0..<chunkCount {
                let start = Int64(i * chunkSize)
                let end = (i == chunkCount - 1) ? (totalSize - 1) : (Int64((i + 1) * chunkSize - 1))
                let chunkByteSize = end - start + 1
                let useMemory = chunkByteSize < memoryChunkThreshold

                group.addTask {
                    var chunkRequest = request
                    chunkRequest.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                    chunkRequest.timeoutInterval = 300

                    let (asyncBytes, chunkResponse) = try await session.bytes(for: chunkRequest)
                    guard let chunkHTTP = chunkResponse as? HTTPURLResponse,
                          (chunkHTTP.statusCode == 200 || chunkHTTP.statusCode == 206) else {
                        throw URLError(.badServerResponse)
                    }

                    if useMemory {
                        // ⚡ 小 chunk 直接下载到内存，避免临时文件 I/O
                        var chunkData = Data()
                        chunkData.reserveCapacity(Int(chunkByteSize))

                        let readBufferSize = 512 * 1024
                        var buffer = Data(capacity: readBufferSize)
                        var pendingProgress: Int64 = 0
                        let progressBatchSize: Int64 = 1024 * 1024

                        for try await byte in asyncBytes {
                            buffer.append(byte)
                            if buffer.count >= readBufferSize {
                                chunkData.append(buffer)
                                pendingProgress += Int64(buffer.count)
                                buffer.removeAll(keepingCapacity: true)

                                if pendingProgress >= progressBatchSize {
                                    await progress.add(pendingProgress)
                                    pendingProgress = 0
                                }
                            }
                        }

                        if !buffer.isEmpty {
                            chunkData.append(buffer)
                            pendingProgress += Int64(buffer.count)
                        }
                        if pendingProgress > 0 {
                            await progress.add(pendingProgress)
                        }

                        return ChunkInfo(index: i, data: chunkData, file: nil, startOffset: start)
                    } else {
                        // 大 chunk 使用临时文件，避免内存占用过高
                        let chunkFile = tempDir.appendingPathComponent("WaifuX_chunk_\(i)_\(UUID().uuidString).tmp")
                        FileManager.default.createFile(atPath: chunkFile.path, contents: nil)
                        let chunkHandle = try FileHandle(forWritingTo: chunkFile)
                        defer { try? chunkHandle.close() }

                        let writeBufferSize = 1024 * 1024
                        let progressBatchSize: Int64 = 1024 * 1024

                        var buffer = Data(capacity: writeBufferSize)
                        var pendingProgress: Int64 = 0

                        for try await byte in asyncBytes {
                            buffer.append(byte)
                            if buffer.count >= writeBufferSize {
                                chunkHandle.write(buffer)
                                pendingProgress += Int64(buffer.count)
                                buffer.removeAll(keepingCapacity: true)

                                if pendingProgress >= progressBatchSize {
                                    await progress.add(pendingProgress)
                                    pendingProgress = 0
                                }
                            }
                        }

                        if !buffer.isEmpty {
                            chunkHandle.write(buffer)
                            pendingProgress += Int64(buffer.count)
                        }
                        if pendingProgress > 0 {
                            await progress.add(pendingProgress)
                        }

                        return ChunkInfo(index: i, data: nil, file: chunkFile, startOffset: start)
                    }
                }
            }

            var results: [ChunkInfo] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }

        // 4. 串行合并所有 chunk 到最终文件（单线程，避免多写竞态）
        let finalHandle = try FileHandle(forWritingTo: finalFile)
        defer { try? finalHandle.close() }

        for chunk in chunks.sorted(by: { $0.index < $1.index }) {
            finalHandle.seek(toFileOffset: UInt64(chunk.startOffset))

            if let data = chunk.data {
                // 内存中的数据直接写入
                finalHandle.write(data)
            } else if let file = chunk.file {
                // 临时文件流式读取写入
                let readHandle = try FileHandle(forReadingFrom: file)
                defer { try? readHandle.close() }

                while true {
                    let data = readHandle.readData(ofLength: 512 * 1024)
                    if data.isEmpty { break }
                    finalHandle.write(data)
                }

                // 清理 chunk 临时文件
                try? FileManager.default.removeItem(at: file)
            }
        }

        progressHandler(1.0)
        return (finalFile, headResponse)
    }

    /// 使用 URLSession bytes API 精确跟踪下载进度
    /// 解决 downloadTask + KVO 在 GitHub 重定向时进度跳变的问题
    private func downloadWithProgress(
        session: URLSession,
        request: URLRequest,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> (URL, URLResponse) {
        let (asyncBytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        // 获取文件总大小
        let expectedLength = response.expectedContentLength
        guard expectedLength > 0 else {
            // 无法获取大小，直接下载不报告进度
            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent("WaifuX_update_\(UUID().uuidString).dmg")
            var data = Data()
            for try await byte in asyncBytes {
                data.append(byte)
            }
            try data.write(to: tempFile)
            return (tempFile, response)
        }

        // 流式下载 + 精确进度报告
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("WaifuX_update_\(UUID().uuidString).dmg")

        // 确保临时文件不存在
        if FileManager.default.fileExists(atPath: tempFile.path) {
            try? FileManager.default.removeItem(at: tempFile)
        }

        // 创建输出文件句柄
        FileManager.default.createFile(atPath: tempFile.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: tempFile)

        defer {
            try? fileHandle.close()
        }

        var receivedBytes: Int64 = 0
        var lastReportedProgress: Double = 0

        // 流式下载：增大缓冲区到 512KB，减少写入频率
        let bufferSize = 512 * 1024
        var buffer = Data(capacity: bufferSize)

        for try await byte in asyncBytes {
            buffer.append(byte)
            receivedBytes += 1

            if buffer.count >= bufferSize {
                fileHandle.write(buffer)
                buffer.removeAll(keepingCapacity: true)
            }

            // 每 1% 更新一次进度，减少 UI 更新频率
            let currentProgress = Double(receivedBytes) / Double(expectedLength)
            if currentProgress - lastReportedProgress >= 0.01 || receivedBytes >= expectedLength {
                lastReportedProgress = currentProgress
                progressHandler(min(currentProgress, 1.0))
            }
        }

        // 写入剩余数据
        if !buffer.isEmpty {
            fileHandle.write(buffer)
        }

        // 最终进度
        progressHandler(1.0)

        return (tempFile, response)
    }

    private func createAppleScript(dmgPath: String) -> String {
        let appName = "WaifuX"
        _ = Bundle.main.bundleIdentifier ?? "com.waifux.app"

        // 创建 bash 脚本文件并执行（参考 AltTab 实现）
        let scriptContent = """
#!/bin/bash
set -e

DMG_PATH="\(dmgPath)"
APP_NAME="\(appName)"

# 等待原应用退出
sleep 1

# 强制退出应用
pkill -9 -x "$APP_NAME" 2>/dev/null || true
osascript -e 'quit app "$APP_NAME"' 2>/dev/null || true
sleep 2

# 创建临时挂载点
MOUNT_POINT="/tmp/WaifuX_Update_$$"
mkdir -p "$MOUNT_POINT"

# 挂载 DMG
hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_POINT" -nobrowse -quiet

# 查找应用
APP_PATH=$(find "$MOUNT_POINT" -name "*.app" -maxdepth 1 | head -n 1)

if [ -z "$APP_PATH" ]; then
    echo "Error: No app found in DMG"
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    exit 1
fi

# 复制到 Applications
DEST_PATH="/Applications/$APP_NAME.app"

if [ -d "$DEST_PATH" ]; then
    rm -rf "$DEST_PATH"
fi

# 使用 ditto 替代 cp -R，保留创建时间、扩展属性、资源分支等所有元数据
# 避免 Gatekeeper 因创建时间丢失而误判"软件损坏"
ditto "$APP_PATH" "$DEST_PATH"

# 卸载 DMG
hdiutil detach "$MOUNT_POINT" -quiet
rmdir "$MOUNT_POINT" 2>/dev/null || true

# 移除隔离属性
xattr -rd com.apple.quarantine "$DEST_PATH" 2>/dev/null || true

# 启动新版本
open "$DEST_PATH"

# 清理下载文件
rm -f "$DMG_PATH"
"""

        // 写入临时脚本文件
        let tempDir = FileManager.default.temporaryDirectory
        let scriptPath = tempDir.appendingPathComponent("waifux_update_\(UUID().uuidString).sh")

        do {
            try scriptContent.write(toFile: scriptPath.path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        } catch {
            print("[UpdateManager] Failed to create install script: \(error)")
        }

        // 使用 AppleScript 执行脚本（请求管理员权限）
        return """
        do shell script "bash '\(scriptPath.path)'" with administrator privileges
        """
    }
}
