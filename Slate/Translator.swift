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
    /// 줄이 넘쳐 번역 없이 돌려보낸 묶음 수.
    var dropped = 0
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
    /// 원어마다 줄에 세워 둘 묶음 수 상한. 넘치면 가장 오래된 묶음을 번역 없이 돌려보낸다 —
    /// 번역보다 요청이 빠르거나 세션이 멈췄을 때 줄과 그 묶음을 기다리는 요청이 끝없이 쌓이지 않게.
    static let queueLimit = 30

    struct Job {
        let texts: [String]
        /// 요청한 문서가 아직 떠 있나. 떠난 문서·닫은 탭의 묶음은 번역하지 않는다.
        let isCurrent: @MainActor () -> Bool
        let continuation: CheckedContinuation<[String?], Never>

        func drop() {
            continuation.resume(returning: [String?](repeating: nil, count: texts.count))
        }
    }

    private var queues: [String: [Job]] = [:]
    /// 줄이 비어 기다리는 서버를 깨우는 손잡이.
    private var wakers: [String: CheckedContinuation<Void, Never>] = [:]
    private var running: Set<String> = []
    private var prepared: Set<String> = []

    /// 중국어 간체·번체 판별기. 만들 때마다 모델 파일을 새로 매핑하므로 하나를 다시 쓴다.
    private static let recognizer: NLLanguageRecognizer = {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese]
        return recognizer
    }()

    /// 스크립트가 보낸 언어표("ja"·"zh")를 세션 원어로. 중국어는 글자를 보고 간체·번체를 가른다.
    static func source(for lang: String, sample: String) -> String {
        guard lang == "zh" else { return "ja" }
        recognizer.reset()
        recognizer.processString(sample)
        return recognizer.dominantLanguage == .traditionalChinese ? "zh-Hant" : "zh-Hans"
    }

    /// 순서대로 같은 길이의 배열. 번역 못 한 자리는 nil.
    func translate(_ texts: [String], source: String,
                   isCurrent: @escaping @MainActor () -> Bool = { true }) async -> [String?] {
        guard !texts.isEmpty, Self.sources.contains(source) else { return [String?](repeating: nil, count: texts.count) }
        TranslationStats.shared.requested += texts.count
        TranslationStats.shared.queued += 1
        defer { TranslationStats.shared.queued -= 1 }
        return await withCheckedContinuation { continuation in
            var queue = queues[source, default: []]
            queue.append(Job(texts: texts, isCurrent: isCurrent, continuation: continuation))
            if queue.count > Self.queueLimit {
                queue.removeFirst().drop()
                TranslationStats.shared.dropped += 1
            }
            queues[source] = queue
            wakers.removeValue(forKey: source)?.resume()
        }
    }

    /// translationTask 안에서 부른다. 세션이 살아 있는 동안 그 원어의 줄을 비운다.
    func serve(_ session: TranslationSession, source: String) async {
        await serve(source: source) { texts in
            if !self.prepared.contains(source) {
                do {
                    try await session.prepareTranslation()
                    self.prepared.insert(source)
                    TranslationStats.shared.prepared.append(source)
                } catch {
                    Self.logger.error("prepare \(source, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    TranslationStats.shared.lastError = "prepare \(source): \(error.localizedDescription)"
                }
            }
            return try await self.run(texts, in: session)
        }
    }

    /// 줄을 비우는 고리. perform이 묶음 하나를 번역한다. perform이 던지면 세션이 닫힌 것으로 보고
    /// 그 묶음을 줄 맨 앞에 되돌린 뒤 멈춘다 — 다음 세션이 이어받는다.
    func serve(source: String, perform: ([String]) async throws -> [String?]) async {
        guard !running.contains(source) else { return }
        running.insert(source)
        defer { running.remove(source) }
        while let job = await next(source) {
            do {
                job.continuation.resume(returning: try await perform(job.texts))
            } catch {
                queues[source, default: []].insert(job, at: 0)
                return
            }
        }
    }

    /// 다음 묶음. 떠난 문서의 묶음은 번역 없이 돌려보내고 넘어간다. 줄이 비면 새 묶음이 올 때까지
    /// 기다린다. 세션이 닫히면(취소) nil.
    private func next(_ source: String) async -> Job? {
        while !Task.isCancelled {
            if var queue = queues[source], !queue.isEmpty {
                let job = queue.removeFirst()
                queues[source] = queue
                if job.isCurrent() { return job }
                job.drop()
                continue
            }
            await withTaskCancellationHandler {
                await withCheckedContinuation { wakers[source] = $0 }
            } onCancel: {
                Task { @MainActor in self.wakers.removeValue(forKey: source)?.resume() }
            }
        }
        return nil
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
