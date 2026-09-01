import WebKit
import os

enum UserScripts {
    private static let logger = Logger(subsystem: "com.wonseon.slate", category: "scripts")
    private static var cache: [String: String] = [:]

    static func source(named name: String) -> String {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else {
            logger.error("source(\(name, privacy: .public)): no bundled resource found")
            return ""
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            logger.error("source(\(name, privacy: .public)): failed to read bundled resource")
            return ""
        }
        cache[name] = text
        return text
    }

    @MainActor
    static func script(named name: String,
                       injectionTime: WKUserScriptInjectionTime,
                       forMainFrameOnly: Bool) -> WKUserScript {
        WKUserScript(source: source(named: name), injectionTime: injectionTime, forMainFrameOnly: forMainFrameOnly)
    }
}
