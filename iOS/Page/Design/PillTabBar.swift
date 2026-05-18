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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button { selection = tab } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 18, weight: .semibold))
                        Text(tab.label)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.5)
                    }
                    .foregroundStyle(selection == tab
                                     ? AnyShapeStyle(scheme == .dark ? Color(hex: "#0E1014") : Color(hex: "#15171A"))
                                     : AnyShapeStyle(Theme.Colour.textMuted))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        ZStack {
                            if selection == tab {
                                RoundedRectangle(cornerRadius: 26, style: .continuous)
                                    .fill(Theme.Colour.pulseGradient(scheme))
                            }
                        }
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(height: 62)
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
