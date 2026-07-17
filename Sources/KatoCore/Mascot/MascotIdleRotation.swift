import Foundation

/// Pure rotation logic for the orb's idle-artwork personality cycle.
///
/// While the mascot is in the `idle` state (see MascotState in the app
/// layer), the orb cycles through the idle variants so the cat feels alive:
///   kato-idle → kato-idle-sleep → kato-idle-play → kato-idle-work → repeat,
/// swapping every `interval` seconds. `alert`/`success` are handled by the
/// caller — pass `active: false` and the rotation resets to the base artwork,
/// so re-entering idle always starts at `kato-idle`.
public struct MascotIdleRotation: Sendable, Equatable {
    public static let variants = ["kato-idle", "kato-idle-sleep", "kato-idle-play", "kato-idle-work"]
    public static let interval: TimeInterval = 45

    public private(set) var variantIndex = 0
    public private(set) var rotationStartedAt: Date?

    public init() {}

    /// Artwork name for the current variant.
    public var imageName: String {
        Self.variants[variantIndex % Self.variants.count]
    }

    /// Drive from a state change or a periodic timer tick.
    /// - Parameter active: true while the mascot state is `idle`.
    public mutating func update(active: Bool, now: Date = Date()) {
        guard active else {
            variantIndex = 0
            rotationStartedAt = nil
            return
        }
        guard let started = rotationStartedAt else {
            rotationStartedAt = now
            return
        }
        if now.timeIntervalSince(started) >= Self.interval {
            variantIndex = (variantIndex + 1) % Self.variants.count
            rotationStartedAt = now
        }
    }
}
