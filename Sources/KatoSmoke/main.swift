import Foundation
import KatoCore

// Tiny assertion-based smoke harness (this machine has Command Line Tools
// only — no XCTest). Run with: swift run KatoSmoke
// Exercises: HookServer (GET /health, POST /event, 404), EventBus dedupe,
// EventStore persistence round-trip, and TerminalTitleResolver.

var failures = 0

@MainActor
func check(_ condition: Bool, _ name: String, _ detail: String = "") {
    if condition {
        print("PASS  \(name)")
    } else {
        print("FAIL  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        failures += 1
    }
}

// MARK: - EventBus dedupe (update-in-place by dedupeKey)

let tempDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("kato-smoke-\(UUID().uuidString)", isDirectory: true)
let bus = EventBus(store: EventStore(directory: tempDir))

var event = KatoEvent(kind: .agentDone, title: "claude · kato", detail: "v1",
                      dedupeKey: "hook:done:ttys001")
await bus.ingest(event)
event.detail = "v2"
await bus.ingest(event)
var snapshot = await bus.snapshot()
check(snapshot.count == 1, "EventBus dedupes by dedupeKey", "count=\(snapshot.count)")
check(snapshot.first?.detail == "v2", "EventBus updates event in place")

// MARK: - EventStore persistence round-trip

let store = EventStore(directory: tempDir)
await store.save(snapshot)
let loaded = await store.load()
check(loaded.count == 1 && loaded.first?.detail == "v2", "EventStore save/load round-trip")

let bus2 = EventBus(store: EventStore(directory: tempDir))
await bus2.loadPersisted()
snapshot = await bus2.snapshot()
check(snapshot.count == 1, "EventBus.loadPersisted restores events")

// MARK: - TerminalTitleResolver

let target = TerminalTitleResolver.focusTarget(cwd: "/Users/jeremy/dev/kato", tty: "ttys001", pid: 4242)
check(target?.appBundleID == "com.mitchellh.ghostty", "resolver targets Ghostty")
check(target?.windowTitleToken == "kato", "resolver token = cwd basename", "token=\(target?.windowTitleToken ?? "nil")")
check(TerminalTitleResolver.focusTarget(cwd: nil, tty: nil, pid: nil) == nil, "resolver returns nil without cwd")

// MARK: - GitHubMonitor: one row per PR, updated in place

let prURL = "https://github.com/helm/pull/pull/7"
// Baseline watermarks older than the snapshot's signals: on a PR's FIRST
// appearance (no baseline), reviews/comments are baselined silently — only
// signals newer than an existing baseline emit.
var prWatermark = GitHubMonitor.PRWatermark(
    lastCommentAt: "2026-07-17T09:00:00Z",
    lastReviewAt: "2026-07-17T09:00:00Z"
)
let prSnapshot = GitHubMonitor.PRSnapshot(
    url: prURL,
    title: "Fix the thing",
    rollupState: "FAILURE",
    reviews: [GitHubMonitor.PRReviewSnapshot(state: "APPROVED",
                                             submittedAt: "2026-07-17T10:00:00Z", author: "bob")],
    comments: [GitHubMonitor.PRCommentSnapshot(createdAt: "2026-07-17T11:00:00Z", author: "alice")]
)

// One poll with CI failure + approval + comment on the SAME PR.
let signals = GitHubMonitor.diff(snapshot: prSnapshot, watermark: &prWatermark,
                                 seeding: false, viewerLogin: "me")
check(signals.count == 3, "diff collects CI + review + comment signals", "count=\(signals.count)")

let prEvent = GitHubMonitor.makeEvent(prURL: prURL, prTitle: prSnapshot.title, signals: signals)
check(prEvent != nil, "multiple signals on one PR collapse to exactly one event")
check(prEvent?.dedupeKey == "gh:pr:\(prURL)", "dedupeKey is gh:pr:<prURL>",
      prEvent?.dedupeKey ?? "nil")
check(prEvent?.kind == .ciFailed, "kind reflects highest-priority signal (ciFailed)",
      prEvent?.kind.rawValue ?? "nil")
check(prEvent?.title == "github · helm/pull", "title stays github · <owner/repo>",
      prEvent?.title ?? "nil")
check(prEvent?.detail == "CI failed · bob approved · alice commented — Fix the thing",
      "detail combines signals, highest priority first", prEvent?.detail ?? "nil")
check(prEvent?.url?.absoluteString == prURL, "event url is the PR url")

// Second identical poll → zero new signals (watermark semantics preserved).
let repeatSignals = GitHubMonitor.diff(snapshot: prSnapshot, watermark: &prWatermark,
                                       seeding: false, viewerLogin: "me")
check(repeatSignals.isEmpty, "second identical poll produces zero new signals")
check(GitHubMonitor.makeEvent(prURL: prURL, prTitle: prSnapshot.title,
                              signals: repeatSignals) == nil,
      "zero signals → zero events")

// Seeding (first run ever) is silent but still advances the watermark.
var seedWatermark = GitHubMonitor.PRWatermark()
let seededSignals = GitHubMonitor.diff(snapshot: prSnapshot, watermark: &seedWatermark,
                                       seeding: true, viewerLogin: "me")
check(seededSignals.isEmpty, "seeding emits nothing")
let afterSeedSignals = GitHubMonitor.diff(snapshot: prSnapshot, watermark: &seedWatermark,
                                          seeding: false, viewerLogin: "me")
check(afterSeedSignals.isEmpty, "no burst after seeding")

// Self-authored reviews/comments are ignored.
var selfWatermark = GitHubMonitor.PRWatermark()
let selfSnapshot = GitHubMonitor.PRSnapshot(
    url: prURL, title: "Fix the thing", rollupState: nil,
    reviews: [GitHubMonitor.PRReviewSnapshot(state: "COMMENTED",
                                             submittedAt: "2026-07-17T10:00:00Z", author: "me")],
    comments: [GitHubMonitor.PRCommentSnapshot(createdAt: "2026-07-17T10:00:00Z", author: "me")]
)
check(GitHubMonitor.diff(snapshot: selfSnapshot, watermark: &selfWatermark,
                         seeding: false, viewerLogin: "me").isEmpty,
      "self-authored reviews/comments are ignored")

// Priority: changes_requested beats comment beats CI passed.
let priorityEvent = GitHubMonitor.makeEvent(prURL: prURL, prTitle: "t", signals: [
    GitHubMonitor.PRSignal(priority: GitHubMonitor.PRSignalPriority.ciPassed,
                           kind: .ciPassed, text: "CI passed"),
    GitHubMonitor.PRSignal(priority: GitHubMonitor.PRSignalPriority.comment,
                           kind: .prComment, text: "alice commented"),
    GitHubMonitor.PRSignal(priority: GitHubMonitor.PRSignalPriority.changesRequested,
                           kind: .prReview, text: "bob requested changes"),
])
check(priorityEvent?.kind == .prReview, "changes_requested outranks comment + CI passed")
check(priorityEvent?.detail == "bob requested changes · alice commented · CI passed — t",
      "detail ordered by priority", priorityEvent?.detail ?? "nil")

// Notification subject API URLs map onto the same gh:pr:<htmlURL> key.
check(GitHubMonitor.htmlURL(forAPIURL: "https://api.github.com/repos/helm/pull/pulls/7")?.absoluteString == prURL,
      "notification API URL maps to the PR html URL")

// MARK: - MascotIdleRotation (idle personality cycle)

check(MascotIdleRotation.variants == ["kato-idle", "kato-idle-sleep", "kato-idle-play", "kato-idle-work"],
      "idle variants in spec order")
check(MascotIdleRotation.interval == 45, "rotation interval is ~45 s")

var rotation = MascotIdleRotation()
check(rotation.imageName == "kato-idle", "rotation starts at kato-idle")

let t0 = Date(timeIntervalSince1970: 1_000_000)
rotation.update(active: true, now: t0)
check(rotation.imageName == "kato-idle", "still base artwork right after entering idle")
rotation.update(active: true, now: t0.addingTimeInterval(44))
check(rotation.imageName == "kato-idle", "no swap before 45 s")
rotation.update(active: true, now: t0.addingTimeInterval(46))
check(rotation.imageName == "kato-idle-sleep", "first swap at ~45 s → kato-idle-sleep")
rotation.update(active: true, now: t0.addingTimeInterval(46 + 45))
check(rotation.imageName == "kato-idle-play", "second swap → kato-idle-play")
rotation.update(active: true, now: t0.addingTimeInterval(46 + 90))
check(rotation.imageName == "kato-idle-work", "third swap → kato-idle-work")
rotation.update(active: true, now: t0.addingTimeInterval(46 + 135))
check(rotation.imageName == "kato-idle", "wraps back to kato-idle")

// alert/success takeover resets the cycle; re-entering idle starts at base.
var takeover = MascotIdleRotation()
let t1 = t0.addingTimeInterval(300)
takeover.update(active: true, now: t1)
takeover.update(active: true, now: t1.addingTimeInterval(50))
check(takeover.imageName == "kato-idle-sleep", "advanced before takeover")
takeover.update(active: false, now: t1.addingTimeInterval(60))
check(takeover.imageName == "kato-idle", "non-idle state resets rotation to kato-idle")
takeover.update(active: true, now: t1.addingTimeInterval(70))
check(takeover.imageName == "kato-idle", "re-entering idle starts at kato-idle")

// MARK: - HookServer HTTP round-trip

final class Box: @unchecked Sendable { var event: KatoEvent? }
let box = Box()
let port: UInt16 = 17811
let server = HookServer(port: port) { received in
    box.event = received
}
do {
    try server.start()
} catch {
    check(false, "HookServer starts", "\(error)")
    exit(1)
}
try? await Task.sleep(for: .milliseconds(300))

// GET /health
if let (data, response) = try? await URLSession.shared.data(
    from: URL(string: "http://127.0.0.1:\(port)/health")!) {
    check((response as? HTTPURLResponse)?.statusCode == 200, "GET /health → 200")
    check(String(data: data, encoding: .utf8) == "ok", "GET /health → \"ok\"")
} else {
    check(false, "GET /health", "request failed")
}

// POST /event
var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/event")!)
request.httpMethod = "POST"
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.httpBody = Data(#"{"kind":"needsInput","title":"claude · kato","detail":"Waiting for confirmation","cwd":"/Users/jeremy/dev/kato","pid":4242}"#.utf8)
if let (_, response) = try? await URLSession.shared.data(for: request) {
    check((response as? HTTPURLResponse)?.statusCode == 200, "POST /event → 200")
} else {
    check(false, "POST /event", "request failed")
}

for _ in 0..<50 where box.event == nil {
    try? await Task.sleep(for: .milliseconds(100))
}
check(box.event != nil, "hook payload reaches the event handler")
if let received = box.event {
    check(received.kind == .agentNeedsInput, "kind alias needsInput → agentNeedsInput", "kind=\(received.kind)")
    check(received.title == "claude · kato", "event title decoded")
    check(received.detail == "Waiting for confirmation", "event detail decoded")
    check(received.focus?.windowTitleToken == "kato", "focus target built from cwd")
    check(received.focus?.processPID == 4242, "focus target carries pid")
}

// Unknown path → 404
if let (_, response) = try? await URLSession.shared.data(
    from: URL(string: "http://127.0.0.1:\(port)/nope")!) {
    check((response as? HTTPURLResponse)?.statusCode == 404, "unknown path → 404")
}

server.stop()
try? FileManager.default.removeItem(at: tempDir)

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
