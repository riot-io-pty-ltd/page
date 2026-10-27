import SwiftUI

/// The named space the Now stream measures in (the scroll view's content).
let nwStreamSpace = "nwStream"

/// FINAL APPROACH for one card (`ApproachModel` for the timing): a card that
/// has just arrived comes down from the pulse into its slot on
/// spring(0.5, 0.8), trailing a faint contrail back up to the pulse; by
/// 520 ms it has settled and the glow is off. In flight it is an empty
/// outline in its class colour that grows out of the pulse, and it passes
/// behind the Horizon's words (`clear`), so no text is ever drawn over
/// text; its own content fades in only as it lands. Whether it is arriving
/// is decided once, when the card first appears (so a re-render can never
/// replay it), and nothing happens on the first look at the stream. The
/// cards below make room on the same spring (the stream animates its
/// layout); nothing above moves.
struct NWArrival<Content: View>: View {
    /// The pulse's centre in `nwStreamSpace`.
    var pulseY: CGFloat
    var tint: NightWatch.RGBA
    var radius: CGFloat
    /// The Horizon's headline and subline, in `nwStreamSpace`: the flying
    /// outline and its contrail pass behind them.
    var clear: ClosedRange<CGFloat>? = nil
    /// The render harness: draw this many seconds into the approach.
    var pinned: Double? = nil
    @ViewBuilder var content: () -> Content

    @State private var startedAt: Double?
    @State private var top: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nwCardGlow) private var cardGlow

    init(arriving: Bool, delay: Double = 0, pulseY: CGFloat, tint: NightWatch.RGBA, radius: CGFloat,
         clear: ClosedRange<CGFloat>? = nil, pinned: Double? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.pulseY = pulseY
        self.tint = tint
        self.radius = radius
        self.clear = clear
        self.pinned = pinned
        self.content = content
        _startedAt = State(initialValue: arriving ? Date().timeIntervalSinceReferenceDate + delay : nil)
    }

    var body: some View {
        if (startedAt == nil && pinned == nil) || reduceMotion {
            content()
        } else {
            NWOneShot(start: startedAt, duration: ApproachModel.duration + 0.4, pinned: pinned) { e in
                if let e { approaching(elapsed: e) } else { content() }
            }
        }
    }

    private func approaching(elapsed e: Double) -> some View {
        // Staggered arrivals wait out of sight until their turn.
        let waiting = e < 0
        let f = ApproachModel.frame(elapsed: max(0, e))
        let distance = max(0, (top ?? 0) - pulseY)
        let measured = top != nil
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content()
            .background(GeometryReader { g in
                Color.clear.onAppear { top = g.frame(in: .named(nwStreamSpace)).minY }
            })
            // Its words only as it lands: in flight it is the outline alone.
            .opacity(f.content)
            .overlay(
                shape.fill(tint.opacity(0.07 * f.glow).color)
                    .overlay(shape.strokeBorder(tint.opacity(0.85 * max(f.glow, f.edge)).color, lineWidth: 1.2))
                    // The soft light round it is a glow, so it follows the Card glow setting (Off: none).
                    .shadow(color: tint.opacity(0.55 * f.glow * cardGlow.strength).color, radius: 14)
                    .allowsHitTesting(false))
            .overlay(alignment: .top) {
                // The contrail: back up to the pulse, brightest at the card.
                let length = distance * CGFloat(min(1, f.travel))
                LinearGradient(colors: [tint.opacity(0).color, tint.opacity(0.9).color], startPoint: .top, endPoint: .bottom)
                    .frame(width: 1.5, height: max(0, length))
                    .offset(y: -length)
                    .opacity(f.contrail)
                    .allowsHitTesting(false)
            }
            .scaleEffect(f.scale, anchor: .top)
            .offset(y: -distance * CGFloat(1 - f.travel))
            .mask(alignment: .top) { behindTheWords(distance: distance) }
            .opacity(waiting || !measured ? 0 : f.opacity)
            .zIndex(1)
    }

    /// Everything but the Horizon's words: the band they sit in is cut out, so
    /// the outline and its contrail pass behind the headline, not across it.
    /// Fixed in the stream (the mask does not move with the card).
    @ViewBuilder private func behindTheWords(distance: CGFloat) -> some View {
        if let clear, let top {
            // From well above the pulse to well below the card: room for the contrail and the glow.
            let reach = distance + 60
            let lo = max(0, clear.lowerBound - (top - reach)), hi = max(0, clear.upperBound - (top - reach))
            VStack(spacing: 0) {
                Rectangle().frame(height: lo)
                Color.clear.frame(height: hi - lo)
                Rectangle().frame(height: reach + 2_000)
            }
            .padding(.horizontal, -40)
            .offset(y: -reach)
        } else {
            Rectangle().padding(-2_000)
        }
    }
}
