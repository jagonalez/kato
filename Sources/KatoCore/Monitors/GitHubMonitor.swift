import Foundation

public enum GitHubMonitorError: Error, CustomStringConvertible {
    case ghNotInstalled
    case ghFailed(Int32, String)

    public var description: String {
        switch self {
        case .ghNotInstalled:
            return "gh CLI not found (looked in /opt/homebrew/bin, /usr/local/bin, /usr/bin)"
        case .ghFailed(let status, let stderr):
            return "gh exited \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Polls GitHub via the `gh` CLI every ~30 s:
///   - `gh api notifications` → review requests / mentions
///   - `gh api graphql` → viewer's open PRs: statusCheckRollup, reviews, comments
/// Diffs against a persisted watermark (github-watermark.json in the
/// app-support dir) so only NEW CI completions/failures, comments and
/// review-state changes are reported. See docs/ARCHITECTURE.md §"GitHub monitor".
///
/// Everything that happened on one PR during a poll is collapsed into ONE
/// event (dedupeKey `gh:pr:<prURL>`, updated in place on the bus) whose
/// detail summarizes the signals, highest priority first:
///   CI failure > changes requested > review approved/commented > new comment
///   > CI passed > review requested / mention.
///
/// TODO: backoff on rate limit (secondary rate limits return 403 + Retry-After).
public final class GitHubMonitor: Monitor, @unchecked Sendable {
    public struct PRWatermark: Codable, Sendable {
        public var rollupState: String?
        public var lastCommentAt: String?
        public var lastReviewAt: String?
        public init(rollupState: String? = nil, lastCommentAt: String? = nil, lastReviewAt: String? = nil) {
            self.rollupState = rollupState
            self.lastCommentAt = lastCommentAt
            self.lastReviewAt = lastReviewAt
        }
    }

    struct Watermark: Codable {
        var prs: [String: PRWatermark] = [:]
        var seenNotificationIDs: [String] = []
    }

    // MARK: - Testable diff/collapse model

    /// Signal priority: higher wins when picking the event's leading detail
    /// and its kind.
    public enum PRSignalPriority {
        public static let ciFailure = 100
        public static let changesRequested = 90
        public static let review = 80
        public static let comment = 70
        public static let ciPassed = 60
        public static let notification = 50
    }

    /// One thing that newly happened on a PR during a poll.
    public struct PRSignal: Sendable, Equatable {
        public var priority: Int
        public var kind: KatoEvent.Kind
        /// Short human summary, e.g. "CI failed", "alice commented".
        public var text: String

        public init(priority: Int, kind: KatoEvent.Kind, text: String) {
            self.priority = priority
            self.kind = kind
            self.text = text
        }
    }

    public struct PRReviewSnapshot: Sendable, Equatable {
        public var state: String
        public var submittedAt: String
        public var author: String
        public init(state: String, submittedAt: String, author: String) {
            self.state = state
            self.submittedAt = submittedAt
            self.author = author
        }
    }

    public struct PRCommentSnapshot: Sendable, Equatable {
        public var createdAt: String
        public var author: String
        public init(createdAt: String, author: String) {
            self.createdAt = createdAt
            self.author = author
        }
    }

    /// One PR's observable state for a poll, flattened out of the GraphQL response.
    public struct PRSnapshot: Sendable, Equatable {
        public var url: String
        public var title: String
        public var rollupState: String?
        public var reviews: [PRReviewSnapshot]
        public var comments: [PRCommentSnapshot]
        public init(url: String, title: String, rollupState: String?,
                    reviews: [PRReviewSnapshot], comments: [PRCommentSnapshot]) {
            self.url = url
            self.title = title
            self.rollupState = rollupState
            self.reviews = reviews
            self.comments = comments
        }
    }

    /// Diffs one PR snapshot against its watermark, updating the watermark in
    /// place. Returns the new signals (empty when seeding, when nothing
    /// changed, or when everything new was self-authored).
    public static func diff(
        snapshot: PRSnapshot,
        watermark: inout PRWatermark,
        seeding: Bool,
        viewerLogin: String?
    ) -> [PRSignal] {
        var signals: [PRSignal] = []

        // CI status rollup
        if let rollup = snapshot.rollupState, rollup != watermark.rollupState {
            if !seeding {
                if rollup == "SUCCESS" {
                    signals.append(PRSignal(priority: PRSignalPriority.ciPassed,
                                            kind: .ciPassed, text: "CI passed"))
                } else if rollup == "FAILURE" || rollup == "ERROR" {
                    signals.append(PRSignal(priority: PRSignalPriority.ciFailure,
                                            kind: .ciFailed, text: "CI failed"))
                }
            }
            watermark.rollupState = rollup
        }

        // Reviews (new since watermark; ignore self)
        for review in snapshot.reviews {
            let isNew = watermark.lastReviewAt.map { review.submittedAt > $0 } ?? false
            watermark.lastReviewAt = max(watermark.lastReviewAt ?? "", review.submittedAt)
            guard isNew, !seeding, review.author != viewerLogin else { continue }
            switch review.state.uppercased() {
            case "CHANGES_REQUESTED":
                signals.append(PRSignal(priority: PRSignalPriority.changesRequested,
                                        kind: .prReview, text: "\(review.author) requested changes"))
            case "APPROVED":
                signals.append(PRSignal(priority: PRSignalPriority.review,
                                        kind: .prReview, text: "\(review.author) approved"))
            default:
                signals.append(PRSignal(priority: PRSignalPriority.review,
                                        kind: .prReview, text: "\(review.author) reviewed"))
            }
        }

        // Comments (new since watermark; ignore self)
        for comment in snapshot.comments {
            let isNew = watermark.lastCommentAt.map { comment.createdAt > $0 } ?? false
            watermark.lastCommentAt = max(watermark.lastCommentAt ?? "", comment.createdAt)
            guard isNew, !seeding, comment.author != viewerLogin else { continue }
            signals.append(PRSignal(priority: PRSignalPriority.comment,
                                    kind: .prComment, text: "\(comment.author) commented"))
        }

        return signals
    }

    /// Collapses all signals for one PR into a single event:
    /// `github · <owner/repo>`, detail = signals highest-priority first, one
    /// `gh:pr:<prURL>` dedupeKey so the row updates in place.
    public static func makeEvent(prURL: String, prTitle: String, signals: [PRSignal]) -> KatoEvent? {
        guard !signals.isEmpty else { return nil }
        let ordered = signals.enumerated().sorted { lhs, rhs in
            lhs.element.priority != rhs.element.priority
                ? lhs.element.priority > rhs.element.priority
                : lhs.offset < rhs.offset
        }.map(\.element)
        var detail = ordered.map(\.text).joined(separator: " · ")
        if !prTitle.isEmpty { detail += " — \(prTitle)" }
        return KatoEvent(
            kind: ordered[0].kind,
            title: "github · \(repoName(from: prURL))",
            detail: detail,
            url: URL(string: prURL),
            dedupeKey: "gh:pr:\(prURL)"
        )
    }

    // MARK: - Lifecycle

    private let interval: TimeInterval
    private let stateDirectory: URL
    private var watermarkURL: URL { stateDirectory.appendingPathComponent("github-watermark.json") }
    private var task: Task<Void, Never>?
    private var viewerLogin: String?

    public init(interval: TimeInterval = 30, stateDirectory: URL? = nil) {
        self.interval = interval
        self.stateDirectory = stateDirectory ?? EventStore.defaultDirectory
        try? FileManager.default.createDirectory(at: self.stateDirectory, withIntermediateDirectories: true)
    }

    public func start(onEvent: @escaping @Sendable (KatoEvent) -> Void) {
        guard task == nil else { return }
        guard Self.ghPath != nil else {
            FileHandle.standardError.write(Data("kato: \(GitHubMonitorError.ghNotInstalled)\n".utf8))
            return
        }
        task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.poll(onEvent: onEvent)
                try? await Task.sleep(for: .seconds(self.interval))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - Poll

    /// Signals collected during one poll, keyed by PR (html) URL so that CI +
    /// reviews + comments + notifications for the same PR merge into one row.
    private typealias PendingEvents = [String: (title: String, signals: [PRSignal])]

    private func poll(onEvent: @escaping @Sendable (KatoEvent) -> Void) async {
        do {
            if viewerLogin == nil {
                viewerLogin = try String(data: runGH(["api", "user", "--jq", ".login"]), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var watermark = (try? loadWatermark()) ?? Watermark()
            // First run ever: seed the watermark silently instead of
            // emitting a burst of events for historical CI/comments.
            let seeding = !FileManager.default.fileExists(atPath: watermarkURL.path)
            var pending: PendingEvents = [:]
            try pollNotifications(watermark: &watermark, seeding: seeding, pending: &pending)
            try pollPullRequests(watermark: &watermark, seeding: seeding, pending: &pending)
            try saveWatermark(watermark)
            // One collapsed event per PR.
            for (prURL, entry) in pending.sorted(by: { $0.key < $1.key }) {
                if let event = Self.makeEvent(prURL: prURL, prTitle: entry.title, signals: entry.signals) {
                    onEvent(event)
                }
            }
        } catch {
            // Transient failures (offline, rate limit, auth) — retry next tick.
            FileHandle.standardError.write(Data("kato: github poll failed: \(error)\n".utf8))
        }
    }

    private func pollNotifications(
        watermark: inout Watermark,
        seeding: Bool,
        pending: inout PendingEvents
    ) throws {
        let jq = """
        map(select(.reason == "review_requested" or .reason == "mention")) \
        | map({id: .id, reason: .reason, title: .subject.title, url: .subject.url, repo: .repository.full_name})
        """
        let data = try runGH(["api", "notifications", "--jq", jq])
        guard let items = try JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] else { return }
        for item in items {
            guard let id = item["id"] as? String else { continue }
            if watermark.seenNotificationIDs.contains(id) { continue }
            watermark.seenNotificationIDs.append(id)
            guard !seeding else { continue }
            let reason = item["reason"] as? String ?? ""
            let title = item["title"] as? String ?? ""
            guard let apiURL = item["url"] as? String else { continue }
            // Map the API subject URL onto the same html URL the PR loop
            // uses, so notifications merge into the same gh:pr:<url> row.
            let prURL = Self.htmlURL(forAPIURL: apiURL)?.absoluteString ?? apiURL
            let isReviewRequest = reason == "review_requested"
            var entry = pending[prURL] ?? (title: title, signals: [])
            entry.signals.append(PRSignal(
                priority: PRSignalPriority.notification,
                kind: isReviewRequest ? .prReview : .prComment,
                text: isReviewRequest ? "review requested" : "mentioned"
            ))
            pending[prURL] = entry
        }
        if watermark.seenNotificationIDs.count > 500 {
            watermark.seenNotificationIDs = Array(watermark.seenNotificationIDs.suffix(500))
        }
    }

    private static let prQuery = """
    query {
      viewer {
        pullRequests(first: 20, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes {
            url
            title
            number
            reviewDecision
            commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
            reviews(last: 10) { nodes { state submittedAt author { login } } }
            comments(last: 10) { nodes { createdAt author { login } } }
          }
        }
      }
    }
    """

    private func pollPullRequests(
        watermark: inout Watermark,
        seeding: Bool,
        pending: inout PendingEvents
    ) throws {
        let data = try runGH(["api", "graphql", "-f", "query=\(Self.prQuery)"])
        guard let root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let viewer = payload["viewer"] as? [String: Any],
              let pullRequests = viewer["pullRequests"] as? [String: Any],
              let nodes = pullRequests["nodes"] as? [[String: Any]] else { return }

        for node in nodes {
            guard let url = node["url"] as? String else { continue }
            let title = node["title"] as? String ?? ""

            var rollup: String?
            if let commits = node["commits"] as? [String: Any],
               let commitNodes = commits["nodes"] as? [[String: Any]],
               let last = commitNodes.last,
               let commit = last["commit"] as? [String: Any],
               let statusCheckRollup = commit["statusCheckRollup"] as? [String: Any] {
                rollup = statusCheckRollup["state"] as? String
            }

            var reviews: [PRReviewSnapshot] = []
            if let reviewNodes = (node["reviews"] as? [String: Any])?["nodes"] as? [[String: Any]] {
                for review in reviewNodes {
                    guard let submittedAt = review["submittedAt"] as? String else { continue }
                    reviews.append(PRReviewSnapshot(
                        state: review["state"] as? String ?? "",
                        submittedAt: submittedAt,
                        author: (review["author"] as? [String: Any])?["login"] as? String ?? ""
                    ))
                }
            }

            var comments: [PRCommentSnapshot] = []
            if let commentNodes = (node["comments"] as? [String: Any])?["nodes"] as? [[String: Any]] {
                for comment in commentNodes {
                    guard let createdAt = comment["createdAt"] as? String else { continue }
                    comments.append(PRCommentSnapshot(
                        createdAt: createdAt,
                        author: (comment["author"] as? [String: Any])?["login"] as? String ?? ""
                    ))
                }
            }

            let snapshot = PRSnapshot(url: url, title: title, rollupState: rollup,
                                      reviews: reviews, comments: comments)
            var pr = watermark.prs[url] ?? PRWatermark()
            let signals = Self.diff(snapshot: snapshot, watermark: &pr,
                                    seeding: seeding, viewerLogin: viewerLogin)
            watermark.prs[url] = pr
            guard !signals.isEmpty else { continue }
            var entry = pending[url] ?? (title: title, signals: [])
            entry.title = title // prefer the PR title over a notification subject title
            entry.signals.append(contentsOf: signals)
            pending[url] = entry
        }
    }

    // MARK: - gh invocation

    private static let ghPath: String? = {
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        where FileManager.default.fileExists(atPath: path) {
            return path
        }
        return nil
    }()

    private func runGH(_ args: [String]) throws -> Data {
        guard let gh = Self.ghPath else { throw GitHubMonitorError.ghNotInstalled }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Read before waiting to avoid pipe-buffer deadlock.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitHubMonitorError.ghFailed(process.terminationStatus,
                                              String(data: errData, encoding: .utf8) ?? "")
        }
        return outData
    }

    // MARK: - Watermark persistence

    private func loadWatermark() throws -> Watermark {
        let data = try Data(contentsOf: watermarkURL)
        return try JSONDecoder().decode(Watermark.self, from: data)
    }

    private func saveWatermark(_ watermark: Watermark) throws {
        let data = try JSONEncoder().encode(watermark)
        try data.write(to: watermarkURL, options: .atomic)
    }

    // MARK: - URL helpers

    /// "https://github.com/owner/repo/pull/123" → "owner/repo"
    /// (split omits empty subsequences, so "https:" is index 0 and the host index 1)
    public static func repoName(from prURL: String) -> String {
        let parts = prURL.split(separator: "/")
        guard parts.count >= 4 else { return prURL }
        return "\(parts[2])/\(parts[3])"
    }

    /// "https://api.github.com/repos/o/r/pulls/1" → "https://github.com/o/r/pull/1"
    public static func htmlURL(forAPIURL apiURL: String) -> URL? {
        var html = apiURL.replacingOccurrences(of: "https://api.github.com/repos/",
                                               with: "https://github.com/")
        html = html.replacingOccurrences(of: "/pulls/", with: "/pull/")
        return URL(string: html)
    }
}
