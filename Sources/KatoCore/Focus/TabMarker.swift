import Foundation

/// Deterministic Ghostty tab identification via the agent's TTY.
///
/// Title matching is inherently fragile: Claude Code rewrites tab titles
/// live (task summaries, spinner glyphs, duplicate generic "✳ Claude Code"
/// titles — see `kato ax-dump`) and users rename tabs. Ghostty exposes no
/// per-tab API (no AppleScript, no IPC, no per-surface env var — unlike
/// Kitty/WezTerm/iTerm), but every hook payload carries the agent's TTY and
/// a TTY maps 1:1 to a Ghostty surface. So at click time we briefly stamp
/// that surface's title via OSC 2 written to /dev/<tty>, find the tab by
/// its unique marker in the AX tab bar, select+raise it, then restore the
/// plain title. The agent is idle at click time (that's why the event
/// exists), so nothing overwrites the stamp during the sub-second poll.
public enum TabMarker {
    /// Separator between the readable part and the TTY in a stamped title.
    public static let delimiter = " ⌁"

    /// What to search for in AX tab titles, e.g. " ⌁ttys021".
    public static func needle(tty: String) -> String {
        delimiter + normalize(tty: tty)
    }

    /// The stamped title, e.g. "● kato ⌁ttys021".
    public static func stampedTitle(token: String, tty: String) -> String {
        "● \(token)\(delimiter)\(normalize(tty: tty))"
    }

    /// "ttys021" and "/dev/ttys021" both normalize to "ttys021".
    public static func normalize(tty: String) -> String {
        var result = tty.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("/dev/") { result = String(result.dropFirst(5)) }
        return result
    }

    /// Writes OSC 2 (`<title>`) to /dev/<tty>. Returns false when the TTY is
    /// gone or unwritable (stale event) — callers then fall back to title
    /// matching.
    @discardableResult
    public static func writeTitle(_ title: String, tty: String) -> Bool {
        let path = "/dev/" + normalize(tty: tty)
        let fd = open(path, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let bytes = [UInt8]("\u{1B}]2;\(title)\u{7}".utf8)
        let written = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        return written == bytes.count
    }

    @discardableResult
    public static func stamp(token: String, tty: String) -> Bool {
        writeTitle(stampedTitle(token: token, tty: tty), tty: tty)
    }

    @discardableResult
    public static func restore(title: String, tty: String) -> Bool {
        writeTitle(title, tty: tty)
    }

    /// Verifies `pid` is alive and its controlling TTY is still `tty`.
    /// Guards against stamping an unrelated tab whose pty reused the TTY
    /// number after the event's session ended (Darwin hands out the lowest
    /// free pty number, so recycling is common).
    public static func verifyOwnership(pid: Int32, tty: String) -> Bool {
        let wanted = normalize(tty: tty)
        guard !wanted.isEmpty else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "tty=", "-p", String(pid)]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        let current = String(data: data, encoding: .utf8) ?? ""
        return normalize(tty: current) == wanted
    }
}
