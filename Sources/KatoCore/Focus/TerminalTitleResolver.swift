import Foundation

/// Resolves hook payload fields (cwd / tty / pid) into a FocusTarget.
///
/// Convention (docs/ARCHITECTURE.md §"Ghostty window+tab focus"): the
/// terminal tab title carries the cwd basename, so the cwd basename is the
/// match token. Kato currently targets Ghostty; other terminals can be
/// added here later.
public enum TerminalTitleResolver {
    public static let ghosttyBundleID = "com.mitchellh.ghostty"

    public static func focusTarget(cwd: String?, tty: String?, pid: Int32?) -> FocusTarget? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let token = URL(fileURLWithPath: cwd).lastPathComponent
        guard !token.isEmpty else { return nil }
        return FocusTarget(appBundleID: ghosttyBundleID, windowTitleToken: token, processPID: pid)
    }
}
