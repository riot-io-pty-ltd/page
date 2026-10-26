import SwiftUI

// The smaller parts of the Now screen: the Mac chip, banners, the Return
// Brief and the In-flight ribbon. Each draws values and hands every tap to a
// closure.

/// "Studio MBP · on battery · 41%". Amber when the cutoff is close, dim when
/// the Mac is not answering. Tapping it opens the Tower.
struct NWMacChip: View {
    var model: MacChipModel
    var onTap: () -> Void = {}

    var body: some View {
        let dot: NightWatch.RGBA = model.tone == .ok ? NightWatch.Palette.green : (model.tone == .warn ? NightWatch.Palette.amber : NightWatch.RGBA(hex: 0x8A8FA0))
        Button(action: onTap) {
            HStack(spacing: 8) {
                Circle().fill(dot.color).frame(width: 8, height: 8)
                Text(model.text)
                    .font(NightWatch.Typo.captionStrong)
                    .foregroundColor((model.tone == .warn ? NightWatch.Palette.amber : NightWatch.Palette.textPrimary).color)
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    .foregroundColor(NightWatch.Palette.textTertiary.color)
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(Capsule().fill(Color.black.opacity(0.35)))
            .overlay(Capsule().strokeBorder(model.tone == .warn ? NightWatch.Palette.amber.opacity(0.5).color : Color.white.opacity(0.14), lineWidth: 1))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(model.text))
        .accessibilityHint(Text("Opens the Tower: power, budget, Macs and settings"))
    }
}

/// A problem above the stream: a rejected pairing, an unreachable relay, a
/// silent Mac, notifications off. One glass card, one action.
struct NWBannerCard: View {
    var banner: NowBanner
    var onAction: (NowBanner.Action) -> Void = { _ in }

    var body: some View {
        let tone = banner.tone == .info ? NightWatch.Palette.sky : NightWatch.Palette.amber
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: banner.symbol)
                .font(.system(.body, weight: .medium))
                .foregroundColor(tone.color)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tone.opacity(0.14).color))
            VStack(alignment: .leading, spacing: 4) {
                Text(banner.title).font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                Text(banner.message).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let t = banner.actionTitle, let a = banner.action {
                    Button(t) { onAction(a) }
                        .font(NightWatch.Typo.captionStrong)
                        .foregroundColor(tone.color)
                        .frame(minHeight: 36, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(NightWatch.Space.md)
        .background(NWGlassBackground(radius: NightWatch.Radius.row, tint: tone))
        .accessibilityElement(children: .contain)
    }
}

/// The Return Brief. Collapsed it is one line ("While you were away · 1h
/// 52m ›"); expanded, a glass card with a short sunrise behind the title
/// (brighter the more finished), three counts, a line per thing that happened,
/// and the two actions. Everything on it is counted from Page's own log.
struct NWBriefCard: View {
    var brief: ReturnBrief
    var expanded: Bool
    var onToggle: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onReview: () -> Void = {}

    var body: some View {
        if expanded { full } else { collapsed }
    }

    private var collapsed: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: "sunrise").foregroundColor(NightWatch.Palette.teal.color)
                Text(brief.title).font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(.caption, weight: .bold)).foregroundColor(NightWatch.Palette.textTertiary.color)
            }
            .padding(.horizontal, 16).frame(minHeight: 52)
            .background(NWGlassBackground(radius: NightWatch.Radius.row))
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens the summary of what happened while you were away"))
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("WHILE YOU WERE AWAY").nwLabel()
                Text(brief.awayText)
                    .font(.system(.largeTitle, weight: .bold)).kerning(-0.6)
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                Text(brief.window).font(NightWatch.Typo.monoSmall).foregroundColor(NightWatch.Palette.textTertiary.color)
            }
            HStack(spacing: 10) {
                ForEach(brief.counts) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(c.value)").font(.system(.title, weight: .bold)).foregroundColor(color(c.kind).color)
                        Text(c.kind.rawValue.uppercased()).font(NightWatch.Typo.label).kerning(0.8)
                            .foregroundColor(NightWatch.Palette.textTertiary.color)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
                    .accessibilityElement(children: .combine)
                }
            }
            if brief.lines.isEmpty {
                Text("Nothing happened that needed you.").font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textSecondary.color)
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(brief.lines) { line in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: line.symbol).font(.system(.callout, weight: .medium))
                            .foregroundColor(tone(line.tone).color)
                            .frame(width: 36, height: 36)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tone(line.tone).opacity(0.14).color))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.title).font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                            if let d = line.detail { Text(d).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color) }
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            HStack(spacing: 10) {
                Button("Dismiss", action: onDismiss).buttonStyle(NWButtonStyle(kind: .quiet))
                if brief.finished > 0 {
                    Button(action: onReview) { Text("Review the \(brief.finished) finished") }.buttonStyle(NWButtonStyle(kind: .bright))
                }
            }
        }
        .padding(NightWatch.Space.lg)
        .background(
            ZStack(alignment: .top) {
                NWGlassBackground(radius: NightWatch.Radius.card)
                // The sunrise: brighter the more finished while you were away.
                NWAnimated { t in
                    NWAuroraCanvas(palette: .brief(sunrise: brief.sunrise), seconds: t)
                        .frame(height: 150)
                        .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom))
                        .opacity(0.55)
                }
                .clipShape(RoundedRectangle(cornerRadius: NightWatch.Radius.card, style: .continuous))
                .allowsHitTesting(false)
            })
        .accessibilityElement(children: .contain)
    }

    private func color(_ k: ReturnBrief.Count.Kind) -> NightWatch.RGBA {
        switch k {
        case .finished: return NightWatch.Palette.teal
        case .inFlight: return NightWatch.Palette.sky
        case .needYou: return NightWatch.Palette.amber
        }
    }

    private func tone(_ t: ReturnBrief.Tone) -> NightWatch.RGBA {
        switch t {
        case .good: return NightWatch.Palette.green
        case .neutral: return NightWatch.Palette.sky
        case .warn: return NightWatch.Palette.amber
        }
    }
}

extension NightWatch.AuroraPalette {
    /// The Brief's sunrise: the working palette, as bright as the absence was productive.
    static func brief(sunrise: Double) -> NightWatch.AuroraPalette {
        let base = NightWatch.AuroraPalette.working
        return NightWatch.AuroraPalette(c1: base.c1, c2: base.c2, c3: base.c3, skyTop: base.skyTop, skyBottom: base.skyBottom,
                                        intensity: 0.25 + 0.75 * max(0, min(1, sunrise)), speed: 0.4)
    }
}

/// "IN FLIGHT 5 ›": one strand per working session, in a horizontal ribbon.
/// Tapping a strand opens that session; the header goes to Sky.
struct NWInFlightRibbon: View {
    var strands: [InFlightStrand]
    var onStrand: (String) -> Void = { _ in }
    var onHeader: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onHeader) {
                HStack(spacing: 8) {
                    Text("IN FLIGHT").font(NightWatch.Typo.labelLarge).kerning(1.2).foregroundColor(NightWatch.Palette.teal.color)
                    Text("\(strands.count)").font(NightWatch.Typo.labelLarge).foregroundColor(NightWatch.Palette.textTertiary.color)
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                    Image(systemName: "chevron.right").font(.system(.caption2, weight: .bold)).foregroundColor(NightWatch.Palette.textTertiary.color)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint(Text("Goes to Sky"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(strands) { s in
                        Button { onStrand(s.id) } label: { strand(s) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)
        }
    }

    private func strand(_ s: InFlightStrand) -> some View {
        HStack(spacing: 10) {
            ZStack {
                NWStarGlyph(seed: s.seed, color: s.hue.color, size: 30)
                if let w = s.workflow, w.total > 0 {
                    NWRing(progress: Double(w.done) / Double(w.total), color: NightWatch.Palette.teal, lineWidth: 2, size: 34)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(s.project).font(NightWatch.Typo.monoSmall).foregroundColor(NightWatch.Palette.textPrimary.color).lineLimit(1)
                Text(s.lastAction).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textTertiary.color).lineLimit(1)
                HStack(spacing: 6) {
                    if let w = s.workflow { Text("\(w.done) of \(w.total)").font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.teal.color) }
                    if let a = s.age { Text(a).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textQuiet.color) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: 190, height: 72, alignment: .leading)
        .background(NWGlassBackground(radius: NightWatch.Radius.row, fill: NightWatch.Palette.surface.opacity(0.85)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(s.project), \(s.lastAction)"))
    }
}

/// "New ↑ 1": arrivals held back while you are touching or scrolling the stream.
struct NWNewPill: View {
    var count: Int
    var onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up").font(.system(.caption, weight: .bold))
                Text("New \(count)").font(NightWatch.Typo.captionStrong)
            }
            .foregroundColor(NightWatch.Palette.onBright.color)
            .padding(.horizontal, 14).frame(height: 34)
            .background(Capsule().fill(NightWatch.Palette.amber.color))
            .shadow(color: Color.black.opacity(0.35), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(count) new, show"))
    }
}

/// "Tonight": the day's three rings and a line about them.
struct NWTonightCard: View {
    var rings: [RingStat]
    var body: some View {
        NWGlassCard {
            HStack(spacing: 18) {
                NWConcentricRings(rings: rings, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(RingSummary.title(rings)).font(NightWatch.Typo.title).foregroundColor(NightWatch.Palette.textPrimary.color)
                    Text(RingSummary.detail(rings)).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
