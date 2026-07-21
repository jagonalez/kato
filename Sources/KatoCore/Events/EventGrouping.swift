import Foundation

/// One collapsible row in the UI: every event sharing a group key, newest
/// first. The key is the event title — "github · helm/pull" collapses all
/// PR rows for that repo, "claude · kato" collapses done/needs-input pings
/// from that project — so a busy source shows ONE row (its newest event)
/// with a count, instead of ten near-identical rows.
public struct EventGroup: Identifiable, Sendable {
    public var key: String
    public var events: [KatoEvent]

    public var id: String { key }
    /// The newest event; what the collapsed row shows and selects.
    public var representative: KatoEvent { events[0] }

    public init(key: String, events: [KatoEvent]) {
        self.key = key
        self.events = events
    }
}

public enum EventGrouping {
    public static func groupKey(for event: KatoEvent) -> String {
        event.title
    }

    /// Collapses a newest-first event list into groups, ordered by each
    /// group's newest event (input order of first appearance).
    public static func group(_ events: [KatoEvent]) -> [EventGroup] {
        var order: [String] = []
        var buckets: [String: [KatoEvent]] = [:]
        for event in events {
            let key = groupKey(for: event)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(event)
        }
        return order.map { EventGroup(key: $0, events: buckets[$0] ?? []) }
    }
}
