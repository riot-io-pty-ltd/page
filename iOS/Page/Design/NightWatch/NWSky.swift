import SwiftUI

/// Everything Sky and Lanes draw, as values.
struct SkyScreenData {
    var sky: SkyModel
    var lanes: LanesModel
    var mode: SkyMode
    var now: Date
    /// Why live sessions can't load, when they can't.
    var availability: SessionAvailabilityCopy? = nil
    /// Other paired Macs, shown dimmed as standby groups in Lanes.
    var standby: [TowerMacRow] = []
    /// The star whose tooltip is open.
    var selectedStar: String? = nil
}

struct SkyScreenActions {
    var setMode: (SkyMode) -> Void = { _ in }
    var select: (String?) -> Void = { _ in }
    var openStar: (SkyStar) -> Void = { _ in }
    var tapMoon: () -> Void = {}
    var availabilityAction: (SessionAvailabilityCopy.Action) -> Void = { _ in }
    var makeLive: (String) -> Void = { _ in }
    var toNow: () -> Void = {}
    var refresh: () async -> Void = {}
}

/// SKY: the fleet. Every live session is a star, every project a constellation
/// (named, joined by faint lines); the Mac is the moon. Or LANES: the same
/// fleet as an accessible list with a 4-hour strip per session. The last mode
/// is remembered. Nothing actionable lives only here: amber stars are also
/// cards in Now.
struct NWSkyScreen: View {
    var data: SkyScreenData
    var actions = SkyScreenActions()
    @Environment(\.nwTopInset) private var topInsetOverride

    var body: some View {
        GeometryReader { geo in
            let inset = topInsetOverride ?? geo.safeAreaInsets.top
            ZStack(alignment: .top) {
                if data.mode == .sky { skyBackdrop }
                VStack(spacing: 0) {
                    header.padding(.top, inset + 8)
                    if let a = data.availability {
                        availabilityCard(a).padding(NightWatch.Space.gutter)
                        Spacer()
                    } else {
                        switch data.mode {
                        case .sky: skyBody
                        case .lanes: lanesBody
                        }
                    }
                }
            }
            .ignoresSafeArea(edges: .top)
            // Beside the list's own scrolling, never instead of it: only a clearly sideways drag goes back to Now.
            .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { v in
                if NWDestination.afterDrag(from: .sky, translation: Double(v.translation.width), vertical: Double(v.translation.height)) == .now { actions.toNow() }
            })
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sky").font(.system(size: 40, weight: .bold)).kerning(-1).foregroundColor(NightWatch.Palette.textPrimary.color)
                    .accessibilityAddTraits(.isHeader)
                Text(data.sky.headline).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
            }
            Spacer()
            NWSegmented(options: SkyMode.allCases.map { ($0, $0.label) },
                        selection: Binding(get: { data.mode }, set: { actions.setMode($0) }))
                .frame(width: 168)
        }
        .padding(.horizontal, NightWatch.Space.gutter)
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

    // MARK: Sky

    private var skyBackdrop: some View {
        ZStack {
            NWAnimated { t in
                NWAuroraCanvas(palette: data.sky.paused ? .dusk : .working, seconds: t)
                    .mask(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white.opacity(0.7), location: 0.5), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
            }
            .ignoresSafeArea()
        }
        .accessibilityHidden(true)
    }

    private var skyBody: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geo in
                ZStack {
                    if data.sky.isEmpty {
                        VStack(spacing: 10) {
                            NWPulseOrb(style: .quiet).frame(width: 120, height: 120)
                            Text("No live sessions").font(NightWatch.Typo.title).foregroundColor(NightWatch.Palette.textPrimary.color)
                            Text("Start Claude Code or Codex on your Mac, or dispatch one from here, and it appears as a star.")
                                .font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color)
                                .multilineTextAlignment(.center).padding(.horizontal, 36)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    let skySize = SkySize(width: Double(geo.size.width), height: Double(geo.size.height))
                    let points = SkyModel.starPoints(data.sky.constellations, in: skySize)
                    let labels = SkyModel.labelLayout(data.sky.constellations, in: skySize)
                    ForEach(data.sky.constellations) { c in constellation(c, in: geo.size, points: points, labels: labels) }
                    moon.position(x: geo.size.width - 64, y: 34)
                    if let id = data.selectedStar, let star = star(id) { tooltip(star).position(x: geo.size.width / 2, y: geo.size.height - 150) }
                }
                .contentShape(Rectangle())
                .onTapGesture { actions.select(nil) }
            }
            .padding(.bottom, 0)
            VStack(spacing: 12) {
                NWTonightCard(rings: data.sky.rings)
                Spacer().frame(height: 96)
            }
            // The label layout reserves a fixed height for the card (SkyModel.labelBottomReserve).
            .dynamicTypeSize(...DynamicTypeSize.large)
            .padding(.horizontal, NightWatch.Space.gutter)
            .opacity(data.selectedStar == nil ? 1 : 0)
        }
    }

    private func star(_ id: String) -> SkyStar? { data.sky.constellations.flatMap(\.stars).first { $0.id == id } }

    private func constellation(_ c: Constellation, in size: CGSize, points: [String: SkyPoint], labels: [SkyLabelPlacement]) -> some View {
        func pt(_ s: SkyStar) -> CGPoint {
            let p = points[s.id] ?? SkyModel.starPoint(s, in: SkySize(width: Double(size.width), height: Double(size.height)))
            return CGPoint(x: p.x, y: p.y)
        }
        return ZStack {
            Path { p in
                for l in c.links where l.count == 2 && c.stars.indices.contains(l[0]) && c.stars.indices.contains(l[1]) {
                    p.move(to: pt(c.stars[l[0]])); p.addLine(to: pt(c.stars[l[1]]))
                }
            }
            .stroke(c.hue.color.opacity(0.32).color, lineWidth: 1)
            // Where each label sits is decided once, for the whole sky, so none lands on another or on a star.
            if let l = labels.first(where: { $0.kind == .project && $0.id == c.key }) {
                Text(l.text)
                    .font(NightWatch.Typo.label).kerning(1)
                    .foregroundColor((c.urgentState == .needsYou ? NightWatch.Palette.amber : c.hue.color).color)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width: CGFloat(l.rect.width), height: CGFloat(l.rect.height))
                    .background(Capsule().fill(Color.black.opacity(0.28)))
                    .dynamicTypeSize(...DynamicTypeSize.large)
                    .position(x: CGFloat(l.rect.midX), y: CGFloat(l.rect.midY))
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(Array(c.stars.enumerated()), id: \.element.id) { i, s in
                Button { actions.select(data.selectedStar == s.id ? nil : s.id) } label: { starView(s) }
                    .buttonStyle(.plain)
                    .position(pt(s))
                    .accessibilityLabel(Text("\(s.title), \(c.name), \(s.state.label.lowercased())"))
                    .accessibilityHint(Text("Shows details"))
                // Only the stars that matter carry a caption (what needs you, what is stuck); the rest
                // say what they are when tapped, so labels never pile up.
                if let l = labels.first(where: { $0.kind == .caption && $0.id == s.id }) {
                    Text(l.text).font(NightWatch.Typo.monoMicro)
                        .foregroundColor(NightWatch.Palette.textSecondary.opacity(0.8).color)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width: CGFloat(l.rect.width), height: CGFloat(l.rect.height), alignment: CGFloat(l.rect.midX) < pt(s).x ? .trailing : .leading)
                        .dynamicTypeSize(...DynamicTypeSize.large)
                        .position(x: CGFloat(l.rect.midX), y: CGFloat(l.rect.midY))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    @ViewBuilder private func starView(_ s: SkyStar) -> some View {
        let color = s.state.color
        let size: CGFloat = s.state == .needsYou ? 38 : 28
        ZStack {
            switch s.state {
            case .needsYou:
                NWAnimated { t in
                    let ph = (t / 2.4).truncatingRemainder(dividingBy: 1)
                    ZStack {
                        ForEach(0..<2, id: \.self) { i in
                            let p = (ph + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                            Circle().stroke(color.opacity(0.4 * (1 - p)).color, lineWidth: 1).frame(width: size * (1.4 + 1.2 * p), height: size * (1.4 + 1.2 * p))
                        }
                    }
                }
                NWStarGlyph(seed: s.seed, color: color, size: size, brightness: s.brightness)
            case .stuck:
                Circle().stroke(color.opacity(0.7).color, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(width: size * 1.6, height: size * 1.6)
                NWStarGlyph(seed: s.seed, color: color, size: size, brightness: s.brightness)
            case .rateLimited:
                NWStarShape(seed: s.seed).stroke(color.opacity(0.9).color, lineWidth: 1.4).frame(width: size * 0.7, height: size * 0.7)
            default:
                NWAnimated { t in
                    let twinkle = s.state == .working ? 0.85 + 0.15 * sin(t * 1.6 + Double(s.seed % 7)) : 1
                    NWStarGlyph(seed: s.seed, color: color, size: size, brightness: s.brightness * twinkle * (s.state == .paused ? 0.6 : 1))
                }
            }
        }
        .frame(width: 56, height: 56)
        .contentShape(Rectangle())
    }

    private var moon: some View {
        Button(action: actions.tapMoon) {
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(data.sky.moon.percent).font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                    Text(data.sky.moon.onAC ? "on power" : "on battery").font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textTertiary.color)
                }
                ZStack {
                    Circle().fill(RadialGradient(colors: [Color.white.opacity(0.95), NightWatch.RGBA(hex: 0xB8C0D8).color], center: .topLeading, startRadius: 1, endRadius: 22))
                        .frame(width: 26, height: 26)
                    if let f = data.sky.moon.fraction {
                        Circle().trim(from: 0, to: CGFloat(f)).stroke(NightWatch.Palette.teal.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90)).frame(width: 34, height: 34)
                    }
                }
            }
            .padding(.leading, 10).padding(.trailing, 6).frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The label layout keeps a fixed 140 x 52 pt corner clear for it.
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityLabel(Text("\(data.sky.macName), battery \(data.sky.moon.percent), \(data.sky.moon.detail)"))
        .accessibilityHint(Text("Opens the Tower at Power"))
    }

    private func tooltip(_ s: SkyStar) -> some View {
        HStack(spacing: 12) {
            NWStarGlyph(seed: s.seed, color: s.state.color, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(NightWatch.Typo.monoSmall).foregroundColor(NightWatch.Palette.textPrimary.color).lineLimit(1)
                Text("\(s.state.label.capitalized) · \(s.agent)" + (s.lastAction.isEmpty ? "" : " · \(s.lastAction)"))
                    .font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textTertiary.color).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(s.interventionId != nil ? "Decide" : "Open") { actions.openStar(s) }
                .font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.onBright.color)
                .padding(.horizontal, 14).frame(height: 36)
                .background(Capsule().fill(NightWatch.Palette.teal.color))
        }
        .padding(12)
        .frame(maxWidth: 360)
        .background(NWGlassBackground(radius: NightWatch.Radius.row))
        .padding(.horizontal, NightWatch.Space.gutter)
    }

    // MARK: Lanes

    private var lanesBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Spacer()
                    ForEach(data.lanes.axis.indices, id: \.self) { i in
                        Text(data.lanes.axis[i]).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textQuiet.color)
                            .frame(maxWidth: .infinity, alignment: i == data.lanes.axis.count - 1 ? .trailing : .leading)
                    }
                }
                .padding(.leading, 150)
                .accessibilityHidden(true)
                if data.lanes.groups.isEmpty && data.standby.isEmpty {
                    Text("No live sessions. Start Claude Code or Codex on your Mac and it shows up here, with what it's doing right now.")
                        .font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color).padding(.top, 20)
                }
                ForEach(data.lanes.groups) { g in group(g) }
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

    private func group(_ g: LaneGroup) -> some View {
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
                laneRow(r)
            }
        }
        .background(NWGlassBackground(radius: NightWatch.Radius.card))
        .clipShape(RoundedRectangle(cornerRadius: NightWatch.Radius.card, style: .continuous))
        .overlay(NWGlassRim(radius: NightWatch.Radius.card, withGlow: false))
    }

    private func laneRow(_ r: LaneRow) -> some View {
        Button { actions.openStar(SkyStar(id: r.id, title: r.title, state: r.state, x: 0, y: 0, brightness: 1, lastAction: r.lastAction,
                                          interventionId: r.interventionId, agent: r.agent, canType: true, seed: r.seed)) } label: {
            HStack(spacing: 10) {
                NWStarGlyph(seed: r.seed, color: r.state.color, size: 30)
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
        .accessibilityLabel(Text("\(r.title), \(r.state.label.lowercased()), \(r.agent)"))
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
/// jagged amber one stuck, a gap with a sky tick rate-limited, a grey band a
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
