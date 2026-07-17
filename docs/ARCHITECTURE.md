# Kato — Architecture

Personal / executive assistant for macOS. Monitors your AI coding agents, GitHub PRs,
and Slack; surfaces events in a floating panel; one click takes you to the exact
window + tab that needs you. Runs on multiple laptops and syncs events peer-to-peer.

## Decisions

### Stack: native Swift (SwiftUI + AppKit), SwiftPM executable → hand-rolled .app bundle
- Required for: floating always-on-top `NSPanel`, Accessibility (AX) APIs to raise
  other apps' windows, menu-bar agent mode (`LSUIElement`).
- No Xcode project: `swift build` produces a binary; `Scripts/make-app.sh` assembles
  `Kato.app` (Info.plist, icon, codesign ad-hoc). Dev loop: `swift run Kato`.

### Event model (everything funnels here)
```swift
struct KatoEvent: Codable, Identifiable {
    var id: UUID
    var kind: Kind            // agentDone, agentNeedsInput, ciPassed, ciFailed,
                              // prComment, prReview, slackMention, slackDM, remoteTaskDone
    var source: Source        // .local / .peer(name)
    var title: String         // "claude · kato · main"
    var detail: String        // "Waiting for confirmation"
    var url: URL?             // web deep link (GitHub PR, Slack message)
    var focus: FocusTarget?   // how to bring the right window forward (local only)
    var createdAt: Date
    var dedupeKey: String     // monitor-specific, for update-in-place
}

struct FocusTarget: Codable {
    var appBundleID: String      // com.mitchellh.ghostty
    var windowTitleToken: String // substring to match against window/tab titles
    var processPID: Int32?
}
```
- `EventBus` (actor): ingest → dedupe → persist (JSON file, `~/Library/Application Support/Kato/events.json`) → publish to UI + peers.

### AI-agent monitoring — hooks, NOT pcap
pcap on loopback is the wrong layer: localhost traffic, TLS, and per-CLI protocol
parsing. Every CLI you use has a first-class hook:

| Tool | Hook | What kato does with it |
|---|---|---|
| Claude Code | `settings.json` hooks: `Notification`, `Stop`, `SubagentStop` | hook runs `curl -X POST 127.0.0.1:7811/event` with JSON (event, cwd, tty, pid, transcript) |
| Codex CLI | `~/.codex/config.toml` → `notify = ["/path/to/kato-hook"]` | same endpoint, argv JSON |
| Kimi Code / others | wrapper or generic `kato hook` subcommand | `kato hook --kind needsInput --title "..."` |
| Fallback (no hook) | AX text watch + process/CPU watch on known agent PIDs | heuristic "idle > N s after activity" = done/needs-input |

- `HookServer`: tiny HTTP server on `127.0.0.1:7811` (Network.framework), `POST /event`.
- Hook payload includes the TTY + cwd; kato resolves TTY → owning terminal window.

### Ghostty window+tab focus (the hard part)
Ghostty windows are real macOS windows and its tabs are native macOS window tabs,
both reachable through the AX API (requires Accessibility permission, prompted at first use):

1. Every hook/wrapper stamps the terminal title with a token: `cwd basename · branch · agent`
   (Claude Code already mutates the tab title; hooks can emit `OSC 0 ; <title> BEL`).
2. Click on event → `FocusController`:
   - `AXUIElementCopyAttributeValue(app, kAXWindowsAttribute)` → iterate windows.
   - For each window, read `kAXTitleAttribute` and the `AXTabGroup` children titles.
   - Match `windowTitleToken` → select the tab (`AXSelected` on the tab radio button),
     `AXRaise` the window, `NSRunningApplication.activate`.
3. If no match (title drifted), fall back to raising the app and flashing a toast
   with the expected title so the user can fix the title template.

### GitHub monitor (first-class, `gh` is installed & authed)
- Poll loop (~30 s, backoff on rate limit):
  - `gh api notifications` → PR review requests, mentions.
  - `gh api graphql` → viewer's open PRs: `checkRuns`/`statusCheckRollup`, `reviews`,
    `comments` since last poll watermark.
- Diff against persisted watermark → emit `ciPassed/ciFailed/prComment/prReview` with `url`
  = PR URL (click opens browser — no window focus needed).

### Slack monitor (pluggable, phase 2)
- `Monitor` protocol seam now; implementation later. Candidate paths, in preference order:
  1. Slack app w/ Socket Mode (`xapp` token) — real-time, no polling, needs a workspace app.
  2. User token polling (`xoxp`, `conversations.history` on mentions/DMs).
  3. Notification Center scrape — rejected (Full Disk Access, brittle).

### Peer-to-peer multi-kato
- Bonjour via Network.framework: advertise `_kato._tcp` + browse for peers (LAN zero-config).
- Each peer connection: length-prefixed JSON, shared-secret HMAC (v1 LAN trust model).
- Remote events arrive with `source: .peer(name)` and `focus: nil` → render as
  notifications/badges only ("Laptop-2: build done"), never clickable-to-focus.
- v2: Tailscale/WireGuard transport for off-LAN sync.

### UI
- Menu-bar agent (`LSUIElement` = true). Two faces:
  1. **Floating mode**: borderless `NSPanel`, `.nonactivatingPanel`, level `.floating`,
     `canJoinAllSpaces`; collapsed = orb with badge count, expanded = event list.
  2. **Popover mode**: classic menu-bar popover (fallback).
- Event row click → `focus != nil` ? FocusController.focus(target) : open `url`.
- SwiftUI `EventListView` shared by both faces.

## Module map (SwiftPM, single executable target `Kato` + library `KatoCore`)
```
KatoCore/
  Events/      KatoEvent, EventBus, EventStore
  Hooks/       HookServer (127.0.0.1:7811), hook payload decoding
  Monitors/    Monitor protocol, GitHubMonitor, AgentProcessWatcher (fallback)
  Focus/       FocusController (AX), TerminalTitleResolver
  Peers/       BonjourAdvertiser, BonjourBrowser, PeerLink, PeerSync
Kato/
  App/         KatoApp (menu bar agent), AppState
  UI/          FloatingPanel, EventListView, OrbView
Scripts/
  make-app.sh  build → Kato.app bundle
  hooks/claude-hook.sh, codex-notify.sh   (installed into each CLI's config)
```

## Build order (this repo)
1. Skeleton builds: `swift build` green, empty menu-bar app runs.
2. HookServer + EventBus + FloatingPanel (test: `kato hook` CLI injects fake event).
3. FocusController against Ghostty.
4. GitHubMonitor.
5. Peers.
6. SlackMonitor.
