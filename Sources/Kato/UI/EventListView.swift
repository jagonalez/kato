import KatoCore
import SwiftUI

/// Shared event list used by both the floating panel and (potentially) the
/// menu-bar popover. Events arrive pre-grouped by title: a group renders as
/// ONE row (its newest event) with a ×N badge; a chevron expands it to the
/// individual events. Row click → `onSelect`; hover reveals a dismiss ×.
struct EventListView: View {
    let groups: [EventGroup]
    var onSelect: (KatoEvent) -> Void
    var onDelete: (KatoEvent) -> Void
    var onDeleteGroup: (EventGroup) -> Void

    @State private var expanded: Set<String> = []

    var body: some View {
        if groups.isEmpty {
            emptyState
        } else {
            List(groups) { group in
                if group.events.count == 1 {
                    selectableRow(event: group.representative)
                } else {
                    groupStack(for: group)
                }
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

    private func selectableRow(event: KatoEvent) -> some View {
        EventRow(event: event, onDelete: { onDelete(event) })
            .onTapGesture { onSelect(event) }
    }

    private func groupStack(for group: EventGroup) -> some View {
        let isExpanded = expanded.contains(group.key)
        return VStack(alignment: .leading, spacing: 0) {
            EventRow(event: group.representative,
                     count: group.events.count,
                     isExpanded: isExpanded,
                     onToggleExpand: { toggle(group.key) },
                     onDelete: { onDeleteGroup(group) })
                .onTapGesture { onSelect(group.representative) }
            if isExpanded {
                ForEach(group.events) { event in
                    EventRow(event: event, compact: true, onDelete: { onDelete(event) })
                        .onTapGesture { onSelect(event) }
                }
            }
        }
    }

    private func toggle(_ key: String) {
        if expanded.contains(key) {
            expanded.remove(key)
        } else {
            expanded.insert(key)
        }
    }
}

/// One event row: kind icon, title (+ ×N badge for groups), detail,
/// relative time. Buttons are siblings of the row's tap gesture (no nested
/// buttons): chevron toggles expansion, × dismisses.
private struct EventRow: View {
    let event: KatoEvent
    var count: Int = 0
    var isExpanded: Bool = false
    var compact: Bool = false
    var onToggleExpand: (() -> Void)?
    var onDelete: (() -> Void)?

    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: event.kind))
                .font(compact ? .body : .title3)
                .foregroundStyle(color(for: event.kind))
                .frame(width: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(compact ? .body.weight(.semibold) : .title3.weight(.semibold))
                        .lineLimit(2)
                    if count > 1 {
                        Text("×\(count)")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(compact ? .callout : .body)
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
            Spacer(minLength: 0)
            controls
        }
        .padding(.vertical, 6)
        .padding(.leading, compact ? 34 : 0)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var controls: some View {
        // Chevron stays visible for groups (discoverability); × is hover-only.
        HStack(spacing: 4) {
            if let onToggleExpand {
                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Collapse" : "Show all \(count)")
            }
            if hovered, let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
        }
        .padding(.top, 2)
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
