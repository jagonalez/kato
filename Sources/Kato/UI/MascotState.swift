import Foundation
import KatoCore

/// Which mascot face the orb shows, derived from the current events.
enum MascotState: String, Sendable {
    case idle
    case alert
    case success

    var imageName: String { "kato-\(rawValue)" }

    /// `success` decays back to `idle` after this long without new events.
    static let successDecay: TimeInterval = 60

    /// Things that need the human right now.
    static let attentionKinds: Set<KatoEvent.Kind> = [
        .agentNeedsInput, .ciFailed, .slackMention, .slackDM,
    ]

    /// - alert:   ANY current event needs the human.
    /// - success: most recent event is ciPassed/agentDone and the last event
    ///            arrived < successDecay ago.
    /// - idle:    everything else.
    static func resolve(events: [KatoEvent], lastEventAt: Date?, now: Date = Date()) -> MascotState {
        if events.contains(where: { attentionKinds.contains($0.kind) }) {
            return .alert
        }
        if let lastEventAt,
           let mostRecent = events.first,
           mostRecent.kind == .ciPassed || mostRecent.kind == .agentDone,
           now.timeIntervalSince(lastEventAt) < successDecay {
            return .success
        }
        return .idle
    }
}
