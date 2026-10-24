import SwiftUI

enum AppTab: Hashable, CaseIterable {
    case inbox, history, stats, settings

    var label: String {
        switch self {
        case .inbox: return "INBOX"
        case .history: return "HISTORY"
        case .stats: return "STATS"
        case .settings: return "SETTINGS"
        }
    }

    var accessibilityName: String {
        switch self {
        case .inbox: return "Inbox"
        case .history: return "History"
        case .stats: return "Stats"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: return "tray.fill"
        case .history: return "clock.arrow.circlepath"
        case .stats: return "chart.bar.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct PillTabBar: View {
    @Binding var selection: AppTab
    var inboxCount: Int = 0
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
                .accessibilityValue(tab == .inbox && inboxCount > 0 ? "\(inboxCount) waiting" : "")
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
}
