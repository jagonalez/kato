import AppKit
import Foundation

/// Deterministic focus path for agents running inside cmux
/// (https://github.com/manaflow-ai/cmux).
///
/// cmux auto-sets `CMUX_WORKSPACE_ID` / `CMUX_SURFACE_ID` inside every
/// terminal it spawns — the per-surface identity channel Ghostty lacks.
/// The hook forwards both ids; at click time we ask the cmux app itself
/// (JSON-RPC over a Unix socket, one newline-terminated request per call)
/// to select the workspace and focus the surface. No accessibility-tree
/// guesswork, no title stamping, immune to agent title rewrites.
///
///   {"id":"kato-focus","method":"surface.focus","params":{"surface_id":"…"}}
///
/// Setup caveat: cmux's default socket access mode is "cmux processes
/// only" — kato runs outside cmux, so cmux must be launched with
/// `CMUX_SOCKET_MODE=allowAll` for these calls to succeed. Any failure
/// (no ids, no socket, denied, not running) is non-fatal: the caller
/// falls back to the tmux/AX paths.
public enum CmuxResolver {
    public static let releaseBundleID = "com.cmuxterm.app"
    public static let debugBundleID = "com.cmuxterm.app.debug"
    public static let defaultSocketPath = "/tmp/cmux.sock"

    /// `CMUX_SOCKET_PATH` env override, else the release default.
    public static func socketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let override = environment["CMUX_SOCKET_PATH"] ?? ""
        return override.isEmpty ? defaultSocketPath : override
    }

    /// One newline-terminated JSON-RPC request (sorted keys for
    /// determinism/testability).
    public static func request(id: String, method: String, params: [String: String]) -> String {
        UnixJSONRPC.request(id: id, method: method, params: params)
    }

    /// Success flag of one response line.
    public static func isOK(response: String) -> Bool {
        guard let data = response.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        return (json["ok"] as? Bool) == true
    }

    /// Selects the workspace + focuses the surface named by `target`.
    /// Returns the focused surface id, or nil when cmux info is absent or
    /// the socket call fails.
    @discardableResult
    public static func focus(target: FocusTarget,
                             socketPath: String = CmuxResolver.socketPath()) -> String? {
        guard let surface = target.cmuxSurface, !surface.isEmpty else { return nil }
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }
        if let workspace = target.cmuxWorkspace, !workspace.isEmpty {
            _ = UnixJSONRPC.roundTrip(socketPath: socketPath,
                                      body: request(id: "kato-ws", method: "workspace.select",
                                                    params: ["workspace_id": workspace]))
        }
        guard let response = UnixJSONRPC.roundTrip(socketPath: socketPath,
                                                   body: request(id: "kato-focus", method: "surface.focus",
                                                                 params: ["surface_id": surface])),
              isOK(response: response) else { return nil }
        return surface
    }

    /// The running cmux app (release or debug bundle id), for activation
    /// after a successful socket focus.
    @MainActor public static func runningApp() -> NSRunningApplication? {
        for bundleID in [releaseBundleID, debugBundleID] {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                return app
            }
        }
        return nil
    }
}
