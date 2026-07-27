import AppKit
import KatoCore
import SwiftUI

/// Menu-bar agent app (`LSUIElement` in the packaged .app; plain `swift run Kato`
/// also works). Two faces: floating NSPanel + menu-bar menu, both sharing
/// `EventListView`. See docs/ARCHITECTURE.md §"UI".
struct KatoApp: App {
    @StateObject private var appState: AppState

    init() {
        // App struct init runs on the main thread at launch; AppState is
        // @MainActor (its init reads the persisted mascotHidden preference).
        let state = MainActor.assumeIsolated { AppState() }
        _appState = StateObject(wrappedValue: state)
        // Start the hook server, monitors and bus subscription at launch.
        Task { @MainActor in state.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(appState)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "bolt.horizontal.circle")
                if appState.unreadCount > 0 {
                    Text("\(appState.unreadCount)")
                }
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var events: [KatoEvent] = []
    @Published var lastFocusError: String?
    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var mascotState: MascotState = .idle
    /// Effective artwork the orb should render (idle variants included).
    @Published private(set) var mascotImageName: String = MascotIdleRotation.variants[0]
    /// Increments on each fresh event — the mascot moves on every bump,
    /// even when its state didn't change (second alert in a row, …).
    @Published private(set) var activityTick = 0
    /// Menu-bar-only mode: the floating mascot orb/panel stays hidden.
    /// Persisted so the panel never appears across launches.
    @Published var mascotHidden: Bool {
        didSet { UserDefaults.standard.set(mascotHidden, forKey: Self.mascotHiddenDefaultsKey) }
    }
    nonisolated static let mascotHiddenDefaultsKey = "kato.mascotHidden"

    /// Newest event the user has viewed (panel expanded or menu opened).
    /// Persisted so restarts don't resurrect a badge for old events.
    @Published private(set) var lastSeenAt: Date {
        didSet { UserDefaults.standard.set(lastSeenAt.timeIntervalSince1970, forKey: Self.lastSeenAtDefaultsKey) }
    }
    nonisolated static let lastSeenAtDefaultsKey = "kato.lastSeenAt"

    /// Events collapsed by title for display (one row per "github · o/r" /
    /// "claude · project"), newest event as each group's representative.
    var groups: [EventGroup] { EventGrouping.group(events) }

    /// Groups with activity newer than the last time the user looked —
    /// drives the red badge. Viewing the panel/menu clears it.
    var unreadCount: Int {
        groups.filter { $0.representative.createdAt > lastSeenAt }.count
    }

    /// The user has seen everything currently in the list.
    func markSeen() {
        lastSeenAt = Date()
        recomputeMascotState() // alert face drops immediately, not on next tick
    }

    let bus = EventBus()
    private var hookServer: HookServer?
    private var monitors: [any Monitor] = []
    private var streamTask: Task<Void, Never>?
    private var panelController: FloatingPanelController?
    private var activationObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var lastEventAt: Date?
    private var idleRotation = MascotIdleRotation()
    private var didStart = false

    init() {
        _mascotHidden = Published(
            initialValue: UserDefaults.standard.bool(forKey: AppState.mascotHiddenDefaultsKey))
        let seen = UserDefaults.standard.double(forKey: AppState.lastSeenAtDefaultsKey)
        _lastSeenAt = Published(
            initialValue: seen > 0 ? Date(timeIntervalSince1970: seen) : .distantPast)
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        let bus = self.bus

        // 1. Hook server (127.0.0.1:7811) — Claude Code / Codex / `kato hook`.
        let server = HookServer { event in
            Task { await bus.ingest(event) }
        }
        do {
            try server.start()
        } catch {
            FileHandle.standardError.write(Data("kato: hook server failed to start: \(error)\n".utf8))
        }
        hookServer = server

        // 2. GitHub monitor (30 s polling via `gh`).
        let github = GitHubMonitor()
        github.start { event in
            Task { await bus.ingest(event) }
        }
        monitors.append(github)

        // 2b. Slack monitor (polls as the user; no-op without a token).
        startSlackMonitor()

        // 3. UI subscription.
        streamTask = Task { [weak self] in
            await bus.loadPersisted()
            let stream = await bus.stream()
            for await snapshot in stream {
                guard let self else { continue }
                // Treat a new top event (or count change) as fresh activity
                // for the mascot's success-decay window. The activity tick
                // (per-event movement) only bumps when events ARRIVE — not
                // on dismissals/clears (shrinking count) or in-place updates.
                if snapshot.count != self.events.count || snapshot.first?.id != self.events.first?.id {
                    self.lastEventAt = Date()
                    if snapshot.count > self.events.count
                        || (snapshot.count == self.events.count
                            && snapshot.first?.id != self.events.first?.id) {
                        self.activityTick += 1
                    }
                }
                self.events = snapshot
                // Events arriving while the panel is already open are on
                // screen, so they never become "unread".
                if self.panelController?.expanded == true, self.unreadCount > 0 {
                    self.markSeen()
                }
                self.recomputeMascotState()
            }
        }

        // 4. Accessibility-permission status. TCC changes don't notify, so
        //    re-check on app activation and on a lightweight timer.
        refreshAccessibilityStatus()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAccessibilityStatus() }
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAccessibilityStatus()
                self?.recomputeMascotState() // success → idle decay check
            }
        }

        // 5. Show the floating orb immediately — the mascot is the app's
        //    primary face, so it's visible without a menu click (unless the
        //    user chose menu-bar-only mode).
        if !mascotHidden {
            showPanel()
        }
    }

    func showPanel() {
        if panelController == nil {
            panelController = FloatingPanelController(appState: self)
        }
    }

    /// Menu-bar-only mode on/off. Hiding closes the panel; showing brings
    /// the orb back.
    func setMascotHidden(_ hidden: Bool) {
        mascotHidden = hidden
        if hidden {
            panelController?.close()
            panelController = nil
        } else {
            showPanel()
        }
    }

    // MARK: - Mascot state

    func recomputeMascotState() {
        mascotState = MascotState.resolve(events: events, lastEventAt: lastEventAt, lastSeenAt: lastSeenAt)
        // Idle personality rotation (driven by the 5 s timer / event updates;
        // resets to kato-idle whenever alert/success takes over).
        idleRotation.update(active: mascotState == .idle)
        mascotImageName = mascotState == .idle ? idleRotation.imageName : mascotState.imageName
    }

    // MARK: - Accessibility permission

    func refreshAccessibilityStatus() {
        accessibilityTrusted = FocusController.isAccessibilityTrusted()
    }

    /// Opens System Settings → Privacy & Security → Accessibility (after
    /// registering Kato in the TCC list via the system prompt path).
    func fixAccessibilityPermission() {
        AccessibilityPermission.openSystemSettings()
        refreshAccessibilityStatus()
    }

    func togglePanel() {
        refreshAccessibilityStatus()
        if mascotHidden {
            setMascotHidden(false)
            return
        }
        if panelController == nil {
            panelController = FloatingPanelController(appState: self)
        }
        panelController?.toggle()
    }

    /// Event row click → focus the terminal window/tab if we know how,
    /// otherwise open the web deep link (reusing an existing browser tab).
    func select(_ event: KatoEvent) {
        if var focus = event.focus {
            // Recycled-TTY guard: Darwin hands out the lowest free pty
            // number, so a stale event's TTY may now belong to an unrelated
            // tab. Keep the deterministic marker path only when the
            // originating process still owns the TTY — or, for events
            // without a pid, when the event is fresh.
            if let tty = focus.tty, !tty.isEmpty, !Self.ttyStampingSafe(for: event) {
                focus.tty = nil
            }
            switch FocusController().focus(focus) {
            case .success:
                lastFocusError = nil
            case .failure(let error):
                lastFocusError = error.description
                FileHandle.standardError.write(Data("kato: focus failed: \(error)\n".utf8))
                refreshAccessibilityStatus()
                if case .accessibilityNotTrusted = error {
                    // Surface an actionable alert instead of failing silently.
                    AccessibilityPermission.presentAlert()
                } else if let url = event.url {
                    BrowserOpener.open(url)
                }
            }
        } else if let url = event.url {
            BrowserOpener.open(url)
        }
    }

    /// Is the TTY-stamping focus path safe for this event? With a pid we
    /// verify the process still owns the TTY; without one we trust only
    /// fresh events (pty numbers get recycled over time).
    private static func ttyStampingSafe(for event: KatoEvent) -> Bool {
        guard let focus = event.focus, let tty = focus.tty, !tty.isEmpty else { return false }
        if let pid = focus.processPID {
            return TabMarker.verifyOwnership(pid: pid, tty: tty)
        }
        return Date().timeIntervalSince(event.createdAt) < 30 * 60
    }

    /// Dismiss a single event (per-row × button).
    func delete(_ event: KatoEvent) {
        Task { await bus.remove(ids: [event.id]) }
    }

    /// Dismiss a whole group (group-header × button).
    func delete(_ group: EventGroup) {
        Task { await bus.remove(ids: group.events.map(\.id)) }
    }

    func clear() {
        Task { await bus.clear() }
    }

    // MARK: - Slack settings

    /// Last status line from the Slack monitor ("connected as @you", auth
    /// failures, …), shown in the settings pane.
    @Published private(set) var slackStatus: String?
    private var slackMonitor: SlackMonitor?

    private func startSlackMonitor() {
        let slack = SlackMonitor()
        // Retract condition-based events when they clear (unread-marked DMs
        // read again) instead of leaving them for manual dismissal.
        slack.onRemove = { [bus] dedupeKey in
            Task { await bus.remove(dedupeKeys: [dedupeKey]) }
        }
        slack.onStatus = { [weak self] status in
            Task { @MainActor in self?.slackStatus = status }
        }
        slack.start { [bus] event in
            Task { await bus.ingest(event) }
        }
        slackMonitor = slack
    }

    /// Current Slack settings as written in the app-support dir, for
    /// pre-filling the settings pane.
    func loadSlackSettings() -> (userToken: String, clientID: String, clientSecret: String, refreshToken: String) {
        let dir = EventStore.defaultDirectory
        var result = ("", "", "", "")
        if let plain = try? String(contentsOf: dir.appendingPathComponent("slack-user-token"), encoding: .utf8) {
            result.0 = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("slack-user-token.json")) {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            if let stored = try? decoder.decode(SlackUserTokenBox.Stored.self, from: data) {
                result.0 = stored.accessToken ?? result.0
                result.1 = stored.clientID ?? ""
                result.2 = stored.clientSecret ?? ""
                result.3 = stored.refreshToken ?? ""
            }
        }
        return result
    }

    /// Persist Slack settings from the settings pane and restart the
    /// monitor. A refresh token switches to the rotating-workspace JSON
    /// format; empty user token removes the configuration entirely.
    func saveSlackSettings(userToken: String, clientID: String, clientSecret: String, refreshToken: String) {
        let dir = EventStore.defaultDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plainFile = dir.appendingPathComponent("slack-user-token")
        let jsonFile = dir.appendingPathComponent("slack-user-token.json")
        try? FileManager.default.removeItem(at: plainFile)
        try? FileManager.default.removeItem(at: jsonFile)

        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let token = trimmed(userToken)
        if !token.isEmpty {
            if !trimmed(refreshToken).isEmpty {
                let stored = SlackUserTokenBox.Stored(
                    accessToken: token,
                    refreshToken: trimmed(refreshToken),
                    clientID: trimmed(clientID),
                    clientSecret: trimmed(clientSecret))
                let encoder = JSONEncoder()
                encoder.keyEncodingStrategy = .convertToSnakeCase
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(stored) {
                    try? data.write(to: jsonFile, options: .atomic)
                }
            } else {
                try? token.write(to: plainFile, atomically: true, encoding: .utf8)
            }
        }

        slackStatus = nil
        slackMonitor?.stop()
        startSlackMonitor()
    }

    func requestAccessibility() {
        AccessibilityPermission.openSystemSettings()
        refreshAccessibilityStatus()
    }
}
