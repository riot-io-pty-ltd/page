import SwiftUI

// The Home Screen widgets' faces, as plain views over values. They are
// compiled into the widget extension (which supplies WidgetKit's
// containerBackground) and into the app (so the render harness can draw
// them). Night Watch is dark, so a widget does not follow the light
// appearance. Card glow does not apply here: a widget is one flat surface.
// Widgets read the relay's `GET /status`, which carries counts, power and
// usage but not the pages themselves, so these faces show a count and the
// Runway, never a page's title.

enum NWWidgetSize: Equatable { case small, medium, large }

/// The widget's sky: a sleeping aurora (amber when something needs you,
/// slate when the Mac is gone) under a darkening so text stays readable.
struct NWWidgetBackground: View {
    var palette: NightWatch.AuroraPalette
    /// 0...1: how much of the aurora to show.
    var strength: Double = 1

    var body: some View {
        ZStack {
            NightWatch.Palette.backgroundDeep.color
            NWAuroraCanvas(palette: palette, seconds: 2.0).opacity(0.85 * strength)
            LinearGradient(colors: [NightWatch.Palette.backgroundDeep.opacity(0.10).color, NightWatch.Palette.backgroundDeep.opacity(0.80).color],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

extension WidgetStatus {
    var faceTone: NightWatch.RGBA {
        if isUnreachable { return NightWatch.RGBA(hex: 0x8A93A8) }
        return needsYou > 0 ? NightWatch.Palette.amber : NightWatch.Palette.textPrimary
    }

    var facePalette: NightWatch.AuroraPalette {
        if isUnreachable { return .asleep }
        if needsYou > 0 { return .needsYou }
        return (working ?? 0) > 0 ? .working : .quiet
    }

    var faceOrb: NWPulseOrb.Style {
        if isUnreachable { return .hollowSlate }
        if needsYou > 0 { return .needsYou }
        return (working ?? 0) > 0 ? .working : .quiet
    }
}

/// "Page · 2 need you": the status widget.
struct NWWidgetStatusFace: View {
    var status: WidgetStatus?
    /// Shown when there is no status ("Open Page to pair", "No connection").
    var problem: String? = nil
    var size: NWWidgetSize
    var now: Date = Date()
    var timeZone: TimeZone = .current

    var body: some View {
        if let s = status {
            switch size {
            case .small: small(s)
            case .medium: medium(s)
            case .large: large(s)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                NWPulseOrb(style: .hollowSlate).frame(width: 44, height: 44).offset(x: -8)
                Text("Page").font(NightWatch.Typo.title).foregroundColor(NightWatch.Palette.textPrimary.color)
                Text(problem ?? "—").font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func macRow(_ s: WidgetStatus) -> some View {
        Text(s.macLine).font(.system(.caption2, weight: .medium)).foregroundColor(NightWatch.Palette.textSecondary.color).lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func dot(_ s: WidgetStatus) -> some View {
        Circle().fill(s.faceTone.color).frame(width: 10, height: 10).shadow(color: s.faceTone.opacity(0.6).color, radius: 4)
    }

    private func small(_ s: WidgetStatus) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) { dot(s); Text("Page").font(.system(.caption, weight: .semibold)).foregroundColor(NightWatch.Palette.textTertiary.color); Spacer(minLength: 0) }
            Spacer(minLength: 0)
            Text(s.faceHeadline).font(.system(.title2, weight: .bold)).kerning(-0.4)
                .foregroundColor(s.faceTone.color).lineLimit(2).minimumScaleFactor(0.7)
            if let d = s.detail { Text(d).font(.system(.caption, weight: .medium)).foregroundColor(NightWatch.Palette.textSecondary.color).lineLimit(1) }
            macRow(s)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func medium(_ s: WidgetStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                dot(s)
                Text(s.faceHeadline).font(.system(.title, weight: .bold)).kerning(-0.5)
                    .foregroundColor(s.faceTone.color).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            Text([s.detail, s.macLine].compactMap { $0 }.joined(separator: " · "))
                .font(.system(.caption, weight: .medium)).foregroundColor(NightWatch.Palette.textSecondary.color).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            NWWidgetRunway(model: s.runway(now: now, timeZone: timeZone))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func large(_ s: WidgetStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Page").font(.system(.subheadline, weight: .semibold)).foregroundColor(NightWatch.Palette.textSecondary.color)
                    Text(s.faceHeadline).font(.system(size: 34, weight: .bold)).kerning(-0.8)
                        .foregroundColor(s.faceTone.color).lineLimit(2).minimumScaleFactor(0.6)
                    if let d = s.detail { Text(d).font(.system(.subheadline, weight: .medium)).foregroundColor(NightWatch.Palette.textSecondary.color) }
                    macRow(s)
                }
                Spacer(minLength: 8)
                NWPulseOrb(style: s.faceOrb).frame(width: 96, height: 96).offset(x: 12, y: -8)
            }
            Spacer(minLength: 0)
            NWWidgetRunway(model: s.runway(now: now, timeZone: timeZone))
            HStack(spacing: 10) {
                Link(destination: URL(string: "page://now")!) { pill("Open Now", NightWatch.Palette.amber, filled: true) }
                Link(destination: URL(string: "page://sky")!) { pill("Sky", NightWatch.Palette.textPrimary, filled: false) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func pill(_ title: String, _ c: NightWatch.RGBA, filled: Bool) -> some View {
        Text(title).font(.system(.subheadline, weight: .semibold))
            .foregroundColor((filled ? NightWatch.Palette.onBright : NightWatch.Palette.textPrimary).color)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(filled ? c.color : Color.white.opacity(0.10)))
    }
}

/// The Runway, small enough for a widget: a line with "now" at the left and
/// a labelled tick per deadline. With nothing ahead it says so.
struct NWWidgetRunway: View {
    var model: RunwayModel

    var body: some View {
        if model.markers.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: model.onAC ? "bolt.fill" : "checkmark").font(.system(size: 10, weight: .bold))
                Text(model.onAC ? "on power · runway clear" : "runway clear").font(.system(.caption2, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundColor(NightWatch.Palette.teal.opacity(0.9).color)
        } else {
            NWRunwayBar(model: model)
        }
    }
}

// MARK: - Claude usage

/// The 5-hour and 7-day windows as two rings with their resets.
struct NWWidgetUsageFace: View {
    var model: UsageCardModel?
    var problem: String? = nil
    var size: NWWidgetSize
    var now: Date = Date()
    var timeZone: TimeZone = .current

    static func tone(_ g: UsageGauge) -> NightWatch.RGBA {
        // Hot is amber too: red is kept for the hold rings.
        g.tone == .calm ? NightWatch.Palette.teal : NightWatch.Palette.amber
    }

    var body: some View {
        if let m = model {
            switch size {
            case .small: rings(m, ring: 62, line: 8)
            case .medium, .large:
                HStack(alignment: .center, spacing: 14) {
                    rings(m, ring: 76, line: 9)
                    let v = m.verdict(format: { NowFormat.clock($0, timeZone: timeZone) })
                    Text(v.text).font(.system(.caption, weight: .semibold))
                        .foregroundColor((v.warning ? NightWatch.Palette.amber : NightWatch.Palette.textSecondary).color)
                        .frame(maxWidth: 120, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Claude usage").font(NightWatch.Typo.title).foregroundColor(NightWatch.Palette.textPrimary.color)
                Text(problem ?? "Turn on usage tracking in Page on your Mac").font(NightWatch.Typo.caption)
                    .foregroundColor(NightWatch.Palette.textSecondary.color).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func rings(_ m: UsageCardModel, ring: CGFloat, line: CGFloat) -> some View {
        HStack(spacing: 10) {
            if let g = m.fiveHour { column(g, short: "5h", ring: ring, line: line) }
            if let g = m.sevenDay { column(g, short: "7d", ring: ring, line: line) }
        }
        .frame(maxWidth: .infinity)
    }

    private func column(_ g: UsageGauge, short: String, ring: CGFloat, line: CGFloat) -> some View {
        let c = Self.tone(g)
        return VStack(spacing: 5) {
            ZStack {
                Circle().stroke(c.opacity(0.18).color, lineWidth: line)
                Circle().trim(from: 0, to: CGFloat(max(0.01, g.fraction)))
                    .stroke(c.color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: c.opacity(0.45).color, radius: 4)
                Text("\(Int(g.pct.rounded()))").font(.system(size: ring * 0.30, weight: .bold, design: .rounded))
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
            }
            .frame(width: ring, height: ring)
            Text(short).font(.system(.caption, weight: .semibold)).foregroundColor(NightWatch.Palette.textPrimary.color)
            if let r = g.resetsAt, r > now {
                // Within the day, a clock time; further out, how long ("resets in 2d 4h").
                Text(r.timeIntervalSince(now) > 12 * 3600 ? "resets in \(UsageGauge.countdown(to: r, now: now))" : "resets \(NowFormat.clock(r, timeZone: timeZone))").font(.system(size: 10, weight: .medium))
                    .foregroundColor(NightWatch.Palette.textTertiary.color).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(g.label), \(Int(g.pct.rounded())) percent used"))
    }
}
