import KatoCore
import SwiftUI

/// Shared event list used by both the floating panel and (potentially) the
/// menu-bar popover. Each row: kind icon, title, detail, relative time.
/// Row click → `onSelect` (focus the terminal window/tab, or open the URL).
struct EventListView: View {
    let events: [KatoEvent]
    var onSelect: (KatoEvent) -> Void

    var body: some View {
        if events.isEmpty {
            emptyState
        } else {
            List(events) { event in
                Button {
                    onSelect(event)
                } label: {
                    row(for: event)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    /// Custom branded empty state. (ContentUnavailableView on macOS does
    /// aggressive vertical centering inside plain VStacks and pushed the
    /// panel header down, leaving a dead band at the top.)
    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            if let mascot = AssetLoader.image(named: "kato-idle") {
                Image(nsImage: mascot)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 90, height: 90)
            }
            Text("No events")
                .font(.title3.weight(.semibold))
            Text("Agent, CI and PR events will show up here.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for event: KatoEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: event.kind))
                .font(.title3)
                .foregroundStyle(color(for: event.kind))
                .frame(width: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                HStack(spacing: 6) {
                    Text(event.createdAt, style: .relative)
                    if case .peer(let name) = event.source {
                        Text("· \(name)")
                    }
                    if event.focus != nil {
                        Image(systemName: "macwindow")
                    } else if event.url != nil {
                        Image(systemName: "link")
                    }
                }
                .font(.callout)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func icon(for kind: KatoEvent.Kind) -> String {
        switch kind {
        case .agentDone: return "checkmark.circle.fill"
        case .agentNeedsInput: return "questionmark.bubble.fill"
        case .ciPassed: return "checkmark.seal.fill"
        case .ciFailed: return "xmark.seal.fill"
        case .prComment: return "bubble.left.fill"
        case .prReview: return "eye.fill"
        case .slackMention: return "at"
        case .slackDM: return "envelope.fill"
        case .remoteTaskDone: return "laptopcomputer.and.arrow.down"
        }
    }

    private func color(for kind: KatoEvent.Kind) -> Color {
        switch kind {
        case .agentDone, .ciPassed, .remoteTaskDone: return .green
        case .agentNeedsInput, .prReview, .slackMention: return .orange
        case .ciFailed: return .red
        case .prComment, .slackDM: return .blue
        }
    }
}
