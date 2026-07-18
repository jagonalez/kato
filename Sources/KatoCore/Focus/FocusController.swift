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
/// Ghostty AX reality (measured via `kato ax-dump`, 2026-07-17): every
/// Ghostty tab is its own AXWindow whose title reflects that tab, and the
/// app exposes exactly ONE AXTabGroup ("tab bar", attached to a single
/// window) whose AXRadioButton(AXTabButton) children carry readable titles
/// for ALL tabs — selected tab has AXValue == 1. AXRaise on a background
/// tab's window does NOT select the tab (the user's bug); the radio button
/// must be selected explicitly, then its window raised.
///
/// When the event carries tmux info, TmuxResolver runs FIRST (deterministic
/// server-side window/pane selection); the AX pass then just raises the
/// front terminal window.
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
        // Deterministic path: select the tmux window/pane server-side first,
        // so whichever terminal window we raise already shows the right pane.
        if let selected = TmuxResolver.select(target: target) {
            FileHandle.standardError.write(Data("kato: tmux selected \(selected)\n".utf8))
        }

        guard Self.isAccessibilityTrusted() else { return .failure(.accessibilityNotTrusted) }

        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: target.appBundleID)
        guard let app = runningApps.first else { return .failure(.appNotRunning(target.appBundleID)) }

        guard let windows = axWindows(of: app), !windows.isEmpty else {
            return .failure(.noWindows(target.appBundleID))
        }

        // 1. Tab-first: find the app's tab bar across ALL windows (Ghostty
        //    attaches it to only one) and select the matching radio button.
        if let tabGroup = findTabGroup(underAnyOf: windows) {
            for tab in axChildren(of: tabGroup) {
                guard axRole(of: tab) == "AXRadioButton",
                      let title = axTitle(of: tab),
                      title.localizedCaseInsensitiveContains(target.windowTitleToken)
                else { continue }
                let selected = select(tab)
                if !selected {
                    FileHandle.standardError.write(Data(
                        "kato: tab press did not read back as selected; raising anyway\n".utf8))
                }
                raiseWindow(for: target.windowTitleToken, tabTitle: title,
                            tabGroupOwner: tabGroup, of: app)
                return .success(())
            }
        }

        // 2. Window-title fallback (apps without an AX tab bar).
        for window in windows {
            if let title = axTitle(of: window),
               title.localizedCaseInsensitiveContains(target.windowTitleToken) {
                raise(window, of: app)
                return .success(())
            }
        }
        return .failure(.noMatch(token: target.windowTitleToken))
    }

    // MARK: - Internals

    /// Selects a tab-bar radio button. Ghostty's AXTabButton exposes only
    /// AXPress/AXShowMenu (AXSelected and AXValue are NOT settable — the
    /// failed set is skipped entirely), so press, then verify the flip.
    /// Returns true when the tab reads back as selected.
    @discardableResult
    private func select(_ tab: AXUIElement) -> Bool {
        if isSelected(tab) { return true }
        AXUIElementPerformAction(tab, kAXPressAction as CFString)
        usleep(150_000) // Ghostty needs a beat before the value updates.
        if isSelected(tab) { return true }
        // Fallback for other terminals whose tab buttons honor AXSelected.
        if AXUIElementSetAttributeValue(tab, "AXSelected" as CFString, kCFBooleanTrue) == .success {
            usleep(100_000)
            return isSelected(tab)
        }
        return false
    }

    private func isSelected(_ tab: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(tab, kAXValueAttribute as CFString, &value) == .success else { return false }
        return (value as? NSNumber)?.boolValue == true
    }

    /// After a tab is selected, raise the window that shows it. Ghostty's
    /// native tabs are per-tab AXWindows whose title equals the tab title;
    /// re-fetch because window order/titles shift after selection.
    private func raiseWindow(for token: String, tabTitle: String,
                             tabGroupOwner: AXUIElement, of app: NSRunningApplication) {
        if let fresh = axWindows(of: app) {
            // Exact tab-title match beats a fuzzy token match (dupe titles).
            if let window = fresh.first(where: { axTitle(of: $0) == tabTitle })
                ?? fresh.first(where: {
                    axTitle(of: $0)?.localizedCaseInsensitiveContains(token) == true
                }) {
                raise(window, of: app)
                return
            }
        }
        // Fallback: raise the window that owns the tab bar.
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(tabGroupOwner, kAXWindowAttribute as CFString, &value) == .success,
           let ownerWindow = value {
            AXUIElementPerformAction(ownerWindow as! AXUIElement, "AXRaise" as CFString)
        }
        app.activate(options: [.activateAllWindows])
    }

    private func raise(_ window: AXUIElement, of app: NSRunningApplication) {
        AXUIElementPerformAction(window, "AXRaise" as CFString)
        app.activate(options: [.activateAllWindows])
    }

    private func axWindows(of app: NSRunningApplication) -> [AXUIElement]? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? [AXUIElement]
    }

    /// Ghostty exposes its single AXTabGroup under just ONE of its windows,
    /// so search every window rather than only the title-matching one.
    private func findTabGroup(underAnyOf windows: [AXUIElement]) -> AXUIElement? {
        for window in windows {
            if let found = findTabGroup(under: window) { return found }
        }
        return nil
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
