import SwiftUI

// First run: Welcome, Scan, the pairing steps and Paired. Plain views over
// values; PairMacView (the live flow, with the camera, the Keychain and the
// relay probe) fills them in, the render harness draws them from fixtures.

// MARK: - Welcome

/// A far ridge and a nearer one against the aurora, like the board's lake
/// at night, drawn with paths so there is no bitmap to ship.
struct NWRidges: View {
    var body: some View {
        Canvas { ctx, size in
            func ridge(_ base: Double, _ amp: Double, _ seed: Double, _ alpha: Double) {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height))
                var x: CGFloat = 0
                while x <= size.width + 4 {
                    let u = Double(x / size.width)
                    let y = size.height * (base - amp * (0.55 * sin(u * 6.0 + seed) + 0.30 * sin(u * 13.0 + seed * 2) + 0.15 * sin(u * 29.0 + seed * 3)))
                    p.addLine(to: CGPoint(x: x, y: y))
                    x += 4
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                ctx.fill(p, with: .linearGradient(Gradient(colors: [Color(red: 0.05, green: 0.12, blue: 0.16).opacity(alpha), NightWatch.Palette.backgroundDeep.color]),
                                                  startPoint: CGPoint(x: 0, y: size.height * (base - amp)), endPoint: CGPoint(x: 0, y: size.height)))
            }
            ridge(0.62, 0.10, 1.2, 0.85)
            ridge(0.80, 0.07, 4.1, 1.0)
        }
        .allowsHitTesting(false)
    }
}

/// The pulse with rings that open out, centred on the water.
struct NWWelcomePulse: View {
    var body: some View {
        NWAnimated { t in
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let p = ((t / 5) + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Circle().stroke(NightWatch.Palette.teal.opacity(0.34 * (1 - p)).color, lineWidth: 1.4)
                        .frame(width: 70 + 220 * p, height: 70 + 220 * p)
                }
                Circle().fill(RadialGradient(colors: [NightWatch.Palette.teal.opacity(0.45).color, .clear],
                                             center: .center, startRadius: 1, endRadius: 80)).frame(width: 160, height: 160)
                NWPulseGlyph()
                    .fill(RadialGradient(colors: [Color.white, NightWatch.Palette.teal.opacity(0.9).color], center: .center, startRadius: 0, endRadius: 24))
                    .overlay(NWPulseGlyph().stroke(NightWatch.Palette.teal.color, lineWidth: 2))
                    .frame(width: 44, height: 44)
                    .shadow(color: NightWatch.Palette.teal.opacity(0.7).color, radius: 14)
            }
        }
        .frame(width: 300, height: 300)
        .accessibilityHidden(true)
    }
}

struct NWWelcomeScreen: View {
    /// A notice that comes first ("Pair again": the old token was retired).
    var notice: (title: String, message: String)? = nil
    var onPair: () -> Void = {}
    var onDismissNotice: () -> Void = {}
    /// Debug builds only: skip pairing with mock data.
    var onSkipDev: (() -> Void)? = nil
    @Environment(\.nwTopInset) private var topInset

    var body: some View {
        ZStack(alignment: .bottom) {
            NWBackdrop()
            // The curtains fade out before the words begin, so the headline always sits on dark sky.
            NWAnimated { t in NWAuroraCanvas(palette: Self.palette, seconds: t) }
                .mask(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.38), .init(color: .clear, location: 0.62)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(maxHeight: .infinity).ignoresSafeArea()
            NWRidges().frame(maxHeight: .infinity).ignoresSafeArea().opacity(0.95)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                NWWelcomePulse().offset(y: -30)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 16) {
                    Text(OnboardingCopy.eyebrow).font(.system(.subheadline, weight: .bold)).kerning(4)
                        .foregroundColor(NightWatch.Palette.teal.color)
                    Text(OnboardingCopy.welcomeTitle)
                        .font(.system(size: 44, weight: .bold)).kerning(-1.4).lineSpacing(-4)
                        .foregroundColor(NightWatch.Palette.textPrimary.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .minimumScaleFactor(0.7)
                        .accessibilityAddTraits(.isHeader)
                    Text(OnboardingCopy.welcomeBody)
                        .font(.system(.body)).foregroundColor(NightWatch.Palette.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                    if let notice { noticeCard(notice) }
                    Button(action: onPair) {
                        HStack(spacing: 12) { Image(systemName: "qrcode.viewfinder"); Text(OnboardingCopy.pairButton) }
                    }
                    .buttonStyle(NWButtonStyle(kind: .bright))
                    .frame(minHeight: 60).padding(.top, 8)
                    if let onSkipDev {
                        Button("Skip pairing (DEV)", action: onSkipDev)
                            .font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textQuiet.color)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 28)
            }
        }
    }

    /// Teal curtains over a deep night sky, as the welcome board has them.
    static let palette = NightWatch.AuroraPalette(
        c1: NightWatch.RGBA(hex: 0x3FBFB6), c2: NightWatch.RGBA(hex: 0x38BDF8), c3: NightWatch.RGBA(hex: 0x4B7BD0),
        skyTop: NightWatch.RGBA(hex: 0x0B2A33), skyBottom: NightWatch.Palette.backgroundDeep, intensity: 0.85, speed: 0.5)

    private func noticeCard(_ n: (title: String, message: String)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(n.title, systemImage: "key.slash").font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.amber.color)
            Text(n.message).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            Button("Dismiss", action: onDismissNotice).font(NightWatch.Typo.captionStrong)
                .foregroundColor(NightWatch.Palette.textPrimary.color).frame(minHeight: 36)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(NWGlassBackground(radius: 18, tint: NightWatch.Palette.amber))
    }
}

// MARK: - Scan

/// Four corner brackets round a square.
struct NWScanCorners: Shape {
    var length: CGFloat = 34
    var radius: CGFloat = 12

    func path(in r: CGRect) -> Path {
        var p = Path()
        let l = length, c = radius
        func corner(_ x: CGFloat, _ y: CGFloat, _ dx: CGFloat, _ dy: CGFloat) {
            p.move(to: CGPoint(x: x + dx * l, y: y))
            p.addLine(to: CGPoint(x: x + dx * c, y: y))
            p.addQuadCurve(to: CGPoint(x: x, y: y + dy * c), control: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: x, y: y + dy * l))
        }
        corner(r.minX, r.minY, 1, 1)
        corner(r.maxX, r.minY, -1, 1)
        corner(r.minX, r.maxY, 1, -1)
        corner(r.maxX, r.maxY, -1, -1)
        return p
    }
}

/// The scanner: a viewfinder window (the camera sits in it on a device), the
/// four teal corners and a scan line, then what the code holds.
struct NWScanScreen<Camera: View>: View {
    var hint: String? = nil
    var onPaste: () -> Void = {}
    var onCancel: () -> Void = {}
    @ViewBuilder var camera: () -> Camera

    var body: some View {
        ZStack {
            NWBackdrop()
            RadialGradient(colors: [NightWatch.Palette.teal.opacity(0.06).color, .clear], center: .center, startRadius: 10, endRadius: 360)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.textSecondary.color)
                        .padding(.horizontal, 16).frame(minHeight: 44)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .padding(.horizontal, 20).padding(.top, 14)
                Text(OnboardingCopy.scanTitle).font(.system(size: 30, weight: .bold)).kerning(-0.8)
                    .foregroundColor(NightWatch.Palette.textPrimary.color).multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7).padding(.top, 34).padding(.horizontal, 24)
                    .accessibilityAddTraits(.isHeader)
                Text(OnboardingCopy.scanHint).font(NightWatch.Typo.subline).foregroundColor(NightWatch.Palette.textTertiary.color).padding(.top, 6)
                Spacer(minLength: 12)
                viewfinder
                if let hint {
                    Text(hint).font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.amber.color)
                        .multilineTextAlignment(.center).padding(.horizontal, 28).padding(.top, 16)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                Spacer(minLength: 12)
                facts.padding(.horizontal, 24)
                Button(action: onPaste) {
                    HStack(spacing: 10) { Image(systemName: "doc.on.clipboard"); Text(OnboardingCopy.pasteInstead) }
                }
                .buttonStyle(NWButtonStyle(kind: .quiet))
                .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 24)
            }
        }
    }

    private var viewfinder: some View {
        let side: CGFloat = 270
        return ZStack {
            camera()
                .frame(width: side - 36, height: side - 36)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            NWScanCorners().stroke(NightWatch.Palette.teal.color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                .frame(width: side, height: side)
            NWAnimated { t in
                let p = 0.5 + 0.5 * sin(t * 1.6)
                Capsule().fill(LinearGradient(colors: [.clear, NightWatch.Palette.teal.color, .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: side - 40, height: 3)
                    .shadow(color: NightWatch.Palette.teal.opacity(0.8).color, radius: 6)
                    .offset(y: CGFloat(p - 0.5) * (side - 60))
            }
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Camera view. Point it at the QR code in Page on your Mac."))
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(OnboardingCopy.scanFacts.enumerated()), id: \.offset) { _, f in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: f.symbol).foregroundColor(NightWatch.Palette.teal.color).frame(width: 22)
                    Text(f.text).font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(NWGlassBackground(radius: 24, fill: NightWatch.Palette.surface.opacity(0.9)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Pairing steps

/// What the pairing flow shows between the scan and Paired: checking the
/// relay, confirming the Mac, or a problem with its one fix.
struct NWPairStep: View {
    enum Content {
        case checking(host: String)
        case confirm(mac: String, host: String, online: Bool?, unused: Bool)
        case problem(title: String, message: String)
    }
    var content: Content
    var onPrimary: (() -> Void)? = nil
    var primaryTitle: String = ""
    var onSecondary: () -> Void = {}
    var secondaryTitle: String = "Start over"

    var body: some View {
        ZStack {
            NWBackdrop()
            ScrollView {
                VStack(spacing: 22) {
                    NWPulseOrb(style: orb).frame(width: 150, height: 150).padding(.top, 34)
                    switch content {
                    case .checking(let host):
                        VStack(spacing: 10) {
                            ProgressView().tint(NightWatch.Palette.textSecondary.color)
                            Text("Checking \(host)…").font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textSecondary.color)
                        }
                    case .confirm(let mac, let host, let online, let unused):
                        confirm(mac: mac, host: host, online: online, unused: unused)
                    case .problem(let title, let message):
                        VStack(alignment: .leading, spacing: 10) {
                            Label(title, systemImage: "exclamationmark.triangle").font(NightWatch.Typo.title)
                                .foregroundColor(NightWatch.Palette.amber.color)
                            Text(message).font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textSecondary.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(NWGlassBackground(radius: 22, tint: NightWatch.Palette.amber))
                    }
                    if let onPrimary {
                        Button(primaryTitle, action: onPrimary).buttonStyle(NWButtonStyle(kind: .bright))
                    }
                    Button(secondaryTitle, action: onSecondary).buttonStyle(NWButtonStyle(kind: .quiet))
                }
                .padding(.horizontal, 24).padding(.bottom, 30)
            }
        }
    }

    private var orb: NWPulseOrb.Style {
        switch content {
        case .checking: return .working
        case .confirm: return .quiet
        case .problem: return .needsYou
        }
    }

    private func confirm(mac: String, host: String, online: Bool?, unused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair with \(mac)?").font(.system(size: 28, weight: .bold)).kerning(-0.6)
                .foregroundColor(NightWatch.Palette.textPrimary.color)
            Text("Relay: \(host)").font(NightWatch.Typo.monoSmall).foregroundColor(NightWatch.Palette.textTertiary.color)
                .lineLimit(1).truncationMode(.middle)
            switch online {
            case true?: line("checkmark.circle", "Your Mac is connected to this relay.", NightWatch.Palette.teal)
            case false? where unused:
                line("exclamationmark.triangle", "No Mac has connected to this relay with this code yet. If it's an old screenshot, or you regenerated the token on your Mac, show the pairing code on your Mac again and scan the new one.", NightWatch.Palette.amber)
            case false?:
                line("exclamationmark.circle", "Your Mac isn't connected to this relay right now. That's fine — pages will arrive once it is.", NightWatch.Palette.amber)
            case nil: EmptyView()
            }
            Text(OnboardingCopy.confirmWarning).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(NWGlassBackground(radius: 26, fill: NightWatch.Palette.surface.opacity(0.92)))
    }

    private func line(_ symbol: String, _ text: String, _ c: NightWatch.RGBA) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundColor(c.color)
            Text(text).font(NightWatch.Typo.caption).foregroundColor(c.color).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Paired

/// Paired: the first star, what Page will and won't page you for, and the one
/// place notifications are asked for.
struct NWPairedScreen: View {
    var model: PairedWelcome
    var onAction: () -> Void = {}
    var onSkip: () -> Void = {}

    var body: some View {
        ZStack(alignment: .bottom) {
            NWBackdrop()
            NWAnimated { t in NWAuroraCanvas(palette: Self.palette, seconds: t) }
                .mask(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.30), .init(color: .clear, location: 0.58)],
                                     startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                check.padding(.bottom, 44)
                Text(model.title).font(.system(size: 36, weight: .bold)).kerning(-1.2)
                    .foregroundColor(NightWatch.Palette.textPrimary.color).multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7).lineLimit(2).padding(.horizontal, 24)
                    .accessibilityAddTraits(.isHeader)
                Text(model.subtitle).font(.system(.body)).foregroundColor(NightWatch.Palette.textSecondary.color)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 36).padding(.top, 12)
                Spacer(minLength: 0)
                promises.padding(.horizontal, 24)
                Button(action: onAction) { Text(model.action.title) }
                    .buttonStyle(NWButtonStyle(kind: .amber)).frame(minHeight: 60)
                    .padding(.horizontal, 24).padding(.top, 16)
                if let skip = model.skipTitle {
                    Button(skip, action: onSkip).font(NightWatch.Typo.bodyStrong)
                        .foregroundColor(NightWatch.Palette.textTertiary.color).frame(minHeight: 48)
                }
                Color.clear.frame(height: 14)
            }
        }
    }

    /// Bright cyan curtains, once, to say it worked.
    static let palette = NightWatch.AuroraPalette(
        c1: NightWatch.RGBA(hex: 0x4FF3E6), c2: NightWatch.RGBA(hex: 0x38BDF8), c3: NightWatch.RGBA(hex: 0x6D8BF0),
        skyTop: NightWatch.RGBA(hex: 0x0C3A44), skyBottom: NightWatch.Palette.backgroundDeep, intensity: 1.3, speed: 0.6)

    private var check: some View {
        NWAnimated { t in
            ZStack {
                ForEach(0..<2, id: \.self) { i in
                    let p = ((t / 4) + Double(i) / 2).truncatingRemainder(dividingBy: 1)
                    Circle().stroke(NightWatch.Palette.teal.opacity(0.4 * (1 - p)).color, lineWidth: 1.5)
                        .frame(width: 120 + 120 * p, height: 120 + 120 * p)
                }
                Circle().fill(RadialGradient(colors: [NightWatch.Palette.sky.color, NightWatch.Palette.teal.color], center: .topLeading, startRadius: 4, endRadius: 90))
                    .frame(width: 120, height: 120)
                    .shadow(color: NightWatch.Palette.teal.opacity(0.5).color, radius: 24)
                Image(systemName: "checkmark").font(.system(size: 44, weight: .semibold)).foregroundColor(NightWatch.Palette.onBright.color)
            }
        }
        .frame(width: 240, height: 240).accessibilityHidden(true)
    }

    private var promises: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "bell").foregroundColor(NightWatch.Palette.yellow.color)
                Text(model.promiseTitle).font(NightWatch.Typo.title).foregroundColor(NightWatch.Palette.textPrimary.color)
            }
            ForEach(model.promises, id: \.self) { p in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark").font(.system(.subheadline, weight: .semibold)).foregroundColor(NightWatch.Palette.green.color)
                    Text(p).font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(NWGlassBackground(radius: 26, fill: NightWatch.Palette.surface.opacity(0.9)))
        .accessibilityElement(children: .combine)
    }
}
