import ApplicationServices
import AppKit

/// Diagnostic: dumps the accessibility tree of a running app (default
/// Ghostty) so we can see exactly how windows, tab groups and tab buttons
/// are exposed — roles, titles, descriptions, values and selected state.
/// Used by the `kato ax-dump` CLI subcommand.
public enum AXDumper {
    /// Roles worth flagging in the output (tab-switching relevant).
    private static let interestingRoles: Set<String> = [
        "AXTabGroup", "AXRadioButton", "AXButton", "AXTab", "AXToolbar",
        "AXGroup", "AXSplitGroup",
    ]

    /// Dumps the AX tree of the first running app matching `bundleID`.
    /// Returns a human-readable report (also suitable for logs).
    @MainActor
    public static func dump(bundleID: String, maxDepth: Int = 4) -> String {
        var out = ""
        guard AXIsProcessTrusted() else {
            return "AXDumper: accessibility NOT trusted — grant permission first."
        }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard let app = apps.first else {
            return "AXDumper: app not running: \(bundleID)"
        }
        out += "app: \(bundleID) pid=\(app.processIdentifier)\n"
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard error == .success, let windows = value as? [AXUIElement], !windows.isEmpty else {
            out += "AXDumper: no readable windows (error=\(error.rawValue))\n"
            return out
        }
        out += "windows: \(windows.count)\n"
        for (index, window) in windows.enumerated() {
            let title = string(window, kAXTitleAttribute) ?? "<no title>"
            out += "\n=== window \(index): \"\(title)\" ===\n"
            walk(window, depth: 0, maxDepth: maxDepth, into: &out)
        }
        return out
    }

    // MARK: - Internals

    private static func walk(_ element: AXUIElement, depth: Int, maxDepth: Int, into out: inout String) {
        guard depth <= maxDepth else { return }
        let role = string(element, kAXRoleAttribute) ?? "<no role>"
        let title = string(element, kAXTitleAttribute)
        let description = string(element, kAXDescriptionAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        let value = rawValue(element).map { truncate($0, to: 80) }
        let selected = boolValue(element, "AXSelected")

        var line = String(repeating: "  ", count: depth + 1)
        line += role
        if let subrole { line += "(\(subrole))" }
        if let title { line += " title=\"\(truncate(title, to: 60))\"" }
        if let description { line += " desc=\"\(truncate(description, to: 60))\"" }
        if let value { line += " value=\"\(value)\"" }
        if let selected { line += " selected=\(selected)" }
        if interestingRoles.contains(role) { line += depth <= 1 ? "   <<<" : "" }
        out += line + "\n"

        let children = children(of: element)
        for child in children.prefix(40) {
            walk(child, depth: depth + 1, maxDepth: maxDepth, into: &out)
        }
        if children.count > 40 {
            out += String(repeating: "  ", count: depth + 2) + "… \(children.count - 40) more children\n"
        }
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolValue(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func rawValue(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func truncate(_ string: String, to limit: Int) -> String {
        let flattened = string.replacingOccurrences(of: "\n", with: "⏎")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }
}
