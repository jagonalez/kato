import Foundation

public enum SlackMonitorError: Error, CustomStringConvertible {
    case missingToken
    case connectionsOpenHTTP(Int, String)
    case connectionsOpenAPI(String)

    public var description: String {
        switch self {
        case .missingToken:
            return "no Slack app token (set KATO_SLACK_APP_TOKEN or write slack-app-token in the app-support dir)"
        case .connectionsOpenHTTP(let status, let body):
            return "apps.connections.open HTTP \(status): \(body.prefix(200))"
        case .connectionsOpenAPI(let error):
            return "apps.connections.open failed: \(error)"
        }
    }
}

/// Real-time Slack events over Socket Mode (WebSocket, no polling).
/// See docs/ARCHITECTURE.md §"Slack monitor".
///
/// One `xapp` (app-level) token opens a WebSocket via `apps.connections.open`;
/// Slack pushes envelopes down the socket, each acked by `envelope_id`
/// (un-acked envelopes are re-sent, so recent IDs are deduped). Surfaced:
///   - `app_mention`                        → `.slackMention`
///   - `message` in an IM channel           → `.slackDM`
///   - `message` in a channel containing `<@selfUserID>`, when selfUserID is
///     configured (env `KATO_SLACK_USER_ID`) and the app is subscribed to
///     `message.channels` / `message.groups` → `.slackMention`
/// Bot messages and subtype messages (edits, joins, …) are ignored.
///
/// Events carry `url` = `slack://channel?team=…&id=…&message=…` deep link
/// (opens the desktop app, no workspace subdomain needed) and `focus` = nil.
/// Reconnect is immediate on Slack's `disconnect` frame (wss URLs rotate),
/// otherwise exponential backoff capped at 60 s.
///
/// Setup: Slack app → Socket Mode on → app-level token (`connections:write`)
/// → subscribe to `app_mention`, `message.im` → install to workspace. Token
/// resolution: init arg → `KATO_SLACK_APP_TOKEN` → `slack-app-token` file in
/// the app-support dir (GUI apps don't inherit shell env).
///
/// TODO: optional bot token (`xoxb`) for `chat.getPermalink` URLs and
/// channel/user name resolution (titles are currently static strings).
public final class SlackMonitor: Monitor, @unchecked Sendable {

    // MARK: - Testable envelope parsing

    /// Slack mrkdwn cleanup for human-readable detail text:
    /// `<@U1>` → `@U1`, `<@U1|bob>` → `@bob`, `<#C1|general>` → `#general`,
    /// `<!channel>` → `@channel`, `<https://x|label>` → `label`,
    /// `<https://x>` → `https://x`; then whitespace-collapsed and truncated.
    public static func cleanText(_ raw: String, limit: Int = 200) -> String {
        var out = ""
        var rest = raw[...]
        while let open = rest.firstIndex(of: "<") {
            out += rest[..<open]
            rest = rest[open...]
            guard let close = rest.firstIndex(of: ">") else { break }
            let inner = rest[rest.index(after: rest.startIndex)..<close]
            out += renderToken(inner)
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        var text = out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.count > limit {
            text = String(text.prefix(limit - 1)) + "…"
        }
        return text
    }

    private static func renderToken(_ inner: Substring) -> String {
        if let pipe = inner.firstIndex(of: "|") {
            let target = inner[..<pipe]
            let label = inner[inner.index(after: pipe)...]
            if target.hasPrefix("@") { return "@\(label)" }
            if target.hasPrefix("#") { return "#\(label)" }
            return String(label)
        }
        if inner.hasPrefix("!") { return "@\(inner.dropFirst())" }
        return String(inner)
    }

    /// `slack://channel?team=T&id=C&message=p<ts without dot>`.
    public static func deepLink(team: String, channel: String, ts: String) -> URL? {
        var components = URLComponents()
        components.scheme = "slack"
        components.host = "channel"
        components.queryItems = [
            URLQueryItem(name: "team", value: team),
            URLQueryItem(name: "id", value: channel),
            URLQueryItem(name: "message", value: "p" + ts.replacingOccurrences(of: ".", with: "")),
        ]
        return components.url
    }

    /// Every envelope carrying an `envelope_id` must be acked back.
    public static func ackID(forEnvelope envelope: [String: Any]) -> String? {
        envelope["envelope_id"] as? String
    }

    /// Slack asks us to reconnect (wss URL rotation) via a disconnect frame.
    public static func shouldReconnect(envelope: [String: Any]) -> Bool {
        (envelope["type"] as? String) == "disconnect"
    }

    /// Parse one Socket Mode envelope into an event, or nil when it isn't an
    /// events_api payload we surface.
    public static func makeEvent(envelope: [String: Any], selfUserID: String? = nil) -> KatoEvent? {
        guard (envelope["type"] as? String) == "events_api",
              let payload = envelope["payload"] as? [String: Any],
              let event = payload["event"] as? [String: Any],
              let type = event["type"] as? String,
              let channel = event["channel"] as? String,
              let ts = event["ts"] as? String
        else { return nil }
        // Bots and edits/joins/leaves etc. never surface.
        if event["bot_id"] != nil || event["subtype"] != nil { return nil }

        let team = (payload["team_id"] as? String) ?? (event["team"] as? String) ?? ""
        let rawText = event["text"] as? String ?? ""
        let text = cleanText(rawText)
        let createdAt = Double(ts).map { Date(timeIntervalSince1970: $0) } ?? Date()

        func make(_ kind: KatoEvent.Kind, _ title: String) -> KatoEvent {
            KatoEvent(
                kind: kind,
                title: title,
                detail: text.isEmpty ? "(no text)" : text,
                url: deepLink(team: team, channel: channel, ts: ts),
                createdAt: createdAt,
                dedupeKey: "slack:\(channel):\(ts)"
            )
        }

        switch type {
        case "app_mention":
            return make(.slackMention, "slack · mention")
        case "message":
            let channelType = event["channel_type"] as? String
            if channelType == "im" {
                return make(.slackDM, "slack · DM")
            }
            if let selfUserID, !selfUserID.isEmpty, rawText.contains("<@\(selfUserID)>") {
                return make(.slackMention, "slack · mention")
            }
            return nil
        default:
            return nil
        }
    }

    /// Resolution order: explicit init arg → `KATO_SLACK_APP_TOKEN` →
    /// `<stateDirectory>/slack-app-token` file.
    public static func resolveToken(explicit: String?, environment: [String: String],
                                    stateDirectory: URL) -> String? {
        if let explicit, !explicit.isEmpty { return explicit }
        if let env = environment["KATO_SLACK_APP_TOKEN"], !env.isEmpty { return env }
        let file = stateDirectory.appendingPathComponent("slack-app-token")
        if let contents = try? String(contentsOf: file, encoding: .utf8) {
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: - Lifecycle

    private let appToken: String?
    private let selfUserID: String?
    private var task: Task<Void, Never>?
    private var webSocket: URLSessionWebSocketTask?
    private var recentEnvelopeIDs: [String] = []
    private var seenEnvelopeIDs: Set<String> = []

    public init(appToken: String? = nil, selfUserID: String? = nil, stateDirectory: URL? = nil) {
        let stateDirectory = stateDirectory ?? EventStore.defaultDirectory
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let environment = ProcessInfo.processInfo.environment
        self.appToken = Self.resolveToken(explicit: appToken, environment: environment,
                                          stateDirectory: stateDirectory)
        self.selfUserID = selfUserID ?? environment["KATO_SLACK_USER_ID"]
    }

    public func start(onEvent: @escaping @Sendable (KatoEvent) -> Void) {
        guard task == nil else { return }
        guard let token = appToken else {
            Self.log("\(SlackMonitorError.missingToken)")
            return
        }
        task = Task.detached(priority: .utility) { [weak self] in
            await self?.connectionLoop(token: token, onEvent: onEvent)
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        webSocket?.cancel(with: .goingAway, reason: Data())
        webSocket = nil
    }

    // MARK: - Connection loop

    private func connectionLoop(token: String,
                                onEvent: @escaping @Sendable (KatoEvent) -> Void) async {
        var backoff: TimeInterval = 1
        while !Task.isCancelled {
            do {
                let url = try await openConnection(token: token)
                backoff = 1
                try await runWebSocket(url: url, onEvent: onEvent)
                // Slack sent `disconnect` — reconnect promptly, no backoff.
            } catch is CancellationError {
                return
            } catch {
                Self.log("\(error) — retrying in \(Int(backoff))s")
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 60)
            }
        }
    }

    private func openConnection(token: String) async throws -> URL {
        var request = URLRequest(url: URL(string: "https://slack.com/api/apps.connections.open")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw SlackMonitorError.connectionsOpenHTTP(status, String(data: data, encoding: .utf8) ?? "")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (json["ok"] as? Bool) == true,
              let urlString = json["url"] as? String,
              let url = URL(string: urlString) else {
            throw SlackMonitorError.connectionsOpenAPI(json["error"] as? String ?? "malformed response")
        }
        return url
    }

    private func runWebSocket(url: URL,
                              onEvent: @escaping @Sendable (KatoEvent) -> Void) async throws {
        let socket = URLSession.shared.webSocketTask(with: url)
        webSocket = socket
        socket.resume()
        defer {
            if webSocket === socket { webSocket = nil }
            socket.cancel(with: .goingAway, reason: Data())
        }
        while !Task.isCancelled {
            let message = try await socket.receive()
            guard case .string(let text) = message,
                  let data = text.data(using: .utf8),
                  let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            if let ackID = Self.ackID(forEnvelope: envelope) {
                // Slack re-sends un-acked envelopes — drop retries.
                guard recordEnvelopeID(ackID) else { continue }
                try? await socket.send(.string("{\"envelope_id\":\"\(ackID)\"}"))
            }
            if Self.shouldReconnect(envelope: envelope) {
                Self.log("slack requested reconnect")
                return
            }
            if let event = Self.makeEvent(envelope: envelope, selfUserID: selfUserID) {
                onEvent(event)
            }
        }
    }

    /// Returns false for IDs seen recently (ring buffer of the last 200).
    private func recordEnvelopeID(_ id: String) -> Bool {
        if seenEnvelopeIDs.contains(id) { return false }
        seenEnvelopeIDs.insert(id)
        recentEnvelopeIDs.append(id)
        if recentEnvelopeIDs.count > 200 {
            seenEnvelopeIDs.remove(recentEnvelopeIDs.removeFirst())
        }
        return true
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("kato: slack: \(message)\n".utf8))
    }
}
