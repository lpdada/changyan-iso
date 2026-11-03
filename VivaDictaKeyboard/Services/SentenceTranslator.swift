import AICore
import Foundation
import os

/// 键盘端直译：把光标前全部文字发给 OpenAI 兼容接口，换回日语。
///
/// 只用在九宫格的星星「译」上：组字串先上屏，取光标前全部内容 → 发请求 →
/// 译文就地替换原文。不再走“发通知等主 App 回结果”那条路，所以主 App
/// 没在后台活着也能翻；代价是键盘扩展里联网要求「允许完全访问」，
/// 没开时请求会失败，调用方按失败处理（给一句人话报错，不再静默转圈）。
///
/// 整框翻译是常态，超过 ``chunkLimit`` 就按句末标点切段、逐段请求、按顺序
/// 拼回：一次塞太长的正文，模型会自己压缩或截断，接口也有 max tokens 上限。
/// 任何一段失败整次就失败，不写回半截译文。
///
/// 配置只读主 App 同步到 App Group 的快照（`SharedAIConfig`，和主 App
/// 选中模式共用同一个 key，不另配）。没有 key 就整体关闭，返回 nil。
/// 不做重试、不做流式、不落盘。
actor SentenceTranslator {
    static let shared = SentenceTranslator()

    struct Config: Sendable {
        var endpoint: URL
        var model: String
        var apiKey: String
        var target: String
        var timeout: TimeInterval
        /// 快照里的服务商：opencode 网关靠请求头路由，不光认 Key，
        /// 发请求时要带 OpenCodeHeaders，否则按匿名限流。
        var provider: AIProvider?
    }

    private static let logger = Logger(
        subsystem: "com.antonnovoselov.VivaDicta.keyboard",
        category: "sentence-translate"
    )
    private static let cacheLimit = 128

    /// 单次请求的字数上限。段内是一整句到几句话，模型译得稳，也不容易撞
    /// 接口的 max tokens；切段只在句末标点/换行处下刀，不切在句子中间。
    private static let chunkLimit = 1_200
    /// 攒到这么多字才肯切，避免一堆碎段（一句一请求又慢又贵）。
    private static let softLimit = 600

    private var cache: [String: String] = [:]
    private var recency: [String] = []
    private var inFlight: [String: Task<String?, Never>] = [:]
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// 拿一段译文；`nil` 表示没配 key、网络失败、超时、或返回内容为空。
    /// 译按钮一次点击翻整框：超过 ``chunkLimit`` 自动切段，逐段请求，
    /// 任何一段失败就整体失败（调用方按失败提示，不写回半截译文）。
    func translate(_ text: String) async -> String? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.count >= 2 else { return nil }
        if let hit = cache[source] { return hit }
        guard let config = Self.loadConfig() else { return nil }
        if let running = inFlight[source] { return await running.value }

        let session = self.session
        let task = Task<String?, Never> { [config] in
            let pieces = Self.split(source)
            var translated: [String] = []
            translated.reserveCapacity(pieces.count)
            for piece in pieces {
                guard let one = await Self.perform(piece, config: config, session: session) else {
                    return nil
                }
                translated.append(one)
            }
            return translated.joined(separator: "\n")
        }
        inFlight[source] = task
        let result = await task.value
        inFlight[source] = nil
        if let result {
            store(source, result)
        }
        return result
    }

    // MARK: - 切段

    /// 把正文切成能一次请求的几段：只在句末标点或换行处下刀，攒够
    /// ``softLimit`` 才切，单句超过 ``chunkLimit`` 才硬切（不丢字）。
    /// 纯函数，不碰网络，便于单测。
    static func split(_ text: String) -> [String] {
        guard text.count > chunkLimit else { return [text] }

        var pieces: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pieces.append(trimmed) }
            current = ""
        }

        for character in text {
            current.append(character)
            let isBoundary = character == "\n" || "。！？!?；;…".contains(character)
            if isBoundary, current.count >= softLimit {
                flush()
            } else if current.count >= chunkLimit {
                // 一整句长到上限还没遇到标点：硬切，字一个都不丢。
                pieces.append(current)
                current = ""
            }
        }
        flush()

        return pieces.isEmpty ? [text] : pieces
    }

    private func store(_ source: String, _ translation: String) {
        if cache[source] == nil {
            recency.append(source)
            if recency.count > Self.cacheLimit {
                let dropped = recency.removeFirst()
                cache[dropped] = nil
            }
        }
        cache[source] = translation
    }

    // MARK: - 配置

    /// 配置来源：主 App 同步到 App Group 的那一套（`SharedAIConfig`，
    /// 和主 App 选中模式共用同一个 key）。没有就返回 nil —— 等于功能关闭。
    static func loadConfig() -> Config? {
        if let shared = SharedAIConfig.snapshot(),
           let endpoint = endpoint(from: shared.baseURL) {
            return Config(
                endpoint: endpoint,
                model: shared.model,
                apiKey: shared.apiKey,
                target: "ja",
                timeout: 30,
                provider: AIProvider(rawValue: shared.provider)
            )
        }
        return nil
    }

    private static func endpoint(from raw: String) -> URL? {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        // AIService 存进快照的是 provider.baseURL（已是完整 chat 地址），
        // 不是裸根地址；已含 /chat/completions 就直通，否则按原规则补路径。
        // 不加这一行，opencodeGo 这类完整地址会被再拼一段 /v1/chat/completions 拼坏。
        if base.contains("/chat/completions") { return URL(string: base) }
        guard !base.isEmpty else { return nil }
        let path = base.hasSuffix("/v1") ? "/chat/completions" : "/v1/chat/completions"
        return URL(string: base + path)
    }

    // MARK: - 请求

    private static func perform(
        _ source: String,
        config: Config,
        session: URLSession
    ) async -> String? {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        // opencode 网关靠这几个头路由（不光认 Key）：没带会被当匿名限流，
        // 跟主 App 的 AIProviderRegistry 一样合并 OpenCodeHeaders。
        if let provider = config.provider {
            for (field, value) in OpenCodeHeaders.headers(for: provider) {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }

        // 不用 Codable 类型：文件作用域的 ChatRequest/ChatResponse 的 Codable
        // 实现会被判定为 MainActor 隔离，从 actor 方法里编解码直接报错
        // （另一分支上已实测两版构建都倒在这里）；JSONSerialization 不走
        // 协议一致性隔离，语义与原来完全一致。
        let payload: [String: Any] = [
            "model": config.model,
            "temperature": 0.2,
            "stream": false,
            "messages": [
                ["role": "system", "content": prompt(target: config.target)],
                ["role": "user", "content": source],
            ],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard (200..<300).contains(http.statusCode) else {
                logger.log(level: .info, "键盘直译 HTTP \(http.statusCode, privacy: .public)")
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else { return nil }
            return cleanup(content)
        } catch {
            logger.log(level: .info, "键盘直译请求失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func prompt(target: String) -> String {
        let language: String
        switch target {
        case "ja": language = "日语"
        case "en": language = "英语"
        default: language = target
        }
        return """
        你是输入法里的翻译器。把用户给出的中文译成自然的\(language)，口语优先，长度与原文相当。
        输入可能是几段：按原文顺序逐段译，段与段之间保留换行，不合并不省略任何一段。
        原文里已经是\(language)的部分原样保留，不用重译。
        只输出译文本身：不要解释，不要加引号，不要罗马字或假名注音。
        """
    }

    /// 模型偶尔会带上引号或「」；去掉这些包装，其余原样。
    private static func cleanup(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers: Set<Character> = ["\"", "“", "”", "「", "」", "『", "』"]
        while let first = text.first, wrappers.contains(first) { text.removeFirst() }
        while let last = text.last, wrappers.contains(last) { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
