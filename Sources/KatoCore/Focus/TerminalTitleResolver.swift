import Foundation

/// Resolves hook payload fields (cwd / tty / pid) into a FocusTarget.
///
/// Convention (docs/ARCHITECTURE.md §"Ghostty window+tab focus"): the
/// terminal tab title carries the cwd basename, so the cwd basename is the
/// match token. Kato currently targets Ghostty; other terminals can be
/// added here later.
public enum TerminalTitleResolver {
    public static let ghosttyBundleID = "com.mitchellh.ghostty"
    public static let cmuxBundleID = "com.cmuxterm.app"

    public static func focusTarget(cwd: String?, tty: String?, pid: Int32?, tmux: String? = nil,
                                   cmuxWorkspace: String? = nil, cmuxSurface: String? = nil,
                                   herdrSocket: String? = nil, herdrWorkspace: String? = nil,
                                   herdrTab: String? = nil, herdrPane: String? = nil) -> FocusTarget? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let token = URL(fileURLWithPath: cwd).lastPathComponent
        guard !token.isEmpty else { return nil }
        let workspace = cmuxWorkspace.flatMap { $0.isEmpty ? nil : $0 }
        let surface = cmuxSurface.flatMap { $0.isEmpty ? nil : $0 }
        // cmux sets TERM_PROGRAM=ghostty for compatibility, so a carried
        // surface id — not the environment — is what identifies cmux.
        // herdr never changes the outer app: it runs inside Ghostty/cmux.
        return FocusTarget(appBundleID: surface != nil ? cmuxBundleID : ghosttyBundleID,
                           windowTitleToken: token,
                           processPID: pid,
                           tmuxTarget: tmux.flatMap { $0.isEmpty ? nil : $0 },
                           tty: tty.flatMap { $0.isEmpty ? nil : $0 },
                           cmuxWorkspace: workspace,
                           cmuxSurface: surface,
                           herdrSocket: herdrSocket.flatMap { $0.isEmpty ? nil : $0 },
                           herdrWorkspace: herdrWorkspace.flatMap { $0.isEmpty ? nil : $0 },
                           herdrTab: herdrTab.flatMap { $0.isEmpty ? nil : $0 },
                           herdrPane: herdrPane.flatMap { $0.isEmpty ? nil : $0 })
    }
}
