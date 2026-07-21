import Foundation

/// Deterministic focus path for agents running inside herdr
/// (https://herdr.dev) — a TUI agent multiplexer that lives INSIDE an outer
/// terminal (Ghostty, cmux, …).
///
/// Herdr injects `HERDR_WORKSPACE_ID` / `HERDR_TAB_ID` / `HERDR_PANE_ID` /
/// `HERDR_SOCKET_PATH` into every pane process; the hook forwards all four.
/// At click time we ask the herdr server (newline-delimited JSON-RPC over
/// its Unix socket) to focus the workspace → tab → agent pane:
///
///   {"id":"kato-agent","method":"agent.focus","params":{"target":"w1:p1"}}
///
/// Success responses carry `result`, errors carry `error` (no `ok` flag —
/// that's the cmux envelope).
///
/// Like the tmux path this selection is server-side and exact, but herdr is
/// NOT the outer terminal: raising the host window is left to the caller
/// (cmux surface focus when herdr runs inside cmux; AX title matching when
/// inside Ghostty, where the outer tab title is herdr's own client title —
/// the TTY-marker path can't help because the hook's pty is herdr's inner
/// pane, not the outer surface).
public enum HerdrResolver {
    /// `~/.config/herdr/herdr.sock` (default session).
    public static func defaultSocketPath(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        home.appendingPathComponent(".config/herdr/herdr.sock").path
    }

    /// Success = parsed response with `result` and no `error`.
    public static func isOK(response: String) -> Bool {
        guard let data = response.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        return json["result"] != nil && json["error"] == nil
    }

    /// Focuses workspace → tab → agent pane named by `target`, best effort
    /// per layer. Returns the most specific id that focused successfully
    /// (pane > tab > workspace), or nil when herdr info is absent or every
    /// call failed.
    @discardableResult
    public static func focus(target: FocusTarget) -> String? {
        guard let pane = target.herdrPane, !pane.isEmpty else { return nil }
        let socketPath: String
        if let explicit = target.herdrSocket, !explicit.isEmpty {
            socketPath = explicit
        } else {
            socketPath = defaultSocketPath()
        }
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }

        var best: String?
        if let workspace = target.herdrWorkspace, !workspace.isEmpty,
           call(socketPath: socketPath, id: "kato-ws", method: "workspace.focus",
                params: ["workspace_id": workspace]) {
            best = workspace
        }
        if let tab = target.herdrTab, !tab.isEmpty,
           call(socketPath: socketPath, id: "kato-tab", method: "tab.focus",
                params: ["tab_id": tab]) {
            best = tab
        }
        if call(socketPath: socketPath, id: "kato-agent", method: "agent.focus",
                params: ["target": pane]) {
            best = pane
        }
        return best
    }

    private static func call(socketPath: String, id: String, method: String,
                             params: [String: String]) -> Bool {
        guard let response = UnixJSONRPC.roundTrip(
            socketPath: socketPath,
            body: UnixJSONRPC.request(id: id, method: method, params: params)
        ) else { return false }
        return isOK(response: response)
    }
}
