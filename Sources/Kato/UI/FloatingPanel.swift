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
        panel = FloatingPanel()
        let hosting = NSHostingView(rootView: FloatingPanelView(appState: appState, controller: self))
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
        Group {
            if controller.expanded {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(4)
            } else {
                OrbView(count: appState.events.count, state: appState.mascotState)
                    .onTapGesture {
                        controller.toggle()
                    }
            }
        }
        // TCC changes don't notify; re-check whenever the panel shows.
        .onAppear { appState.refreshAccessibilityStatus() }
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
