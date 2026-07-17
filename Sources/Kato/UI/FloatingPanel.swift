import AppKit
import KatoCore
import SwiftUI

/// Borderless, always-on-top panel: `.nonactivatingPanel`, level `.floating`,
/// `canJoinAllSpaces`. Collapsed = orb with badge count; expanded = event list.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 256, height: 256),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
    }
}

@MainActor
final class FloatingPanelController: ObservableObject {
    @Published private(set) var expanded = false

    private let panel: FloatingPanel
    private let collapsedSize = NSSize(width: 256, height: 256)
    private let expandedSize = NSSize(width: 420, height: 540)

    init(appState: AppState) {
        // TEMP DEBUG (revert after screenshot verification): allow launching
        // with the panel expanded via KATO_EXPANDED=1.
        expanded = ProcessInfo.processInfo.environment["KATO_EXPANDED"] == "1"
        panel = FloatingPanel()
        let hosting = NSHostingView(rootView: FloatingPanelView(appState: appState, controller: self))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        layout(animated: false)
        panel.orderFrontRegardless()
    }

    func toggle() {
        expanded.toggle()
        layout(animated: true)
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
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            panel.setContentSize(size)
            return
        }
        let margin: CGFloat = 16
        // Anchor top-right of the visible frame; resize downward from the same corner.
        let origin = NSPoint(
            x: screen.visibleFrame.maxX - size.width - margin,
            y: screen.visibleFrame.maxY - size.height - margin
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: animated)
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
            OrbView(count: appState.events.count,
                    imageName: appState.mascotImageName,
                    state: appState.mascotState)
                .onTapGesture {
                    controller.toggle()
                }
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
            EventListView(events: appState.events) { event in
                appState.select(event)
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
