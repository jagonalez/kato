import Foundation
import Network

/// Tiny HTTP server on 127.0.0.1:7811 (Network.framework).
///   POST /event  — JSON body -> KatoEvent on the bus
///   GET  /health — "ok"
/// See docs/ARCHITECTURE.md §"AI-agent monitoring — hooks, NOT pcap".
public final class HookServer: @unchecked Sendable {
    /// Payload accepted by POST /event (emitted by hooks / `kato hook`).
    public struct HookPayload: Codable, Sendable {
        public var kind: String
        public var title: String
        public var detail: String?
        public var tty: String?
        public var cwd: String?
        public var pid: Int32?
        public var url: String?

        public init(
            kind: String,
            title: String,
            detail: String? = nil,
            tty: String? = nil,
            cwd: String? = nil,
            pid: Int32? = nil,
            url: String? = nil
        ) {
            self.kind = kind
            self.title = title
            self.detail = detail
            self.tty = tty
            self.cwd = cwd
            self.pid = pid
            self.url = url
        }
    }

    public static let defaultPort: UInt16 = 7811

    private let port: UInt16
    private let handler: @Sendable (KatoEvent) -> Void
    private let queue = DispatchQueue(label: "dev.kato.hook-server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    public init(port: UInt16 = HookServer.defaultPort, handler: @escaping @Sendable (KatoEvent) -> Void) {
        self.port = port
        self.handler = handler
    }

    public func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "dev.kato.hook-server", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid port \(port)"])
        }
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                FileHandle.standardError.write(Data("kato: hook listener failed: \(error)\n".utf8))
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    // MARK: - Connections (all state touched only on `queue`)

    private func handleNewConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections[id] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, state: ConnectionState())
    }

    private func receive(on connection: NWConnection, state: ConnectionState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { state.buffer.append(data) }
            if let request = state.nextRequest() {
                self.respond(on: connection, to: request)
                self.connections[ObjectIdentifier(connection)] = nil
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                self.connections[ObjectIdentifier(connection)] = nil
                return
            }
            self.receive(on: connection, state: state)
        }
    }

    private func respond(on connection: NWConnection, to request: ConnectionState.Request) {
        var status = "200 OK"
        var body = "ok"
        switch (request.method, request.path) {
        case ("GET", "/health"):
            body = "ok"
        case ("POST", "/event"):
            if let payload = try? JSONDecoder().decode(HookPayload.self, from: request.body) {
                handler(Self.event(from: payload))
            } else {
                status = "400 Bad Request"
                body = "bad request"
            }
        default:
            status = "404 Not Found"
            body = "not found"
        }
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/plain\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Payload → event

    static func event(from payload: HookPayload) -> KatoEvent {
        let kind: KatoEvent.Kind
        switch payload.kind.lowercased() {
        case "needsinput", "needs_input", "agentneedsinput", "notification":
            kind = .agentNeedsInput
        case "done", "agentdone", "stop", "subagentstop", "complete", "completed":
            kind = .agentDone
        default:
            kind = KatoEvent.Kind(rawValue: payload.kind) ?? .agentDone
        }
        let focus = TerminalTitleResolver.focusTarget(cwd: payload.cwd, tty: payload.tty, pid: payload.pid)
        let url = payload.url.flatMap { URL(string: $0) }
        let identity = payload.tty ?? payload.pid.map(String.init) ?? payload.title
        return KatoEvent(
            kind: kind,
            title: payload.title,
            detail: payload.detail ?? "",
            url: url,
            focus: focus,
            dedupeKey: "hook:\(kind.rawValue):\(identity)"
        )
    }
}

/// Per-connection receive state. Only touched on the server's serial queue.
private final class ConnectionState: @unchecked Sendable {
    struct Request {
        var method: String
        var path: String
        var body: Data
    }

    var buffer = Data()

    /// Returns a fully-received request, or nil if more bytes are needed.
    func nextRequest() -> Request? {
        let headerTerminator = Data([13, 10, 13, 10])
        guard let headerRange = buffer.range(of: headerTerminator) else { return nil }
        guard let head = String(data: buffer.subdata(in: 0..<headerRange.lowerBound), encoding: .utf8) else {
            return Request(method: "", path: "", body: Data())
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return Request(method: "", path: "", body: Data())
        }
        var contentLength = 0
        for line in lines where line.lowercased().hasPrefix("content-length:") {
            contentLength = Int(line.dropFirst("content-length:".count)
                .trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let bodyStart = headerRange.upperBound
        guard buffer.count >= bodyStart + contentLength else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        return Request(method: String(parts[0]), path: String(parts[1]), body: body)
    }
}
