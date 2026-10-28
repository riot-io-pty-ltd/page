import SwiftUI

/// The floating glass nav capsule: Now, the pulse, Lanes. Each side carries a
/// badge (the Decide count in amber, the working count in teal). Two places
/// and one verb: a tap on a side switches, a horizontal drag on the capsule
/// switches (Lanes lies to the right of Now), a tap on the pulse opens
/// Dispatch, and holding the pulse is the Stop ring (see `NWStopOverlay`).
struct NWNavCapsule: View {
    enum Destination: Hashable { case now, lanes }
    @Binding var selection: Destination
    var decideCount: Int
    var workingCount: Int
    /// What the pulse here counts, one ring each: the same count as every
    /// other pulse (`NowModel.pulseWaiting`: decisions, else looks). The
    /// Decide count when nil.
    var pulseWaiting: Int? = nil
    /// The oldest wait among those, which sets the ripple's pace.
    var pulseLongestWait: TimeInterval = 0
    /// Seconds the pulse has been held, nil when it is not pressed.
    var held: Binding<TimeInterval?>? = nil
    var onPulseTap: () -> Void = {}
    var onPulseHold: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nwReduceMotion) private var forcedReduceMotion
    @Environment(\.nwChromeGlassOn) private var glass
    @Environment(\.nwMotion) private var pin
    @Environment(\.nwNowScript) private var script
    /// When each badge's count last went from one number to another (`NowMotion.BadgeScene`).
    @State private var badges = NowMotion.BadgeScene()

    private var calm: Bool { reduceMotion || forcedReduceMotion }

    /// The badges' scene and the moment: the harness's script replayed to its pinned moment, else the live one.
    private var badgeMotion: (scene: NowMotion.BadgeScene, pinned: Double?) {
        if let p = pin.flatMap({ $0.kind == .now ? $0.time : nil }), let script, let r = NowMotion.replay(script, until: p) {
            return (r.scene.badges, script.base + p)
        }
        return (badges, nil)
    }

    var body: some View {
        // One container: the pulse's glass sits in the capsule's, refracting the same sky.
        NWChromeGlassGroup {
            HStack(spacing: 0) {
                side(.now, "Now", decideCount, NightWatch.Palette.amber, badge: 0)
                pulse
                side(.lanes, "Lanes", workingCount, NightWatch.Palette.teal, badge: 1)
            }
            .padding(.horizontal, 8)
            .frame(height: 68)
            // Not interactive: the pulse in the middle is a hold, and its ring is the feedback.
            .nwChromeGlass(in: RoundedRectangle(cornerRadius: NightWatch.Radius.capsule, style: .continuous), interactive: false) {
                NWGlassBackground(radius: NightWatch.Radius.capsule, fill: NightWatch.Palette.surface.opacity(0.94))
            }
        }
        .onAppear { badges.observe([decideCount, workingCount], at: Date().timeIntervalSinceReferenceDate) }
        .onChange(of: [decideCount, workingCount]) { _, counts in badges.observe(counts, at: Date().timeIntervalSinceReferenceDate) }
    }

    /// A horizontal drag on either side of the capsule switches place. The
    /// pulse in the middle keeps its own gestures, so a slow tap never switches.
    private var switchDrag: some Gesture {
        DragGesture(minimumDistance: 24).onEnded { v in
            let to = NWDestination.afterDrag(from: selection == .now ? .now : .lanes, translation: Double(v.translation.width), vertical: Double(v.translation.height))
            let next: Destination = to == .now ? .now : .lanes
            if next != selection { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { selection = next } }
        }
    }

    private var pulse: some View {
        NWHoldSurface(spec: .stopAll, held: held, onComplete: onPulseHold, onTap: onPulseTap) { p in
            ZStack {
                // The pulse, here too: an amber ring per waiting item, or the teal breath.
                if p == 0 { NWCapsulePulse(model: PulseModel(working: workingCount, waiting: pulseWaiting ?? decideCount,
                                                          longestWait: pulseLongestWait)) }
                // The ring around the button fills as the hold goes on.
                Circle().stroke(Color.white.opacity(p > 0 ? 0.12 : 0), lineWidth: 4).frame(width: 64, height: 64)
                Circle().trim(from: 0, to: CGFloat(p))
                    .stroke(NightWatch.Palette.amber.mixed(with: NightWatch.Palette.red, HoldRingSpec.warmth(progress: p)).color,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 64, height: 64)
                Image(systemName: "plus").font(.system(size: 24, weight: .regular))
                    .foregroundColor(NightWatch.Palette.onBright.color)
                    .frame(width: 56, height: 56)
                    // Teal glass, running to sky at the lower edge as the fill does.
                    .background {
                        if glass {
                            Circle().fill(RadialGradient(colors: [NightWatch.Palette.sky.opacity(0).color, NightWatch.Palette.sky.opacity(0.75).color],
                                                         center: .topLeading, startRadius: 2, endRadius: 56))
                        }
                    }
                    .nwChromeGlass(in: Circle(), tint: NightWatch.Palette.teal, interactive: false) {
                        Circle().fill(RadialGradient(
                            colors: [NightWatch.Palette.teal.color, NightWatch.Palette.sky.color],
                            center: .topLeading, startRadius: 2, endRadius: 56))
                    }
                    .scaleEffect(1 - 0.06 * p)
            }
            .frame(width: 72, height: 68)
        }
        .frame(width: 72, height: 68)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Start new work"))
        .accessibilityHint(Text("Hold for 10 seconds to stop everything"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onPulseTap() }
        .accessibilityAction(named: Text("Stop all agents")) { onPulseHold() }
    }

    /// A side and its badge. A new count rolls in as the badge bumps (1 → 1.22 → 1, `NowMotion.badgeBump`);
    /// a badge appearing scales in from 0.5 on a (0.35, 0.6) spring, and going scales back to 0.5 as it fades.
    private func side(_ d: Destination, _ title: String, _ count: Int, _ badge: NightWatch.RGBA, badge i: Int) -> some View {
        let on = selection == d
        let m = badgeMotion
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { selection = d }
        } label: {
            HStack(spacing: 8) {
                Text(title).font(.system(.body, weight: on ? .bold : .medium))
                    .foregroundColor((on ? NightWatch.Palette.textPrimary : NightWatch.Palette.textTertiary).color)
                if count > 0 {
                    NWWorkflowClock(origin: 0, until: m.scene.settlesAt(i, reduceMotion: calm), pinned: m.pinned) { t in
                        Text("\(count)").font(.system(.caption, weight: .bold))
                            .foregroundColor(badge.color)
                            .contentTransition(calm ? .opacity : .numericText(value: Double(count)))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(badge.opacity(0.18).color))
                            .scaleEffect(CGFloat(m.scene.scale(i, at: t, reduceMotion: calm)))
                    }
                    .transition(calm ? .opacity : .scale(scale: NowMotion.badgeFrom).combined(with: .opacity))
                }
            }
            .animation(calm ? .easeOut(duration: WorkflowMotion.reducedFade)
                       : .spring(response: NowMotion.badgeResponse, dampingFraction: NowMotion.badgeDamping), value: count)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Capsule().fill(on ? Color.white.opacity(0.08) : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(switchDrag)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(Text(count > 0 ? "\(title), \(count)" : title))
    }
}

/// The pulse on the capsule's button: an amber ripple opening from the
/// button, one ring per waiting item, or a teal ring breathing while agents
/// work; nothing when quiet. A slow 20 fps; Reduce Motion holds a still ring.
struct NWCapsulePulse: View {
    var model: PulseModel

    var body: some View {
        NWAnimated(fps: 20, active: model.isAnimated) { t in
            ZStack {
                ForEach(Array(model.ripples(at: t).enumerated()), id: \.offset) { _, r in
                    Circle().stroke(NightWatch.Palette.amber.opacity(0.7 * r.opacity).color, lineWidth: 1.5)
                        .frame(width: 58 + 30 * CGFloat(r.progress), height: 58 + 30 * CGFloat(r.progress))
                }
                if model.mode == .working {
                    let b = model.breath(at: t)
                    Circle().stroke(NightWatch.Palette.teal.opacity(0.18 + 0.22 * b).color, lineWidth: 1.5)
                        .frame(width: 62 + 6 * CGFloat(b), height: 62 + 6 * CGFloat(b))
                } else if model.mode == .waiting {
                    Circle().stroke(NightWatch.Palette.amber.opacity(0.55).color, lineWidth: 1.5).frame(width: 62, height: 62)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The Stop ring, big, over the screen: it appears after 300 ms of holding the
/// pulse, names the scope, fills over 1.2 s (amber, red only in the last
/// third), then Face ID / Touch ID / passcode asks. Letting go early unwinds
/// it and nothing is sent. Dim background; the screen under it is untouched.
struct NWStopOverlay: View {
    var phase: StopFlowPhase
    var plan: StopPlan
    var biometry: String = "Face ID"

    var body: some View {
        if phase.isActive {
            ZStack {
                Color.black.opacity(0.82).ignoresSafeArea()
                VStack(spacing: 22) {
                    Text(plan.scope)
                        .font(NightWatch.Typo.headline)
                        .foregroundColor(NightWatch.Palette.textPrimary.color)
                        .multilineTextAlignment(.center)
                    if !plan.names.isEmpty, plan.canStop {
                        Text(plan.names).font(NightWatch.Typo.monoSmall)
                            .foregroundColor(NightWatch.Palette.textTertiary.color)
                    }
                    ring
                    Text(caption)
                        .font(NightWatch.Typo.bodyStrong)
                        .foregroundColor(captionColor.color)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
            }
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("\(plan.scope). \(caption)"))
        }
    }

    private var progress: Double {
        switch phase {
        case .holding(let p): return p
        case .idle: return 0
        default: return 1
        }
    }

    private var ring: some View {
        var tone = NightWatch.Palette.amber.mixed(with: NightWatch.Palette.red, HoldRingSpec.warmth(progress: progress))
        // A confirmed Stop is calm, not alarming: the ring settles to teal.
        if case .result(let r) = phase { tone = r.isSuccess ? NightWatch.Palette.teal : NightWatch.Palette.amber }
        return ZStack {
            Circle().stroke(Color.white.opacity(0.10), lineWidth: 14).frame(width: 150, height: 150)
            Circle().trim(from: 0, to: CGFloat(progress))
                .stroke(tone.color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90)).frame(width: 150, height: 150)
                .shadow(color: tone.opacity(0.5 * progress).color, radius: 10)
            Circle().fill(tone.opacity(0.9).color).frame(width: 92, height: 92)
            Image(systemName: icon).font(.system(size: 36)).foregroundColor(NightWatch.Palette.onBright.color)
        }
    }

    private var icon: String {
        switch phase {
        case .authenticating: return "faceid"
        case .result(let r): return r.isSuccess ? "checkmark" : "exclamationmark"
        default: return "stop.fill"
        }
    }

    private var caption: String {
        switch phase {
        case .idle: return ""
        case .holding(let p): return plan.canStop ? HoldRingSpec.prompt(progress: p, biometry: biometry) : plan.scope
        case .authenticating: return "Confirm with \(biometry)"
        case .sending: return "Asking your Mac…"
        case .result(let r): return r.message
        }
    }

    private var captionColor: NightWatch.RGBA {
        if case .result(let r) = phase, r.isSuccess { return NightWatch.Palette.teal }
        return NightWatch.Palette.red.mixed(with: .init(1, 1, 1), 0.35)
    }
}
