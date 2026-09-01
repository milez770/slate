import Foundation
import Network

/// UI 테스트 전용 로컬 HTTP 서버. 경로별 고정 HTML을 돌려준다.
final class TestServer: @unchecked Sendable {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "slate.uitest.server")
    private let pages: [String: String]
    private(set) var port: UInt16 = 0

    init(pages: [String: String]) throws {
        self.pages = pages
        listener = try NWListener(using: .tcp, on: .any)
    }

    /// 리스너를 띄우고 준비될 때까지 기다린다. 5초 안에 준비 안 되면 false.
    func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        // 핸들러는 start 전에 걸어야 한다 — 없으면 리스너가 ready로 넘어가지 않는다.
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            self.serve(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { return false }
        port = listener.port?.rawValue ?? 0
        return port != 0
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [pages] data, _, _, _ in
            guard let data, let request = String(data: data, encoding: .utf8),
                  let requestLine = request.split(separator: "\r\n").first else {
                connection.cancel()
                return
            }
            let parts = requestLine.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1]) : "/"
            let html = pages[path] ?? "<h1>not found</h1>"
            let body = Data(html.utf8)
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
    }
}
