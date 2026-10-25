import SwiftUI

/// Four tabs: Stats lives inside History as a segment, which keeps the bar
/// at four and the Dynamic Type cap below workable.
enum AppTab: Hashable, CaseIterable {
    // Sessions first: the live list is home; the inbox holds what needs an answer.
    case sessions, inbox, history, settings

    var label: String {
        switch self {
        case .inbox: return "INBOX"
        case .sessions: return "SESSIONS"
        case .history: return "HISTORY"
        case .settings: return "SETTINGS"
        }
    }

    var accessibilityName: String {
        switch self {
        case .inbox: return "Inbox"
        case .sessions: return "Sessions"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: return "tray.fill"
        case .sessions: return "terminal.fill"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape.fill"
        }
    }
}

struct PillTabBar: View {
    @Binding var selection: AppTab
    var inboxCount: Int = 0
    /// Live sessions waiting on the user, read out on the Sessions tab.
    var sessionsNeedingYou: Int = 0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button { selection = tab } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(.body, design: .default, weight: .semibold))
                        Text(tab.label)
                            .font(.system(.caption2, design: .default, weight: .semibold))
                            .tracking(0.5)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(selection == tab
                                     ? AnyShapeStyle(Theme.Colour.onAccent)
                                     : AnyShapeStyle(Theme.Colour.textMuted))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        ZStack {
                            if selection == tab {
                                RoundedRectangle(cornerRadius: 26, style: .continuous)
                                    .fill(Theme.Colour.pulseGradient(scheme))
                            }
                        }
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.accessibilityName)
                .accessibilityValue(accessibilityValue(tab))
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(4)
        .frame(minHeight: 62)
        .fixedSize(horizontal: false, vertical: true)
        // Four tabs can't grow forever on a phone; past this size iOS's own
        // tab bars rely on the large-content viewer too.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .background(
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(Theme.Colour.surfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: 36, style: .continuous)
                        .strokeBorder(Theme.Colour.hairline, lineWidth: 1)
                )
        )
        .padding(.horizontal, 21)
        .padding(.bottom, 21)
    }

    private func accessibilityValue(_ tab: AppTab) -> String {
        switch tab {
        case .inbox where inboxCount > 0: return "\(inboxCount) waiting"
        case .sessions where sessionsNeedingYou > 0: return "\(sessionsNeedingYou) need\(sessionsNeedingYou == 1 ? "s" : "") you"
        default: return ""
        }
    }
}
