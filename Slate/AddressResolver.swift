import Foundation

enum AddressResolver {
    static func url(from input: String) -> URL {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("http://") || t.hasPrefix("https://"), let u = URL(string: t) {
            return u
        }
        let looksLikeHost = !t.contains(" ") && t.contains(".")
        if looksLikeHost, let u = URL(string: "https://\(t)") {
            return u
        }
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: t)]
        return c.url!
    }
}
