import SwiftUI

/// Everything Lanes draws, as values.
struct LanesScreenData {
    /// The fleet, the Mac's battery (the moon) and whether agents are paused for power.
    var fleet: SkyModel
    var lanes: LanesModel
    var now: Date
    /// Why live sessions can't load, when they can't.
    var availability: SessionAvailabilityCopy? = nil
    /// Other paired Macs, shown dimmed as standby groups.
    var standby: [TowerMacRow] = []
    /// The last battery pause: the dusk and the dawn (`NWDuskDawn.swift`).
    var duskDawn = DuskDawnLog()
}

struct LanesScreenActions {
    /// A lane was tapped: its decision when it has one, else its session.
    var openRow: (LaneRow) -> Void = { _ in }
    /// The Mac's battery, top right: opens the Tower at Power.
    var tapMoon: () -> Void = {}
    var availabilityAction: (SessionAvailabilityCopy.Action) -> Void = { _ in }
    var makeLive: (String) -> Void = { _ in }
    var toNow: () -> Void = {}
    var refresh: () async -> Void = {}
}

/// LANES: the fleet as a list, one group per project and one lane per live
/// session, each with a 4-hour strip. The Mac's battery sits top right. While
/// agents are paused for power the screen plays the dusk (the aurora fades,
/// every working glyph dims, a grey horizon holds above the bar) and, when
/// power returns, the dawn (gold rising from the horizon, each glyph
/// relighting once its session is seen working). Nothing actionable lives
/// only here: a lane that needs you is also a card in Now.
struct NWLanesScreen: View {
    var data: LanesScreenData
    var actions = LanesScreenActions()
    @Environment(\.nwTopInset) private var topInsetOverride
    @Environment(\.nwMotion) private var motionPin

    /// How far above the bottom of the screen the horizon of a pause sits: clear of the capsule.
    private static let horizonLift: CGFloat = 92

    var body: some View {
        GeometryReader { geo in
            let inset = topInsetOverride ?? geo.safeAreaInsets.top
            ZStack(alignment: .top) {
                powerBackdrop
                dawnLight
                VStack(spacing: 0) {
                    header.padding(.top, inset + 8)
                    if let a = data.availability {
                        availabilityCard(a).padding(NightWatch.Space.gutter)
                        Spacer()
                    } else {
                        lanesBody
                    }
                }
                // The horizon holds in front of the lanes, a fine line above the bar, so a pause is seen even over a long list.
                horizonBand
            }
            .ignoresSafeArea(edges: .top)
            // Beside the list's own scrolling, never instead of it: only a clearly sideways drag goes back to Now.
            .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { v in
                if NWDestination.afterDrag(from: .lanes, translation: Double(v.translation.width), vertical: Double(v.translation.height)) == .now { actions.toNow() }
            })
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Lanes").font(.system(size: 40, weight: .bold)).kerning(-1).foregroundColor(NightWatch.Palette.textPrimary.color)
                    .accessibilityAddTraits(.isHeader)
                Text(data.fleet.headline).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
            }
            Spacer()
            moon
        }
        .padding(.horizontal, NightWatch.Space.gutter)
    }

    /// The Mac: its battery as a small moon with a ring. A tap opens the Tower at Power.
    private var moon: some View {
        Button(action: actions.tapMoon) {
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(data.fleet.moon.percent).font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                    Text(data.fleet.moon.onAC ? "on power" : "on battery").font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textTertiary.color)
                }
                ZStack {
                    Circle().fill(RadialGradient(colors: [Color.white.opacity(0.95), NightWatch.RGBA(hex: 0xB8C0D8).color], center: .topLeading, startRadius: 1, endRadius: 22))
                        .frame(width: 26, height: 26)
                    if let f = data.fleet.moon.fraction {
                        Circle().trim(from: 0, to: CGFloat(f)).stroke(NightWatch.Palette.teal.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90)).frame(width: 34, height: 34)
                    }
                }
            }
            .padding(.leading, 10).padding(.trailing, 6).frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityLabel(Text("\(data.fleet.macName), battery \(data.fleet.moon.percent), \(data.fleet.moon.detail)"))
        .accessibilityHint(Text("Opens the Tower at Power"))
    }

    private func availabilityCard(_ a: SessionAvailabilityCopy) -> some View {
        let banner = NowBanner(id: "availability", tone: a.tone == .info ? .info : (a.tone == .error ? .error : .warning), symbol: a.systemImage,
                               title: a.title, message: a.message, actionTitle: a.actionTitle, action: a.action == .repair ? .repair : (a.action == .retry ? .retry : nil))
        return NWBannerCard(banner: banner) { act in
            switch act {
            case .repair: actions.availabilityAction(.repair)
            default: actions.availabilityAction(.retry)
            }
        }
    }

    // MARK: The power story

    /// The aurora behind the list, only while the power story is on screen: fading to dusk,
    /// settled in the night of a pause, or fading back into the day as the dawn ends. Otherwise
    /// the shell's own sky shows, as it always has behind Lanes.
    private var powerBackdrop: some View {
        let story = data.powerStoryShown(pin: motionPin)
        return Group {
            if story {
                // A battery pause that has settled is a still night: no clock while agents are paused for power.
                NWAnimated(active: data.powerStoryMoving(pin: motionPin)) { t in
                    let light = data.skyLight(at: t, pin: motionPin)
                    NWLivingAurora(palette: light.palette, seconds: t, stars: light.stars)
                        .mask(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white.opacity(0.7), location: 0.5), .init(color: .clear, location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                        .opacity(light.cover)
                }
                .ignoresSafeArea()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The dawn's gold rising from the horizon to the very top of the screen, behind the lanes. No clock otherwise.
    private var dawnLight: some View {
        NWAnimated(active: data.powerStoryMoving(pin: motionPin)) { t in
            ZStack(alignment: .bottom) {
                if let d = data.skyLight(at: t, pin: motionPin).dawn {
                    NWDawnLight(sweep: d.sweep, warmth: d.warmth).padding(.bottom, Self.horizonLift).padding(.top, -160)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The grey band of a battery pause: it falls with the dusk, holds while paused, and fades as the dawn leaves it.
    private var horizonBand: some View {
        NWAnimated(active: data.powerStoryMoving(pin: motionPin)) { t in
            NWHorizonBand(opacity: data.skyLight(at: t, pin: motionPin).band)
                .padding(.bottom, Self.horizonLift - 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Lanes

    private var lanesBody: some View {
        // Each lane's own resume, one by one, from the bottom of the list up (computed once per draw).
        let relights = data.duskDawn.dawnAt != nil || motionPin?.kind == .dawn ? data.relights : [:]
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !data.lanes.groups.isEmpty {
                    HStack {
                        Spacer()
                        ForEach(data.lanes.axis.indices, id: \.self) { i in
                            Text(data.lanes.axis[i]).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textQuiet.color)
                                .frame(maxWidth: .infinity, alignment: i == data.lanes.axis.count - 1 ? .trailing : .leading)
                        }
                    }
                    .padding(.leading, 150)
                    .accessibilityHidden(true)
                }
                if data.lanes.groups.isEmpty && data.standby.isEmpty {
                    Text("No live sessions. Start Claude Code or Codex on your Mac, or start one from the + button, and it shows up here with what it's doing right now.")
                        .font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color).padding(.top, 20)
                }
                ForEach(data.lanes.groups) { g in group(g, relights: relights) }
                ForEach(data.standby.filter { !$0.isActive }) { m in standby(m) }
                if let note = data.lanes.coverageNote {
                    Text(note).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textQuiet.color)
                }
                Spacer().frame(height: 120)
            }
            .padding(.horizontal, NightWatch.Space.gutter)
            .padding(.top, 14)
        }
        .refreshable { await actions.refresh() }
    }

    private func group(_ g: LaneGroup, relights: [String: TimeInterval]) -> some View {
        let head: NightWatch.RGBA = g.urgentState == .needsYou || g.urgentState == .stuck ? NightWatch.Palette.amber : g.hue.color
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(head.color).frame(width: 8, height: 8)
                Text(g.name.uppercased()).font(NightWatch.Typo.labelLarge).kerning(1.2).foregroundColor(head.color).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).frame(height: 40)
            .background(head.opacity(0.10).color)
            .accessibilityAddTraits(.isHeader)
            ForEach(g.rows) { r in
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                laneRow(r, relights: relights)
            }
        }
        .background(NWGlassBackground(radius: NightWatch.Radius.card))
        .clipShape(RoundedRectangle(cornerRadius: NightWatch.Radius.card, style: .continuous))
        .overlay(NWGlassRim(radius: NightWatch.Radius.card, withGlow: false))
    }

    private func laneRow(_ r: LaneRow, relights: [String: TimeInterval]) -> some View {
        Button { actions.openRow(r) } label: {
            HStack(spacing: 10) {
                // In the power story the glyph exhales and dims with the pause, and relights at its own resume.
                NWAnimated(fps: 20, active: data.powerStoryMoving(pin: motionPin)) { t in
                    let light = data.starLight(id: r.id, state: r.state, at: t, pin: motionPin, relights: relights)
                    NWStarGlyph(seed: r.seed, color: r.state.color, size: 30, brightness: light.brightness)
                        .scaleEffect(light.scale)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.title).font(NightWatch.Typo.mono).foregroundColor(NightWatch.Palette.textPrimary.color).lineLimit(1)
                    Text(r.state.label).font(NightWatch.Typo.label).kerning(0.8).foregroundColor(r.state.color.color)
                }
                .frame(width: 100, alignment: .leading)
                NWActivityStrip(cells: r.strip)
                    .frame(height: 30)
            }
            .padding(.horizontal, 12).frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(r.title), \(r.state.label.lowercased()), \(r.agent)" + (r.lastAction.isEmpty ? "" : ", \(r.lastAction)")))
        .accessibilityHint(Text(r.interventionId != nil ? "Opens the decision" : "Opens the session"))
    }

    private func standby(_ m: TowerMacRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer").foregroundColor(NightWatch.Palette.textTertiary.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name).font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.textSecondary.color)
                Text("standby · \(m.subtitle)").font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textQuiet.color)
            }
            Spacer()
            Button("Make live") { actions.makeLive(m.id) }
                .font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                .padding(.horizontal, 14).frame(height: 36)
                .background(Capsule().fill(Color.white.opacity(0.1)))
        }
        .padding(14)
        .background(NWGlassBackground(radius: NightWatch.Radius.card, fill: NightWatch.Palette.surface.opacity(0.5)))
        .accessibilityElement(children: .combine)
    }
}

/// The 4-hour strip on a lane: one thin bar per five minutes, ending at now.
/// A bright teal bar is working, a short dim one idle, an amber bar waiting, a
/// jagged amber one stuck, a gap with a blue tick rate-limited, a grey band a
/// battery pause. A faint dot is time this iPhone did not see: it is never
/// filled in.
struct NWActivityStrip: View {
    var cells: [StripCell]

    var body: some View {
        GeometryReader { geo in
            let n = max(1, cells.count)
            let gap: CGFloat = 1
            let w = max(1, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(cells.indices, id: \.self) { i in
                    let last = i == cells.count - 1
                    bar(cells[i].level, index: i, last: last, width: w, height: geo.size.height)
                }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func bar(_ level: StarState?, index: Int, last: Bool, width: CGFloat, height: CGFloat) -> some View {
        switch level {
        case nil:
            Circle().fill(Color.white.opacity(0.12)).frame(width: min(width, 2), height: 2).frame(width: width, height: height, alignment: .bottom)
        case .working?:
            RoundedRectangle(cornerRadius: 1).fill(NightWatch.Palette.teal.opacity(last ? 1 : 0.55).color).frame(width: width, height: height)
        case .needsYou?:
            RoundedRectangle(cornerRadius: 1).fill(NightWatch.Palette.amber.opacity(last ? 1 : 0.6).color).frame(width: width, height: height * 0.8)
        case .stuck?:
            RoundedRectangle(cornerRadius: 1).fill(NightWatch.Palette.amber.opacity(last ? 1 : 0.6).color).frame(width: width, height: height * (index % 2 == 0 ? 1 : 0.55))
        case .rateLimited?:
            Rectangle().fill(NightWatch.Palette.sky.opacity(0.6).color).frame(width: width, height: 2)
        case .paused?:
            Rectangle().fill(NightWatch.RGBA(hex: 0x8A8FA0).opacity(0.5).color).frame(width: width, height: height * 0.4)
        case .idle?:
            RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(last ? 0.5 : 0.22)).frame(width: width, height: height * 0.2)
        case .offline?:
            Circle().fill(Color.white.opacity(0.2)).frame(width: min(width, 2), height: 2).frame(width: width, height: height, alignment: .bottom)
        }
    }
}
