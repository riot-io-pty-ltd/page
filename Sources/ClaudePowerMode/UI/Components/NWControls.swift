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
}

/// The small all-caps label on a row. Plain tracked text, as on the boards;
/// `pill` adds a tinted capsule for use on busier backgrounds.
struct NWChip: View {
    var kind: ChipKind
    var pill = false

    var body: some View {
        Text(kind.title)
            .font(NightWatch.Typo.label)
            .kerning(NightWatch.Typo.labelTracking)
            .foregroundColor(kind.color.color)
            .padding(.horizontal, pill ? 6 : 0)
            .padding(.vertical, pill ? 2 : 0)
            .background(pill ? AnyView(Capsule().fill(kind.color.opacity(0.14).color)) : AnyView(EmptyView()))
            .accessibilityLabel(Text(kind.title.capitalized))
    }
}

// MARK: - Key cap

/// A keyboard key, as in "hold 1", "esc", "O". Monospaced, on a raised pill.
struct NWKeyCap: View {
    var label: String
    var emphasised = false
    /// The small cap beside a button's name ("Open terminal  O").
    var compact = false

    var body: some View {
        Group {
            if label == "↵" {
                Image(systemName: "return").font(Font.system(size: compact ? 9 : 11, weight: .semibold))
            } else {
                // Compact caps use the proportional face: in a monospaced one "O" reads as a zero.
                Text(label).font(compact ? Font.system(size: 10, weight: .semibold) : NightWatch.Typo.monoSmall)
            }
        }
            .foregroundColor(NightWatch.Palette.textPrimary.opacity(emphasised ? 1 : 0.78).color)
            .padding(.horizontal, compact ? 5 : 8)
            .frame(minWidth: compact ? 17 : 26, minHeight: compact ? 16 : 24)
            .background(
                RoundedRectangle(cornerRadius: NightWatch.Radius.keycap, style: .continuous)
                    .fill(Color.white.opacity(emphasised ? 0.14 : 0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: NightWatch.Radius.keycap, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .accessibilityLabel(Text(label == "esc" ? "Escape" : (label == "↵" ? "Return" : label)))
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(configuration.isOn ? "on" : "off"))
    }
}

/// The capsule on its own (also used where there is no label).
struct NWSwitch: View {
    var isOn: Bool
    var width: CGFloat = 46
    var height: CGFloat = 26
    @Environment(\.nwReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn
                      ? AnyShapeStyle(LinearGradient(colors: [NightWatch.Palette.teal.opacity(0.95).color,
                                                              NightWatch.Palette.green.opacity(0.9).color],
                                                     startPoint: .leading, endPoint: .trailing))
                      : AnyShapeStyle(Color.white.opacity(0.10)))
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
/// under the selected option.
struct NWSegmented<Value: Hashable>: View {
    var options: [(value: Value, label: String)]
    @Binding var selection: Value
    var height: CGFloat = 28

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i]
                let on = o.value == selection
                // Buttons, so Tab / Space (Full Keyboard Access) and VoiceOver reach them.
                Button { selection = o.value } label: {
                    Text(o.label)
                        .font(Font.system(size: 12, weight: on ? .semibold : .medium))
                        .foregroundColor(on ? NightWatch.Palette.textPrimary.color : NightWatch.Palette.textTertiary.color)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .frame(minHeight: height - 4)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(on ? Color.white.opacity(0.13) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

// MARK: - Ring

/// A progress ring, as for Unblocked / Shipped / Calm.
struct NWRing: View {
    var progress: Double
    var color: NightWatch.RGBA
    var lineWidth: CGFloat = 3.5
    var size: CGFloat = 20

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

extension RingStat.Kind {
    var color: NightWatch.RGBA {
        switch self {
        case .unblocked: return NightWatch.Palette.amber
        case .shipped: return NightWatch.Palette.teal
        case .calm: return NightWatch.Palette.violet
        }
    }
}

/// The three daily rings in a row, with labels.
struct NWRingsRow: View {
    var rings: [RingStat]
    var ringSize: CGFloat = 20
    var showsDetail = false

    var body: some View {
        HStack(spacing: 14) {
            ForEach(rings) { r in
                HStack(spacing: 8) {
                    NWRing(progress: r.progress, color: r.kind.color, lineWidth: ringSize / 6, size: ringSize)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.kind.rawValue + (r.kind == .calm && r.progress >= 1 ? " ✦" : ""))
                            .font(Font.system(size: 12, weight: .medium))
                            .foregroundColor(NightWatch.Palette.textPrimary.opacity(0.88).color)
                        if showsDetail {
                            Text(r.detail).font(NightWatch.Typo.monoMicro)
                                .foregroundColor(NightWatch.Palette.textTertiary.color)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("\(r.kind.rawValue) \(r.detail)"))
            }
        }
    }
}

// MARK: - Receipt line

/// One line of proof that a keystroke landed (or why it did not).
struct NWReceiptLine: View {
    var text: String
    var failed = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: failed ? "exclamationmark.square" : "dollarsign.square")
                .font(Font.system(size: 12, weight: .medium))
            Text(text)
                .font(Font.system(size: 10.5, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .truncationMode(.tail)
        }
        .foregroundColor((failed ? NightWatch.Palette.amber : NightWatch.Palette.teal).opacity(0.92).color)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background((failed ? NightWatch.Palette.amber : NightWatch.Palette.teal).opacity(0.07).color)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Labelled action

/// What an action button looks like: its name in words, nothing else. A key
/// is never drawn beside it (that was a guessing game); the key lives in the
/// button's tooltip and the shortcuts sheet. `fills` stretches it across the
/// space it is given (the In-flight card's Open and Steer).
struct NWActionLabel: View {
    var title: String
    var enabled = true
    var emphasised = false
    var fills = false

    var body: some View {
        Text(title)
            .font(Font.system(size: 12, weight: emphasised ? .semibold : .medium))
            .foregroundColor(NightWatch.Palette.textPrimary.opacity(enabled ? (emphasised ? 1 : 0.92) : 0.5).color)
            .lineLimit(1)
            .padding(.horizontal, 13)
            .frame(maxWidth: fills ? .infinity : nil, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: NightWatch.Radius.keycap + 1, style: .continuous)
                .fill(Color.white.opacity(emphasised ? 0.14 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: NightWatch.Radius.keycap + 1, style: .continuous)
                .strokeBorder(Color.white.opacity(emphasised ? 0.18 : 0.10), lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: NightWatch.Radius.keycap + 1, style: .continuous))
    }
}

/// A button for one action: `NWActionLabel` with a tooltip (which carries the
/// key) and a VoiceOver name.
struct NWActionButton: View {
    var title: String
    var enabled = true
    var emphasised = false
    var fills = false
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            NWActionLabel(title: title, enabled: enabled, emphasised: emphasised, fills: fills)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(Text(title))
    }
}
