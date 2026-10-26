import SwiftUI
import AppKit

// The Tower window's chrome (sidebar, page scaffold, footer) and the small
// controls its pages are made of. Pages themselves are in TowerPages.swift.

private typealias P = NightWatch.Palette

// MARK: - Window

/// The whole window: sidebar on the left, the selected page on the right.
struct NWTowerView: View {
    @ObservedObject var store: TowerStore

    static let sidebarWidth: CGFloat = 264

    var body: some View {
        HStack(spacing: 0) {
            NWTowerSidebar(store: store)
                .frame(width: Self.sidebarWidth)
            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
            VStack(spacing: 0) {
                NWTowerPageHost(store: store)
                NWTowerFooter(store: store)
            }
        }
        .background(NWTowerBackground())
        .environment(\.colorScheme, .dark)
        // The live window draws under its transparent title bar.
        .ignoresSafeArea()
    }
}

/// Near-black navy with a faint teal pool at the bottom left and a violet one
/// at the top right, as on the board's window.
struct NWTowerBackground: View {
    var body: some View {
        ZStack {
            P.background.color
            RadialGradient(colors: [P.glass.opacity(0.07).color, .clear],
                           center: .bottomLeading, startRadius: 10, endRadius: 700)
            RadialGradient(colors: [P.violet.opacity(0.05).color, .clear],
                           center: .topTrailing, startRadius: 10, endRadius: 600)
        }
    }
}

// MARK: - Sidebar

struct NWTowerSidebar: View {
    @ObservedObject var store: TowerStore

    var body: some View {
        let card = store.card
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic lights.
            Color.clear.frame(height: 34)
            NWTowerCard(card: card)
                .padding(.horizontal, 14)
            VStack(spacing: 2) {
                ForEach(TowerSection.allCases) { section in
                    NWSidebarRow(section: section, selected: store.selection == section,
                                 badge: section == .attention ? card.attentionBadge : 0)
                        .onTapGesture { store.selection = section }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.22))
    }
}

/// The Tower card: status dot, name, "Studio MBP · 5 working" and the rings.
struct NWTowerCard: View {
    var card: TowerCardModel

    private var dotColor: NightWatch.RGBA {
        switch card.dot {
        case .running: return P.teal
        case .paused: return P.violet
        case .starting: return P.textQuiet
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(dotColor.color)
                    .frame(width: 10, height: 10)
                    .shadow(color: dotColor.opacity(0.7).color, radius: 4)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .font(Font.system(size: 15, weight: .bold)).kerning(-0.2)
                        .foregroundColor(P.textPrimary.color)
                    Text(card.subtitle)
                        .font(Font.system(size: 11.5, weight: .regular))
                        .foregroundColor(P.textTertiary.color)
                        .lineLimit(1)
                }
            }
            if !card.rings.isEmpty {
                HStack(spacing: 10) {
                    ForEach(card.rings) { r in
                        NWRing(progress: r.progress, color: r.kind.color, lineWidth: 3.5, size: 26)
                            .accessibilityLabel(Text("\(r.kind.rawValue) \(r.detail)"))
                    }
                }
                .padding(.leading, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NWGlassBackground(radius: 14, fill: P.surface.opacity(0.7), glow: P.glass.opacity(0.3), glowHeight: 14))
        .accessibilityElement(children: .contain)
    }
}

struct NWSidebarRow: View {
    var section: TowerSection
    var selected: Bool
    var badge: Int

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: section.symbol)
                .font(Font.system(size: 13, weight: .regular))
                .frame(width: 20)
                .foregroundColor((selected ? P.teal : P.textSecondary).color)
            Text(section.title)
                .font(Font.system(size: 13.5, weight: selected ? .semibold : .regular))
                .foregroundColor((selected ? P.textPrimary : P.textSecondary.opacity(0.92)).color)
            Spacer(minLength: 4)
            if badge > 0 {
                Text("\(badge)")
                    .font(Font.system(size: 11, weight: .bold))
                    .foregroundColor(P.amber.color)
                    .frame(minWidth: 20, minHeight: 18)
                    .padding(.horizontal, 3)
                    .background(Capsule().fill(P.amber.opacity(0.18).color))
                    .accessibilityLabel(Text("\(badge) need you"))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(selected ? Color.white.opacity(0.10) : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Page host and footer

/// The selected page, in a scroll view, under the config-problem banner.
struct NWTowerPageHost: View {
    @ObservedObject var store: TowerStore

    var body: some View {
        VStack(spacing: 0) {
            if let problem = store.problem {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(problem).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(Font.system(size: 12, weight: .medium))
                .foregroundColor(P.amber.color)
                .padding(.horizontal, 22).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(P.amber.opacity(0.10).color)
            }
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    NWTowerPageContent(store: store)
                }
                .frame(maxWidth: 800, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 30)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Apply, Cancel and Reset to defaults, as before: edits wait for Apply
/// (so a half-typed relay URL is never saved).
struct NWTowerFooter: View {
    @ObservedObject var store: TowerStore

    var body: some View {
        HStack(spacing: 10) {
            NWButton(title: "Reset to defaults", kind: .quiet) { store.resetToDefaults() }
                .help("Resets everything except the relay URL and Codex path.")
            if store.isDirty {
                HStack(spacing: 6) {
                    Circle().fill(P.amber.color).frame(width: 6, height: 6)
                    Text("Unsaved changes").font(Font.system(size: 11.5, weight: .medium))
                        .foregroundColor(P.amber.opacity(0.9).color)
                }
                .padding(.leading, 6)
            }
            Spacer(minLength: 8)
            NWButton(title: "Cancel", kind: .secondary, shortcut: .cancelAction) { store.cancel() }
            NWButton(title: "Apply", kind: .primary, shortcut: .defaultAction) { store.apply() }
        }
        .padding(.horizontal, 32)
        .frame(height: 56)
        .background(Color.black.opacity(0.28))
        .overlay(Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1), alignment: .top)
    }
}

// MARK: - Scaffold

/// Page title and subtitle, then the page's cards.
struct NWPage<Content: View>: View {
    var section: TowerSection
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(section.title)
                    .font(Font.system(size: 28, weight: .bold)).kerning(-0.6)
                    .foregroundColor(P.textPrimary.color)
                Text(section.subtitle)
                    .font(Font.system(size: 14, weight: .regular))
                    .foregroundColor(P.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 2)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Cards and rows

/// A grouped card: rows separated by hairlines.
struct NWCard<Content: View>: View {
    var padding: CGFloat = 0
    var title: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).nwLabel().padding(.leading, 4) }
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NWGlassBackground(radius: 14, fill: RGBAHex.card, glow: P.glass.opacity(0.28), glowHeight: 12))
        }
    }
}

enum RGBAHex {
    /// The board's card fill: a touch lighter than the window.
    static let card = NightWatch.RGBA(hex: 0x0B0E14, alpha: 0.92)
}

struct NWDivider: View {
    var body: some View { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
}

/// A row: title and detail on the left, a control on the right.
struct NWRow<Trailing: View>: View {
    var title: String
    var detail: String?
    var enabled = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Font.system(size: 13.5, weight: .semibold))
                    .foregroundColor(P.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(Font.system(size: 11.5, weight: .regular))
                        .foregroundColor(P.textTertiary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing().layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(minHeight: 60)
        .opacity(enabled ? 1 : 0.42)
        .allowsHitTesting(enabled)
    }
}

struct NWToggleRow: View {
    var title: String
    var detail: String?
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        // A Button, so Tab / Space (Full Keyboard Access) and VoiceOver reach it.
        Button { isOn.toggle() } label: {
            NWRow(title: title, detail: detail, enabled: enabled) {
                NWSwitch(isOn: isOn, width: 42, height: 24)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(Text(isOn ? "on" : "off"))
    }
}

/// A toggle whose change goes through a function (so a rule can intercept it).
struct NWToggleRowCustom: View {
    var title: String
    var detail: String?
    var isOn: Bool
    var enabled = true
    var set: (Bool) -> Void

    var body: some View {
        NWToggleRow(title: title, detail: detail,
                    isOn: Binding(get: { isOn }, set: { set($0) }), enabled: enabled)
    }
}

struct NWSegmentedRow<V: Hashable>: View {
    var title: String
    var detail: String?
    var options: [(value: V, label: String)]
    @Binding var selection: V
    var enabled = true

    var body: some View {
        NWRow(title: title, detail: detail, enabled: enabled) {
            NWSegmented(options: options, selection: $selection, height: 28)
        }
    }
}

/// A title with its value, over a slider.
struct NWSliderRow: View {
    var title: String
    var detail: String?
    var valueText: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(Font.system(size: 13.5, weight: .semibold))
                        .foregroundColor(P.textPrimary.color)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(Font.system(size: 11.5))
                            .foregroundColor(P.textTertiary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Text(valueText)
                    .font(Font.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(P.teal.opacity(0.95).color)
            }
            NWSlider(value: $value, range: range, step: step)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .opacity(enabled ? 1 : 0.42)
        .allowsHitTesting(enabled)
    }
}

/// A slim slider: dark track, teal fill, white knob.
struct NWSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1

    /// Pure. The value at horizontal position `x` of a track `width` wide,
    /// snapped to `step` and kept in range.
    static func value(at x: CGFloat, width: CGFloat, range: ClosedRange<Double>, step: Double) -> Double {
        guard width > 0 else { return range.lowerBound }
        let f = Double(min(1, max(0, x / width)))
        let raw = range.lowerBound + f * (range.upperBound - range.lowerBound)
        let snapped = step > 0 ? (raw / step).rounded() * step : raw
        return min(range.upperBound, max(range.lowerBound, snapped))
    }

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let f = span > 0 ? min(1, max(0, (value - range.lowerBound) / span)) : 0
            let knob: CGFloat = 16
            let travel = geo.size.width - knob
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10)).frame(height: 4)
                Capsule().fill(LinearGradient(colors: [P.teal.opacity(0.9).color, P.green.opacity(0.85).color],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(width: knob / 2 + CGFloat(f) * travel, height: 4)
                Circle().fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: Color.black.opacity(0.4), radius: 2, y: 1)
                    .offset(x: CGFloat(f) * travel)
            }
            .frame(height: knob)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let v = Self.value(at: g.location.x - knob / 2, width: travel, range: range, step: step)
                if v != value { value = v }
            })
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int(value))"))
        .accessibilityAdjustableAction { direction in
            let delta = max(step, 1)
            switch direction {
            case .increment: value = min(range.upperBound, value + delta)
            case .decrement: value = max(range.lowerBound, value - delta)
            @unknown default: break
            }
        }
    }
}

// MARK: - Fields, buttons, lines

struct NWField: View {
    @Binding var text: String
    var placeholder = ""
    var enabled = true
    var monospaced = false

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(monospaced ? Font.system(size: 12.5, design: .monospaced) : Font.system(size: 13))
            .foregroundColor(P.textPrimary.color)
            .disableAutocorrection(true)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
    }
}

/// A labelled field row inside a card.
struct NWFieldRow: View {
    var title: String
    var detail: String?
    @Binding var text: String
    var placeholder = ""
    var enabled = true
    var monospaced = true
    var trailing: AnyView?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Font.system(size: 13.5, weight: .semibold)).foregroundColor(P.textPrimary.color)
                if let detail, !detail.isEmpty {
                    Text(detail).font(Font.system(size: 11.5)).foregroundColor(P.textTertiary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                NWField(text: $text, placeholder: placeholder, enabled: enabled, monospaced: monospaced)
                if let trailing { trailing }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .opacity(enabled ? 1 : 0.42)
    }
}

struct NWButton: View {
    enum Kind { case primary, secondary, quiet }
    var title: String
    var kind: Kind = .secondary
    var enabled = true
    var shortcut: KeyboardShortcut?
    var action: () -> Void

    var body: some View {
        if let shortcut { button.keyboardShortcut(shortcut) } else { button }
    }

    private var button: some View {
        Button(action: action) {
            Text(title)
                .font(Font.system(size: 12.5, weight: kind == .primary ? .semibold : .medium))
                .foregroundColor(foreground)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(kind == .secondary ? Color.white.opacity(0.14) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Color(red: 0.02, green: 0.10, blue: 0.10)
        case .secondary: return P.textPrimary.color
        case .quiet: return P.textSecondary.color
        }
    }

    private var fill: AnyShapeStyle {
        switch kind {
        case .primary: return AnyShapeStyle(LinearGradient(colors: [P.teal.color, P.green.color], startPoint: .leading, endPoint: .trailing))
        case .secondary: return AnyShapeStyle(Color.white.opacity(0.07))
        case .quiet: return AnyShapeStyle(Color.clear)
        }
    }
}

/// One line of explanation or status under a card or row.
struct NWNote: View {
    var text: String
    var tone: TowerStatusLine.Tone = .quiet
    var mono = false

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(mono ? Font.system(size: 11.5, design: .monospaced) : Font.system(size: 11.5))
                .foregroundColor(color.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var color: NightWatch.RGBA {
        switch tone {
        case .quiet: return P.textTertiary
        case .good: return P.green
        case .bad: return P.red.mixed(with: P.amber, 0.35)
        }
    }
}

/// A rounded chip with a dot or icon: the lid state, the relay state.
struct NWStateChip: View {
    var text: String
    var color: NightWatch.RGBA
    var symbol: String?

    var body: some View {
        HStack(spacing: 7) {
            if let symbol { Image(systemName: symbol).font(Font.system(size: 12, weight: .medium)) }
            Text(text).font(Font.system(size: 12.5, weight: .semibold)).lineLimit(2)
        }
        .foregroundColor(color.color)
    }
}
