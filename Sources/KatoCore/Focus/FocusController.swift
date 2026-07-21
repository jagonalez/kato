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
/// Resolution order:
///   0. herdr ids → HerdrResolver focuses the pane via herdr's socket API
///      (deterministic, server-side; the outer terminal window is still
///      raised by the paths below — herdr is a TUI inside the host terminal).
///   1. cmux ids → CmuxResolver selects via cmux's socket API
///      (deterministic, no AX permission needed; raises + activates).
///   2. tmux info → TmuxResolver selects server-side (deterministic).
///   3. TTY marker (TabMarker): stamp the surface's title through its TTY
///      and find the tab by the unique marker — immune to Claude Code's
///      live title rewrites, duplicate titles and user renames.
///   4. Ranked title matching across EVERY window's tab group (multi-window
///      Ghostty exposes one tab bar per window).
///   5. Window-title fallback for apps without an AX tab bar; with a
///      successful herdr focus, front-window activation as last resort.
///
/// Ghostty AX reality (measured via `kato ax-dump`, 2026-07-17): every
/// Ghostty tab is its own AXWindow whose title reflects that tab, and the
/// app exposes AXTabGroup(s) ("tab bar") whose AXRadioButton(AXTabButton)
/// children carry readable titles — selected tab has AXValue == 1. AXRaise
/// on a background tab's window does NOT select the tab; the radio button
/// must be pressed explicitly, then its (now main) window raised.
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

    /// Ranks how well a window/tab title matches the token: exact (4) >
    /// case-insensitive exact (3) > prefix (2) > substring (1) > none (0).
    /// Pure + public for the smoke harness. First-substring-match was the
    /// "wrong tab" bug: token "kato" matched tab "kato-fork" when it sat
    /// earlier in tab order than the exact "kato" tab.
    public static func matchScore(title: String, token: String) -> Int {
        if title == token { return 4 }
        if title.caseInsensitiveCompare(token) == .orderedSame { return 3 }
        if title.range(of: token, options: [.caseInsensitive, .anchored]) != nil { return 2 }
        if title.range(of: token, options: .caseInsensitive) != nil { return 1 }
        return 0
    }

    /// Attempts to focus the window/tab described by `target`.
    /// Main-actor isolated because of NSRunningApplication.activate.
    @MainActor
    @discardableResult
    public func focus(_ target: FocusTarget) -> Result<Void, FocusError> {
        // Deterministic path 0a: herdr socket API — focuses the pane
        // server-side inside the outer terminal. herdr is a TUI multiplexer,
        // NOT the host window: never returns early, the paths below still
        // raise the host (cmux surface / AX).
        let herdrFocused = HerdrResolver.focus(target: target)
        if let herdrFocused {
            FileHandle.standardError.write(Data("kato: herdr focused \(herdrFocused)\n".utf8))
        }

        // Deterministic path 0b: cmux socket API — cmux selects the
        // workspace/surface itself; activation needs no AX permission.
        if let surface = CmuxResolver.focus(target: target) {
            FileHandle.standardError.write(Data("kato: cmux focused surface \(surface)\n".utf8))
            if let app = CmuxResolver.runningApp() {
                app.activate(options: [.activateAllWindows])
                return .success(())
            }
            FileHandle.standardError.write(Data(
                "kato: cmux surface focused but app not running; falling back to AX\n".utf8))
        }

        // Deterministic path 1: select the tmux window/pane server-side first,
        // so whichever terminal window we raise already shows the right pane.
        let tmuxSelected = TmuxResolver.select(target: target)
        if let tmuxSelected {
            FileHandle.standardError.write(Data("kato: tmux selected \(tmuxSelected)\n".utf8))
        }

        guard Self.isAccessibilityTrusted() else { return .failure(.accessibilityNotTrusted) }

        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: target.appBundleID)
        guard let app = runningApps.first else { return .failure(.appNotRunning(target.appBundleID)) }

        guard let windows = axWindows(of: app), !windows.isEmpty else {
            return .failure(.noWindows(target.appBundleID))
        }

        // 0. TTY marker path (TabMarker): stamp the surface's title via its
        //    TTY and find the tab by the unique marker. Skipped when tmux
        //    already selected the pane, when herdr focused (the hook's TTY is
        //    herdr's INNER pane pty — stamping it can't reach the outer tab),
        //    or the event carries no TTY.
        if tmuxSelected == nil, herdrFocused == nil, let tty = target.tty, !tty.isEmpty,
           focusByMarker(target: target, tty: tty, app: app, windows: windows) {
            return .success(())
        }

        // 1. Tab-first: scan EVERY window's tab group (multi-window Ghostty
        //    exposes one tab bar per window) and select the BEST-matching
        //    radio button (exact beats prefix beats substring).
        var best: (tab: AXUIElement, group: AXUIElement, title: String, score: Int)?
        for window in windows {
            guard let tabGroup = findTabGroup(under: window) else { continue }
            for tab in axChildren(of: tabGroup) {
                guard axRole(of: tab) == "AXRadioButton",
                      let title = axTitle(of: tab) else { continue }
                let score = Self.matchScore(title: title, token: target.windowTitleToken)
                if score > (best?.score ?? 0) { best = (tab, tabGroup, title, score) }
            }
        }
        if let best {
            let selected = select(best.tab)
            if !selected {
                FileHandle.standardError.write(Data(
                    "kato: tab press did not read back as selected; raising anyway\n".utf8))
            }
            raiseWindow(for: target.windowTitleToken, tabTitle: best.title,
                        tabGroupOwner: best.group, of: app)
            return .success(())
        }

        // 2. Window-title fallback (apps without an AX tab bar), same ranking.
        var bestWindow: (window: AXUIElement, score: Int)?
        for window in windows {
            guard let title = axTitle(of: window) else { continue }
            let score = Self.matchScore(title: title, token: target.windowTitleToken)
            if score > (bestWindow?.score ?? 0) { bestWindow = (window, score) }
        }
        if let bestWindow {
            raise(bestWindow.window, of: app)
            return .success(())
        }
        // 3. Last resort when herdr already focused the pane server-side:
        //    the outer tab title is herdr's client title (the cwd token can
        //    never match), so just bring the host app forward — the right
        //    pane is already showing in whatever herdr window is frontmost.
        if herdrFocused != nil {
            app.activate(options: [.activateAllWindows])
            return .success(())
        }
        return .failure(.noMatch(token: target.windowTitleToken))
    }

    // MARK: - TTY marker path

    /// Finds the tab whose title carries the TTY marker. Fast path first: a
    /// stamp from an earlier click may still be live. Otherwise stamps the
    /// surface via OSC 2 → polls ~1 s for the AX title to refresh → selects
    /// + raises. The plain title is restored before returning either way.
    private func focusByMarker(target: FocusTarget, tty: String,
                               app: NSRunningApplication, windows: [AXUIElement]) -> Bool {
        let needle = TabMarker.needle(tty: tty)
        if let hit = findMarkedTab(needle: needle, in: windows) {
            select(hit.tab)
            raiseWindow(for: needle, tabTitle: hit.title, tabGroupOwner: hit.group, of: app)
            TabMarker.restore(title: target.windowTitleToken, tty: tty)
            return true
        }
        guard TabMarker.stamp(token: target.windowTitleToken, tty: tty) else { return false }
        defer { TabMarker.restore(title: target.windowTitleToken, tty: tty) }
        // Measured AX title-refresh latency after an OSC 2 write: ~0.8 s.
        for _ in 0..<6 {
            usleep(250_000)
            guard let fresh = axWindows(of: app) else { continue }
            if let hit = findMarkedTab(needle: needle, in: fresh) {
                select(hit.tab)
                raiseWindow(for: needle, tabTitle: hit.title, tabGroupOwner: hit.group, of: app)
                return true
            }
        }
        FileHandle.standardError.write(Data(
            "kato: marker stamp not visible in AX after 1.5s; falling back to title match\n".utf8))
        return false
    }

    /// Scans every window's tab group for a radio button whose title
    /// contains the marker needle (unique per TTY — first hit is the hit).
    private func findMarkedTab(needle: String, in windows: [AXUIElement])
        -> (tab: AXUIElement, group: AXUIElement, title: String)? {
        for window in windows {
            guard let tabGroup = findTabGroup(under: window) else { continue }
            for tab in axChildren(of: tabGroup) where axRole(of: tab) == "AXRadioButton" {
                if let title = axTitle(of: tab), title.contains(needle) {
                    return (tab, tabGroup, title)
                }
            }
        }
        return nil
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

    /// After a tab is selected, raise the window that shows it. The radio-
    /// button press makes the selected tab's NSWindow the app's MAIN window,
    /// so prefer AXMainWindow: deterministic even when several windows carry
    /// the same tab title (the old title search raised the first AXWindow
    /// match — the other half of the "wrong tab" bug).
    private func raiseWindow(for token: String, tabTitle: String,
                             tabGroupOwner: AXUIElement, of app: NSRunningApplication) {
        if let main = axMainWindow(of: app),
           let mainTitle = axTitle(of: main),
           mainTitle == tabTitle || mainTitle.caseInsensitiveCompare(tabTitle) == .orderedSame {
            raise(main, of: app)
            return
        }
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

    private func axMainWindow(of app: NSRunningApplication) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &value) == .success,
              let window = value, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return (window as! AXUIElement)
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

    /// Ghostty exposes an AXTabGroup per window that has a tab bar, so the
    /// caller iterates windows and searches each group separately.

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
