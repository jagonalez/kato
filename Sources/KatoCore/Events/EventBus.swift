import Foundation

/// Ingest → dedupe → persist → publish to UI (+ peers, later).
/// See docs/ARCHITECTURE.md §"Event model".
public actor EventBus {
    private let store: EventStore
    private var events: [KatoEvent] = []
    private var subscribers: [UUID: AsyncStream<[KatoEvent]>.Continuation] = [:]
    private var didLoad = false
    private let maxEvents = 500

    public init(store: EventStore = EventStore()) {
        self.store = store
    }

    /// Load persisted events from disk. Idempotent; call once at startup.
    public func loadPersisted() async {
        guard !didLoad else { return }
        didLoad = true
        events = await store.load()
        publish()
    }

    /// Insert a new event, or update in place when an event with the same
    /// `dedupeKey` already exists (the stable `id` is preserved so UI
    /// identity does not flicker).
    public func ingest(_ event: KatoEvent) {
        if let index = events.firstIndex(where: { $0.dedupeKey == event.dedupeKey }) {
            var updated = event
            updated.id = events[index].id
            events[index] = updated
        } else {
            events.insert(event, at: 0)
            if events.count > maxEvents {
                events.removeSubrange(maxEvents...)
            }
        }
        persist()
        publish()
    }

    /// Removes events by id (per-row dismiss and group dismiss from the UI).
    public func remove(ids: some Sequence<UUID>) {
        let doomed = Set(ids)
        guard !doomed.isEmpty else { return }
        events.removeAll { doomed.contains($0.id) }
        persist()
        publish()
    }

    public func clear() {
        events.removeAll()
        persist()
        publish()
    }

    public func snapshot() -> [KatoEvent] {
        events
    }

    /// Full-snapshot stream for UI consumers. Yields the current snapshot
    /// immediately, then after every mutation.
    public func stream() -> AsyncStream<[KatoEvent]> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.yield(events)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func publish() {
        for continuation in subscribers.values {
            continuation.yield(events)
        }
    }

    private func persist() {
        let snapshot = events
        Task { await store.save(snapshot) }
    }
}
