import SwiftUI

// The Tower's Widgets page. Apple does not let an app place a widget, so this
// page is honest about it: a status row (which Page widgets are on your
// screens), the steps for the Home Screen and the Lock Screen drawn as small
// pictures, and "What you'll get", drawn by the widgets' own faces over
// example data. The words are TowerWidgets (pure).

private typealias P = NightWatch.Palette

extension NWTowerScreen {
    var widgets: some View {
        VStack(alignment: .leading, spacing: 14) {
            card {
                widgetStatusRow
                divider
                towerRowBody(icon: "square.grid.2x2", tint: P.teal, title: TowerWidgets.addTitle, detail: TowerWidgets.honestLine, trailing: nil, chevron: false)
            }
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { widgetGuideOpen.toggle() } }) {
                Text(widgetGuideOpen ? TowerWidgets.hideLabel : TowerWidgets.showLabel).font(NightWatch.Typo.bodyStrong)
                    .foregroundColor(widgetGuideOpen ? P.teal.color : P.onBright.color)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Capsule().fill(widgetGuideOpen ? Color.white.opacity(0.08) : P.teal.color))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            if widgetGuideOpen { widgetGuide }
            widgetPreviews
            Text(TowerWidgets.macNote).font(NightWatch.Typo.caption).foregroundColor(P.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
    }

    // MARK: Status

    private var widgetStatusRow: some View {
        let status = data.widgets
        let icon = status.placed == nil ? "circle.dotted" : (status.isPlaced ? "checkmark.circle.fill" : "plus.circle")
        let tint: NightWatch.RGBA = status.isPlaced ? P.green : (status.placed == nil ? P.textSecondary : P.amber)
        return HStack(spacing: 14) {
            Image(systemName: icon).font(.system(.body, weight: .medium)).foregroundColor(tint.color)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.14).color))
            VStack(alignment: .leading, spacing: 3) {
                ForEach(status.lines, id: \.self) { line in
                    Text(line).font(NightWatch.Typo.bodyStrong).foregroundColor(P.textPrimary.color).fixedSize(horizontal: false, vertical: true)
                }
                Text(TowerWidgets.hint(status)).font(NightWatch.Typo.caption).foregroundColor(P.textTertiary.color).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 64)
        .accessibilityElement(children: .combine)
    }

    // MARK: Show me how

    private var widgetGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            NWSegmented(options: TowerWidgets.Place.allCases.map { ($0, $0.label) }, selection: $widgetGuidePlace)
            card {
                let steps = TowerWidgets.steps(widgetGuidePlace)
                ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                    if i > 0 { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.leading, 14) }
                    widgetStepRow(step, place: widgetGuidePlace)
                }
            }
        }
    }

    private func widgetStepRow(_ step: TowerWidgets.Step, place: TowerWidgets.Place) -> some View {
        HStack(alignment: .center, spacing: 14) {
            NWWidgetStepPicture(place: place, step: step.number)
                .frame(width: 96, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.10)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(step.number)").font(.system(size: 11, weight: .bold)).foregroundColor(P.onBright.color)
                        .frame(width: 18, height: 18).background(Circle().fill(P.teal.color))
                    Text(step.title).font(NightWatch.Typo.bodyStrong).foregroundColor(P.textPrimary.color).fixedSize(horizontal: false, vertical: true)
                }
                Text(step.detail).font(NightWatch.Typo.caption).foregroundColor(P.textTertiary.color).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    // MARK: What you'll get

    private var widgetPreviews: some View {
        let status = TowerWidgets.exampleStatus(now: data.now)
        let usage = UsageCardModel(status.usage, now: data.now)
        let tone = status.facePalette
        return VStack(alignment: .leading, spacing: 12) {
            Text(TowerWidgets.previewsTitle.uppercased()).font(NightWatch.Typo.label).kerning(1.2).foregroundColor(P.textTertiary.color).padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 12) {
                captioned("Page · small") {
                    NWWidgetPreviewTile(shape: .small, palette: tone) { NWWidgetStatusFace(status: status, size: .small, now: data.now, timeZone: data.timeZone) }
                }
                captioned("Claude usage · small") {
                    NWWidgetPreviewTile(shape: .small, palette: .quiet, strength: 0.5) { NWWidgetUsageFace(model: usage, size: .small, now: data.now, timeZone: data.timeZone) }
                }
            }
            captioned("Page · medium") {
                NWWidgetPreviewTile(shape: .medium, palette: tone) { NWWidgetStatusFace(status: status, size: .medium, now: data.now, timeZone: data.timeZone) }
            }
            captioned("Claude usage · medium") {
                NWWidgetPreviewTile(shape: .medium, palette: .quiet, strength: 0.5) { NWWidgetUsageFace(model: usage, size: .medium, now: data.now, timeZone: data.timeZone) }
            }
            captioned("Page · large") {
                NWWidgetPreviewTile(shape: .large, palette: tone) { NWWidgetStatusFace(status: status, size: .large, now: data.now, timeZone: data.timeZone) }
            }
            .id("widgets-large")
            Text(TowerWidgets.examplesNote).font(NightWatch.Typo.caption).foregroundColor(P.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)

            Text(TowerWidgets.lockScreenTitle.uppercased()).font(NightWatch.Typo.label).kerning(1.2).foregroundColor(P.textTertiary.color)
                .padding(.leading, 4).padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            NWLockScreenPreview(status: status, usage: usage)
                .id("widgets-lock")
            Text(TowerWidgets.lockNote).font(NightWatch.Typo.caption).foregroundColor(P.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)

            // The list, with every size each widget comes in.
            card {
                ForEach(Array(TowerWidgets.widgets.enumerated()), id: \.element.id) { i, w in
                    if i > 0 { divider }
                    towerRowBody(icon: w.kind == .macStatus ? "bell.badge" : "chart.pie", tint: w.kind == .macStatus ? P.amber : P.teal,
                                 title: w.name, detail: w.detail + "\n" + w.sizesLine, trailing: nil, chevron: false)
                }
            }
        }
    }

    private func captioned<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
            Text(title).font(NightWatch.Typo.captionStrong).foregroundColor(P.textTertiary.color).padding(.leading, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Preview: \(title)"))
    }
}

// MARK: - A widget at the size iOS would draw it

/// A Home Screen widget's real face, over its real background, at the widget's proportions
/// but as wide as the space it is given. A still frame: the aurora holds a pose, and nothing in it is tappable.
struct NWWidgetPreviewTile<Face: View>: View {
    enum Shape { case small, medium, large }
    var shape: Shape
    var palette: NightWatch.AuroraPalette
    var strength: Double = 1
    @ViewBuilder var face: () -> Face

    /// Width over height of a widget on an iPhone 15 Pro (170 x 170, 364 x 170, 364 x 382).
    private var ratio: CGFloat {
        switch shape {
        case .small: return 1
        case .medium: return 364 / 170
        case .large: return 364 / 382
        }
    }

    var body: some View {
        Color.clear
            .aspectRatio(ratio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(
                face()
                    .padding(16)
                    .environment(\.nwFixedPhase, 2.0)
                    .allowsHitTesting(false)
                    .background(NWWidgetBackground(palette: palette, strength: strength))
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - The Lock Screen

/// Stand-ins for the Lock Screen widgets (iOS draws the real ones in the wallpaper's tint):
/// the circle, the rectangle and the line, with the same words the widgets use.
struct NWLockScreenPreview: View {
    var status: WidgetStatus
    var usage: UsageCardModel?

    var body: some View {
        ZStack {
            LinearGradient(colors: [P.violet.opacity(0.42).color, P.sky.opacity(0.22).color, P.background.color],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 10) {
                Text("Tuesday 27 October").font(.system(size: 13, weight: .semibold)).foregroundColor(Color.white.opacity(0.85))
                Text("Page: \(status.faceHeadline), \(status.working ?? 0) working").font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white).lineLimit(1).minimumScaleFactor(0.7)
                HStack(spacing: 10) {
                    rectangular
                    circle { VStack(spacing: 0) {
                        Text("\(status.needsYou)").font(.system(size: 22, weight: .bold)).foregroundColor(.white)
                        Text("need").font(.system(size: 9)).foregroundColor(Color.white.opacity(0.85))
                    } }
                    usageCircle
                }
            }
            .padding(.vertical, 16).padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Preview: the Page widgets on the Lock Screen, in three shapes"))
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Page · Online").font(.system(size: 11, weight: .semibold)).foregroundColor(Color.white.opacity(0.85))
            Text(status.faceHeadline).font(.system(size: 17, weight: .bold)).foregroundColor(.white)
            if let d = status.detail { Text(d).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.85)).lineLimit(1) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.20)))
    }

    private func circle<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content().frame(width: 62, height: 62).background(Circle().fill(Color.white.opacity(0.20)))
    }

    private var usageCircle: some View {
        let g = usage?.fiveHour
        return circle {
            ZStack {
                Circle().stroke(Color.white.opacity(0.25), lineWidth: 5)
                Circle().trim(from: 0, to: CGFloat(max(0.02, g?.fraction ?? 0.6))).stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: -1) {
                    Text("\(Int((g?.pct ?? 62).rounded()))").font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                    Text("5h").font(.system(size: 9)).foregroundColor(Color.white.opacity(0.85))
                }
            }
            .padding(6)
        }
    }
}

// MARK: - The step pictures

/// A small drawing for each step: where to touch, what lights up. Simple shapes,
/// the teal marks the thing to do.
struct NWWidgetStepPicture: View {
    var place: TowerWidgets.Place
    var step: Int

    var body: some View {
        ZStack {
            P.surface.color
            picture
        }
    }

    @ViewBuilder private var picture: some View {
        switch (place, step) {
        case (.homeScreen, 1): holdOnHome
        case (.homeScreen, 2): editMenu
        case (.homeScreen, 3): search
        case (.homeScreen, 4): sizes
        case (.homeScreen, _): addButton
        case (.lockScreen, 1): holdOnLock
        case (.lockScreen, 2): customize
        case (.lockScreen, 3): widgetRow
        default: choosePage
        }
    }

    private let ink = P.onBright.color

    private func icon(lit: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(lit ? P.teal.opacity(0.9).color : Color.white.opacity(0.14)).frame(width: 15, height: 15)
    }

    private var hand: some View {
        Image(systemName: "hand.point.up.left.fill").font(.system(size: 17)).foregroundColor(.white).shadow(color: .black.opacity(0.6), radius: 2)
    }

    /// Icons that wiggle, with a gap under a finger.
    private var holdOnHome: some View {
        ZStack {
            VStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { r in
                    HStack(spacing: 7) {
                        ForEach(0..<4, id: \.self) { c in
                            if r == 1 && c == 1 || r == 1 && c == 2 {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(P.teal.color, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2])).frame(width: 15, height: 15)
                            } else {
                                icon().rotationEffect(.degrees(r + c % 2 == 0 ? 3 : -3))
                            }
                        }
                    }
                }
            }
            hand.offset(x: 4, y: 12)
        }
    }

    private var editMenu: some View {
        ZStack(alignment: .topLeading) {
            Text("Edit").font(.system(size: 9.5, weight: .bold)).foregroundColor(ink)
                .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(P.teal.color)).offset(x: 8, y: 8)
            VStack(alignment: .leading, spacing: 0) {
                menuRow("Add Widget", symbol: "plus", lit: true)
                menuRow("Edit Pages", symbol: "square.grid.2x2", lit: false)
                menuRow("Customize", symbol: "paintbrush", lit: false)
            }
            .padding(3).frame(width: 78)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.65)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
            .offset(x: 8, y: 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func menuRow(_ text: String, symbol: String, lit: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 6.5, weight: .bold))
            Text(text).font(.system(size: 7.5, weight: lit ? .bold : .regular)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundColor(lit ? ink : P.textSecondary.color)
        .padding(.horizontal, 4).frame(height: 14)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(lit ? P.teal.color : Color.clear))
    }

    private var search: some View {
        VStack(spacing: 7) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 8))
                Text("Page").font(.system(size: 9.5, weight: .semibold))
                Spacer()
            }
            .foregroundColor(P.textPrimary.color).padding(.horizontal, 6).frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.12)))
            HStack(spacing: 8) {
                tile("Page", color: P.amber)
                tile("Usage", color: P.teal)
            }
        }
        .padding(.horizontal, 9)
    }

    private func tile(_ name: String, color: NightWatch.RGBA) -> some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.opacity(0.28).color)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(color.opacity(0.7).color, lineWidth: 1))
                .frame(width: 30, height: 30)
            Text(name).font(.system(size: 7.5, weight: .medium)).foregroundColor(P.textSecondary.color)
        }
    }

    private var sizes: some View {
        VStack(spacing: 7) {
            HStack(alignment: .bottom, spacing: 6) {
                shape(w: 15, h: 15, lit: false)
                shape(w: 32, h: 15, lit: true)
                shape(w: 32, h: 32, lit: false)
            }
            HStack(spacing: 4) {
                Circle().fill(Color.white.opacity(0.3)).frame(width: 4, height: 4)
                Circle().fill(P.teal.color).frame(width: 4, height: 4)
                Circle().fill(Color.white.opacity(0.3)).frame(width: 4, height: 4)
            }
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 9, weight: .semibold)).foregroundColor(P.textSecondary.color)
        }
    }

    private func shape(w: CGFloat, h: CGFloat, lit: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(lit ? P.teal.opacity(0.35).color : Color.white.opacity(0.12))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(lit ? P.teal.color : Color.white.opacity(0.2), lineWidth: 1))
            .frame(width: w, height: h)
    }

    private var addButton: some View {
        ZStack {
            Text("Add Widget").font(.system(size: 10, weight: .bold)).foregroundColor(ink)
                .padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(P.teal.color))
            hand.offset(x: 26, y: 16)
        }
    }

    private var lockWallpaper: some View {
        LinearGradient(colors: [P.violet.opacity(0.30).color, P.sky.opacity(0.16).color, P.background.color], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func clock() -> some View {
        VStack(spacing: 0) {
            Text("Tue 27").font(.system(size: 7.5, weight: .semibold)).foregroundColor(Color.white.opacity(0.8))
            Text("9:41").font(.system(size: 22, weight: .bold)).foregroundColor(.white)
        }
    }

    private var holdOnLock: some View {
        ZStack {
            lockWallpaper
            VStack { clock().padding(.top, 8); Spacer() }
            hand.offset(x: 8, y: 22)
        }
    }

    private var customize: some View {
        ZStack {
            lockWallpaper
            VStack { clock().padding(.top, 8); Spacer() }
            VStack { Spacer()
                Text("Customize").font(.system(size: 8.5, weight: .bold)).foregroundColor(ink)
                    .padding(.horizontal, 9).padding(.vertical, 4).background(Capsule().fill(P.teal.color)).padding(.bottom, 8)
            }
        }
    }

    private var widgetRow: some View {
        ZStack {
            lockWallpaper
            VStack(spacing: 5) {
                clock().padding(.top, 6)
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(P.teal.color, style: StrokeStyle(lineWidth: 1.1, dash: [3, 2]))
                            .frame(width: 20, height: 20)
                    }
                }
                Spacer()
            }
        }
    }

    private var choosePage: some View {
        ZStack {
            P.surface.color
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "bell.badge").font(.system(size: 8, weight: .semibold))
                    Text("Page").font(.system(size: 9, weight: .bold))
                    Spacer()
                }
                .foregroundColor(P.textPrimary.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Page · Online").font(.system(size: 6.5, weight: .semibold)).foregroundColor(P.textSecondary.color)
                    Text("2 need you").font(.system(size: 10.5, weight: .bold)).foregroundColor(P.textPrimary.color)
                }
                .padding(.horizontal, 7).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(P.teal.opacity(0.22).color))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(P.teal.color, lineWidth: 1))
            }
            .padding(.horizontal, 10)
        }
    }
}
