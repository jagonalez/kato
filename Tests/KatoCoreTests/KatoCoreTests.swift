import XCTest
@testable import KatoCore

final class HookServerTests: XCTestCase {
    func testHealthAndEventPost() async throws {
        let port: UInt16 = 17811
        final class Box: @unchecked Sendable { var event: KatoEvent? }
        let box = Box()
        let server = HookServer(port: port) { event in
            box.event = event
        }
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(300))

        // GET /health
        let (healthData, healthResponse) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/health")!)
        XCTAssertEqual((healthResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: healthData, encoding: .utf8), "ok")

        // POST /event
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/event")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"kind":"needsInput","title":"claude · kato","detail":"Waiting for confirmation","cwd":"/Users/x/kato","pid":4242}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        // Wait for the handler to fire.
        for _ in 0..<50 where box.event == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        let event = try XCTUnwrap(box.event)
        XCTAssertEqual(event.kind, .agentNeedsInput)
        XCTAssertEqual(event.title, "claude · kato")
        XCTAssertEqual(event.detail, "Waiting for confirmation")
        XCTAssertEqual(event.focus?.appBundleID, "com.mitchellh.ghostty")
        XCTAssertEqual(event.focus?.windowTitleToken, "kato")
        XCTAssertEqual(event.focus?.processPID, 4242)

        // 404 for anything else
        let (_, notFound) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/nope")!)
        XCTAssertEqual((notFound as? HTTPURLResponse)?.statusCode, 404)
    }
}

final class GitHubMonitorCollapseTests: XCTestCase {
    private let prURL = "https://github.com/helm/pull/pull/7"

    private func snapshot() -> GitHubMonitor.PRSnapshot {
        GitHubMonitor.PRSnapshot(
            url: prURL,
            title: "Fix the thing",
            rollupState: "FAILURE",
            reviews: [GitHubMonitor.PRReviewSnapshot(state: "APPROVED",
                                                     submittedAt: "2026-07-17T10:00:00Z", author: "bob")],
            comments: [GitHubMonitor.PRCommentSnapshot(createdAt: "2026-07-17T11:00:00Z", author: "alice")]
        )
    }

    func testMultipleSignalsCollapseToOneEvent() {
        // Baseline older than the snapshot's signals (first-sight reviews and
        // comments are baselined silently by design).
        var watermark = GitHubMonitor.PRWatermark(
            lastCommentAt: "2026-07-17T09:00:00Z",
            lastReviewAt: "2026-07-17T09:00:00Z"
        )
        let signals = GitHubMonitor.diff(snapshot: snapshot(), watermark: &watermark,
                                         seeding: false, viewerLogin: "me")
        XCTAssertEqual(signals.count, 3)

        let event = GitHubMonitor.makeEvent(prURL: prURL, prTitle: "Fix the thing", signals: signals)
        XCTAssertEqual(event?.dedupeKey, "gh:pr:\(prURL)")
        XCTAssertEqual(event?.kind, .ciFailed)
        XCTAssertEqual(event?.title, "github · helm/pull")
        XCTAssertEqual(event?.detail, "CI failed · bob approved · alice commented — Fix the thing")
        XCTAssertEqual(event?.url?.absoluteString, prURL)
    }

    func testSecondIdenticalPollProducesZeroSignals() {
        var watermark = GitHubMonitor.PRWatermark()
        _ = GitHubMonitor.diff(snapshot: snapshot(), watermark: &watermark,
                               seeding: false, viewerLogin: "me")
        let repeatSignals = GitHubMonitor.diff(snapshot: snapshot(), watermark: &watermark,
                                               seeding: false, viewerLogin: "me")
        XCTAssertTrue(repeatSignals.isEmpty)
        XCTAssertNil(GitHubMonitor.makeEvent(prURL: prURL, prTitle: "t", signals: repeatSignals))
    }

    func testSeedingIsSilentAndSelfAuthoredIgnored() {
        var watermark = GitHubMonitor.PRWatermark()
        XCTAssertTrue(GitHubMonitor.diff(snapshot: snapshot(), watermark: &watermark,
                                         seeding: true, viewerLogin: "me").isEmpty)
        XCTAssertTrue(GitHubMonitor.diff(snapshot: snapshot(), watermark: &watermark,
                                         seeding: false, viewerLogin: "me").isEmpty)

        var selfWatermark = GitHubMonitor.PRWatermark()
        let selfSnapshot = GitHubMonitor.PRSnapshot(
            url: prURL, title: "t", rollupState: nil,
            reviews: [GitHubMonitor.PRReviewSnapshot(state: "COMMENTED",
                                                     submittedAt: "2026-07-17T10:00:00Z", author: "me")],
            comments: [GitHubMonitor.PRCommentSnapshot(createdAt: "2026-07-17T10:00:00Z", author: "me")]
        )
        XCTAssertTrue(GitHubMonitor.diff(snapshot: selfSnapshot, watermark: &selfWatermark,
                                         seeding: false, viewerLogin: "me").isEmpty)
    }

    func testNotificationAPIURLMapsToPRHtmlURL() {
        XCTAssertEqual(
            GitHubMonitor.htmlURL(forAPIURL: "https://api.github.com/repos/helm/pull/pulls/7")?.absoluteString,
            prURL
        )
    }
}

final class FocusMatchScoreTests: XCTestCase {
    func testRanking() {
        XCTAssertEqual(FocusController.matchScore(title: "kato", token: "kato"), 4)
        XCTAssertEqual(FocusController.matchScore(title: "Kato", token: "kato"), 3)
        XCTAssertEqual(FocusController.matchScore(title: "kato — claude", token: "kato"), 2)
        XCTAssertEqual(FocusController.matchScore(title: "work · kato", token: "kato"), 1)
        XCTAssertEqual(FocusController.matchScore(title: "other", token: "kato"), 0)
        XCTAssertGreaterThan(FocusController.matchScore(title: "kato", token: "kato"),
                             FocusController.matchScore(title: "kato-fork", token: "kato"))
    }
}

final class EventGroupingTests: XCTestCase {
    private func event(_ title: String, _ detail: String, _ t: TimeInterval, _ key: String) -> KatoEvent {
        KatoEvent(kind: .prComment, title: title, detail: detail,
                  createdAt: Date(timeIntervalSince1970: t), dedupeKey: key)
    }

    func testGroupsByTitleNewestFirst() {
        let groups = EventGrouping.group([
            event("github · o/r", "CI failed", 300, "a"),
            event("claude · kato", "done", 200, "b"),
            event("github · o/r", "alice commented", 100, "c"),
        ])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?.key, "github · o/r")
        XCTAssertEqual(groups.first?.events.count, 2)
        XCTAssertEqual(groups.first?.representative.detail, "CI failed")
    }
}

final class EventBusRemoveTests: XCTestCase {
    func testRemoveByIDs() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kato-test-\(UUID().uuidString)", isDirectory: true)
        let bus = EventBus(store: EventStore(directory: dir))
        let a = KatoEvent(kind: .prComment, title: "github · o/r", dedupeKey: "a")
        let b = KatoEvent(kind: .agentDone, title: "claude · kato", dedupeKey: "b")
        await bus.ingest(a)
        await bus.ingest(b)
        await bus.remove(ids: [a.id])
        var snapshot = await bus.snapshot()
        XCTAssertEqual(snapshot.map(\.id), [b.id])
        await bus.remove(ids: [b.id])
        snapshot = await bus.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(await EventStore(directory: dir).load().count, 0)
    }
}

final class BrowserOpenerTests: XCTestCase {
    func testComparisonKey() {
        let url = URL(string: "HTTPS://GitHub.COM/helm/pull/pull/7/?notification_referrer_id=1#diff")!
        XCTAssertEqual(BrowserOpener.comparisonKey(for: url),
                       "https://github.com/helm/pull/pull/7")
        XCTAssertEqual(BrowserOpener.comparisonKey(for: URL(string: "https://github.com")!),
                       "https://github.com")
    }
}

final class TabMarkerTests: XCTestCase {
    func testNeedleAndTitle() {
        XCTAssertEqual(TabMarker.needle(tty: "ttys021"), " ⌁ttys021")
        XCTAssertEqual(TabMarker.needle(tty: "/dev/ttys021"), " ⌁ttys021")
        XCTAssertEqual(TabMarker.stampedTitle(token: "kato", tty: "ttys021"), "● kato ⌁ttys021")
        XCTAssertEqual(TabMarker.normalize(tty: " /dev/ttys099 "), "ttys099")
        XCTAssertTrue(TabMarker.stampedTitle(token: "kato", tty: "ttys021")
            .contains(TabMarker.needle(tty: "ttys021")))
        XCTAssertFalse(TabMarker.stampedTitle(token: "kato", tty: "ttys021")
            .contains(TabMarker.needle(tty: "ttys210")))
    }

    func testOwnershipGuards() {
        XCTAssertFalse(TabMarker.verifyOwnership(pid: 99999999, tty: "ttys021"))
        XCTAssertFalse(TabMarker.verifyOwnership(pid: 1, tty: ""))
        XCTAssertFalse(TabMarker.verifyOwnership(pid: 1, tty: "ttys021"))
    }
}

final class EventBusTests: XCTestCase {
    func testDedupeUpdateInPlace() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kato-test-\(UUID().uuidString)", isDirectory: true)
        let bus = EventBus(store: EventStore(directory: dir))

        var event = KatoEvent(kind: .agentDone, title: "claude · kato", detail: "v1", dedupeKey: "hook:done:ttys001")
        await bus.ingest(event)
        event.detail = "v2"
        await bus.ingest(event)

        let snapshot = await bus.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.detail, "v2")
    }

    func testPersistenceRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kato-test-\(UUID().uuidString)", isDirectory: true)
        let store = EventStore(directory: dir)
        let event = KatoEvent(
            kind: .ciFailed,
            title: "github · o/r",
            detail: "CI failed: fix tests",
            url: URL(string: "https://github.com/o/r/pull/1"),
            dedupeKey: "gh:ci:https://github.com/o/r/pull/1"
        )
        await store.save([event])
        let loaded = await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.kind, .ciFailed)
        XCTAssertEqual(loaded.first?.url?.absoluteString, "https://github.com/o/r/pull/1")
    }

    func testLoadPersistedIntoBus() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kato-test-\(UUID().uuidString)", isDirectory: true)
        let store = EventStore(directory: dir)
        await store.save([KatoEvent(kind: .prComment, title: "t", dedupeKey: "k")])
        let bus = EventBus(store: store)
        await bus.loadPersisted()
        let snapshot = await bus.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.kind, .prComment)
    }
}
