import AppKit
import SwiftUI

/// Menu-bar dropdown content (popover/menu face).
struct MenuContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if !appState.accessibilityTrusted {
                Button("⚠️ Accessibility Permission Needed — Fix…") {
                    appState.fixAccessibilityPermission()
                }
                Divider()
            }
            let recent = Array(appState.events.prefix(5))
            if recent.isEmpty {
                Text("No events")
            } else {
                ForEach(recent) { event in
                    Button(event.title) {
                        appState.select(event)
                    }
                }
            }
            if let error = appState.lastFocusError {
                Divider()
                Text("⚠︎ \(error)")
            }
            Divider()
            Button("Show / Hide Floating Panel") {
                appState.togglePanel()
            }
            Button("Clear Events") {
                appState.clear()
            }
            Divider()
            Button("Request Accessibility Permission…") {
                appState.requestAccessibility()
            }
            Divider()
            Button("Quit Kato") {
                NSApplication.shared.terminate(nil)
            }
        }
        // Menu content re-renders each time the menu opens; refresh the AX
        // status here since TCC changes don't notify.
        .onAppear { appState.refreshAccessibilityStatus() }
    }
}
