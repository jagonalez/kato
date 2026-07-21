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

// tmux/tty pass-through (empty strings normalize to nil).
let tmuxTarget = TerminalTitleResolver.focusTarget(cwd: "/tmp/x", tty: "ttys021", pid: nil, tmux: "work:2.1")
check(tmuxTarget?.tmuxTarget == "work:2.1", "resolver carries tmux target")
check(tmuxTarget?.tty == "ttys021", "resolver carries tty")
let emptyTmux = TerminalTitleResolver.focusTarget(cwd: "/tmp/x", tty: "", pid: nil, tmux: "")
check(emptyTmux?.tmuxTarget == nil && emptyTmux?.tty == nil, "empty tmux/tty normalize to nil")

// cmux pass-through: a carried surface id switches the bundle id to cmux's.
let cmuxTarget = TerminalTitleResolver.focusTarget(cwd: "/Users/jeremy/dev/kato", tty: "ttys030",
                                                   pid: 42, cmuxWorkspace: "w1", cmuxSurface: "s1")
check(cmuxTarget?.appBundleID == "com.cmuxterm.app", "cmux surface id switches bundle id",
      cmuxTarget?.appBundleID ?? "nil")
check(cmuxTarget?.cmuxWorkspace == "w1" && cmuxTarget?.cmuxSurface == "s1", "resolver carries cmux ids")
check(cmuxTarget?.windowTitleToken == "kato", "cmux target keeps cwd-basename token")
let emptyCmux = TerminalTitleResolver.focusTarget(cwd: "/tmp/x", tty: nil, pid: nil,
                                                  cmuxWorkspace: "", cmuxSurface: "")
check(emptyCmux?.cmuxSurface == nil && emptyCmux?.appBundleID == "com.mitchellh.ghostty",
      "empty cmux ids normalize to nil (stays Ghostty)")

// MARK: - FocusTarget Codable (cmux fields)

do {
    let target = FocusTarget(appBundleID: "com.cmuxterm.app", windowTitleToken: "kato",
                             cmuxWorkspace: "w1", cmuxSurface: "s1")
    let data = try JSONEncoder().encode(target)
    check(try JSONDecoder().decode(FocusTarget.self, from: data) == target,
          "FocusTarget codable round-trip with cmux fields")
    // Events persisted BEFORE the cmux fields existed must still decode.
    let legacy = Data(#"{"appBundleID":"com.mitchellh.ghostty","windowTitleToken":"kato"}"#.utf8)
    let decoded = try JSONDecoder().decode(FocusTarget.self, from: legacy)
    check(decoded.windowTitleToken == "kato" && decoded.cmuxSurface == nil,
          "legacy FocusTarget JSON decodes (cmux keys optional)")
} catch {
    check(false, "FocusTarget codable", "\(error)")
}

// MARK: - CmuxResolver (socket API focus path)

check(CmuxResolver.socketPath(environment: [:]) == "/tmp/cmux.sock", "cmux socket path default")
check(CmuxResolver.socketPath(environment: ["CMUX_SOCKET_PATH": "/tmp/x.sock"]) == "/tmp/x.sock",
      "cmux socket path env override")
check(CmuxResolver.socketPath(environment: ["CMUX_SOCKET_PATH": ""]) == "/tmp/cmux.sock",
      "cmux socket path empty override falls back to default")
let cmuxRequest = CmuxResolver.request(id: "kato-focus", method: "surface.focus",
                                       params: ["surface_id": "abc"])
check(cmuxRequest == #"{"id":"kato-focus","method":"surface.focus","params":{"surface_id":"abc"}}"# + "\n",
      "cmux request framing: sorted keys, newline-terminated", cmuxRequest)
check(CmuxResolver.isOK(response: #"{"id":"1","ok":true,"result":{}}"#), "cmux ok response")
check(!CmuxResolver.isOK(response: #"{"id":"1","ok":false,"error":"denied"}"#), "cmux error response")
check(!CmuxResolver.isOK(response: "not json"), "cmux malformed response")
check(CmuxResolver.focus(target: FocusTarget(appBundleID: "com.cmuxterm.app",
                                             windowTitleToken: "kato")) == nil,
      "cmux focus nil without surface id")
check(CmuxResolver.focus(target: FocusTarget(appBundleID: "com.cmuxterm.app",
                                             windowTitleToken: "kato", cmuxSurface: "s1"),
                         socketPath: "/tmp/kato-smoke-nonexistent-\(UUID().uuidString).sock") == nil,
      "cmux focus nil when socket absent")
check(CmuxResolver.focus(target: FocusTarget(appBundleID: "com.cmuxterm.app",
                                             windowTitleToken: "kato", cmuxWorkspace: "w1", cmuxSurface: "s1"),
                         socketPath: "/tmp") == nil,
      "cmux focus nil when socket path is not a socket")

// A fake cmux socket: accept two connections (workspace.select + surface.focus),
// capture the request lines, reply ok — verifies the full focus round-trip.
let fakeSockPath = "/tmp/kato-smoke-cmux-\(UUID().uuidString).sock"
final class FakeCmux: @unchecked Sendable {
    var lines: [String] = []
    func serve(path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        Array(path.utf8).withUnsafeBytes { source in
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyMemory(from: source) }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 2) == 0 else { return -1 }
        return fd
    }
    func reply(fd: Int32) {
        var byte = UInt8(0)
        var line = ""
        while read(fd, &byte, 1) == 1 {
            if byte == 0x0A { break }
            line.append(Character(UnicodeScalar(byte)))
        }
        lines.append(line)
        let ok = #"{"id":"r","ok":true,"result":{}}"#
        _ = ok.withCString { write(fd, $0, strlen($0)) }
        _ = write(fd, "\n", 1)
        close(fd)
    }
}
let fake = FakeCmux()
let listenFD = fake.serve(path: fakeSockPath)
check(listenFD >= 0, "fake cmux socket binds")
if listenFD >= 0 {
    let server = Thread {
        for _ in 0..<2 {
            let client = accept(listenFD, nil, nil)
            if client >= 0 { fake.reply(fd: client) }
        }
        close(listenFD)
    }
    server.start()
    let focused = CmuxResolver.focus(
        target: FocusTarget(appBundleID: "com.cmuxterm.app", windowTitleToken: "kato",
                            cmuxWorkspace: "w1", cmuxSurface: "s1"),
        socketPath: fakeSockPath)
    unlink(fakeSockPath)
    // focus() is synchronous — the server thread may just be finishing up.
    for _ in 0..<50 where fake.lines.count < 2 {
        try? await Task.sleep(for: .milliseconds(20))
    }
    check(focused == "s1", "cmux focus round-trip returns the surface id", focused ?? "nil")
    check(fake.lines.count == 2, "cmux focus sent workspace.select + surface.focus",
          "\(fake.lines.count) request(s)")
    check(fake.lines.first?.contains(#"workspace.select"#) == true
          && fake.lines.first?.contains(#""workspace_id":"w1""#) == true,
          "workspace.select carries the workspace id", fake.lines.first ?? "nil")
    check(fake.lines.last?.contains(#"surface.focus"#) == true
          && fake.lines.last?.contains(#""surface_id":"s1""#) == true,
          "surface.focus carries the surface id", fake.lines.last ?? "nil")
}

// MARK: - HerdrResolver (socket API pane focus)

check(HerdrResolver.isOK(response: #"{"id":"1","result":{"type":"pane_info"}}"#),
      "herdr result response")
check(!HerdrResolver.isOK(response: #"{"id":"1","error":{"code":"not_found","message":"pane not found"}}"#),
      "herdr error response")
check(!HerdrResolver.isOK(response: "not json"), "herdr malformed response")
check(HerdrResolver.focus(target: FocusTarget(appBundleID: "com.mitchellh.ghostty",
                                              windowTitleToken: "kato")) == nil,
      "herdr focus nil without pane id")
check(HerdrResolver.focus(target: FocusTarget(appBundleID: "com.mitchellh.ghostty",
                                              windowTitleToken: "kato",
                                              herdrSocket: "/tmp/kato-smoke-nonexistent-\(UUID().uuidString).sock",
                                              herdrPane: "w1:p1")) == nil,
      "herdr focus nil when socket absent")

// Fake herdr server: expect workspace.focus → tab.focus → agent.focus.
let herdrSockPath = "/tmp/kato-smoke-herdr-\(UUID().uuidString).sock"
let herdrFake = FakeCmux()
let herdrFD = herdrFake.serve(path: herdrSockPath)
check(herdrFD >= 0, "fake herdr socket binds")
if herdrFD >= 0 {
    let herdrServer = Thread {
        for _ in 0..<3 {
            let client = accept(herdrFD, nil, nil)
            if client >= 0 { herdrFake.reply(fd: client) }
        }
        close(herdrFD)
    }
    herdrServer.start()
    let focused = HerdrResolver.focus(
        target: FocusTarget(appBundleID: "com.mitchellh.ghostty", windowTitleToken: "kato",
                            herdrSocket: herdrSockPath, herdrWorkspace: "w1",
                            herdrTab: "w1:t1", herdrPane: "w1:p1"))
    unlink(herdrSockPath)
    for _ in 0..<50 where herdrFake.lines.count < 3 {
        try? await Task.sleep(for: .milliseconds(20))
    }
    check(focused == "w1:p1", "herdr focus round-trip returns the pane id", focused ?? "nil")
    check(herdrFake.lines.count == 3, "herdr focus sent workspace + tab + agent focus",
          "\(herdrFake.lines.count) request(s)")
    check(herdrFake.lines.count > 0 && herdrFake.lines[0].contains("workspace.focus")
          && herdrFake.lines[0].contains(#""workspace_id":"w1""#),
          "workspace.focus carries the workspace id", herdrFake.lines.first ?? "nil")
    check(herdrFake.lines.count > 1 && herdrFake.lines[1].contains("tab.focus")
          && herdrFake.lines[1].contains(#""tab_id":"w1:t1""#),
          "tab.focus carries the tab id", herdrFake.lines.count > 1 ? herdrFake.lines[1] : "nil")
    check(herdrFake.lines.count > 2 && herdrFake.lines[2].contains("agent.focus")
          && herdrFake.lines[2].contains(#""target":"w1:p1""#),
          "agent.focus targets the pane", herdrFake.lines.count > 2 ? herdrFake.lines[2] : "nil")
}

// herdr pass-through: ids carried, outer app stays Ghostty (herdr is a TUI inside it).
let herdrTarget = TerminalTitleResolver.focusTarget(cwd: "/Users/jeremy/dev/kato", tty: "ttys040",
                                                    pid: 42, herdrSocket: "/tmp/h.sock",
                                                    herdrWorkspace: "w1", herdrTab: "w1:t1",
                                                    herdrPane: "w1:p1")
check(herdrTarget?.appBundleID == "com.mitchellh.ghostty", "herdr keeps the outer bundle id",
      herdrTarget?.appBundleID ?? "nil")
check(herdrTarget?.herdrSocket == "/tmp/h.sock" && herdrTarget?.herdrWorkspace == "w1"
      && herdrTarget?.herdrTab == "w1:t1" && herdrTarget?.herdrPane == "w1:p1",
      "resolver carries herdr ids")
let emptyHerdr = TerminalTitleResolver.focusTarget(cwd: "/tmp/x", tty: nil, pid: nil,
                                                   herdrSocket: "", herdrWorkspace: "",
                                                   herdrTab: "", herdrPane: "")
check(emptyHerdr?.herdrPane == nil, "empty herdr ids normalize to nil")

do {
    let target = FocusTarget(appBundleID: "com.mitchellh.ghostty", windowTitleToken: "kato",
                             herdrWorkspace: "w1", herdrTab: "w1:t1", herdrPane: "w1:p1")
    let data = try JSONEncoder().encode(target)
    check(try JSONDecoder().decode(FocusTarget.self, from: data) == target,
          "FocusTarget codable round-trip with herdr fields")
} catch {
    check(false, "FocusTarget herdr codable", "\(error)")
}

// MARK: - TmuxResolver (pure parsing; no tmux server needed)

let listPanes = """
ttys020 work:0.0
ttys021 work:1.0
/dev/ttys099 other:3.2
"""
check(TmuxResolver.target(forTTY: "ttys021", inListPanesOutput: listPanes) == "work:1.0",
      "tmux resolver maps tty to session:window.pane")
check(TmuxResolver.target(forTTY: "/dev/ttys021", inListPanesOutput: listPanes) == "work:1.0",
      "tmux resolver tolerates /dev/ prefix on query")
check(TmuxResolver.target(forTTY: "ttys099", inListPanesOutput: listPanes) == "other:3.2",
      "tmux resolver tolerates /dev/ prefix in list-panes output")
check(TmuxResolver.target(forTTY: "ttys777", inListPanesOutput: listPanes) == nil,
      "tmux resolver returns nil for unknown tty")
check(TmuxResolver.target(forTTY: "", inListPanesOutput: listPanes) == nil,
      "tmux resolver returns nil for empty tty")

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

// MARK: - SlackMonitor (Socket Mode envelope parsing)

let mentionEnvelope: [String: Any] = [
    "envelope_id": "e1",
    "type": "events_api",
    "payload": [
        "team_id": "T1",
        "event": [
            "type": "app_mention",
            "user": "U2",
            "text": "<@U9> can you review <https://github.com/x/y/pull/1|the PR>?",
            "ts": "1700000000.000100",
            "channel": "C1",
        ],
    ],
]
let mention = SlackMonitor.makeEvent(envelope: mentionEnvelope)
check(mention?.kind == .slackMention, "app_mention → slackMention")
check(mention?.dedupeKey == "slack:C1:1700000000.000100", "dedupeKey is slack:<channel>:<ts>",
      mention?.dedupeKey ?? "nil")
check(mention?.url?.absoluteString == "slack://channel?team=T1&id=C1&message=p1700000000000100",
      "url is the slack:// deep link", mention?.url?.absoluteString ?? "nil")
check(mention?.detail == "@U9 can you review the PR?", "mrkdwn stripped from detail",
      mention?.detail ?? "nil")
check(mention?.focus == nil, "slack events never carry a focus target")
check(mention?.createdAt == Date(timeIntervalSince1970: 1700000000.0001),
      "createdAt comes from the slack ts")

let dmEnvelope: [String: Any] = [
    "type": "events_api",
    "payload": [
        "team_id": "T1",
        "event": [
            "type": "message", "channel_type": "im",
            "user": "U2", "text": "ship it?",
            "ts": "1700000001.000200", "channel": "D1",
        ],
    ],
]
check(SlackMonitor.makeEvent(envelope: dmEnvelope)?.kind == .slackDM, "IM message → slackDM")

// Channel message naming the configured user → mention; without config → nil.
let channelPing: [String: Any] = [
    "type": "events_api",
    "payload": [
        "team_id": "T1",
        "event": [
            "type": "message", "channel_type": "channel",
            "user": "U2", "text": "<@U5> ping",
            "ts": "1700000002.000300", "channel": "C2",
        ],
    ],
]
check(SlackMonitor.makeEvent(envelope: channelPing, selfUserID: "U5")?.kind == .slackMention,
      "channel message naming selfUserID → slackMention")
check(SlackMonitor.makeEvent(envelope: channelPing) == nil,
      "channel message ignored without selfUserID")

// Bots, subtypes (edits/joins), and non-events_api envelopes are ignored.
var botMessage = channelPing
if var payload = botMessage["payload"] as? [String: Any],
   var event = payload["event"] as? [String: Any] {
    event["bot_id"] = "B1"
    payload["event"] = event
    botMessage["payload"] = payload
}
check(SlackMonitor.makeEvent(envelope: botMessage, selfUserID: "U5") == nil, "bot messages ignored")
var edited = channelPing
if var payload = edited["payload"] as? [String: Any],
   var event = payload["event"] as? [String: Any] {
    event["subtype"] = "message_changed"
    payload["event"] = event
    edited["payload"] = payload
}
check(SlackMonitor.makeEvent(envelope: edited, selfUserID: "U5") == nil, "subtype messages ignored")
check(SlackMonitor.makeEvent(envelope: ["type": "hello"]) == nil, "non-events_api envelopes ignored")

// Envelope bookkeeping.
check(SlackMonitor.ackID(forEnvelope: mentionEnvelope) == "e1", "ackID extracts envelope_id")
check(SlackMonitor.shouldReconnect(envelope: ["type": "disconnect"]), "disconnect frame → reconnect")
check(!SlackMonitor.shouldReconnect(envelope: mentionEnvelope), "events_api frame → no reconnect")

// cleanText coverage.
check(SlackMonitor.cleanText("<!channel> heads up") == "@channel heads up", "broadcast token")
check(SlackMonitor.cleanText("<#C1|general> standup in 5") == "#general standup in 5", "channel token")
check(SlackMonitor.cleanText("<@U1|bob> hi") == "@bob hi", "user token with label")
check(SlackMonitor.cleanText("see <https://example.com>") == "see https://example.com", "bare link")
check(SlackMonitor.cleanText("a\nb   c") == "a b c", "whitespace collapses")
check(SlackMonitor.cleanText(String(repeating: "x", count: 300)).count == 200, "truncates at 200")
check(SlackMonitor.cleanText("unclosed <tag") == "unclosed <tag", "unclosed < survives")

// Token resolution: explicit > env > file.
let slackTemp = FileManager.default.temporaryDirectory
    .appendingPathComponent("kato-smoke-slack-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: slackTemp, withIntermediateDirectories: true)
try? "xapp-file\n".write(to: slackTemp.appendingPathComponent("slack-app-token"),
                         atomically: true, encoding: .utf8)
check(SlackMonitor.resolveToken(explicit: "xapp-arg",
                                environment: ["KATO_SLACK_APP_TOKEN": "xapp-env"],
                                stateDirectory: slackTemp) == "xapp-arg", "token: explicit wins")
check(SlackMonitor.resolveToken(explicit: nil,
                                environment: ["KATO_SLACK_APP_TOKEN": "xapp-env"],
                                stateDirectory: slackTemp) == "xapp-env", "token: env beats file")
check(SlackMonitor.resolveToken(explicit: nil, environment: [:],
                                stateDirectory: slackTemp) == "xapp-file",
      "token: file fallback, trimmed")
check(SlackMonitor.resolveToken(explicit: nil, environment: [:],
                                stateDirectory: slackTemp.deletingLastPathComponent()
                                    .appendingPathComponent("kato-smoke-none-\(UUID().uuidString)")) == nil,
      "token: nil when nothing configured")
try? FileManager.default.removeItem(at: slackTemp)

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

// MARK: - FocusController.matchScore (wrong-tab regression)

check(FocusController.matchScore(title: "kato", token: "kato") == 4, "matchScore: exact = 4")
check(FocusController.matchScore(title: "Kato", token: "kato") == 3, "matchScore: case-insensitive exact = 3")
check(FocusController.matchScore(title: "kato — claude", token: "kato") == 2, "matchScore: prefix = 2")
check(FocusController.matchScore(title: "work · kato", token: "kato") == 1, "matchScore: substring = 1")
check(FocusController.matchScore(title: "other", token: "kato") == 0, "matchScore: no match = 0")
check(FocusController.matchScore(title: "kato", token: "kato")
      > FocusController.matchScore(title: "kato-fork", token: "kato"),
      "exact tab beats an earlier substring-only tab (wrong-tab fix)")

// MARK: - EventGrouping (one row per title, newest first)

let g1 = KatoEvent(kind: .ciFailed, title: "github · helm/pull", detail: "CI failed",
                   createdAt: Date(timeIntervalSince1970: 300), dedupeKey: "gh:pr:u1")
let g2 = KatoEvent(kind: .agentDone, title: "claude · kato", detail: "done",
                   createdAt: Date(timeIntervalSince1970: 200), dedupeKey: "hook:done:t1")
let g3 = KatoEvent(kind: .prComment, title: "github · helm/pull", detail: "alice commented",
                   createdAt: Date(timeIntervalSince1970: 100), dedupeKey: "gh:pr:u2")
// Bus order is newest-first; grouping must preserve first-appearance order.
let groups = EventGrouping.group([g1, g2, g3])
check(groups.count == 2, "10-rows-per-repo collapse into one group", "count=\(groups.count)")
check(groups.first?.key == "github · helm/pull", "group order follows newest event")
check(groups.first?.events.count == 2, "group keeps all events")
check(groups.first?.representative.detail == "CI failed",
      "representative is the newest event", groups.first?.representative.detail ?? "nil")

// MARK: - EventBus.remove (per-row / group dismiss)

let bus3 = EventBus(store: EventStore(directory: tempDir))
await bus3.ingest(g1)
await bus3.ingest(g2)
await bus3.ingest(g3)
await bus3.remove(ids: [g1.id])
var snapshot3 = await bus3.snapshot()
check(snapshot3.count == 2 && !snapshot3.contains(where: { $0.id == g1.id }),
      "EventBus.remove deletes one event")
let groupIDs = EventGrouping.group(snapshot3).first(where: { $0.key == "github · helm/pull" })?
    .events.map(\.id) ?? []
await bus3.remove(ids: groupIDs)
snapshot3 = await bus3.snapshot()
check(snapshot3.count == 1 && snapshot3.first?.title == "claude · kato",
      "EventBus.remove deletes a whole group")
let reloaded = EventStore(directory: tempDir)
check(await reloaded.load().count == 1, "removals persist to disk")

// MARK: - BrowserOpener.comparisonKey (tab reuse matching)

if let u = URL(string: "HTTPS://GitHub.COM/helm/pull/pull/7/?notification_referrer_id=1#diff") {
    check(BrowserOpener.comparisonKey(for: u) == "https://github.com/helm/pull/pull/7",
          "comparisonKey strips query/fragment/trailing slash, lowercases scheme+host",
          BrowserOpener.comparisonKey(for: u))
} else {
    check(false, "comparisonKey test URL parses")
}

// MARK: - TabMarker (deterministic Ghostty tab identification via TTY)

check(TabMarker.needle(tty: "ttys021") == " ⌁ttys021", "marker needle")
check(TabMarker.needle(tty: "/dev/ttys021") == " ⌁ttys021", "marker needle tolerates /dev/ prefix")
check(TabMarker.stampedTitle(token: "kato", tty: "ttys021") == "● kato ⌁ttys021", "stamped title")
check(TabMarker.normalize(tty: " /dev/ttys099 ") == "ttys099", "tty normalize trims + strips /dev/")
check(TabMarker.stampedTitle(token: "kato", tty: "ttys021").contains(TabMarker.needle(tty: "ttys021")),
      "stamped title contains its own needle")
check(!TabMarker.stampedTitle(token: "kato", tty: "ttys021").contains(TabMarker.needle(tty: "ttys210")),
      "needle is tty-specific (no false hits)")
check(TabMarker.verifyOwnership(pid: 99999999, tty: "ttys021") == false,
      "ownership fails for dead pid (recycled-tty guard)")
check(TabMarker.verifyOwnership(pid: 1, tty: "") == false,
      "ownership fails for empty tty")
check(TabMarker.verifyOwnership(pid: 1, tty: "ttys021") == false,
      "launchd (no controlling tty) fails ownership")

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
request.httpBody = Data(#"{"kind":"needsInput","title":"claude · kato","detail":"Waiting for confirmation","cwd":"/Users/jeremy/dev/kato","pid":4242,"tty":"ttys021","tmux":"work:2.1"}"#.utf8)
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
    check(received.focus?.tmuxTarget == "work:2.1", "focus target carries tmux target",
          received.focus?.tmuxTarget ?? "nil")
    check(received.focus?.tty == "ttys021", "focus target carries tty",
          received.focus?.tty ?? "nil")
}

// Unknown path → 404
if let (_, response) = try? await URLSession.shared.data(
    from: URL(string: "http://127.0.0.1:\(port)/nope")!) {
    check((response as? HTTPURLResponse)?.statusCode == 404, "unknown path → 404")
}

// cmux ids in the payload land on the focus target (deterministic cmux path).
box.event = nil
var cmuxPost = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/event")!)
cmuxPost.httpMethod = "POST"
cmuxPost.setValue("application/json", forHTTPHeaderField: "Content-Type")
cmuxPost.httpBody = Data(#"{"kind":"done","title":"claude · cmux-proj","cwd":"/tmp/cmux-proj","tty":"ttys031","cmuxWorkspace":"w9","cmuxSurface":"s9"}"#.utf8)
if let (_, response) = try? await URLSession.shared.data(for: cmuxPost) {
    check((response as? HTTPURLResponse)?.statusCode == 200, "POST /event with cmux ids → 200")
} else {
    check(false, "POST /event with cmux ids", "request failed")
}
for _ in 0..<50 where box.event == nil {
    try? await Task.sleep(for: .milliseconds(100))
}
check(box.event?.focus?.cmuxWorkspace == "w9" && box.event?.focus?.cmuxSurface == "s9",
      "hook cmux ids land on the focus target",
      "\(box.event?.focus?.cmuxWorkspace ?? "nil")/\(box.event?.focus?.cmuxSurface ?? "nil")")
check(box.event?.focus?.appBundleID == "com.cmuxterm.app",
      "cmux hook event targets the cmux app", box.event?.focus?.appBundleID ?? "nil")
check(box.event?.focus?.windowTitleToken == "cmux-proj",
      "cmux hook event keeps the cwd-basename token")

// herdr ids in the payload land on the focus target (server-side pane focus).
box.event = nil
var herdrPost = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/event")!)
herdrPost.httpMethod = "POST"
herdrPost.setValue("application/json", forHTTPHeaderField: "Content-Type")
herdrPost.httpBody = Data(#"{"kind":"needsInput","title":"claude · herdr-proj","cwd":"/tmp/herdr-proj","tty":"ttys041","herdrSocket":"/tmp/h.sock","herdrWorkspace":"w1","herdrTab":"w1:t1","herdrPane":"w1:p1"}"#.utf8)
if let (_, response) = try? await URLSession.shared.data(for: herdrPost) {
    check((response as? HTTPURLResponse)?.statusCode == 200, "POST /event with herdr ids → 200")
} else {
    check(false, "POST /event with herdr ids", "request failed")
}
for _ in 0..<50 where box.event == nil {
    try? await Task.sleep(for: .milliseconds(100))
}
check(box.event?.focus?.herdrWorkspace == "w1" && box.event?.focus?.herdrTab == "w1:t1"
      && box.event?.focus?.herdrPane == "w1:p1" && box.event?.focus?.herdrSocket == "/tmp/h.sock",
      "hook herdr ids land on the focus target")
check(box.event?.focus?.appBundleID == "com.mitchellh.ghostty",
      "herdr hook event keeps the outer (Ghostty) bundle id",
      box.event?.focus?.appBundleID ?? "nil")

// herdr INSIDE cmux: both env sets ride along; herdr focuses the pane
// server-side, cmux raises the exact outer surface (fully deterministic).
box.event = nil
var bothPost = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/event")!)
bothPost.httpMethod = "POST"
bothPost.setValue("application/json", forHTTPHeaderField: "Content-Type")
bothPost.httpBody = Data(#"{"kind":"done","title":"claude · both-proj","cwd":"/tmp/both-proj","tty":"ttys042","cmuxWorkspace":"cw1","cmuxSurface":"cs1","herdrSocket":"/tmp/h.sock","herdrWorkspace":"w1","herdrTab":"w1:t1","herdrPane":"w1:p1"}"#.utf8)
if let (_, response) = try? await URLSession.shared.data(for: bothPost) {
    check((response as? HTTPURLResponse)?.statusCode == 200, "POST /event with cmux+herdr ids → 200")
} else {
    check(false, "POST /event with cmux+herdr ids", "request failed")
}
for _ in 0..<50 where box.event == nil {
    try? await Task.sleep(for: .milliseconds(100))
}
check(box.event?.focus?.cmuxSurface == "cs1" && box.event?.focus?.herdrPane == "w1:p1",
      "hook event carries BOTH cmux and herdr ids")
check(box.event?.focus?.appBundleID == "com.cmuxterm.app",
      "cmux+herdr event targets the cmux app (outer terminal)",
      box.event?.focus?.appBundleID ?? "nil")

server.stop()
try? FileManager.default.removeItem(at: tempDir)

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
