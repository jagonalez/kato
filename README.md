# Kato

Personal-assistant menu-bar app for macOS. It monitors your AI coding CLIs
(Claude Code, Codex), GitHub PRs, and Slack; surfaces everything as
events in a floating panel; and can jump you to the exact Ghostty window/tab
that needs your attention.

Spec: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

## Build & run

Requirements: macOS 14+, Swift 6 toolchain, `gh` (GitHub CLI, authenticated).
No third-party dependencies; no Xcode project.

```sh
swift build                # debug build
swift run Kato             # run the menu-bar agent (menu bar + floating orb)
swift run KatoSmoke        # smoke harness: HookServer/EventBus/EventStore checks
swift test                 # XCTest suite (requires full Xcode; CLT-only machines
                           #   lack XCTest — use KatoSmoke there instead)

Scripts/make-app.sh        # release build → build/Kato.app (LSUIElement, ad-hoc signed)
open build/Kato.app        # run packaged app; also symlinks ~/.local/bin/kato
```

The app is a menu-bar agent: an orb appears at the top-right of the screen
(click to expand the event list), plus a menu-bar item with the event count.

## CLI subcommands

The same binary doubles as a CLI (detected before the app starts):

```sh
kato hook --kind needsInput --title "claude · kato" --detail "Waiting for confirmation"
#   → POSTs to the local hook server (127.0.0.1:7811). Used by hooks & smoke tests.

kato focus-test "kato"     # → exercises FocusController against Ghostty directly
kato serve                 # → headless hook server + event bus (dev/smoke testing)
```

## Installing the hooks

### Claude Code

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Notification": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "/Users/jeremy/dev/kato/Scripts/hooks/claude-hook.sh" } ] }
    ],
    "Stop": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "/Users/jeremy/dev/kato/Scripts/hooks/claude-hook.sh" } ] }
    ]
  }
}
```

(The same snippet is in a comment block at the top of
[Scripts/hooks/claude-hook.sh](Scripts/hooks/claude-hook.sh).)

### Codex CLI

Add to `~/.codex/config.toml`:

```toml
notify = ["/Users/jeremy/dev/kato/Scripts/hooks/codex-notify.sh"]
```

## Connecting Slack

Kato polls Slack **as you**, with a user token — no bot, no Socket Mode, no
channel invites. Every 30 s it surfaces: DMs to you, `<@you>` mentions in
every channel you're a member of, and **mark-as-unread** reminders (mark a
DM unread in Slack → event appears; read it → event retracts). Messages
that arrived while Kato was offline notify after launch. Your Slack user ID
is discovered from the token itself — nothing else to configure.

1. Create a Slack app at <https://api.slack.com/apps> → "Create New App" →
   "From a manifest" and paste [docs/slack-app-manifest.yaml](docs/slack-app-manifest.yaml).
2. Settings → Install App → Install to your workspace.
3. Features → OAuth & Permissions → copy the **User OAuth Token** (`xoxp-...`).
4. Paste it into Kato: expand the panel → gear → Slack → Save. (The pane
   writes to the app-support dir and reconnects immediately; no restart,
   no env vars.)

Notes:

- The first sight of each DM seeds silently — existing messages won't spam
  you; only new activity notifies.
- **Workspace enforces token rotation?** (user tokens expire every 12 h)
  Also paste the client ID, client secret and refresh token (`xoxe-1-…`,
  both shown at install time) into the settings pane — Kato renews the
  token automatically via `oauth.v2.exchange`.
- Mentions use `search.messages`, so they can lag real time by up to ~30 s
  plus Slack's search-indexing delay (usually seconds).
- Advanced: the files the pane writes (`slack-user-token` /
  `slack-user-token.json` in `~/Library/Application Support/Kato`) can also
  be managed by hand; `KATO_SLACK_USER_TOKEN` works when launching from a
  shell. Per-DM watermarks live in `slack-dm-watermark.json` there.

Without a token the monitor is a silent no-op; configuration problems are
logged to stderr (`kato: slack: ...`) and shown in the settings pane.

### Focusing terminal windows
Clicking a local agent event raises the matching Ghostty window/tab via the
Accessibility API. On first use macOS will prompt for Accessibility
permission (System Settings → Privacy & Security → Accessibility) — or use
the "Request Accessibility Permission…" menu item.

Tab identification does NOT rely on titles (Claude Code rewrites them live;
users rename tabs). Inside tmux the pane is selected server-side; otherwise
kato stamps the tab through the event's TTY (`OSC 2` → `/dev/ttysNNN`,
verified against the agent's pid so recycled pty numbers can't misfire),
finds the unique marker in the AX tab bar, then restores the title. Ranked
title matching remains as the fallback for events without a TTY.

## Module status

| Module | Status |
|---|---|
| `KatoCore/Events` — KatoEvent, EventBus (actor, dedupe by `dedupeKey`), EventStore (JSON in `~/Library/Application Support/Kato`) | ✅ working, verified via `KatoSmoke` harness + XCTest suite (Xcode required for the latter) |
| `KatoCore/Hooks` — HookServer on `127.0.0.1:7811` (`POST /event`, `GET /health`, Network.framework) | ✅ working, verified via `KatoSmoke` + live `kato serve` / `kato hook` round-trip |
| `KatoCore/Focus` — FocusController (TTY tab-stamp + tmux resolver + ranked AX fallback; permission helpers) | ✅ working, verified via `kato focus-test` / `ax-dump` |
| `KatoCore/Monitors` — Monitor protocol + GitHubMonitor (`gh` polling, 30 s, persisted watermark) + SlackMonitor (Socket Mode) | ✅ working |
| `KatoCore/Peers` — PeerSync | 🚧 stub (phase 5, see ARCHITECTURE.md §Peer-to-peer) |
| `Kato` app — menu-bar agent, floating NSPanel (orb ↔ event list), shared EventListView | ✅ working |
| Hook scripts — claude-hook.sh, codex-notify.sh | ✅ ready to install |
| AgentProcessWatcher (AX/CPU fallback watcher) | 🚧 not started (fallback path in ARCHITECTURE.md) |

Events persist across launches in `~/Library/Application Support/Kato/events.json`;
GitHub poll state in `github-watermark.json` (same directory). First GitHub poll
seeds the watermark silently so you don't get a burst of historical events.
