import AppKit
import KatoCore
import SwiftUI

/// Menu-bar agent app (`LSUIElement` in the packaged .app; plain `swift run Kato`
/// also works). Two faces: floating NSPanel + menu-bar menu, both sharing
/// `EventListView`. See docs/ARCHITECTURE.md §"UI".
struct KatoApp: App {
    @StateObject private var appState: AppState

    init() {
        let state = AppState()
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
                if !appState.events.isEmpty {
                    Text("\(appState.events.count)")
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

    let bus = EventBus()
    private var hookServer: HookServer?
    private var monitors: [any Monitor] = []
    private var streamTask: Task<Void, Never>?
    private var panelController: FloatingPanelController?
    private var activationObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var lastEventAt: Date?
    private var didStart = false

    nonisolated init() {}

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

        // 3. UI subscription.
        streamTask = Task { [weak self] in
            await bus.loadPersisted()
            let stream = await bus.stream()
            for await snapshot in stream {
                guard let self else { continue }
                // Treat a new top event (or count change) as fresh activity
                // for the mascot's success-decay window.
                if snapshot.count != self.events.count || snapshot.first?.id != self.events.first?.id {
                    self.lastEventAt = Date()
                }
                self.events = snapshot
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
    }

    // MARK: - Mascot state

    func recomputeMascotState() {
        mascotState = MascotState.resolve(events: events, lastEventAt: lastEventAt)
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
        if panelController == nil {
            panelController = FloatingPanelController(appState: self)
        }
        panelController?.toggle()
    }

    /// Event row click → focus the terminal window/tab if we know how,
    /// otherwise open the web deep link.
    func select(_ event: KatoEvent) {
        if let focus = event.focus {
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
                    NSWorkspace.shared.open(url)
                }
            }
        } else if let url = event.url {
            NSWorkspace.shared.open(url)
        }
    }

    func clear() {
        Task { await bus.clear() }
    }

    func requestAccessibility() {
        AccessibilityPermission.openSystemSettings()
        refreshAccessibilityStatus()
    }
}
