import Foundation

/// How to bring the right window forward (local events only).
/// See docs/ARCHITECTURE.md §"Ghostty window+tab focus".
public struct FocusTarget: Codable, Sendable, Equatable {
    /// e.g. "com.mitchellh.ghostty"
    public var appBundleID: String
    /// Substring to match against window/tab titles.
    public var windowTitleToken: String
    /// Optional pid of the originating CLI process (informational; the app
    /// itself is located via its bundle id).
    public var processPID: Int32?
    /// Optional tmux "session:window.pane" target captured by the hook.
    public var tmuxTarget: String?
    /// Optional TTY of the originating process (tmux resolution fallback).
    public var tty: String?
    /// Optional cmux workspace + surface ids (CMUX_WORKSPACE_ID /
    /// CMUX_SURFACE_ID), captured by the hook when the agent runs inside
    /// cmux — enables deterministic focus via cmux's socket API.
    public var cmuxWorkspace: String?
    public var cmuxSurface: String?
    /// Optional herdr socket path + workspace/tab/pane ids (HERDR_SOCKET_PATH /
    /// HERDR_WORKSPACE_ID / HERDR_TAB_ID / HERDR_PANE_ID), captured by the hook
    /// when the agent runs inside herdr — enables deterministic pane focus via
    /// herdr's socket API (the outer terminal window is raised separately).
    public var herdrSocket: String?
    public var herdrWorkspace: String?
    public var herdrTab: String?
    public var herdrPane: String?

    public init(appBundleID: String, windowTitleToken: String, processPID: Int32? = nil,
                tmuxTarget: String? = nil, tty: String? = nil,
                cmuxWorkspace: String? = nil, cmuxSurface: String? = nil,
                herdrSocket: String? = nil, herdrWorkspace: String? = nil,
                herdrTab: String? = nil, herdrPane: String? = nil) {
        self.appBundleID = appBundleID
        self.windowTitleToken = windowTitleToken
        self.processPID = processPID
        self.tmuxTarget = tmuxTarget
        self.tty = tty
        self.cmuxWorkspace = cmuxWorkspace
        self.cmuxSurface = cmuxSurface
        self.herdrSocket = herdrSocket
        self.herdrWorkspace = herdrWorkspace
        self.herdrTab = herdrTab
        self.herdrPane = herdrPane
    }
}

/// Every signal kato surfaces funnels into this one model.
/// See docs/ARCHITECTURE.md §"Event model".
public struct KatoEvent: Codable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case agentDone
        case agentNeedsInput
        case ciPassed
        case ciFailed
        case prComment
        case prReview
        case slackMention
        case slackDM
        case remoteTaskDone
    }

    public enum Source: Codable, Sendable, Equatable {
        case local
        case peer(String)

        public var displayName: String {
            switch self {
            case .local: return "local"
            case .peer(let name): return name
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var source: Source
    /// e.g. "claude · kato · main"
    public var title: String
    /// e.g. "Waiting for confirmation"
    public var detail: String
    /// Web deep link (GitHub PR, Slack message).
    public var url: URL?
    /// How to bring the right window forward (local only).
    public var focus: FocusTarget?
    public var createdAt: Date
    /// Monitor-specific key, for dedupe / update-in-place.
    public var dedupeKey: String

    public init(
        id: UUID = UUID(),
        kind: Kind,
        source: Source = .local,
        title: String,
        detail: String = "",
        url: URL? = nil,
        focus: FocusTarget? = nil,
        createdAt: Date = Date(),
        dedupeKey: String
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.title = title
        self.detail = detail
        self.url = url
        self.focus = focus
        self.createdAt = createdAt
        self.dedupeKey = dedupeKey
    }
}
