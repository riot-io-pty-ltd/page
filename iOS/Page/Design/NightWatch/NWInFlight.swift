import SwiftUI

// The In flight section of Now, and the small callout a first-time tip is
// drawn with. Every card hands its actions to closures; the container routes
// them (open the room, retire a tip). Nothing here types anything: Steer only
// opens the room with the composer focused.

// MARK: - First-time tip

/// A one-line tip with a pointer to the element it explains. Drawn inline in
/// the stream (never over a control), dismissible, and quiet: no motion of
/// its own beyond a fade.
struct NWTipCallout: View {
    enum Pointer { case up, down }

    var text: String
    var symbol: String = "lightbulb"
    var pointer: Pointer = .up
    /// Distance of the pointer from the leading edge.
    var pointerInset: CGFloat = 36
    var onDismiss: () -> Void = {}

    private var base: NightWatch.RGBA { NightWatch.Palette.surface.mixed(with: NightWatch.Palette.teal.opacity(1), 0.13) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if pointer == .up { arrow(up: true).padding(.leading, pointerInset) }
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(.footnote, weight: .semibold)).foregroundColor(NightWatch.Palette.teal.color)
                Text(text).font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(.caption2, weight: .bold)).foregroundColor(NightWatch.Palette.textTertiary.color)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss tip"))
            }
            .padding(.leading, 14).padding(.vertical, 2)
            .background(NWGlassBackground(radius: 16, fill: base, rim: false))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(NightWatch.Palette.teal.opacity(0.32).color, lineWidth: 1))
            .zIndex(1)
            if pointer == .down { arrow(up: false).padding(.leading, pointerInset) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Tip. \(text)"))
    }

    /// A small triangle in the card's colour, its two sloping edges in the rim's.
    private func arrow(up: Bool) -> some View {
        NWTipArrow(up: up).fill(base.color)
            .overlay(NWTipArrow(up: up).stroke(NightWatch.Palette.teal.opacity(0.32).color, lineWidth: 1))
            .frame(width: 18, height: 9)
            .padding(up ? .bottom : .top, -1)
            .accessibilityHidden(true)
    }
}

/// The pointer: an open triangle (its base is left to the card), point up or down.
struct NWTipArrow: Shape {
    var up = true
    func path(in r: CGRect) -> Path {
        var p = Path()
        let base = up ? r.maxY : r.minY, tip = up ? r.minY : r.maxY
        p.move(to: CGPoint(x: r.minX, y: base))
        p.addLine(to: CGPoint(x: r.midX, y: tip))
        p.addLine(to: CGPoint(x: r.maxX, y: base))
        return p
    }
}

// MARK: - In flight

/// "IN FLIGHT 3": a side-scroll strip that summarises every working session,
/// then one full card per session, as big as a Review card, so the whole
/// picture of the work is on one screen. Tapping a card opens its room on
/// Story; "Open" shows its terminal and "Steer" opens the composer. Touching
/// and holding offers the same, and Stop (which opens the room where the 0.6 s
/// hold lives).
struct NWInFlightSection: View {
    var section: InFlightSection
    /// The first-time tip, when it points at one of these rows.
    var tip: NowTipTarget? = nil
    var biometry = "Face ID"
    var onOpen: (String, RoomEntry) -> Void = { _, _ in }
    var onToggle: () -> Void = {}
    var onHeader: () -> Void = {}
    var onDismissTip: (NWTip) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if section.showsStrip {
                NWInFlightStrip(rows: section.strip, onOpen: { onOpen($0, .story) })
                    .padding(.horizontal, -NightWatch.Space.gutter)
            }
            ForEach(section.rows) { row in
                NWInFlightCardView(row: row, onOpen: { onOpen(row.id, $0) })
                    .id("row-inflight-\(row.id)")
                if let tip, tip.anchorId == row.id {
                    NWTipCallout(text: tip.tip.text(biometry: biometry), symbol: tip.tip.symbol, onDismiss: { onDismissTip(tip.tip) })
                        .padding(.top, -4)
                        .transition(.opacity)
                }
            }
            if section.isCapped {
                Button(action: onToggle) {
                    Text(section.isExpanded ? "Show fewer" : section.showAllLabel)
                        .font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.teal.color)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(section.isExpanded ? "Shows only the first few" : "Shows every working session"))
            }
        }
    }

    private var header: some View {
        Button(action: onHeader) {
            HStack(spacing: 8) {
                Text("IN FLIGHT").font(NightWatch.Typo.labelLarge).kerning(1.2).foregroundColor(NightWatch.Palette.teal.color)
                Text("\(section.total)").font(NightWatch.Typo.labelLarge).foregroundColor(NightWatch.Palette.textTertiary.color)
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                Image(systemName: "chevron.right").font(.system(.caption2, weight: .bold)).foregroundColor(NightWatch.Palette.textTertiary.color)
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(Text("In flight, \(section.total)"))
        .accessibilityHint(Text("Goes to Lanes"))
    }
}

/// The side-scroll summary: one small tile per working session (the ribbon),
/// with what it is doing and for how long. A tap opens that session.
struct NWInFlightStrip: View {
    var rows: [InFlightRow]
    var onOpen: (String) -> Void = { _ in }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(rows) { r in
                    Button { onOpen(r.id) } label: { tile(r) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, NightWatch.Space.gutter)
        }
    }

    private func tile(_ r: InFlightRow) -> some View {
        let time = r.card.turn.map { String($0.dropFirst("working ".count)) } ?? r.age.map { "\($0) ago" }
        let flow = r.card.workflows.first
        return HStack(spacing: 10) {
            ZStack {
                NWStarGlyph(seed: r.seed, color: r.hue.color, size: 30)
                if let f = flow?.fraction { NWRing(progress: f, color: NightWatch.Palette.teal, lineWidth: 2, size: 34) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(r.project).font(NightWatch.Typo.monoSmall).foregroundColor(NightWatch.Palette.textPrimary.color).lineLimit(1)
                Text(r.card.now).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textTertiary.color).lineLimit(1)
                HStack(spacing: 6) {
                    if r.card.health.needsAttention, let h = r.card.health.label {
                        Text(h).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.amber.color)
                    } else if let flow, let p = flow.progress {
                        Text(p.replacingOccurrences(of: " agents", with: "")).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.teal.color)
                    }
                    if let time { Text(time).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textQuiet.color) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: 200, height: 72, alignment: .leading)
        .background(NWGlassBackground(radius: NightWatch.Radius.row, fill: NightWatch.Palette.surface.opacity(0.85),
                                      tint: r.card.health.needsAttention ? NightWatch.Palette.amber : nil))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(r.spoken))
        .accessibilityHint(Text("Opens the session"))
        .accessibilityAddTraits(.isButton)
    }
}

/// One working session, as big as a Review card: who and where, what it is
/// doing now and just did, how long, its workflows, how it is doing, and two
/// buttons in words. The body is a button that opens the room on Story; the
/// buttons sit under it, each at least 44 pt.
struct NWInFlightCardView: View {
    var row: InFlightRow
    var onOpen: (RoomEntry) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var card: InFlightCard { row.card }
    private var tint: NightWatch.RGBA { card.health.needsAttention ? NightWatch.Palette.amber : NightWatch.Palette.teal }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { onOpen(.story) } label: {
                VStack(alignment: .leading, spacing: 12) {
                    top
                    fact("NOW") { nowBlock }
                    if let t = card.timeText { fact("TIME") { text(t, NightWatch.Palette.textPrimary) } }
                    if let heading = card.workflowHeading { fact("WORKFLOWS") { workflowBlock(heading) } }
                    fact("HEALTH") { healthBlock }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(row.spoken))
            .accessibilityHint(Text("Opens the session"))
            HStack(spacing: 10) {
                button(.screen, enabled: row.canMirror, kind: .quiet)
                button(.type, enabled: row.canType, kind: .bright)
            }
        }
        .padding(NightWatch.Space.lg)
        .background(NWGlassBackground(radius: NightWatch.Radius.card, tint: tint))
        .contextMenu {
            Button { onOpen(.screen) } label: { Label("Open", systemImage: "display") }
            Button { onOpen(.type) } label: { Label("Steer", systemImage: "arrow.turn.down.right") }
            if row.canStop { Button(role: .destructive) { onOpen(.stop) } label: { Label("Stop…", systemImage: "stop.circle") } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Open")) { onOpen(.screen) }
        .accessibilityAction(named: Text("Steer")) { onOpen(.type) }
        .accessibilityActions { if row.canStop { Button("Stop") { onOpen(.stop) } } }
    }

    // MARK: parts

    /// The star, the project, and where it runs.
    private var top: some View {
        HStack(spacing: 12) {
            NWStarGlyph(seed: row.seed, color: row.hue.color, size: 30).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.project).font(NightWatch.Typo.mono).foregroundColor(NightWatch.Palette.textPrimary.color).lineLimit(1)
                Text(whoWhere).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color).lineLimit(1)
            }
            Spacer(minLength: 4)
            if card.health.needsAttention, let h = card.health.label {
                Text(h.uppercased()).font(NightWatch.Typo.label).kerning(NightWatch.Typo.labelTracking)
                    .foregroundColor(NightWatch.Palette.amber.color)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(NightWatch.Palette.amber.opacity(0.14).color))
            }
        }
    }

    /// "Claude · cmux › page · Opus 4.5".
    private var whoWhere: String {
        [row.character, row.route ?? row.host, card.model].compactMap { $0 }.joined(separator: " · ")
    }

    /// The step in words, and the few before it as a short timeline.
    private var nowBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.now).font(NightWatch.Typo.monoSmall.weight(.semibold))
                .foregroundColor(NightWatch.Palette.textPrimary.color)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(card.previous.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(NightWatch.Palette.textQuiet.opacity(1 - 0.22 * Double(i)).color).frame(width: 5, height: 5)
                        .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
                    Text(step).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textTertiary.color)
                        .lineLimit(1)
                }
            }
        }
    }

    private func workflowBlock(_ heading: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading).font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.teal.color)
            ForEach(card.workflows) { w in
                VStack(alignment: .leading, spacing: 4) {
                    Text(w.text).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textSecondary.color)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let f = w.fraction {
                        Capsule().fill(Color.white.opacity(0.08)).frame(height: 3)
                            .overlay(GeometryReader { g in
                                Capsule().fill(NightWatch.Palette.teal.color).frame(width: max(3, g.size.width * CGFloat(f)))
                            }, alignment: .leading)
                    }
                }
            }
        }
    }

    private var healthBlock: some View {
        HStack(spacing: 8) {
            Circle().fill(healthColor.color).frame(width: 7, height: 7)
            Text(card.healthLine ?? "Normal")
                .font(NightWatch.Typo.monoMicro).foregroundColor(card.health.needsAttention ? NightWatch.Palette.amber.color : NightWatch.Palette.textSecondary.color)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var healthColor: NightWatch.RGBA {
        switch card.health {
        case .normal: return NightWatch.Palette.green
        case .longRunning: return NightWatch.Palette.sky
        case .stuck, .rateLimited: return NightWatch.Palette.amber
        }
    }

    private func text(_ s: String, _ c: NightWatch.RGBA) -> some View {
        Text(s).font(NightWatch.Typo.monoSmall).foregroundColor(c.color).lineLimit(2)
    }

    /// A small caps label, and its content under it (stacked like the Mac's
    /// card, so a long step or a health line gets the card's whole width).
    private func fact<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(NightWatch.Typo.label).kerning(NightWatch.Typo.labelTracking)
                .foregroundColor(NightWatch.Palette.textTertiary.color)
                .lineLimit(1)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A button in words. A terminal Page cannot mirror or type into is dimmed,
    /// not hidden: it still opens the room, which says why.
    private func button(_ entry: RoomEntry, enabled: Bool, kind: NWButtonStyle.Kind) -> some View {
        Button { onOpen(entry) } label: { Text(entry.buttonTitle) }
            .buttonStyle(NWButtonStyle(kind: enabled ? kind : .quiet))
            .opacity(enabled ? 1 : 0.55)
            .accessibilityHint(Text(enabled ? (entry == .type ? "Opens the session with the keyboard up" : "Shows its terminal")
                                    : (entry == .type ? "Page can't type into this terminal; opens the session to say why" : "Page can't mirror this terminal; opens the session")))
    }
}
