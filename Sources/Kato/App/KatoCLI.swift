import Foundation
import KatoCore

/// CLI subcommands:
///   kato hook --kind needsInput --title "..." [--detail "..."] [--cwd ...] [--tty ...] [--pid ...] [--url ...]
///       POSTs an event to the local hook server (also used for smoke tests).
///   kato focus-test "title-token"
///       Exercises FocusController directly against Ghostty.
///   kato ax-dump [bundle-id]
///       Dumps the running Ghostty (or other app's) accessibility tree:
///       window titles, tab groups, tab buttons, roles and selected state.
///   kato serve
///       Runs just the HookServer (+ EventBus) in the foreground — handy for
///       development and headless smoke testing.
@MainActor
enum KatoCLI {
    static let knownSubcommands: Set<String> = ["hook", "focus-test", "serve", "assets-check", "ax-dump"]

    static func run(subcommand: String, arguments: [String]) async -> Int32 {
        switch subcommand {
        case "hook":
            return await runHook(arguments)
        case "focus-test":
            return runFocusTest(arguments)
        case "serve":
            return runServe()
        case "assets-check":
            return runAssetsCheck()
        case "ax-dump":
            return runAXDump(arguments)
        default:
            return 2
        }
    }

    // MARK: - kato assets-check

    /// Debug path: verifies AssetLoader resolves all mascot images in the
    /// current (dev or bundled) mode.
    private static func runAssetsCheck() -> Int32 {
        let names = [
            "kato-idle", "kato-idle-sleep", "kato-idle-play", "kato-idle-work",
            "kato-alert", "kato-success", "kato-appicon",
        ]
        var missing = 0
        for name in names {
            if let url = AssetLoader.url(forImageNamed: name),
               AssetLoader.image(named: name) != nil {
                print("OK      \(name) → \(url.path)")
            } else {
                print("MISSING \(name)")
                missing += 1
            }
        }
        print(missing == 0 ? "all assets found" : "\(missing) asset(s) missing")
        return missing == 0 ? 0 : 1
    }

    // MARK: - kato hook

    private static func runHook(_ args: [String]) async -> Int32 {
        let options = parseOptions(args)
        guard let kind = options["kind"], let title = options["title"] else {
            FileHandle.standardError.write(Data("""
            usage: kato hook --kind <kind> --title <title> [--detail <text>] [--cwd <path>] [--tty <tty>] [--pid <pid>] [--url <url>] [--tmux <session:window.pane>]

            """.utf8))
            return 2
        }
        let payload = HookServer.HookPayload(
            kind: kind,
            title: title,
            detail: options["detail"],
            tty: options["tty"],
            cwd: options["cwd"] ?? FileManager.default.currentDirectoryPath,
            pid: options["pid"].flatMap(Int32.init),
            url: options["url"],
            tmux: options["tmux"]
        )
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(HookServer.defaultPort)/event")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3
        do {
            request.httpBody = try JSONEncoder().encode(payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                FileHandle.standardError.write(Data("kato hook: server returned \(status)\n".utf8))
                return 1
            }
            print("event delivered: \(String(data: data, encoding: .utf8) ?? "")")
            return 0
        } catch {
            FileHandle.standardError.write(Data(
                "kato hook: could not reach hook server at 127.0.0.1:\(HookServer.defaultPort) — is kato running? (\(error.localizedDescription))\n".utf8))
            return 1
        }
    }

    // MARK: - kato focus-test

    private static func runFocusTest(_ args: [String]) -> Int32 {
        guard let token = args.first(where: { !$0.hasPrefix("--") }) else {
            FileHandle.standardError.write(Data("usage: kato focus-test <window-title-token> [--tmux <session:window.pane>] [--tty <tty>]\n".utf8))
            return 2
        }
        let options = parseOptions(args)
        if !FocusController.isAccessibilityTrusted() {
            print("Accessibility permission not granted yet — requesting (grant it, then re-run)…")
            FocusController.requestAccessibilityPermission()
        }
        let target = FocusTarget(
            appBundleID: TerminalTitleResolver.ghosttyBundleID,
            windowTitleToken: token,
            tmuxTarget: options["tmux"],
            tty: options["tty"]
        )
        switch FocusController().focus(target) {
        case .success:
            print("focused window/tab matching '\(token)'")
            return 0
        case .failure(let error):
            print("focus failed: \(error)")
            return 1
        }
    }

    // MARK: - kato ax-dump

    private static func runAXDump(_ args: [String]) -> Int32 {
        let bundleID = args.first(where: { !$0.hasPrefix("--") })
            ?? TerminalTitleResolver.ghosttyBundleID
        if !FocusController.isAccessibilityTrusted() {
            print("Accessibility permission not granted yet — requesting (grant it, then re-run)…")
            FocusController.requestAccessibilityPermission()
        }
        print(AXDumper.dump(bundleID: bundleID))
        return 0
    }

    // MARK: - kato serve

    private static func runServe() -> Int32 {
        let bus = EventBus()
        let server = HookServer { event in
            print("event: [\(event.kind.rawValue)] \(event.title) — \(event.detail)")
            Task { await bus.ingest(event) }
        }
        do {
            try server.start()
        } catch {
            FileHandle.standardError.write(Data("kato serve: \(error.localizedDescription)\n".utf8))
            return 1
        }
        print("kato hook server listening on 127.0.0.1:\(HookServer.defaultPort) (ctrl-c to stop)")
        dispatchMain()
    }

    // MARK: - Option parsing

    private static func parseOptions(_ args: [String]) -> [String: String] {
        var options: [String: String] = [:]
        var index = 0
        while index < args.count {
            if args[index].hasPrefix("--"), index + 1 < args.count {
                options[String(args[index].dropFirst(2))] = args[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        return options
    }
}
