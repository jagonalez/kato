import ApplicationServices
import AppKit

public enum FocusError: Error, CustomStringConvertible {
    /// AXIsProcessTrusted() == false; the user must grant Accessibility permission.
    case accessibilityNotTrusted
    case appNotRunning(String)
    case noWindows(String)
    case noMatch(token: String)
    case axError(String, AXError)

    public var description: String {
        switch self {
        case .accessibilityNotTrusted:
            return "Accessibility permission not granted (System Settings → Privacy & Security → Accessibility)."
        case .appNotRunning(let bundleID):
            return "App not running: \(bundleID)"
        case .noWindows(let bundleID):
            return "No windows found for \(bundleID)."
        case .noMatch(let token):
            return "No window or tab title contains '\(token)' (the title may have drifted)."
        case .axError(let attribute, let error):
            return "AX error reading \(attribute): \(error.rawValue)"
        }
    }
}

/// Raises the exact window + native tab that needs the user.
/// See docs/ARCHITECTURE.md §"Ghostty window+tab focus (the hard part)".
///
/// Strategy: iterate the target app's AX windows; match `windowTitleToken`
/// against window titles AND the titles of native macOS window tabs
/// (AXTabGroup → AXRadioButton children); select the matching tab
/// (AXSelected / AXPress), AXRaise the window, then activate the app.
public struct FocusController: Sendable {
    public init() {}

    public static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the system Accessibility-permission dialog on first use.
    /// Returns the current trust state.
    @discardableResult
    public static func requestAccessibilityPermission() -> Bool {
        // kAXTrustedCheckOptionPrompt is imported as a (non-Sendable) C global;
        // its documented value is the literal "AXTrustedCheckOptionPrompt".
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Attempts to focus the window/tab described by `target`.
    /// Main-actor isolated because of NSRunningApplication.activate.
    @MainActor
    @discardableResult
    public func focus(_ target: FocusTarget) -> Result<Void, FocusError> {
        guard Self.isAccessibilityTrusted() else { return .failure(.accessibilityNotTrusted) }

        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: target.appBundleID)
        guard let app = runningApps.first else { return .failure(.appNotRunning(target.appBundleID)) }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard error == .success else { return .failure(.axError("AXWindows", error)) }
        guard let windows = value as? [AXUIElement], !windows.isEmpty else {
            return .failure(.noWindows(target.appBundleID))
        }

        for window in windows {
            if let title = axTitle(of: window),
               title.localizedCaseInsensitiveContains(target.windowTitleToken) {
                selectMatchingTab(in: window, token: target.windowTitleToken)
                raise(window, of: app)
                return .success(())
            }
            if selectMatchingTab(in: window, token: target.windowTitleToken) {
                raise(window, of: app)
                return .success(())
            }
        }
        return .failure(.noMatch(token: target.windowTitleToken))
    }

    // MARK: - Internals

    private func raise(_ window: AXUIElement, of app: NSRunningApplication) {
        AXUIElementPerformAction(window, "AXRaise" as CFString)
        app.activate(options: [.activateAllWindows])
    }

    /// Finds the window's AXTabGroup (native macOS window tabs) and selects
    /// the tab radio button whose title contains `token`.
    @discardableResult
    private func selectMatchingTab(in window: AXUIElement, token: String) -> Bool {
        guard let tabGroup = findTabGroup(under: window) else { return false }
        for tab in axChildren(of: tabGroup) {
            guard axRole(of: tab) == "AXRadioButton" else { continue }
            guard let title = axTitle(of: tab),
                  title.localizedCaseInsensitiveContains(token) else { continue }
            if AXUIElementSetAttributeValue(tab, "AXSelected" as CFString, kCFBooleanTrue) == .success {
                return true
            }
            if AXUIElementPerformAction(tab, kAXPressAction as CFString) == .success {
                return true
            }
        }
        return false
    }

    private func findTabGroup(under element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth <= 5 else { return nil }
        if axRole(of: element) == "AXTabGroup" { return element }
        for child in axChildren(of: element) {
            if let found = findTabGroup(under: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private func axTitle(of element: AXUIElement) -> String? { axString(element, kAXTitleAttribute) }
    private func axRole(of element: AXUIElement) -> String? { axString(element, kAXRoleAttribute) }

    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func axChildren(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
