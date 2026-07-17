import Foundation

/// Stub — phase 6. See docs/ARCHITECTURE.md §"Slack monitor (pluggable, phase 2)".
///
/// TODO: implement one of the candidate paths from the architecture doc:
///   1. Slack app w/ Socket Mode (`xapp` token) — real-time, no polling (preferred).
///   2. User token polling (`xoxp`, `conversations.history` on mentions/DMs).
///   3. Notification Center scrape — REJECTED (Full Disk Access, brittle).
/// Emit `.slackMention` / `.slackDM` events with `url` = Slack deep link and `focus` = nil.
public final class SlackMonitor: Monitor, @unchecked Sendable {
    public init() {}

    public func start(onEvent: @escaping @Sendable (KatoEvent) -> Void) {
        // TODO(phase 6): see docs/ARCHITECTURE.md §"Slack monitor".
    }

    public func stop() {
        // TODO(phase 6): see docs/ARCHITECTURE.md §"Slack monitor".
    }
}
