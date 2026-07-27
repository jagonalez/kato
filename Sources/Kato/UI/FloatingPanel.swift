import AppKit
import KatoCore
import SwiftUI

/// Borderless, always-on-top panel: `.nonactivatingPanel`, level `.floating`,
/// `canJoinAllSpaces`. Collapsed = orb with badge count; expanded = event list.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // enabled only while expanded (see layout())
        hidesOnDeactivate = false
    }
}

/// Hosting view that tells a click on the collapsed orb apart from a drag.
/// `isMovableByWindowBackground` fights SwiftUI tap gestures (the hosting
/// view claims the mouse, so drags were being swallowed into "clicks"),
/// so in collapsed mode the window is moved manually here and the tap
/// only counts if the pointer barely moved.
private final class PanelHostingView: NSHostingView<FloatingPanelView> {
    var isExpanded: () -> Bool = { false }
    var onOrbClick: () -> Void = {}
    var onDragEnd: () -> Void = {}

    private var downPoint: NSPoint?
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        guard !isExpanded() else { super.mouseDown(with: event); return }
        downPoint = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isExpanded(), let down = downPoint, !dragged else {
            super.mouseDragged(with: event)
            return
        }
        let loc = event.locationInWindow
        guard abs(loc.x - down.x) >= 4 || abs(loc.y - down.y) >= 4 else { return }
        dragged = true
        downPoint = nil
        // Native drag: smooth, no coordinate feedback (manually offsetting
        // the frame from window-relative deltas lags behind the cursor).
        window?.performDrag(with: event)
        onDragEnd()
    }

    override func mouseUp(with event: NSEvent) {
        guard !isExpanded() else { super.mouseUp(with: event); return }
        if !dragged { onOrbClick() }
        downPoint = nil
        dragged = false
    }
}

@MainActor
final class FloatingPanelController: ObservableObject {
    @Published private(set) var expanded = false
    /// Settings pane replaces the event list while open.
    @Published var showSettings = false

    private let panel: FloatingPanel
    private weak var appState: AppState?
    private let collapsedSize = NSSize(width: 240, height: 240)
    private let expandedSize = NSSize(width: 420, height: 540)
    /// Where the orb sat before expanding — collapsing restores it exactly.
    private var collapsedOrigin: NSPoint?

    nonisolated static let orbXDefaultsKey = "kato.orbX"
    nonisolated static let orbYDefaultsKey = "kato.orbY"

    /// Last dragged orb position, persisted across launches.
    private static var savedOrbOrigin: NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: orbXDefaultsKey) != nil else { return nil }
        return NSPoint(x: defaults.double(forKey: orbXDefaultsKey),
                       y: defaults.double(forKey: orbYDefaultsKey))
    }

    init(appState: AppState) {
        self.appState = appState
        panel = FloatingPanel()
        let hosting = PanelHostingView(rootView: FloatingPanelView(appState: appState, controller: self))
        hosting.isExpanded = { [weak self] in self?.expanded ?? false }
        hosting.onOrbClick = { [weak self] in self?.toggle() }
        hosting.onDragEnd = { [weak self] in self?.persistOrbPosition() }
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        layout(animated: false)
        panel.orderFrontRegardless()
    }

    private func persistOrbPosition() {
        guard !expanded else { return }
        collapsedOrigin = panel.frame.origin
        UserDefaults.standard.set(Double(panel.frame.origin.x), forKey: Self.orbXDefaultsKey)
        UserDefaults.standard.set(Double(panel.frame.origin.y), forKey: Self.orbYDefaultsKey)
    }

    func toggle() {
        expanded.toggle()
        if expanded { appState?.markSeen() }
        layout(animated: true)
    }

    /// Closes the panel (menu-bar-only mode). The controller is discarded
    /// by the caller; a fresh one is created when the mascot is re-shown.
    func close() {
        panel.close()
    }

    private func layout(animated: Bool) {
        let size = expanded ? expandedSize : collapsedSize
        // The panel has exactly two fixed sizes. Clamp min == max so greedy
        // SwiftUI content (List / Spacer fitting-size passes) can never
        // inflate the window — without this the expanded window was observed
        // growing from 420×540 to 420×964, and the (previously centered)
        // content left a dead band above the header.
        panel.contentMinSize = size
        panel.contentMaxSize = size
        // Shadow only in expanded mode: on the transparent collapsed orb the
        // window shadow outlines the whole panel rect (a static gray ring,
        // very visible on light backgrounds). The expanded card is opaque,
        // so the shadow hugs it correctly there.
        panel.hasShadow = expanded
        // Background-dragging only in expanded mode; the collapsed orb
        // drags via PanelHostingView's click-vs-drag discrimination.
        panel.isMovableByWindowBackground = expanded

        let origin: NSPoint
        if expanded {
            // Remember the orb's exact spot so collapsing puts it back.
            if !panel.frame.equalTo(.zero) { collapsedOrigin = panel.frame.origin }
            // Expand where the mascot was: keep the top-right corner.
            origin = NSPoint(x: panel.frame.maxX - size.width,
                             y: panel.frame.maxY - size.height)
        } else if let collapsedOrigin {
            // Collapse back to where the mascot was dragged.
            origin = collapsedOrigin
        } else if !panel.frame.equalTo(.zero) {
            origin = NSPoint(x: panel.frame.maxX - size.width,
                             y: panel.frame.maxY - size.height)
        } else if let saved = Self.savedOrbOrigin {
            // First show after launch: restore the dragged position.
            origin = saved
        } else {
            // Very first run: anchor top-right of the main screen.
            guard let screen = NSScreen.main ?? NSScreen.screens.first else {
                panel.setContentSize(size)
                return
            }
            let margin: CGFloat = 16
            origin = NSPoint(x: screen.visibleFrame.maxX - size.width - margin,
                             y: screen.visibleFrame.maxY - size.height - margin)
        }

        // Clamp onto the screen the panel lives on so it can never end up
        // half off-screen (expanding near an edge, display disconnected
        // since the position was saved, …).
        var frame = NSRect(origin: origin, size: size)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) })
            ?? NSScreen.main ?? NSScreen.screens.first {
            let vis = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            frame.origin.x = min(max(frame.origin.x, vis.minX), vis.maxX - size.width)
            frame.origin.y = min(max(frame.origin.y, vis.minY), vis.maxY - size.height)
        }
        panel.setFrame(frame, display: true, animate: animated)
        if !expanded { persistOrbPosition() }
    }
}

struct FloatingPanelView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var controller: FloatingPanelController

    var body: some View {
        // Plain top-level conditional (no Group wrapper): only the active
        // branch contributes layout, so the collapsed orb's fixed 256×256
        // frame can never union-size or shift the expanded layout.
        if controller.expanded {
            expandedBody
                // TCC changes don't notify; re-check whenever the panel shows.
                .onAppear { appState.refreshAccessibilityStatus() }
        } else {
            OrbView(count: appState.unreadCount,
                    imageName: appState.mascotImageName,
                    state: appState.mascotState,
                    tick: appState.activityTick,
                    dancing: appState.musicPlaying)
                // Clicks/drags are handled by PanelHostingView so a drag
                // can never be misread as a tap.
                .onAppear { appState.refreshAccessibilityStatus() }
        }
    }

    private var expandedBody: some View {
        VStack(spacing: 0) {
            if !appState.accessibilityTrusted {
                accessibilityBanner
                Divider()
            }
            header
            Divider()
            if controller.showSettings {
                SettingsView(appState: appState)
            } else {
                EventListView(groups: appState.groups,
                              onSelect: { appState.select($0) },
                              onDelete: { appState.delete($0) },
                              onDeleteGroup: { appState.delete($0) })
            }
        }
        // Pin content to the very top of the panel.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(4)
    }

    /// Persistent warning shown while AX permission is missing.
    private var accessibilityBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Accessibility permission needed for window-jumping")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Fix…") {
                appState.fixAccessibilityPermission()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.yellow.opacity(0.15))
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let mascot = AssetLoader.image(named: MascotState.idle.imageName) {
                Image(nsImage: mascot)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
            }
            Text("Kato")
                .font(.title3.weight(.semibold))
            Spacer()
            Button {
                controller.showSettings.toggle()
            } label: {
                Image(systemName: controller.showSettings ? "gearshape.fill" : "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            Button {
                appState.clear()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Clear events")
            Button {
                controller.toggle()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Collapse")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
