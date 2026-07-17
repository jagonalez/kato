import AppKit
import KatoCore

/// Helpers for the Accessibility (AX) permission UX.
///
/// Kato is a menu-bar agent (`LSUIElement` / accessory activation policy), so
/// presenting UI needs an explicit `NSApp.activate()` first or it can end up
/// hidden behind other apps' windows.
@MainActor
enum AccessibilityPermission {
    /// System Settings → Privacy & Security → Accessibility.
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    /// Registers Kato in the TCC list (via the system prompt path) and opens
    /// the Accessibility pane so the user can flip the switch.
    static func openSystemSettings() {
        FocusController.requestAccessibilityPermission()
        NSWorkspace.shared.open(settingsURL)
    }

    /// App-modal alert shown when a window-jump fails for lack of permission.
    static func presentAlert() {
        // Ensure Kato appears in the Accessibility list even if the user
        // picks "Later".
        FocusController.requestAccessibilityPermission()
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Accessibility Permission Needed"
        alert.informativeText = """
        Kato needs Accessibility permission to jump to the exact window and tab that needs you.

        Open System Settings, enable Kato under Privacy & Security → Accessibility, then click the event again.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(settingsURL)
        }
    }
}
