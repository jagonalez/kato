import Foundation

public enum SlackMonitorError: Error, CustomStringConvertible {
    case missingToken
    case api(String, String)

    public var description: String {
        switch self {
        case .missingToken:
            return "no Slack user token — paste it in Kato's settings (gear in the panel) or write slack-user-token in the app-support dir"
        case .api(let method, let error):
            return "\(method) failed: \(error)"
        }
    }
}

/// Slack events polled as YOU, with a user token (`xoxp`) — no bot, no
/// Socket Mode, nothing to configure but the token. Your user ID comes from
/// `auth.test`. See docs/ARCHITECTURE.md §"Slack monitor".
///
/// Every 30 s, with per-channel watermarks in `slack-dm-watermark.json`:
///   - DMs: `conversations.list` + `conversations.history` → `.slackDM`
///     (bot apps can't see DMs between humans; polling as you can).
///   - Mentions: `search.messages` for `<@you>` across every channel you're
///     a member of (`search:read.*` scopes) → `.slackMention`.
///   - Mark-as-unread: `conversations.info` unread counts — marking a DM
///     unread surfaces a reminder event; reading it retracts the event
///     through `onRemove`.
/// First sight of a DM/search seeds silently (no backfill burst); anything
/// newer than the stored watermark is emitted, so messages that arrived
/// while Kato was offline still notify. Own messages, bots and subtypes are
/// skipped.
///
/// Token resolution: init arg → `slack-user-token.json` (rotating
/// workspaces: refresh token + client credentials, auto-renewed via
/// `oauth.v2.exchange`) → `KATO_SLACK_USER_TOKEN` → `slack-user-token` file
/// (the file paths are what the in-app settings pane writes; GUI apps don't
/// inherit shell env).
///
/// Events carry `url` = search permalink when available, else a
/// `slack://channel?team=…&id=…&message=…` deep link, and `focus` = nil.
public final class SlackMonitor: Monitor, @unchecked Sendable {

    // MARK: - Testable helpers

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

    /// Resolution order: explicit init arg → environment variable → file in
    /// the state directory (GUI apps don't inherit shell env).
    public static func resolveToken(explicit: String?, environment: [String: String],
                                    envKey: String = "KATO_SLACK_USER_TOKEN",
                                    fileName: String = "slack-user-token",
                                    stateDirectory: URL) -> String? {
        if let explicit, !explicit.isEmpty { return explicit }
        if let env = environment[envKey], !env.isEmpty { return env }
        let file = stateDirectory.appendingPathComponent(fileName)
        if let contents = try? String(contentsOf: file, encoding: .utf8) {
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// User-token resolution: explicit init arg (plain token) →
    /// `slack-user-token.json` (rotating: refresh token + client credentials)
    /// → `KATO_SLACK_USER_TOKEN` → plain `slack-user-token` file.
    public static func resolveUserTokenBox(explicit: String?, environment: [String: String],
                                           stateDirectory: URL) -> SlackUserTokenBox? {
        if let explicit, !explicit.isEmpty {
            return SlackUserTokenBox(stored: .init(accessToken: explicit), fileURL: nil)
        }
        let jsonFile = stateDirectory.appendingPathComponent("slack-user-token.json")
        if let data = try? Data(contentsOf: jsonFile) {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            if let stored = try? decoder.decode(SlackUserTokenBox.Stored.self, from: data) {
                return SlackUserTokenBox(stored: stored, fileURL: jsonFile)
            }
        }
        if let token = resolveToken(explicit: nil, environment: environment,
                                    stateDirectory: stateDirectory) {
            return SlackUserTokenBox(stored: .init(accessToken: token), fileURL: nil)
        }
        return nil
    }

    // MARK: - Lifecycle

    private let userTokenBox: SlackUserTokenBox?
    private let stateDirectory: URL
    private var dmWatermarkURL: URL { stateDirectory.appendingPathComponent("slack-dm-watermark.json") }
    private var dmTask: Task<Void, Never>?
    private var dmNameCache: [String: String] = [:]
    /// DMs that answer channel_not_found (deleted/bot/cross-workspace
    /// ghosts) — skipped after the first failure so they don't spam.
    private var deadChannels: Set<String> = []

    /// Called when a previously-surfaced condition clears and its event
    /// should be retracted (currently: an unread-marked DM is read again).
    /// Receives the event's dedupeKey.
    public var onRemove: (@Sendable (String) -> Void)?

    /// Human-readable status for the settings pane ("connected as @you",
    /// auth failures, …). Also mirrored to stderr.
    public var onStatus: (@Sendable (String) -> Void)?

    public init(userToken: String? = nil, stateDirectory: URL? = nil) {
        let stateDirectory = stateDirectory ?? EventStore.defaultDirectory
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        self.stateDirectory = stateDirectory
        self.userTokenBox = Self.resolveUserTokenBox(
            explicit: userToken,
            environment: ProcessInfo.processInfo.environment,
            stateDirectory: stateDirectory)
    }

    public func start(onEvent: @escaping @Sendable (KatoEvent) -> Void) {
        guard dmTask == nil else { return }
        guard let box = userTokenBox else {
            note("\(SlackMonitorError.missingToken)")
            return
        }
        dmTask = Task.detached(priority: .utility) { [weak self] in
            await self?.pollLoop(tokenBox: box, onEvent: onEvent)
        }
    }

    public func stop() {
        dmTask?.cancel()
        dmTask = nil
    }

    // MARK: - Poll loop

    private func pollLoop(tokenBox: SlackUserTokenBox,
                          onEvent: @escaping @Sendable (KatoEvent) -> Void) async {
        var identity: (userID: String, teamID: String)?
        do {
            let auth = try await Self.userAPICall("auth.test", box: tokenBox, post: true)
            identity = (auth["user_id"] as? String ?? "", auth["team_id"] as? String ?? "")
            let user = auth["user"] as? String ?? identity?.userID ?? "?"
            note("connected as @\(user)")
        } catch {
            note("auth.test failed for user token (\(error)) — Slack polling disabled")
            return
        }
        var mentionsDisabled = false
        while !Task.isCancelled {
            do {
                try await pollDMsOnce(tokenBox: tokenBox, identity: identity, onEvent: onEvent)
                if !mentionsDisabled {
                    do {
                        try await pollMentionsOnce(tokenBox: tokenBox, identity: identity, onEvent: onEvent)
                    } catch SlackMonitorError.api(_, let error) where error == "missing_scope" {
                        // search:read.* not granted (app installed before the
                        // scopes were added).
                        note("mention catch-up needs the search:read.* user scopes — reinstall the Slack app to grant them")
                        mentionsDisabled = true
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                note("poll failed: \(error)")
            }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    private func pollDMsOnce(tokenBox: SlackUserTokenBox,
                             identity: (userID: String, teamID: String)?,
                             onEvent: @escaping @Sendable (KatoEvent) -> Void) async throws {
        // No pagination: 200 open DMs is plenty for a personal assistant.
        let list = try await Self.userAPICall("conversations.list", box: tokenBox,
                                              query: ["types": "im", "limit": "200"])
        let ims = list["channels"] as? [[String: Any]] ?? []
        var watermark = loadDMWatermark()
        for im in ims {
            // Skip ghosts: closed DMs and deactivated users carry stale
            // unread counts from years ago and can never be acted on.
            guard let channel = im["id"] as? String,
                  (im["is_open"] as? Bool) ?? true,
                  (im["is_user_deleted"] as? Bool) != true,
                  !deadChannels.contains(channel)
            else { continue }
            // Per-DM isolation: one failing channel must not abort the poll
            // (or the watermark never saves and every retry re-bursts).
            do {
                try await pollDM(channel: channel, im: im, tokenBox: tokenBox,
                                 identity: identity, watermark: &watermark, onEvent: onEvent)
            } catch is CancellationError {
                throw CancellationError()
            } catch SlackMonitorError.api(_, let error) where error == "channel_not_found" {
                note("skipping DM \(channel) for good: channel_not_found (stale conversation)")
                deadChannels.insert(channel)
            } catch {
                note("DM \(channel) poll failed: \(error)")
            }
        }
        saveDMWatermark(watermark)
    }

    /// One DM per call. `conversations.info` already carries the
    /// latest-message ts and the unread count, so detection costs ONE call
    /// per DM; `conversations.history` only runs for DMs that actually have
    /// new messages (keeps the first-poll burst small and rate-limit-safe).
    private func pollDM(channel: String, im: [String: Any], tokenBox: SlackUserTokenBox,
                        identity: (userID: String, teamID: String)?,
                        watermark: inout [String: String],
                        onEvent: @escaping @Sendable (KatoEvent) -> Void) async throws {
        let info = try await Self.userAPICall("conversations.info", box: tokenBox,
                                              query: ["channel": channel])
        let channelInfo = info["channel"] as? [String: Any]
        let latestTS = (channelInfo?["latest"] as? [String: Any])?["ts"] as? String

        // New messages: only fetch history when the latest ts advanced past
        // the watermark. First sight seeds silently (no backfill burst);
        // channels WITH a watermark emit everything newer — including
        // messages that arrived while Kato was offline.
        let oldest = watermark[channel]
        if let latestTS, latestTS > (oldest ?? "") {
            if let oldest {
                let history = try await Self.userAPICall(
                    "conversations.history", box: tokenBox,
                    query: ["channel": channel, "oldest": oldest, "limit": "10"])
                let messages = history["messages"] as? [[String: Any]] ?? []
                for message in messages.reversed() {
                    guard let ts = message["ts"] as? String, ts > oldest,
                          message["bot_id"] == nil, message["subtype"] == nil,
                          let sender = message["user"] as? String,
                          sender != identity?.userID
                    else { continue }
                    let name = await resolveUserName(sender, tokenBox: tokenBox)
                    let text = Self.cleanText(message["text"] as? String ?? "")
                    onEvent(KatoEvent(
                        kind: .slackDM,
                        title: "slack · \(name ?? "DM")",
                        detail: text.isEmpty ? "(no text)" : text,
                        url: Self.deepLink(team: identity?.teamID ?? "", channel: channel, ts: ts),
                        createdAt: Double(ts).map { Date(timeIntervalSince1970: $0) } ?? Date(),
                        dedupeKey: "slack:\(channel):\(ts)"
                    ))
                }
            }
            watermark[channel] = latestTS
        }

        // Unread reminders (mark-as-unread in Slack → event; read again →
        // retracted via onRemove). Unreads present on first sight surface
        // too — Kato IS the unread inbox.
        let unread = (channelInfo?["unread_count_display"] as? Int)
            ?? (channelInfo?["unread_count"] as? Int) ?? 0
        let unreadKey = "unread:\(channel)"
        let prevUnread = watermark[unreadKey].flatMap(Int.init) ?? 0
        if unread > 0, prevUnread == 0 {
            let name = await resolveUserName((im["user"] as? String) ?? "", tokenBox: tokenBox)
            onEvent(KatoEvent(
                kind: .slackDM,
                title: "slack · \(name ?? "DM")",
                detail: unread == 1 ? "1 unread message" : "\(unread) unread messages",
                url: Self.deepLink(team: identity?.teamID ?? "", channel: channel,
                                   ts: watermark[channel] ?? ""),
                createdAt: Date(),
                dedupeKey: "slack-unread:\(channel)"
            ))
        } else if unread == 0, prevUnread > 0 {
            onRemove?("slack-unread:\(channel)")
        }
        watermark[unreadKey] = String(unread)
    }

    /// Catch-up for mentions: one `search.messages` call per cycle fetches
    /// recent `<@self>` matches across every channel you're a member of and
    /// emits anything newer than the watermark. Note Slack's search index
    /// can lag real time by seconds to a couple of minutes.
    private func pollMentionsOnce(tokenBox: SlackUserTokenBox,
                                  identity: (userID: String, teamID: String)?,
                                  onEvent: @escaping @Sendable (KatoEvent) -> Void) async throws {
        guard let selfID = identity?.userID, !selfID.isEmpty else { return }
        var watermark = loadDMWatermark()
        let key = "search:mentions"
        let oldest = watermark[key]
        let result = try await Self.userAPICall("search.messages", box: tokenBox, query: [
            "query": "<@\(selfID)>",
            "sort": "timestamp",
            "sort_dir": "desc",
            "count": "20",
        ])
        let matches = (result["messages"] as? [String: Any])?["matches"] as? [[String: Any]] ?? []
        if let newest = matches.first?["ts"] as? String {
            watermark[key] = max(newest, oldest ?? "")
        }
        // No watermark yet (first run): don't seed away the recent past —
        // surface the last 24 h of mentions (bounded backfill) so mentions
        // that happened before Kato launched aren't lost forever.
        let threshold = oldest ?? String(format: "%.6f", Date().timeIntervalSince1970 - 24 * 3600)
        for match in matches.reversed() {
            let channel = match["channel"] as? [String: Any]
            guard let ts = match["ts"] as? String, ts > threshold,
                  let channelID = channel?["id"] as? String,
                  !channelID.hasPrefix("D"), // DMs are the DM poller's job
                  match["user"] as? String != selfID
            else { continue }
            let name: String?
            if let userID = match["user"] as? String {
                name = await resolveUserName(userID, tokenBox: tokenBox)
            } else {
                name = match["username"] as? String
            }
            let text = Self.cleanText(match["text"] as? String ?? "")
            let url = (match["permalink"] as? String).flatMap(URL.init)
                ?? Self.deepLink(team: identity?.teamID ?? "", channel: channelID, ts: ts)
            onEvent(KatoEvent(
                kind: .slackMention,
                title: "slack · mention",
                detail: "\(name.map { "\($0): " } ?? "")\(text.isEmpty ? "(no text)" : text)",
                url: url,
                createdAt: Double(ts).map { Date(timeIntervalSince1970: $0) } ?? Date(),
                dedupeKey: "slack:\(channelID):\(ts)"
            ))
        }
        saveDMWatermark(watermark)
    }

    /// Display name for a user ID, cached for the app's lifetime.
    private func resolveUserName(_ userID: String, tokenBox: SlackUserTokenBox) async -> String? {
        if let cached = dmNameCache[userID] { return cached }
        guard let json = try? await Self.userAPICall("users.info", box: tokenBox, query: ["user": userID]),
              let user = json["user"] as? [String: Any] else { return nil }
        let profile = user["profile"] as? [String: Any]
        let displayName = profile?["display_name"] as? String
        let name = (displayName?.isEmpty == false ? displayName : nil)
            ?? (profile?["real_name"] as? String)
            ?? (user["name"] as? String)
        if let name { dmNameCache[userID] = name }
        return name
    }

    private func loadDMWatermark() -> [String: String] {
        guard let data = try? Data(contentsOf: dmWatermarkURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    private func saveDMWatermark(_ watermark: [String: String]) {
        guard let data = try? JSONEncoder().encode(watermark) else { return }
        try? data.write(to: dmWatermarkURL, options: .atomic)
    }

    /// Web API call with the user token: fetches a valid token from the box
    /// (refreshing when rotated), and retries once on `token_expired`.
    private static func userAPICall(_ method: String, box: SlackUserTokenBox,
                                    query: [String: String] = [:], post: Bool = false) async throws -> [String: Any] {
        let token = try await box.validToken()
        do {
            return try await apiCall(method, token: token, query: query, post: post)
        } catch SlackMonitorError.api(_, let error) where error == "token_expired" {
            await box.noteExpired()
            let fresh = try await box.validToken()
            return try await apiCall(method, token: fresh, query: query, post: post)
        }
    }

    /// Minimal Slack Web API call. Read methods go out as GET with query
    /// params; `auth.test` wants a POST. HTTP 429 / `ratelimited` is retried
    /// after Slack's Retry-After hint (the first poll burst can trip it).
    private static func apiCall(_ method: String, token: String,
                                query: [String: String] = [:], post: Bool = false) async throws -> [String: Any] {
        for attempt in 0...4 {
            var request: URLRequest
            if post {
                request = URLRequest(url: URL(string: "https://slack.com/api/\(method)")!)
                request.httpMethod = "POST"
            } else {
                var components = URLComponents(string: "https://slack.com/api/\(method)")!
                components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
                request = URLRequest(url: components.url!)
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? -1
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if status == 429 || json["error"] as? String == "ratelimited" {
                guard attempt < 4 else { break }
                let retryAfter = http?.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(TimeInterval.init) ?? 5
                try? await Task.sleep(for: .seconds(min(retryAfter, 30)))
                continue
            }
            guard status == 200, (json["ok"] as? Bool) == true else {
                var error = (json["error"] as? String) ?? "HTTP \(status)"
                // missing_scope responses name the needed/provided scopes —
                // gold for debugging manifest-vs-install mismatches.
                if error == "missing_scope",
                   let needed = json["needed"] as? String, let provided = json["provided"] as? String {
                    error += " (needed: \(needed), token has: \(provided))"
                }
                throw SlackMonitorError.api(method, error)
            }
            return json
        }
        throw SlackMonitorError.api(method, "ratelimited")
    }

    private func note(_ message: String) {
        FileHandle.standardError.write(Data("kato: slack: \(message)\n".utf8))
        onStatus?(message)
    }
}

// MARK: - User token rotation

/// Holds the `xoxp` user token. Workspaces with token rotation expire user
/// tokens every 12 h; when a refresh token + the app's client credentials
/// are present (see `slack-user-token.json`), the box exchanges them
/// (`oauth.v2.exchange`) and persists the rotated pair back to disk. A
/// plain access token without refresh credentials is used as-is
/// (non-rotating workspaces).
public actor SlackUserTokenBox {
    public struct Stored: Codable {
        public var accessToken: String?
        public var refreshToken: String?
        public var expiresAt: Date?
        public var clientID: String?
        public var clientSecret: String?

        public init(accessToken: String? = nil, refreshToken: String? = nil,
                    expiresAt: Date? = nil, clientID: String? = nil, clientSecret: String? = nil) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
            self.clientID = clientID
            self.clientSecret = clientSecret
        }
    }

    private var stored: Stored
    private let fileURL: URL?

    public init(stored: Stored, fileURL: URL?) {
        self.stored = stored
        self.fileURL = fileURL
    }

    /// A usable access token, refreshing first when expired or expiring.
    public func validToken() async throws -> String {
        let fresh = stored.expiresAt.map { $0.timeIntervalSinceNow > 120 } ?? true
        if !fresh, stored.refreshToken != nil {
            try await refresh()
        }
        guard let token = stored.accessToken else {
            throw SlackMonitorError.missingToken
        }
        return token
    }

    /// Slack answered `token_expired` — force a refresh on the next call.
    func noteExpired() {
        if stored.refreshToken != nil { stored.expiresAt = .distantPast }
    }

    private func refresh() async throws {
        guard let refreshToken = stored.refreshToken,
              let clientID = stored.clientID,
              let clientSecret = stored.clientSecret else { return }
        var request = URLRequest(url: URL(string: "https://slack.com/api/oauth.v2.exchange")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
        .sorted().joined(separator: "&").data(using: .utf8)
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (json["ok"] as? Bool) == true else {
            throw SlackMonitorError.api("oauth.v2.exchange", json["error"] as? String ?? "malformed response")
        }
        // Rotated USER tokens live under `authed_user`; bot tokens at top level.
        let container = (json["authed_user"] as? [String: Any]) ?? json
        if let token = container["access_token"] as? String { stored.accessToken = token }
        if let token = container["refresh_token"] as? String { stored.refreshToken = token }
        if let ttl = container["expires_in"] as? Double {
            stored.expiresAt = Date().addingTimeInterval(ttl)
        }
        persist()
    }

    private func persist() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(stored) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
