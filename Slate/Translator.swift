import NaturalLanguage
import SwiftUI
import Translation
import os

/// 번역 진단 숫자. 설정 화면이 읽는다.
@MainActor
@Observable
final class TranslationStats {
    static let shared = TranslationStats()
    var requested = 0
    var translated = 0
    var failed = 0
    var cacheHits = 0
    var queued = 0
    var prepared: [String] = []
    var lastError = ""
    var lastFailedText = ""
}

/// 일본어·중국어 → 한국어 기기 내 번역. TranslationSession은 SwiftUI의 translationTask 안에서만
/// 살아 있으므로 원어별로 요청을 줄에 세워 두고 TranslationBridge가 그 안에서 하나씩 꺼내 처리한다.
@MainActor
final class Translator {
    static let shared = Translator()
    private static let logger = Logger(subsystem: "com.wonseon.slate", category: "translate")

    /// 세션을 하나씩 두는 원어.
    static let sources = ["ja", "zh-Hans", "zh-Hant"]

    struct Job {
        let texts: [String]
        let continuation: CheckedContinuation<[String?], Never>
    }

    private var streams: [String: AsyncStream<Job>] = [:]
    private var feeds: [String: AsyncStream<Job>.Continuation] = [:]
    private var running: Set<String> = []
    private var prepared: Set<String> = []

    init() {
        for source in Self.sources {
            let (stream, feed) = AsyncStream.makeStream(of: Job.self)
            streams[source] = stream
            feeds[source] = feed
        }
    }

    /// 스크립트가 보낸 언어표("ja"·"zh")를 세션 원어로. 중국어는 글자를 보고 간체·번체를 가른다.
    static func source(for lang: String, sample: String) -> String {
        guard lang == "zh" else { return "ja" }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese]
        recognizer.processString(sample)
        return recognizer.dominantLanguage == .traditionalChinese ? "zh-Hant" : "zh-Hans"
    }

    /// 순서대로 같은 길이의 배열. 번역 못 한 자리는 nil.
    func translate(_ texts: [String], source: String) async -> [String?] {
        guard !texts.isEmpty, let feed = feeds[source] else { return [String?](repeating: nil, count: texts.count) }
        TranslationStats.shared.requested += texts.count
        TranslationStats.shared.queued += 1
        defer { TranslationStats.shared.queued -= 1 }
        return await withCheckedContinuation { continuation in
            feed.yield(Job(texts: texts, continuation: continuation))
        }
    }

    /// translationTask 안에서 부른다. 세션이 살아 있는 동안 그 원어의 줄을 비운다.
    func serve(_ session: TranslationSession, source: String) async {
        guard !running.contains(source), let stream = streams[source] else { return }
        running.insert(source)
        defer { running.remove(source) }
        for await job in stream {
            if !prepared.contains(source) {
                do {
                    try await session.prepareTranslation()
                    prepared.insert(source)
                    TranslationStats.shared.prepared.append(source)
                } catch {
                    Self.logger.error("prepare \(source, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    TranslationStats.shared.lastError = "prepare \(source): \(error.localizedDescription)"
                }
            }
            do {
                job.continuation.resume(returning: try await run(job.texts, in: session))
            } catch {
                // 세션이 닫히며 취소된 것 — 이 묶음은 버리지 않고 다음 세션이 이어받는다.
                feeds[source]?.yield(job)
                return
            }
            if Task.isCancelled { return }
        }
    }

    private static let chunk = 20

    /// 20개씩 보내고, 실패한 묶음은 낱개로 다시 보낸다 — 문장 하나가 묶음 전체를 죽이지 않게.
    /// 첫 묶음과 그 첫 문장이 둘 다 실패하면 모델 자체가 안 되는 것으로 보고 나머지는 nil.
    private func run(_ texts: [String], in session: TranslationSession) async throws -> [String?] {
        var out = [String?](repeating: nil, count: texts.count)
        var start = 0
        while start < texts.count {
            let end = min(start + Self.chunk, texts.count)
            let slice = Array(texts[start..<end])
            if let translated = try await attempt(slice, in: session) {
                out.replaceSubrange(start..<end, with: translated)
            } else {
                for (offset, text) in slice.enumerated() {
                    guard let single = try await attempt([text], in: session) else {
                        if start == 0 && offset == 0 { return out }
                        continue
                    }
                    out[start + offset] = single[0]
                }
            }
            start = end
        }
        return out
    }

    /// 성공하면 같은 길이의 배열, 모델이 거부하면 nil. 취소는 던진다.
    private func attempt(_ texts: [String], in session: TranslationSession) async throws -> [String?]? {
        let requests = texts.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }
        do {
            var out = [String?](repeating: nil, count: texts.count)
            for response in try await session.translations(from: requests) {
                if let id = response.clientIdentifier, let index = Int(id), out.indices.contains(index) {
                    out[index] = response.targetText
                }
            }
            TranslationStats.shared.translated += out.compactMap { $0 }.count
            return out
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            Self.logger.error("translate \(texts.count) items: \(error.localizedDescription, privacy: .public)")
            if texts.count == 1 {
                TranslationStats.shared.failed += 1
                TranslationStats.shared.lastFailedText = texts[0]
            }
            TranslationStats.shared.lastError = error.localizedDescription
            return nil
        }
    }
}

/// 화면에 보이지 않는 뷰. 원어 하나의 세션을 얻어 Translator에 넘기는 일만 한다.
struct TranslationBridge: View {
    let source: String
    /// 한 번 만들어 고정한다. 화면이 다시 그려질 때 새 설정을 주면 세션이 닫혔다 열리며
    /// 날아가던 번역이 취소된다.
    @State private var configuration: TranslationSession.Configuration

    init(source: String) {
        self.source = source
        _configuration = State(initialValue: TranslationSession.Configuration(
            source: Locale.Language(identifier: source),
            target: Locale.Language(identifier: "ko")
        ))
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(configuration) { session in
                await Translator.shared.serve(session, source: source)
            }
    }
}
