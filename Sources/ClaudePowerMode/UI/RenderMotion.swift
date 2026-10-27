import AppKit
import SwiftUI

// The signature motions at fixed timestamps, as contact sheets laid out like
// board 07 (`--render-ui <dir> --motion`). Every frame is the shipped view
// with the clock pinned (`nwFixedNow` / `nwFixedPhase`), and the stores reach
// their states through the same calls the app makes (update, the key
// handlers, markSent, finishSending, confirmResumed), so a sheet is what the
// panel shows at that instant. Not shipped UI.

extension RenderSurfaces {
    /// The motion sheets. Frames with shaders go through ImageRenderer; frames
    /// of the whole popover need AppKit layout (`cacheDisplay`), so they show
    /// the Canvas drawing.
    @MainActor
    static func motion() -> [Surface] {
        [
            Surface(name: "motion-1-pulse", width: NWMotionSheetWidth.value, renderer: .image, motion: true,
                    view: AnyView(NWPulseSheet())),
            Surface(name: "motion-1-pulse-canvas", width: NWMotionSheetWidth.value, renderer: .cache, motion: true,
                    view: AnyView(NWPulseSheet(title: "1 · The pulse (Canvas fallback, macOS 12–13)"))),
            Surface(name: "motion-2-approach", width: NWMotionSheetWidth.value, renderer: .cache, motion: true,
                    view: AnyView(NWApproachSheet())),
            Surface(name: "motion-3-receipt-thread", width: NWMotionSheetWidth.value, renderer: .cache, motion: true,
                    view: AnyView(NWThreadSheet())),
            Surface(name: "motion-4-hold-ring", width: NWMotionSheetWidth.value, renderer: .cache, motion: true,
                    view: AnyView(NWHoldSheet())),
            Surface(name: "motion-5-dusk-dawn", width: NWMotionSheetWidth.value, renderer: .image, motion: true,
                    view: AnyView(NWDuskDawnSheet())),
            Surface(name: "motion-5-dusk-dawn-canvas", width: NWMotionSheetWidth.value, renderer: .cache, motion: true,
                    view: AnyView(NWDuskDawnSheet(title: "5 · Dusk & dawn (Canvas fallback)"))),
            Surface(name: "motion-5-sunrise", width: NWMotionSheetWidth.value, renderer: .image, motion: true,
                    view: AnyView(NWSunriseSheet())),
            Surface(name: "motion-0-popover-metal", width: NightWatch.Space.popoverWidth + 56, renderer: .image, motion: true,
                    view: AnyView(NWMetalPopoverSheet())),
        ]
    }
}

// MARK: - Sheet chrome

/// A board-07-style sheet: a title, then rows of captioned frames.
enum NWMotionSheetWidth { static let value: CGFloat = 2300 }

struct NWMotionSheet<Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SIGNATURE MOTION · MAC")
                    .font(Font.system(size: 11, weight: .bold)).kerning(2.2)
                    .foregroundColor(NightWatch.Palette.teal.color)
                Text(title)
                    .font(Font.system(size: 26, weight: .bold)).kerning(-0.6)
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                Text(subtitle)
                    .font(Font.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundColor(NightWatch.Palette.textTertiary.color)
            }
            content()
        }
        .padding(36)
        .frame(width: NWMotionSheetWidth.value, alignment: .leading)
        .background(NightWatch.Palette.backgroundDeep.color)
    }
}

/// One row of frames with a label column.
struct NWMotionRow<Content: View>: View {
    var label: String
    var note: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(Font.system(size: 15, weight: .semibold)).foregroundColor(NightWatch.Palette.textPrimary.color)
                Text(note).font(Font.system(size: 10.5, design: .monospaced))
                    .foregroundColor(NightWatch.Palette.textTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 190, alignment: .leading)
            HStack(alignment: .top, spacing: 14) { content() }
        }
    }
}

/// One frame: the view on a dark tile, its caption underneath, the clock pinned.
struct NWMotionFrame<Content: View>: View {
    var caption: String
    var width: CGFloat
    var height: CGFloat
    var now: Date
    var phase: Double = 3
    var reduceMotion = false
    var tile = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
                .environment(\.nwFixedNow, now)
                .environment(\.nwFixedPhase, phase)
                .environment(\.nwReduceMotion, reduceMotion)
                .frame(width: width, height: height)
                .background(tile ? RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(red: 0.045, green: 0.055, blue: 0.075)) : nil)
                .overlay(tile ? RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1) : nil)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(caption)
                .font(Font.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundColor(NightWatch.Palette.textTertiary.color)
                .frame(width: width, alignment: .leading)
        }
    }
}

enum NWMotionFixtures {
    static let t0 = NightWatchFixtures.boardNow()

    @MainActor
    static func store(_ inputs: NowInputs, at now: Date = t0) -> NowStore {
        let st = NowStore(model: NowModel.build(inputs), prefs: .ephemeral().dismissingTip())
        st.now = { now }
        return st
    }

    /// Board 05 without the "page" approval (it arrives).
    static func needsYouBefore() -> NowInputs {
        var i = NightWatchFixtures.needsYou()
        i.snapshot = NightWatchFixtures.snapshot(
            sessions: NightWatchFixtures.working5, scheduledResumes: i.snapshot.scheduledResumes,
            pending: i.snapshot.pendingInterventions.filter { $0.projectName != "page" })
        return i
    }

    /// Six agents paused at the cutoff (one star each).
    static func pausedSix(now: Date = t0) -> NowInputs {
        var i = NightWatchFixtures.pausedForBattery(now: now)
        let names = ["mac-on-claude-code", "page-relay", "bottle-flip", "llm-play", "page", "docs"]
        let paused = names.enumerated().map { n, name in
            PausedSession(backend: .claude, sessionId: "sess-\(name)", projectName: name,
                          cwd: "/Users/roy/projects/\(name)", pausedAt: now.addingTimeInterval(-Double(3 + n) * 60),
                          detail: "Interrupted in cmux")
        }
        i.snapshot = NightWatchFixtures.snapshot(
            power: PowerSnapshot(percent: 10, onAC: false, hasBattery: true, isCharging: false), awake: .none,
            battery: Coordinator.BatteryStatus(phase: .drained, paused: paused, graceEndsAt: nil, mode: .pause))
        return i
    }

    /// The same six working again on AC.
    static func workingSix(now: Date = t0) -> NowInputs {
        var i = NightWatchFixtures.allQuiet(now: now)
        let names = ["mac-on-claude-code", "page-relay", "bottle-flip", "llm-play", "page", "docs"]
        i.snapshot = NightWatchFixtures.snapshot(sessions: names.map { NightWatchFixtures.session($0) })
        return i
    }
}

// MARK: - 1 · The pulse

struct NWPulseSheet: View {
    var title = "1 · The pulse"
    private let t0 = NWMotionFixtures.t0

    var body: some View {
        NWMotionSheet(title: title, subtitle: "still white = quiet · teal breath 4 s · one amber ring per waiting item, rate up with the wait, ≤ 1 every 1.5 s · exhale amber→teal 800 ms") {
            NWMotionRow(label: "States", note: "board row 1\nframes at fixed t") {
                cell("quiet · still", NWPulseInputs(style: .quiet), t: 3)
                cell("working · breathe (in)", NWPulseInputs(style: .working, agents: 5), t: 1.85)
                cell("working · breathe (out)", NWPulseInputs(style: .working, agents: 5), t: 3.7)
                cell("1 waiting · ripple", NWPulseInputs(style: .needsYou, waiting: 1, longestWait: 30), t: 1.6)
                cell("3 waiting · faster, capped", NWPulseInputs(style: .needsYou, waiting: 3, longestWait: 600), t: 2.2)
                cell("dusk · low glow", NWPulseInputs(style: .dusk), t: 3)
            }
            NWMotionRow(label: "1 waiting over time", note: "ring life 3 s fresh\none ring per item") {
                ForEach([0.4, 1.2, 2.0, 2.8, 3.6], id: \.self) { t in
                    cell(String(format: "t = %.1f s", t), NWPulseInputs(style: .needsYou, waiting: 1, longestWait: 0), t: t)
                }
            }
            NWMotionRow(label: "Last one clears", note: "amber → teal 800 ms\none long exhale\nrings fade") {
                ForEach([0.0, 0.2, 0.4, 0.6, 0.8, 1.2], id: \.self) { e in
                    cell("\(Int(e * 1000)) ms", NWPulseInputs(style: .working, waiting: 0, agents: 5,
                                                         clearedAt: t0, clearedRings: 2),
                         t: 2.2 + e, now: t0.addingTimeInterval(e))
                }
            }
            NWMotionRow(label: "Aurora settles", note: "the header as the\nlast one clears,\nblended in OKLCH") {
                ForEach([0.3, 0.45, 0.6, 0.8, 1.2], id: \.self) { e in exhaleHeader(e) }
            }
            NWMotionRow(label: "Reduce Motion", note: "static ring\nwith a count") {
                cell("3 waiting · still", NWPulseInputs(style: .needsYou, waiting: 3), t: 2, reduce: true)
                cell("working · still", NWPulseInputs(style: .working, agents: 5), t: 2, reduce: true)
            }
            NWMotionRow(label: "Menu bar glyph", note: "8 fps, phases quantised\n15 fps for the exhale only") {
                glyphStrip
            }
        }
    }

    /// The popover's header the moment the last waiting item clears: the
    /// needs-you aurora settling into the working one with the pulse.
    private func exhaleHeader(_ e: Double) -> some View {
        let model = NowModel.build(NWMotionFixtures.workingSix())
        var m = NowMotion()
        m.clearedAt = t0
        let now = t0.addingTimeInterval(e)
        let look = NowSky.look(model: model, motion: m, now: now, reduceMotion: false)
        return NWMotionFrame(caption: "\(Int(e * 1000)) ms", width: 380, height: 92, now: now, phase: 6 + e) {
            NWAuroraHeader(palette: look.palette, headline: model.headline, subline: model.subline, pulse: model.mood.pulse,
                           pulseInputs: NWPulseInputs(style: model.mood.pulse, waiting: 0, agents: model.workingCount,
                                                      clearedAt: t0, clearedRings: 2),
                           sky: look.sky)
        }
    }

    private func cell(_ caption: String, _ inputs: NWPulseInputs, t: Double, now: Date? = nil, reduce: Bool = false) -> some View {
        NWMotionFrame(caption: caption, width: 200, height: 150, now: now ?? t0, phase: t, reduceMotion: reduce) {
            NWPulseOrb(inputs: inputs).scaleEffect(1.8)
        }
    }

    private var glyphStrip: some View {
        let entries: [(String, GlyphDrawing)] = [
            ("quiet", GlyphDrawing.make(GlyphState(mode: .quiet))),
            ("working · in", GlyphDrawing.make(GlyphState(mode: .working(agents: 5)), phase: 0.25)),
            ("working · out", GlyphDrawing.make(GlyphState(mode: .working(agents: 5)), phase: 0.75)),
            ("1 waiting", GlyphDrawing.make(GlyphState(mode: .needsYou(count: 1)), phase: 0.35)),
            ("3 waiting", GlyphDrawing.make(GlyphState(mode: .needsYou(count: 3)), phase: 0.2)),
            ("cleared 200 ms", GlyphDrawing.make(GlyphState(mode: .working(agents: 5)), phase: 0.3,
                                                 exhale: PulseModel.exhale(elapsed: 0.2), exhaleRings: 2)),
            ("cleared 500 ms", GlyphDrawing.make(GlyphState(mode: .working(agents: 5)), phase: 0.45,
                                                 exhale: PulseModel.exhale(elapsed: 0.5), exhaleRings: 2)),
            ("paused · low glow", GlyphDrawing.make(GlyphState(mode: .paused))),
        ]
        return HStack(spacing: 14) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                VStack(spacing: 6) {
                    Image(nsImage: StatusGlyphRenderer.image(e.1, scale: 4))
                        .frame(width: CGFloat(e.1.width) * 4, height: 72)
                        .frame(width: 140, height: 90)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.11, green: 0.11, blue: 0.13)))
                    Text(e.0).font(Font.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(NightWatch.Palette.textTertiary.color)
                }
            }
        }
    }
}

// MARK: - 2 · Final approach

struct NWApproachSheet: View {
    private let t0 = NWMotionFixtures.t0

    var body: some View {
        NWMotionSheet(title: "2 · Final approach", subtitle: "a new decision leaves the pulse for its ranked slot · contrail · spring(.5, .8) ≈ 520 ms · only rows below ease down, by one card height") {
            NWMotionRow(label: "Popover", note: "\"page\" arrives at\nrank 2; llm-play\nmakes room;\nbottle-flip stays") {
                ForEach([(0.0, "0 ms · leaves pulse"), (0.09, "90 ms"), (0.18, "180 ms · contrail"),
                         (0.27, "270 ms"), (0.36, "360 ms · lands")], id: \.0) { t, caption in
                    frame(t, caption)
                }
            }
            NWMotionRow(label: "", note: "") {
                frame(0.52, "520 ms · settles, glow off")
                frame(0.44, "440 ms · glow going off")
                frozen
                reduced
            }
        }
    }

    private func arrivedStore() -> NowStore {
        let st = NWMotionFixtures.store(NWMotionFixtures.needsYouBefore())
        st.animates = true
        st.update(NowModel.build(NightWatchFixtures.needsYou()))
        return st
    }

    private func frame(_ t: Double, _ caption: String) -> some View {
        NWMotionFrame(caption: caption, width: 380, height: 440, now: t0.addingTimeInterval(t), tile: false) {
            NWNowPopover(store: arrivedStore()).frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// The pointer is over the list: the arrival waits behind the pill.
    private var frozen: some View {
        let st = NWMotionFixtures.store(NWMotionFixtures.needsYouBefore())
        st.animates = true
        st.pointerInList = true
        st.update(NowModel.build(NightWatchFixtures.needsYou()))
        return NWMotionFrame(caption: "pointer in list · waits behind New ↑ 1", width: 380, height: 440, now: t0, tile: false) {
            NWNowPopover(store: st).frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var reduced: some View {
        NWMotionFrame(caption: "Reduce Motion · in place at 180 ms", width: 380, height: 440, now: t0.addingTimeInterval(0.18),
                      reduceMotion: true, tile: false) {
            NWNowPopover(store: arrivedStore()).frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - 3 · Receipt thread

struct NWThreadSheet: View {
    private let t0 = NWMotionFixtures.t0

    var body: some View {
        NWMotionSheet(title: "3 · Receipt thread", subtitle: "sent (handed to the reply path) → typed → verified, only after the Mac confirms · fold into a hairline · failure snaps back, one soft shake, words") {
            NWMotionRow(label: "Thread", note: "close-up, 2x\nrow answered at\nthe Mac (no relay)") {
                strip("sent · 120 ms", sentFor: 0.12)
                strip("sent · waiting on Mac", sentFor: 2.4)
                strip("typed (confirmed +150 ms)", sentFor: 2.4, resolvedFor: 0.15, .verified)
                strip("verified ✓ (+300 ms)", sentFor: 2.4, resolvedFor: 0.32, .verified)
                strip("Touch ID · nothing sent", authenticating: true)
            }
            NWMotionRow(label: "Resolve", note: "dot amber → teal\nrings contract\nfold, drift to Settled") {
                ForEach([(0.45, "+450 ms · rings in"), (0.82, "+820 ms · folding"), (0.95, "+950 ms · hairline"),
                         (1.1, "+1.1 s · drifts")], id: \.0) { e, caption in
                    popover(caption, resolvedFor: e, .verified)
                }
            }
            NWMotionRow(label: "Failure", note: "thread snaps back\none soft shake\noutcome in words") {
                strip("snap back · +100 ms", sentFor: 1.5, resolvedFor: 0.1, .failed("Prompt closed before your answer"))
                strip("shake · +330 ms", sentFor: 1.5, resolvedFor: 0.33, .failed("Prompt closed before your answer"))
                strip("words · +1 s", sentFor: 1.5, resolvedFor: 1.0, .failed("Prompt closed before your answer"))
                strip("queued (not landed)", sentFor: 1.5, resolvedFor: 0.6, .queued)
                strip("Reduce Motion · verified", sentFor: 1.5, resolvedFor: 0.2, .verified, reduce: true)
            }
            NWMotionRow(label: "In the popover", note: "waiting on the Mac\nand a failure") {
                popover("sent · waiting on Mac", sentFor: 1.2)
                popover("failed · words", resolvedFor: 1.0, .failed("Prompt closed before your answer"))
            }
        }
    }

    private func thread(sentFor: Double?, resolvedFor: Double?, _ res: ReceiptThreadModel.Resolution?,
                        authenticating: Bool = false) -> NowMotion.Thread {
        let row = NowModel.build(NightWatchFixtures.needsYou()).rows[1]
        var th = NowMotion.Thread(row: row, index: 1)
        th.authenticating = authenticating
        if let r = resolvedFor {
            th.resolvedAt = t0.addingTimeInterval(-r)
            th.resolution = res
            th.sentAt = th.resolvedAt!.addingTimeInterval(-(sentFor ?? 1))
        } else if let s = sentFor {
            th.sentAt = t0.addingTimeInterval(-s)
        }
        return th
    }

    private func strip(_ caption: String, sentFor: Double? = nil, resolvedFor: Double? = nil,
                       _ res: ReceiptThreadModel.Resolution? = nil, authenticating: Bool = false, reduce: Bool = false) -> some View {
        let th = thread(sentFor: sentFor, resolvedFor: resolvedFor, res, authenticating: authenticating)
        let f = NWDecideRowView.threadFrame(th, now: t0, reduceMotion: reduce)
        return NWMotionFrame(caption: caption, width: 270, height: 120, now: t0, reduceMotion: reduce) {
            NWReceiptStrip(frame: f, authenticating: authenticating)
                .frame(width: 230)
                .scaleEffect(1.12)
                .offset(x: f.shake)
        }
    }

    private func popover(_ caption: String, sentFor: Double? = nil, resolvedFor: Double? = nil,
                         _ res: ReceiptThreadModel.Resolution? = nil) -> some View {
        let st = NWMotionFixtures.store(NightWatchFixtures.needsYou())
        let th = thread(sentFor: sentFor, resolvedFor: resolvedFor, res)
        st.previewMotion { $0.threads[th.rowId] = th }
        return NWMotionFrame(caption: caption, width: 380, height: 440, now: t0, tile: false) {
            NWNowPopover(store: st).frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - 4 · Hold ring

struct NWHoldSheet: View {
    private let t0 = NWMotionFixtures.t0

    var body: some View {
        NWMotionSheet(title: "4 · The hold ring", subtitle: "irreversible + stop-all only · appears after 300 ms · fills 1.2 s · amber, warming to red in the last third · ticks at 25/50/75 % + full · Touch ID → burst · early release unwinds") {
            NWMotionRow(label: "Hold 1", note: "the cap's ring, 3x") {
                cap("0 ms", progress: nil)
                cap("320 ms · appears", progress: 0.017)
                cap("600 ms · 25% tick", progress: 0.25)
                cap("900 ms · 50% tick", progress: 0.5)
                cap("1.2 s · 75% tick, warming", progress: 0.75)
                cap("1.35 s · red", progress: 0.875)
                cap("1.5 s · full", progress: 1)
            }
            NWMotionRow(label: "Then", note: "Touch ID, burst,\nor let go early") {
                capAuth("Touch ID · nothing sent")
                capBurst("burst · +120 ms", 0.12)
                capBurst("burst · +300 ms", 0.3)
                capUnwind("let go at 60% · +150 ms", from: 0.6, since: 0.15)
                capUnwind("unwinding · +500 ms", from: 0.6, since: 0.5)
            }
            NWMotionRow(label: "Stop all (⌘. held)", note: "the same rule\nas a circle") {
                ForEach([0.0, 0.25, 0.5, 0.75, 0.9, 1.0], id: \.self) { p in
                    NWMotionFrame(caption: "\(Int(p * 100))%", width: 150, height: 110, now: t0) {
                        NWHoldRing(progress: p, size: 28, lineWidth: 3.5).scaleEffect(2.2)
                    }
                }
                popoverHold
            }
        }
    }

    private func row(store: NowStore) -> some View {
        let r = store.model.rows[0]
        return NWDecideRowView(row: r, focused: false, holdProgress: holdProgress(store), thread: store.motion.threads[r.id],
                               unwind: store.motion.unwind, burst: store.motion.burst)
            .frame(width: 360)
    }

    private func holdProgress(_ st: NowStore) -> Double? {
        guard let h = st.hold, case .approve = h.kind else { return nil }
        return st.holdProgress
    }

    private func capFrame<V: View>(_ caption: String, _ v: V) -> some View {
        NWMotionFrame(caption: caption, width: 260, height: 150, now: t0) {
            // The right end of the row, where the caps are, at 2.4x.
            v.scaleEffect(2.4, anchor: .center).offset(x: -2.4 * 132)
        }
    }

    private func baseStore() -> NowStore {
        let i = NightWatchFixtures.needsYou()
        let st = NWMotionFixtures.store(i)
        st.select(st.model.rows[0].id)
        return st
    }

    private func cap(_ caption: String, progress: Double?) -> some View {
        let st = baseStore()
        if let p = progress { st.previewHold(.approve(rowId: st.model.rows[0].id), progress: p) }
        return capFrame(caption, row(store: st))
    }

    private func capAuth(_ caption: String) -> some View {
        let st = baseStore()
        let r = st.model.rows[0]
        st.previewMotion { m in var th = NowMotion.Thread(row: r, index: 0); th.authenticating = true; m.threads[r.id] = th }
        return capFrame(caption, row(store: st))
    }

    private func capBurst(_ caption: String, _ e: Double) -> some View {
        let st = baseStore()
        let r = st.model.rows[0]
        st.previewMotion { $0.burst = NowMotion.Burst(rowId: r.id, at: t0.addingTimeInterval(-e)) }
        return capFrame(caption, row(store: st))
    }

    private func capUnwind(_ caption: String, from: Double, since: Double) -> some View {
        let st = baseStore()
        let r = st.model.rows[0]
        st.previewMotion { $0.unwind = NowMotion.Unwind(kind: .approve(rowId: r.id), from: from, at: t0.addingTimeInterval(-since)) }
        return capFrame(caption, row(store: st))
    }

    private var popoverHold: some View {
        let st = NWMotionFixtures.store(NightWatchFixtures.needsYou())
        st.previewHold(.stopAll, progress: 0.8)
        return NWMotionFrame(caption: "popover · stop all at 80%", width: 380, height: 470, now: t0, tile: false) {
            NWNowPopover(store: st).frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - 5 · Dusk & dawn

struct NWDuskDawnSheet: View {
    var title = "5 · Dusk & dawn"
    private let t0 = NWMotionFixtures.t0

    var body: some View {
        NWMotionSheet(title: title, subtitle: "battery cutoff: the aurora fades to dusk, working stars exhale and dim together, a grey horizon holds · power back: dawn rises and relights each star as its resume is confirmed") {
            NWMotionRow(label: "Dusk", note: "the header sky\none star per agent") {
                header("working sky", duskFor: nil, working: true)
                header("cutoff · +300 ms · exhale", duskFor: 0.3)
                header("dusk falls · +1.1 s", duskFor: 1.1)
                header("paused · horizon only", duskFor: 2.6)
            }
            NWMotionRow(label: "Dawn", note: "resumes confirmed\nat +0.3 s (3) and\n+1.0 s (2); one never\n(stays dim)") {
                ForEach([(0.35, "power · +350 ms"), (0.8, "+800 ms · relighting"), (1.3, "+1.3 s"),
                         (2.0, "+2 s · last confirmed"), (3.4, "+3.4 s · day")], id: \.0) { e, caption in
                    dawnHeader(caption, e)
                }
            }
            NWMotionRow(label: "Popover", note: "mid-dusk and\nmid-dawn") {
                popoverDusk
                popoverDawn
                header("Reduce Motion · paused", duskFor: 0.4, reduce: true)
            }
        }
    }

    private func header(_ caption: String, duskFor: Double?, working: Bool = false, reduce: Bool = false) -> some View {
        let model = NowModel.build(working ? NWMotionFixtures.workingSix() : NWMotionFixtures.pausedSix())
        var m = NowMotion()
        if let d = duskFor { m.duskAt = t0.addingTimeInterval(-d) }
        let look = NowSky.look(model: model, motion: m, now: t0, reduceMotion: reduce)
        return NWMotionFrame(caption: caption, width: 380, height: 92, now: t0, phase: 6, reduceMotion: reduce) {
            NWAuroraHeader(palette: look.palette, headline: model.headline, subline: model.subline,
                           pulse: model.mood.pulse, sky: look.sky)
        }
    }

    private func dawnMotion() -> (NowModel, NowMotion) {
        let paused = NowModel.build(NWMotionFixtures.pausedSix())
        let model = NowModel.build(NWMotionFixtures.workingSix())
        var dawn = NowMotion.Dawn(stars: paused.paused, startedAt: t0)
        for (n, s) in paused.paused.enumerated() where n < 5 {
            dawn.confirmed[s.id] = t0.addingTimeInterval(n < 3 ? 0.3 : 1.0)
        }
        var m = NowMotion()
        m.dawn = dawn
        return (model, m)
    }

    private func dawnHeader(_ caption: String, _ e: Double) -> some View {
        let (model, m) = dawnMotion()
        let look = NowSky.look(model: model, motion: m, now: t0.addingTimeInterval(e), reduceMotion: false)
        let words = NowSky.lines(model: model, motion: m, now: t0.addingTimeInterval(e), reduceMotion: false)
        return NWMotionFrame(caption: caption, width: 380, height: 92, now: t0.addingTimeInterval(e), phase: 6 + e) {
            NWAuroraHeader(palette: look.palette, headline: words.headline, subline: words.subline,
                           pulse: model.mood.pulse, sky: look.sky)
        }
    }

    private var popoverDusk: some View {
        let st = NWMotionFixtures.store(NWMotionFixtures.workingSix())
        st.animates = true
        st.update(NowModel.build(NWMotionFixtures.pausedSix()))
        return NWMotionFrame(caption: "popover · dusk +1.4 s", width: 380, height: 470, now: t0.addingTimeInterval(1.4),
                             phase: 6, tile: false) {
            NWNowPopover(store: st).frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var popoverDawn: some View {
        let st = NWMotionFixtures.store(NWMotionFixtures.pausedSix())
        st.animates = true
        st.update(NowModel.build(NWMotionFixtures.workingSix()))
        st.confirmResumed(sessionIds: ["sess-mac-on-claude-code", "sess-page-relay", "sess-bottle-flip"])
        return NWMotionFrame(caption: "popover · dawn +0.9 s", width: 380, height: 470, now: t0.addingTimeInterval(0.9),
                             phase: 6.9, tile: false) {
            NWNowPopover(store: st).frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - Sunrise

struct NWSunriseSheet: View {
    private let t0 = NWMotionFixtures.t0

    var body: some View {
        let rings = NightWatchFixtures.allQuiet().day?.rings ?? []
        let good = WelcomeBack.build(away: 52 * 60, finished: 4, needYou: 0, handledOnPhone: 0, rings: rings)
        let mixed = WelcomeBack.build(away: 52 * 60, finished: 1, needYou: 2, handledOnPhone: 0, rings: rings)
        return NWMotionSheet(title: "5 · The sunrise that opens Welcome back", subtitle: "the same dawn, scaled to how much finished: higher and warmer after a good absence") {
            NWMotionRow(label: "4 finished", note: String(format: "scale %.2f", good.sunrise)) {
                ForEach([0.0, 0.4, 0.9, 1.4, 2.2], id: \.self) { e in sunrise(good, e) }
            }
            NWMotionRow(label: "1 finished, 2 need you", note: String(format: "scale %.2f", mixed.sunrise)) {
                ForEach([0.0, 0.4, 0.9, 1.4, 2.2], id: \.self) { e in sunrise(mixed, e) }
            }
        }
    }

    private func sunrise(_ m: WelcomeBack, _ e: Double) -> some View {
        NWMotionFrame(caption: String(format: "+%.1f s", e), width: 300, height: 150, now: t0.addingTimeInterval(e), tile: false) {
            NWWelcomeBackView(model: m, shownAt: t0).scaleEffect(0.75)
        }
    }
}

// MARK: - The popover with Metal

/// The live popover header with the Metal aurora, pulse and glass rim (no
/// scroll view or text field, so ImageRenderer can draw it).
struct NWMetalPopoverSheet: View {
    private let t0 = NWMotionFixtures.t0

    var body: some View {
        let st = NWMotionFixtures.store(NightWatchFixtures.needsYou())
        let quiet = NWMotionFixtures.store(NightWatchFixtures.allQuiet())
        return VStack(spacing: 20) {
            NWNowPopover(store: st)
            NWNowPopover(store: quiet)
        }
        .environment(\.nwFixedNow, t0)
        .environment(\.nwFixedPhase, 3)
        .environment(\.nwReduceMotion, false)
        .padding(28)
        .background(NWBackdrop())
    }
}
