import Foundation

/// Deterministic focus path for agents running inside tmux.
///
/// When a hook payload carries tmux info, we ask the tmux SERVER to select
/// the right window/pane (`tmux select-window` + `tmux select-pane`). That
/// switch happens server-side — every attached client (including the
/// Ghostty tab the user is looking at) follows instantly, with no
/// accessibility-tree guesswork.
///
/// Resolution order:
///   1. `FocusTarget.tmuxTarget` ("session:window.pane") — used directly.
///   2. `FocusTarget.tty` — mapped via `tmux list-panes -a`.
/// Returns the selected target on success, nil when tmux info is absent,
/// tmux is not installed, or resolution fails (all non-fatal: the caller
/// falls back to the AX path).
public enum TmuxResolver {
    /// Candidate tmux binary locations (Homebrew arm64 / Intel, PATH lookup
    /// is unreliable from a launchd-started menu-bar app).
    static let candidatePaths = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
    ]

    public static func tmuxPath() -> String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Selects the tmux window + pane described by `target`.
    /// Returns the "session:window.pane" string that was selected, or nil.
    @discardableResult
    public static func select(target: FocusTarget) -> String? {
        guard let tmux = tmuxPath() else { return nil }
        let resolved: String?
        if let explicit = target.tmuxTarget, !explicit.isEmpty {
            resolved = explicit
        } else if let tty = target.tty, !tty.isEmpty {
            resolved = resolve(tty: tty, tmux: tmux)
        } else {
            resolved = nil
        }
        guard let paneTarget = resolved else { return nil }
        // "session:window.pane" — select-window accepts the full pane target
        // too, but passing the window part keeps the intent explicit.
        let windowTarget = paneTarget.components(separatedBy: ".").first ?? paneTarget
        guard run(tmux, arguments: ["select-window", "-t", windowTarget]) else { return nil }
        run(tmux, arguments: ["select-pane", "-t", paneTarget])
        return paneTarget
    }

    /// Maps a TTY (e.g. "ttys021" or "/dev/ttys021") to a
    /// "session:window.pane" target via `tmux list-panes -a`.
    static func resolve(tty: String, tmux: String) -> String? {
        guard let output = runCapturing(tmux, arguments: [
            "list-panes", "-a", "-F", "#{pane_tty} #{session_name}:#{window_index}.#{pane_index}",
        ]) else { return nil }
        return target(forTTY: tty, inListPanesOutput: output)
    }

    /// Pure parsing (unit-testable): first line whose tty matches.
    /// Tolerates "/dev/" prefixes on either side.
    public static func target(forTTY tty: String, inListPanesOutput output: String) -> String? {
        let wanted = normalize(tty: tty)
        guard !wanted.isEmpty else { return nil }
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            if normalize(tty: String(parts[0])) == wanted {
                return String(parts[1])
            }
        }
        return nil
    }

    static func normalize(tty: String) -> String {
        var result = tty.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("/dev/") { result = String(result.dropFirst("/dev/".count)) }
        return result
    }

    // MARK: - Process helpers

    @discardableResult
    private static func run(_ tmux: String, arguments: [String]) -> Bool {
        runCapturing(tmux, arguments: arguments) != nil
    }

    /// Returns stdout on exit status 0, nil otherwise (tmux absent, no
    /// server running, unknown target — all fine, caller falls back).
    private static func runCapturing(_ tmux: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
