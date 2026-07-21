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
    var appBundleID: String      // com.mitchellh.ghostty / com.cmuxterm.app
    var windowTitleToken: String // substring to match against window/tab titles
    var processPID: Int32?
    var tmuxTarget: String?      // "session:window.pane" (deterministic tmux path)
    var tty: String?             // pty of the agent (marker path / tmux fallback)
    var cmuxWorkspace: String?   // CMUX_WORKSPACE_ID (deterministic cmux path)
    var cmuxSurface: String?     // CMUX_SURFACE_ID  (deterministic cmux path)
    var herdrSocket: String?     // HERDR_SOCKET_PATH
    var herdrWorkspace: String?  // HERDR_WORKSPACE_ID (deterministic herdr path)
    var herdrTab: String?        // HERDR_TAB_ID
    var herdrPane: String?       // HERDR_PANE_ID
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
both reachable through the AX API (requires Accessibility permission, prompted at first use).
Ghostty exposes NO per-tab API (no AppleScript, no IPC socket, no per-surface env var —
unlike Kitty/WezTerm/iTerm/**cmux**), and Claude Code rewrites tab titles live (task summaries,
spinner glyphs, duplicate generic titles), so titles cannot be the identity channel.
Every hook payload therefore carries the agent's TTY (+ cwd, pid); a TTY maps 1:1 to a
Ghostty surface. Click on event → `FocusController`, in order:

0. **herdr ids present → herdr's socket API (deterministic pane selection).**
   herdr injects `HERDR_WORKSPACE_ID` / `HERDR_TAB_ID` / `HERDR_PANE_ID` /
   `HERDR_SOCKET_PATH` into every pane; the hook forwards all four.
   `HerdrResolver` sends `workspace.focus` → `tab.focus` → `agent.focus`
   (newline-delimited JSON-RPC over `~/.config/herdr/herdr.sock`). herdr is a
   TUI multiplexer INSIDE the host terminal, so this never raises the outer
   window itself — it composes with the paths below (cmux surface focus when
   herdr runs inside cmux; title match → front-window activation as last
   resort inside Ghostty, where the outer tab title is herdr's own client
   title and the hook's pty is herdr's inner pane, so the TTY marker is
   skipped for herdr events).
1. **cmux ids present → cmux's own socket API (fully deterministic, no AX).**
   cmux auto-sets `CMUX_WORKSPACE_ID` / `CMUX_SURFACE_ID` in every terminal it
   spawns; the hook forwards both. `CmuxResolver` sends `workspace.select` +
   `surface.focus` (JSON-RPC over `/tmp/cmux.sock`) and activates the app —
   immune to title rewrites by construction, works without Accessibility
   permission. Requires cmux to run with `CMUX_SOCKET_MODE=allowAll` (its
   default access mode only serves processes spawned inside cmux). Bundle id
   `com.cmuxterm.app`; any socket failure falls through to the paths below.
2. tmux target present → `tmux select-window/select-pane` server-side (deterministic),
   then raise the front terminal window.
3. TTY marker (`TabMarker`): verify the event's pid still owns the TTY (Darwin recycles
   pty numbers), stamp the surface's title via `OSC 2` written to `/dev/<tty>`
   ("● \<token\> ⌁\<tty\>"), find the unique marker among the AX tab-bar radio buttons
   (~0.8 s refresh, polled), select the tab, raise its (now main) window, restore the
   plain title. Deterministic; the agent is idle at click time by definition.
4. Ranked title match (exact > case-insensitive exact > prefix > substring) across
   EVERY window's tab group — fallback for events without a TTY.
5. No match → surface the focus error in the menu/panel; URL events fall back to
   opening the deep link instead.

### GitHub monitor (first-class, `gh` is installed & authed)
- Poll loop (~30 s, backoff on rate limit):
  - `gh api notifications` → PR review requests, mentions.
  - `gh api graphql` → viewer's open PRs: `checkRuns`/`statusCheckRollup`, `reviews`,
    `comments` since last poll watermark.
- Diff against persisted watermark → emit `ciPassed/ciFailed/prComment/prReview` with `url`
  = PR URL (click opens browser — no window focus needed).

### Slack monitor (Socket Mode, `xapp` app-level token)
- One app-level token opens a WebSocket via `apps.connections.open`; Slack pushes
  envelopes down the socket, each acked by `envelope_id` (re-sends deduped by ID).
  No polling; reconnect is immediate on Slack's `disconnect` frame (wss URLs
  rotate), otherwise exponential backoff capped at 60 s.
- Surfaces: `app_mention` → `slackMention`; `message` in IMs → `slackDM`;
  channel `message` containing `<@$KATO_SLACK_USER_ID>` → `slackMention` (only
  when that env var is set and the app subscribes to `message.channels` /
  `message.groups`). Bot messages and subtypes (edits, joins) are ignored.
- `url` = `slack://channel?team=…&id=…&message=…` deep link (opens the desktop
  app; no workspace subdomain needed), `focus` = nil.
- Token resolution: `KATO_SLACK_APP_TOKEN` env → `slack-app-token` file in the
  app-support dir (GUI apps don't inherit shell env). Setup: Slack app →
  Socket Mode on → app-level token (`connections:write`) → subscribe to
  `app_mention`, `message.im` → install to workspace.
- Rejected: Notification Center scrape (Full Disk Access, brittle).
  Later: `xoxb` bot token for `chat.getPermalink` URLs + channel/user names.

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
- The mascot can be hidden entirely (**Hide Mascot** menu item, persisted via
  `kato.mascotHidden` in UserDefaults): the floating panel never appears and
  the menu-bar extra (icon + group count) is the only face.
- Event row click → `focus != nil` ? FocusController.focus(target) : open `url`.
- SwiftUI `EventListView` shared by both faces.

## Module map (SwiftPM, single executable target `Kato` + library `KatoCore`)
```
KatoCore/
  Events/      KatoEvent, EventBus, EventStore
  Hooks/       HookServer (127.0.0.1:7811), hook payload decoding
  Monitors/    Monitor protocol, GitHubMonitor, SlackMonitor, AgentProcessWatcher (fallback)
  Focus/       FocusController (AX), TerminalTitleResolver, TmuxResolver,
               CmuxResolver, HerdrResolver, UnixJSONRPC, TabMarker
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
