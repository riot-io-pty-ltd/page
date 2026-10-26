import SwiftUI

// MARK: - Chip

extension ChipKind {
    /// IRREVERSIBLE red, UNDOABLE green, CONSIDERED sky, everything that needs
    /// a look amber, a finished turn teal.
    var color: NightWatch.RGBA {
        switch self {
        case .irreversible: return NightWatch.Palette.red
        case .undoable: return NightWatch.Palette.green
        case .considered: return NightWatch.Palette.sky
        case .looksStuck, .question, .forecast, .rateLimited: return NightWatch.Palette.amber
        case .review: return NightWatch.Palette.teal
        }
    }

    /// SF Symbol drawn in front of the label on a card.
    var symbol: String {
        switch self {
        case .irreversible: return "exclamationmark.shield"
        case .considered: return "doc.text.magnifyingglass"
        case .undoable: return "arrow.uturn.backward.circle"
        case .looksStuck: return "arrow.triangle.2.circlepath"
        case .question: return "questionmark.bubble"
        case .forecast: return "clock.badge.exclamationmark"
        case .rateLimited: return "gauge.with.needle"
        case .review: return "checkmark.circle"
        }
    }
}

/// The small all-caps label on a row. `pill` adds a tinted capsule with the
/// class symbol (as on the Decide cards); without it, plain tracked text.
struct NWChip: View {
    var kind: ChipKind
    var pill = false

    var body: some View {
        HStack(spacing: 5) {
            if pill { Image(systemName: kind.symbol).font(.system(.caption2, weight: .bold)) }
            Text(kind.title)
                .font(NightWatch.Typo.label)
                .kerning(NightWatch.Typo.labelTracking)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundColor(kind.color.color)
        .padding(.horizontal, pill ? 9 : 0)
        .padding(.vertical, pill ? 5 : 0)
        .background(pill ? AnyView(Capsule().fill(kind.color.opacity(0.16).color)) : AnyView(EmptyView()))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(kind.title.capitalized))
    }
}

// MARK: - Buttons

/// A Night Watch button: quiet slate (Deny, Steer), bright teal-to-sky
/// (Looks good), amber (Steer on a stuck card) or red-tinted (the Irreversible
/// approve). Fixed 52 pt minimum height, so the touch target is generous.
struct NWButtonStyle: ButtonStyle {
    enum Kind { case quiet, bright, amber, danger }
    var kind: Kind = .quiet

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NightWatch.Typo.button)
            .foregroundColor(foreground.color)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: NightWatch.Radius.button, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: NightWatch.Radius.button, style: .continuous)
                .strokeBorder(border.color, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }

    private var foreground: NightWatch.RGBA {
        switch kind {
        case .quiet: return NightWatch.Palette.textPrimary
        case .bright, .amber: return NightWatch.Palette.onBright
        case .danger: return NightWatch.Palette.textPrimary
        }
    }

    private var border: NightWatch.RGBA {
        switch kind {
        case .quiet: return NightWatch.Palette.hairline
        case .bright: return NightWatch.Palette.teal.opacity(0.4)
        case .amber: return NightWatch.Palette.yellow.opacity(0.5)
        case .danger: return NightWatch.Palette.red.opacity(0.45)
        }
    }

    private var background: AnyView {
        switch kind {
        case .quiet: return AnyView(Color.white.opacity(0.07))
        case .bright:
            return AnyView(LinearGradient(colors: [NightWatch.Palette.teal.color, NightWatch.Palette.sky.color],
                                          startPoint: .leading, endPoint: .trailing))
        case .amber:
            return AnyView(LinearGradient(colors: [NightWatch.Palette.yellow.color, NightWatch.Palette.amber.color],
                                          startPoint: .leading, endPoint: .trailing))
        case .danger: return AnyView(NightWatch.Palette.red.opacity(0.14).color)
        }
    }
}

// MARK: - Delivery preview and receipt

/// The delivery preview: what will be typed, where, on which Mac, in a dark
/// inset with a keyboard glyph ("Will type 1 · cmux › page · Studio MBP").
struct NWDeliveryPreview: View {
    var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .font(.system(.footnote, weight: .medium))
                .foregroundColor(NightWatch.Palette.textTertiary.color)
            Text(text)
                .font(NightWatch.Typo.monoSmall)
                .foregroundColor(NightWatch.Palette.textSecondary.color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: NightWatch.Radius.inset, style: .continuous)
            .fill(Color.white.opacity(0.05)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
    }
}

/// One line of proof that a keystroke landed (or why it did not).
struct NWReceiptLine: View {
    var text: String
    var failed = false

    var body: some View {
        let tone = failed ? NightWatch.Palette.amber : NightWatch.Palette.teal
        HStack(spacing: 10) {
            Image(systemName: failed ? "exclamationmark.square" : "checkmark.square")
                .font(.system(.footnote, weight: .medium))
            Text(text)
                .font(NightWatch.Typo.monoMicro)
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .foregroundColor(tone.opacity(0.95).color)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: NightWatch.Radius.inset, style: .continuous)
            .fill(tone.opacity(0.08).color))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Toggle

/// The Night Watch switch: a teal capsule with a white knob; off is a dim slate.
struct NWToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                configuration.label
                Spacer(minLength: 12)
                NWSwitch(isOn: configuration.isOn)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(configuration.isOn ? "on" : "off"))
    }
}

/// The capsule on its own.
struct NWSwitch: View {
    var isOn: Bool
    var width: CGFloat = 51
    var height: CGFloat = 31
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn
                      ? AnyShapeStyle(LinearGradient(colors: [NightWatch.Palette.teal.opacity(0.95).color,
                                                              NightWatch.Palette.green.opacity(0.9).color],
                                                     startPoint: .leading, endPoint: .trailing))
                      : AnyShapeStyle(Color.white.opacity(0.12)))
            // A fixed size: a bare Circle takes the whole track and the
            // alignment above would have nothing to move.
            Circle()
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.35), radius: 2, y: 1)
                .frame(width: height - 6, height: height - 6)
                .padding(3)
        }
        .frame(width: width, height: height)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isOn)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(Text(isOn ? "on" : "off"))
    }
}

// MARK: - Segmented control

/// A segmented control in the Night Watch style: slate track, a raised pill
/// under the selected option. Every segment is a 44 pt button.
struct NWSegmented<Value: Hashable>: View {
    var options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i]
                let on = o.value == selection
                Button { selection = o.value } label: {
                    Text(o.label)
                        .font(.system(.subheadline, weight: on ? .semibold : .medium))
                        .foregroundColor(on ? NightWatch.Palette.textPrimary.color : NightWatch.Palette.textTertiary.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(on ? Color.white.opacity(0.14) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}

// MARK: - Rings

extension RingStat.Kind {
    var color: NightWatch.RGBA {
        switch self {
        case .unblocked: return NightWatch.Palette.amber
        case .shipped: return NightWatch.Palette.teal
        case .calm: return NightWatch.Palette.violet
        }
    }
}

/// A progress ring.
struct NWRing: View {
    var progress: Double
    var color: NightWatch.RGBA
    var lineWidth: CGFloat = 4
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2).color, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0, progress))))
                .stroke(color.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

/// Unblocked, Shipped and Calm as three concentric rings (the glyph in the
/// corner of the Horizon and in Sky's "Tonight" card).
struct NWConcentricRings: View {
    var rings: [RingStat]
    var size: CGFloat = 44

    var body: some View {
        let lw = max(3, size / 9)
        ZStack {
            ForEach(Array(rings.enumerated()), id: \.element.id) { i, r in
                NWRing(progress: r.progress, color: r.kind.color, lineWidth: lw,
                       size: size - CGFloat(i) * (lw * 2 + 2))
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(rings.map { "\($0.kind.rawValue) \($0.detail)" }.joined(separator: ", ")))
    }
}

/// The three daily rings with labels, one per line.
struct NWRingsList: View {
    var rings: [RingStat]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rings) { r in
                HStack(spacing: 10) {
                    Circle().fill(r.kind.color.color).frame(width: 8, height: 8)
                    Text(r.kind.rawValue)
                        .font(NightWatch.Typo.bodyStrong)
                        .foregroundColor(NightWatch.Palette.textPrimary.color)
                    Spacer()
                    Text(r.detail)
                        .font(NightWatch.Typo.monoSmall)
                        .foregroundColor(r.kind.color.color)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
