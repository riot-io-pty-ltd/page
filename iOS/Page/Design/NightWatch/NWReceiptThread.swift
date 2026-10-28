import SwiftUI

/// THE RECEIPT THREAD on a card or sheet (`ReceiptThread` for the truth and
/// the timing): the card's dot, the relay and the Mac, joined by a thin
/// thread of light. ARM winds a ring round the dot (tap cancels); SEND
/// draws the thread to the relay, and a glint travels on while the Mac is
/// awaited; only the Mac's confirmation runs it on to the Mac ("typed",
/// then "verified ✓"), turns the dot teal and contracts its rings into it.
/// A failure snaps the thread back, shakes once softly and says what
/// happened. It runs a clock only while something on it moves.
struct NWReceiptThreadView: View {
    var input: ReceiptThreadInput
    /// Arm: cancels. A failure: opens the decision to see and retry.
    var onTap: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NWLiveClock(until: input.movingUntil(now: Date())) { now in
            strip(reduceMotion ? Self.still(input.frame(now: now)) : input.frame(now: now), now: now)
        }
    }

    /// Reduce Motion: each stage drawn where it ends, with nothing travelling
    /// (the arm ring still counts down: it is the cancel window).
    static func still(_ f: ReceiptThread) -> ReceiptThread {
        var s = f
        switch f.stage {
        case .sending: s.reach = 0.42
        case .sent, .queued, .held: s.reach = 0.5
        case .typed, .verified:
            s.reach = 1; s.macLit = true; s.dotTeal = 1; s.rings = 0
        case .failed, .retracted: s.reach = 0
        case .idle, .arming: break
        }
        s.glint = nil
        s.shake = 0
        return s
    }

    // MARK: colours (board 07: white arm, sky sent and typed, green verified)

    private func tone(_ f: ReceiptThread) -> NightWatch.RGBA {
        switch f.stage {
        case .idle, .arming: return NightWatch.RGBA(1, 1, 1, 0.92)
        case .sending, .sent, .typed: return NightWatch.Palette.sky
        case .queued, .held: return NightWatch.Palette.amber
        case .retracted: return NightWatch.Palette.textSecondary
        case .verified: return NightWatch.Palette.green
        case .failed: return NightWatch.Palette.amber
        }
    }

    private func strip(_ f: ReceiptThread, now: Date) -> some View {
        let tone = tone(f)
        let arming = f.stage == .arming
        // Only the arm (cancel) and a failure (see and retry) answer a tap; once sent there is nothing to undo.
        return Button { if arming || f.isFailure { onTap() } } label: {
            VStack(spacing: 8) {
                thread(f, tone: tone)
                    .frame(height: 30)
                Text(words(f, now: now))
                    .font(arming ? NightWatch.Typo.bodyStrong : NightWatch.Typo.captionStrong)
                    .foregroundColor((arming ? NightWatch.Palette.textPrimary : tone).color)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .contentTransition(.opacity)
                if arming, let preview = input.pending?.preview {
                    Text(preview).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textTertiary.color)
                        .lineLimit(2).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: NightWatch.Radius.button, style: .continuous)
                .fill(tone.opacity(arming ? 0.06 : 0.07).color))
            .overlay(RoundedRectangle(cornerRadius: NightWatch.Radius.button, style: .continuous)
                .strokeBorder(tone.opacity(arming ? 0.22 : 0.16).color, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: CGFloat(f.shake * 7))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibility(f, now: now)))
        .accessibilityHint(Text(arming ? "Tap to cancel" : (f.isFailure ? "Opens the decision to try again" : "")))
    }

    private func words(_ f: ReceiptThread, now: Date) -> String {
        if f.stage == .arming, let p = input.pending { return p.armLabel(now: now) }
        return f.word
    }

    private func accessibility(_ f: ReceiptThread, now: Date) -> String {
        switch f.stage {
        case .arming: return "Sending, tap to cancel"
        case .sending: return "Sending"
        case .sent: return "Sent, waiting for your Mac to confirm"
        case .queued: return "Queued until your Mac is back online"
        case .held: return "Held on your Mac until the rate limit resets"
        case .retracted(let why): return why
        case .typed, .verified: return "Delivered and verified on your Mac"
        case .failed(let why): return why
        case .idle: return ""
        }
    }

    // MARK: the thread

    private func thread(_ f: ReceiptThread, tone: NightWatch.RGBA) -> some View {
        GeometryReader { geo in
            let w = geo.size.width, mid = geo.size.height / 2
            let node: CGFloat = 30
            let x0 = node / 2, x2 = w - node / 2
            let xr = x0 + (x2 - x0) * CGFloat(MotionCurve.clamp01(f.reach))
            ZStack(alignment: .topLeading) {
                // The track: where the thread will go.
                Path { p in p.move(to: CGPoint(x: x0, y: mid)); p.addLine(to: CGPoint(x: x2, y: mid)) }
                    .stroke(Color.white.opacity(0.08), lineWidth: 1.5)
                // The thread of light, as far as it has really gone.
                if f.reach > 0.001 {
                    Path { p in p.move(to: CGPoint(x: x0, y: mid)); p.addLine(to: CGPoint(x: xr, y: mid)) }
                        .stroke(tone.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .shadow(color: tone.opacity(0.7).color, radius: 4)
                }
                // A glint travelling on towards the Mac: listening, not arriving.
                if let g = f.glint {
                    let xg = x0 + (x2 - x0) * CGFloat(g)
                    Capsule()
                        .fill(LinearGradient(colors: [tone.opacity(0).color, tone.opacity(0.75 * (1 - (g - 0.5) * 1.6)).color, tone.opacity(0).color],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: 34, height: 2)
                        .position(x: xg, y: mid)
                }
                dot(f, tone: tone).frame(width: node, height: node).position(x: x0, y: mid)
                station("cloud", lit: f.relayLit, tone: tone).frame(width: node, height: node).position(x: (x0 + x2) / 2, y: mid)
                station("desktopcomputer", lit: f.macLit, tone: tone).frame(width: node, height: node).position(x: x2, y: mid)
            }
        }
    }

    /// The card's dot: amber, with two faint rings round it; the arm ring
    /// winds round it; on the Mac's confirmation it turns teal and its rings
    /// contract into it.
    private func dot(_ f: ReceiptThread, tone: NightWatch.RGBA) -> some View {
        let c = NightWatch.Palette.amber.mixed(with: NightWatch.Palette.teal, f.dotTeal)
        let open = 0.35 + 0.65 * f.rings
        return ZStack {
            Circle().fill(NightWatch.Palette.surfaceRaised.color)
            Circle().strokeBorder((f.reach > 0 || f.stage == .verified ? tone : NightWatch.RGBA(1, 1, 1)).opacity(f.reach > 0 ? 0.55 : 0.12).color, lineWidth: 1)
            ForEach(0..<2, id: \.self) { i in
                Circle().stroke(c.opacity(0.35 * f.rings + (f.rings < 1 ? 0.25 * (1 - f.rings) * (1 - f.dotTeal) : 0)).color, lineWidth: 1)
                    .frame(width: CGFloat(12 + 6 * i) * CGFloat(open), height: CGFloat(12 + 6 * i) * CGFloat(open))
            }
            Circle().fill(c.color).frame(width: 8, height: 8)
                .shadow(color: c.opacity(0.8).color, radius: f.dotTeal > 0 ? 5 : 2)
            if f.stage == .arming {
                Circle().trim(from: 0, to: CGFloat(f.arm))
                    .stroke(Color.white.opacity(0.92), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 26, height: 26)
            }
        }
    }

    private func station(_ symbol: String, lit: Bool, tone: NightWatch.RGBA) -> some View {
        ZStack {
            Circle().fill((lit ? tone.opacity(0.16) : NightWatch.Palette.surfaceRaised).color)
            Circle().strokeBorder((lit ? tone.opacity(0.6) : NightWatch.RGBA(1, 1, 1, 0.12)).color, lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor((lit ? tone : NightWatch.Palette.textQuiet).color)
        }
    }
}

/// A card that has left the stream with its reply confirmed: after the
/// thread resolves it folds into a hairline and drifts down into Settled
/// (`ReceiptThread.resolved`). Pinned by the harness through `\.nwFixedNow`.
struct NWResolveFold: ViewModifier {
    var changedAt: Date?
    @Environment(\.nwFixedNow) private var fixedNow

    func body(content: Content) -> some View {
        if let at = changedAt {
            if let fixedNow {
                fold(content, ReceiptThread.resolved(since: max(0, fixedNow.timeIntervalSince(at))))
            } else {
                NWOneShot(start: at.timeIntervalSinceReferenceDate, duration: ReceiptThread.resolveDuration) { e in
                    fold(content, ReceiptThread.resolved(since: e ?? ReceiptThread.resolveDuration))
                }
            }
        } else {
            content
        }
    }

    private func fold(_ content: Content, _ f: ReceiptThread) -> some View {
        content
            .opacity(1 - f.fold)
            .scaleEffect(x: 1, y: max(0.004, 1 - f.fold), anchor: .center)
            .overlay(
                // The hairline the card becomes, teal like the receipt it now is.
                Capsule().fill(NightWatch.Palette.teal.opacity(0.8 * f.fold * (1 - f.drift)).color)
                    .frame(height: 1)
                    .padding(.horizontal, CGFloat(24 * f.drift))
                    .offset(y: CGFloat(28 * f.drift)))
            .allowsHitTesting(false)
            .accessibilityHidden(f.fold > 0)
    }
}
