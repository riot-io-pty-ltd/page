import SwiftUI

/// Everything the Tower draws, as values.
struct TowerScreenData {
    var macName: String
    var power: TowerPower
    var budget: TowerBudget
    var macs: [TowerMacRow]
    /// "online · 3 active sessions · Battery 54%, on power".
    var macLine: String?
    var relayHost: String?
    var relayText: String
    var notifications: NotificationsState
    var push: PushStatus
    /// "3 live sessions · end-to-end encrypted".
    var liveSessionsText: String
    var glow: CardGlow
    var version: String
    var now: Date
    var timeZone: TimeZone = .current
    /// Open the Tower scrolled to a section (the Runway opens Budget).
    var scrollTo: TowerSection? = nil
    var feedbackURL: URL? = nil
}

struct TowerScreenActions {
    var close: () -> Void = {}
    var switchMac: (String) -> Void = { _ in }
    var removeMac: (String) -> Void = { _ in }
    var addMac: () -> Void = {}
    var unpair: () -> Void = {}
    var openNotificationSettings: () -> Void = {}
    var turnOnNotifications: () -> Void = {}
    var setGlow: (CardGlow) -> Void = { _ in }
    var openHistory: () -> Void = {}
    /// "Show the tips again": every first-time tip comes back.
    var resetTips: () -> Void = {}
    var refresh: () async -> Void = {}
}

/// The Tower: power, budget, Macs, attention, pairing, appearance and about.
/// It drops from the Mac chip and holds every setting Page has next to the
/// thing it controls. The phone reads the Mac's power and usage but cannot
/// change them (those are set in Page on the Mac), so those rows say where to
/// change them instead of drawing a switch that does nothing.
struct NWTowerScreen: View {
    var data: TowerScreenData
    var actions = TowerScreenActions()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    section(.power) { power }
                    section(.budget) { budget }
                    section(.macs) { macs }
                    section(.attention) { attention }
                    section(.gestures) { gestures }
                    section(.terminals) { terminals }
                    section(.pairing) { pairing }
                    section(.appearance) { appearance }
                    section(.about) { about }
                    Spacer().frame(height: 40)
                }
                .padding(.horizontal, NightWatch.Space.gutter)
                .padding(.top, 18)
            }
            .refreshable { await actions.refresh() }
            .onAppear {
                if let s = data.scrollTo { DispatchQueue.main.async { proxy.scrollTo(s.rawValue, anchor: UnitPoint(x: 0.5, y: -0.04)) } }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("THE TOWER").font(NightWatch.Typo.labelLarge).kerning(2).foregroundColor(NightWatch.Palette.teal.color)
                Text(DeliveryPreview.macLabel(data.macName)).font(.system(size: 34, weight: .bold)).kerning(-0.8)
                    .foregroundColor(NightWatch.Palette.textPrimary.color).lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                if let l = data.macLine { Text(l).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color) }
            }
            Spacer()
            Button(action: actions.close) {
                Image(systemName: "xmark").font(.system(.body, weight: .semibold))
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
        }
    }

    private func section<C: View>(_ s: TowerSection, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(s.title.uppercased()).font(NightWatch.Typo.labelLarge).kerning(1.4).foregroundColor(NightWatch.Palette.textTertiary.color)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .id(s.rawValue)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NWGlassBackground(radius: NightWatch.Radius.card))
            .clipShape(RoundedRectangle(cornerRadius: NightWatch.Radius.card, style: .continuous))
            .overlay(NWGlassRim(radius: NightWatch.Radius.card, withGlow: false))
    }

    private var divider: some View { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.leading, 70) }

    // MARK: Power

    private var power: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(data.power.headline).font(NightWatch.Typo.title).foregroundColor(NightWatch.Palette.textPrimary.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(data.power.state).font(NightWatch.Typo.captionStrong)
                        .foregroundColor((data.power.warn ? NightWatch.Palette.amber : NightWatch.Palette.textSecondary).color)
                }
                if let f = data.power.fraction { powerBar(fraction: f, cutoff: data.power.cutoffFraction) }
                Text(data.power.note).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
            }
            .padding(16)
            .accessibilityElement(children: .combine)
        }
    }

    private func powerBar(fraction: Double, cutoff: Double?) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [NightWatch.Palette.amber.color, NightWatch.Palette.green.color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(8, w * CGFloat(fraction)))
                if let cutoff {
                    RoundedRectangle(cornerRadius: 1.5).fill(NightWatch.Palette.red.color)
                        .frame(width: 3, height: 18).offset(x: w * CGFloat(cutoff) - 1.5)
                }
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    // MARK: Budget

    private var budget: some View {
        card {
            if let m = data.budget.model {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 16) {
                        if let g = m.fiveHour { gauge(g) }
                        if let g = m.sevenDay { gauge(g) }
                    }
                    let verdict = m.verdict(format: { NowFormat.clock($0, timeZone: data.timeZone) })
                    HStack(spacing: 8) {
                        Image(systemName: verdict.warning ? "exclamationmark.triangle" : "checkmark.seal")
                        Text(verdict.text).fixedSize(horizontal: false, vertical: true)
                        if let m = m.staleMinutes { Text("as of \(m < 60 ? "\(m)m" : "\(m / 60)h") ago").foregroundColor(NightWatch.Palette.textQuiet.color) }
                    }
                    .font(NightWatch.Typo.caption)
                    .foregroundColor((verdict.warning ? NightWatch.Palette.amber : NightWatch.Palette.teal).color)
                }
                .padding(16)
            } else {
                Text(data.budget.emptyNote).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color)
                    .padding(16)
            }
            divider
            towerRow(icon: "clock.arrow.circlepath", tint: NightWatch.Palette.sky, title: "History and stats", detail: "everything you've settled, and the day's numbers",
                     trailing: nil, chevron: true, action: actions.openHistory)
        }
    }

    private func gauge(_ g: UsageGauge) -> some View {
        let tone: NightWatch.RGBA = g.tone == .calm ? NightWatch.Palette.teal : NightWatch.Palette.amber
        return HStack(spacing: 12) {
            ZStack {
                NWRing(progress: g.fraction, color: tone, lineWidth: 7, size: 64)
                Text("\(Int(g.pct.rounded()))").font(.system(.headline, weight: .bold)).foregroundColor(NightWatch.Palette.textPrimary.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(g.label).font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                if let r = g.resetsAt { Text("resets \(NowFormat.clock(r, timeZone: data.timeZone))").font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color) }
                if let p = g.paceLine { Text(p).font(NightWatch.Typo.monoMicro).foregroundColor(tone.color) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Macs

    private var macs: some View {
        card {
            ForEach(Array(data.macs.enumerated()), id: \.element.id) { i, m in
                if i > 0 { divider }
                macRow(m)
            }
            if !data.macs.isEmpty { divider }
            towerRow(icon: "plus", tint: NightWatch.Palette.teal, title: "Add another Mac", detail: "scan its pairing code; you can switch between them",
                     trailing: nil, chevron: true, action: actions.addMac)
        }
    }

    private func macRow(_ m: TowerMacRow) -> some View {
        let dot: NightWatch.RGBA = m.isActive ? NightWatch.Palette.green : (m.presence == .online ? NightWatch.Palette.green : (m.presence == .offline ? NightWatch.RGBA(hex: 0x8A8FA0) : NightWatch.Palette.textQuiet))
        return HStack(spacing: 14) {
            Image(systemName: m.isActive ? "desktopcomputer" : "laptopcomputer").font(.system(.body, weight: .medium))
                .foregroundColor(dot.color)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(dot.opacity(0.14).color))
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name).font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                Text(m.subtitle).font(NightWatch.Typo.caption).foregroundColor((m.needsYou > 0 ? NightWatch.Palette.amber : NightWatch.Palette.textTertiary).color).lineLimit(2)
            }
            Spacer(minLength: 8)
            if m.isActive {
                Text("Active").font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.textSecondary.color)
            } else {
                Button("Switch") { actions.switchMac(m.id) }
                    .font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.teal.color).buttonStyle(.plain).frame(minHeight: 44)
                Menu {
                    Button("Remove", role: .destructive) { actions.removeMac(m.id) }
                } label: {
                    Image(systemName: "ellipsis").foregroundColor(NightWatch.Palette.textSecondary.color).frame(width: 32, height: 44)
                }
                .accessibilityLabel(Text("More for \(m.name)"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    // MARK: Attention

    private var attention: some View {
        card {
            towerRow(icon: "bell.badge", tint: NightWatch.Palette.violet, title: "Notifications", detail: data.notifications.text,
                     trailing: data.notifications == .off ? "Open Settings" : (data.notifications == .notSet ? "Turn on" : nil), chevron: false,
                     action: data.notifications == .off ? actions.openNotificationSettings : (data.notifications == .notSet ? actions.turnOnNotifications : nil))
            divider
            towerRow(icon: "antenna.radiowaves.left.and.right", tint: NightWatch.Palette.sky, title: "Push", detail: data.push.text, trailing: nil, chevron: false, action: nil)
            divider
            towerRow(icon: "sparkles", tint: NightWatch.Palette.teal, title: "Live sessions", detail: data.liveSessionsText, trailing: nil, chevron: false, action: nil)
            divider
            towerRow(icon: "moon", tint: NightWatch.Palette.textTertiary, title: "Quiet hours and when to page", detail: "set in Page on your Mac, where they apply",
                     trailing: nil, chevron: false, action: nil)
        }
    }

    // MARK: Gestures & shortcuts

    /// Every gesture and what it does, from `GestureGuide`: the same lines the first-time tips use.
    private var gestures: some View {
        VStack(alignment: .leading, spacing: 10) {
            card {
                ForEach(Array(GestureGuide.entries.enumerated()), id: \.element.id) { i, e in
                    if i > 0 { divider }
                    gestureRow(e)
                }
            }
            Text("Everything here can also be done without the gesture: VoiceOver offers each one as an action on the row.")
                .font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            card {
                ForEach(Array(GestureGuide.shortcuts.enumerated()), id: \.element.id) { i, e in
                    if i > 0 { divider }
                    towerRowBody(icon: e.symbol, tint: NightWatch.Palette.teal, title: e.gesture, detail: "\(e.context) · \(e.effect)", trailing: nil, chevron: false)
                }
            }
            Button(action: actions.resetTips) {
                Text(GestureGuide.showAgainLabel).font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.teal.color)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func gestureRow(_ e: GestureEntry) -> some View {
        towerRowBody(icon: e.symbol, tint: NightWatch.Palette.teal, title: "\(e.gesture) \(e.context)", detail: e.effect, trailing: nil, chevron: false)
    }

    // MARK: Works with

    private var terminals: some View {
        VStack(alignment: .leading, spacing: 10) {
            card {
                ForEach(Array(TowerHosts.hosts.enumerated()), id: \.element.id) { i, h in
                    if i > 0 { divider }
                    towerRow(icon: h.symbol, tint: NightWatch.Palette.teal, title: h.name, detail: h.line, trailing: nil, chevron: false, action: nil)
                }
            }
            Text(TowerHosts.setUpLine).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            Text(TowerHosts.othersLine).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
    }

    // MARK: Pairing

    private var pairing: some View {
        card {
            towerRow(icon: "key", tint: NightWatch.Palette.textSecondary, title: "End-to-end encrypted", detail: "session key from the pairing QR", trailing: nil, chevron: false, action: nil)
            divider
            towerRow(icon: "arrow.triangle.2.circlepath", tint: NightWatch.Palette.sky, title: "Relay", detail: ([data.relayText] + (data.relayHost.map { [$0] } ?? [])).joined(separator: " · "),
                     trailing: nil, chevron: false, action: nil)
            divider
            towerRow(icon: "xmark.circle", tint: NightWatch.Palette.amber, title: "Unpair \(DeliveryPreview.macLabel(data.macName))",
                     detail: "this iPhone stops receiving pages until you scan a pairing code again", trailing: nil, chevron: true, action: actions.unpair)
        }
    }

    // MARK: Appearance

    private var appearance: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Card glow").font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                NWSegmented(options: CardGlow.allCases.map { ($0, $0.label) },
                            selection: Binding(get: { data.glow }, set: { actions.setGlow($0) }))
                Text("A soft light along the bottom edge of cards. It follows the card's shape and fades inside it. Off by default.")
                    .font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
                // A live sample, so the choice can be judged right here.
                Text("Sample card").font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                    .padding(16).frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
                    .background(NWGlassBackground(radius: NightWatch.Radius.card))
                    .environment(\.nwCardGlow, data.glow)
                    .accessibilityHidden(true)
            }
            .padding(16)
        }
    }

    // MARK: About

    private var about: some View {
        card {
            towerRow(icon: "info.circle", tint: NightWatch.Palette.textSecondary, title: "Version", detail: data.version, trailing: nil, chevron: false, action: nil)
            if let url = data.feedbackURL {
                divider
                Link(destination: url) {
                    towerRowBody(icon: "bubble.left.and.bubble.right", tint: NightWatch.Palette.teal, title: "Help & feedback", detail: "opens the Page issue tracker on GitHub",
                                 trailing: nil, chevron: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Rows

    @ViewBuilder private func towerRow(icon: String, tint: NightWatch.RGBA, title: String, detail: String?, trailing: String?, chevron: Bool, action: (() -> Void)?) -> some View {
        if let action {
            Button(action: action) { towerRowBody(icon: icon, tint: tint, title: title, detail: detail, trailing: trailing, chevron: chevron) }.buttonStyle(.plain)
        } else {
            towerRowBody(icon: icon, tint: tint, title: title, detail: detail, trailing: trailing, chevron: chevron)
        }
    }

    private func towerRowBody(icon: String, tint: NightWatch.RGBA, title: String, detail: String?, trailing: String?, chevron: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(.body, weight: .medium)).foregroundColor(tint.color)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.14).color))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                if let detail { Text(detail).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            if let trailing { Text(trailing).font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.teal.color) }
            if chevron { Image(systemName: "chevron.right").font(.system(.caption, weight: .bold)).foregroundColor(NightWatch.Palette.textQuiet.color) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 64)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
