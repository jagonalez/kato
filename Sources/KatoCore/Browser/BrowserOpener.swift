import AppKit
import Foundation

/// Opens web deep links in the DEFAULT browser, reusing a tab that already
/// shows the URL (Safari + Chromium-family via AppleScript) instead of
/// piling up duplicate tabs. Falls back to a plain open when the browser
/// can't be scripted (Firefox, Automation permission denied, browser not
/// running) — the first scripted attempt triggers the macOS "Kato wants to
/// control <browser>" prompt.
public enum BrowserOpener {
    enum ScriptFamily {
        case safari
        case chromium
    }

    /// scheme://host/path — scheme+host lowercased, trailing slashes and
    /// query/fragment dropped — so "…/pull/7?notification_referrer_id=…"
    /// matches an open tab at "…/pull/7". Pure + public for the smoke harness.
    public static func comparisonKey(for url: URL) -> String {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty,
              let host = url.host?.lowercased(), !host.isEmpty else {
            return url.absoluteString
        }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        var key = "\(scheme)://\(host)"
        if let port = url.port { key += ":\(port)" }
        return key + path
    }

    /// Call on the main actor. Activates an existing matching tab when the
    /// default browser supports tab scripting; otherwise opens a new tab.
    @MainActor
    public static func open(_ url: URL) {
        let target = comparisonKey(for: url)
        guard let bundleID = defaultBrowserBundleID(),
              let family = scriptFamily(for: bundleID),
              !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        else {
            NSWorkspace.shared.open(url)
            return
        }
        // AppleScript execution (and a possible TCC prompt) can block, so it
        // runs off the main thread; the fallback open hops back.
        Task.detached {
            if !activateExistingTab(family: family, bundleID: bundleID, target: target) {
                _ = await MainActor.run { NSWorkspace.shared.open(url) }
            }
        }
    }

    // MARK: - Internals

    static func defaultBrowserBundleID() -> String? {
        guard let https = URL(string: "https:"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: https) else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    static func scriptFamily(for bundleID: String) -> ScriptFamily? {
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            return .safari
        case "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium",
             "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
             "com.operasoftware.Opera", "company.thebrowser.Browser":
            return .chromium
        default: // Firefox & friends expose no tab scripting — plain open.
            return nil
        }
    }

    /// Returns true when a matching tab was found and activated. Any script
    /// error (Automation permission denied, missing suite) → false, and the
    /// caller falls back to a plain open.
    static func activateExistingTab(family: ScriptFamily, bundleID: String, target: String) -> Bool {
        let script = NSAppleScript(source: scriptSource(family: family, bundleID: bundleID, target: target))
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if let error {
            FileHandle.standardError.write(Data("kato: browser tab lookup failed: \(error)\n".utf8))
            return false
        }
        return result?.stringValue == "found"
    }

    /// URL characters that could break the string literal are percent-encoded
    /// by URL, and bundle ids are [a-z0-9.-], so direct interpolation is safe.
    static func scriptSource(family: ScriptFamily, bundleID: String, target: String) -> String {
        // Match the exact key, or the key followed by "/", "?" or "#" — so
        // /pull/7 matches its Files/Commits sub-tabs but never /pull/71.
        let match = """
        u is "\(target)" or u starts with ("\(target)" & "/") \
        or u starts with ("\(target)" & "?") or u starts with ("\(target)" & "#")
        """
        switch family {
        case .safari:
            return """
            tell application id "\(bundleID)"
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            set u to URL of t
                            if \(match) then
                                set current tab of w to t
                                set index of w to 1
                                activate
                                return "found"
                            end if
                        end try
                    end repeat
                end repeat
            end tell
            return "notfound"
            """
        case .chromium:
            return """
            tell application id "\(bundleID)"
                repeat with w in windows
                    set i to 0
                    repeat with t in tabs of w
                        set i to i + 1
                        try
                            set u to URL of t
                            if \(match) then
                                set active tab index of w to i
                                set index of w to 1
                                activate
                                return "found"
                            end if
                        end try
                    end repeat
                end repeat
            end tell
            return "notfound"
            """
        }
    }
}
