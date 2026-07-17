import Foundation

/// Stub — phase 5. See docs/ARCHITECTURE.md §"Peer-to-peer multi-kato".
///
/// TODO: implement the pieces listed in the module map:
///   - BonjourAdvertiser: NWListener advertising `_kato._tcp` (LAN zero-config).
///   - BonjourBrowser: NWBrowser discovering peers.
///   - PeerLink: length-prefixed JSON over the connection, shared-secret HMAC
///     (v1 LAN trust model).
///   - PeerSync (this type): glue that forwards local EventBus events to peers
///     and ingests remote ones with `source: .peer(name)`, `focus: nil`
///     (render as notifications/badges only, never clickable-to-focus).
/// v2: Tailscale/WireGuard transport for off-LAN sync.
public actor PeerSync {
    public static let serviceType = "_kato._tcp"

    public init() {}

    public func start() {
        // TODO(phase 5): see docs/ARCHITECTURE.md §"Peer-to-peer multi-kato".
    }

    public func stop() {
        // TODO(phase 5): see docs/ARCHITECTURE.md §"Peer-to-peer multi-kato".
    }
}
