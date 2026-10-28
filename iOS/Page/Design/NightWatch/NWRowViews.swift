import SwiftUI

// The Now stream's building blocks: section headers, the Decide cards shaped
// by reversibility, the swipeable Undoable row, Look and Review cards, the
// Settled list and the floating nav capsule. They draw a `NowRow` and hand
// every action to a closure; the screen that hosts them routes it through
// the existing services (APIClient / SessionStore / NotificationService),
// so these views never type anything themselves.

/// "DECIDE 2" and a hairline.
struct NWSectionHeader: View {
    var title: String
    var count: Int?
    var color: NightWatch.RGBA

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(NightWatch.Typo.labelLarge).kerning(1.2).foregroundColor(color.color)
            if let count { Text("\(count)").font(NightWatch.Typo.labelLarge).foregroundColor(NightWatch.Palette.textTertiary.color) }
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension NowRow.Section {
    var color: NightWatch.RGBA {
        switch self {
        case .decide, .look: return NightWatch.Palette.amber
        case .review: return NightWatch.Palette.teal
        }
    }
}

extension NowRow {
    /// "waiting 4m", "finished 2m".
    func waitingText(now: Date) -> String {
        let t = RelativeTime.compact(seconds: Int(max(0, now.timeIntervalSince(waitingSince))))
        return (section == .review ? "finished " : "waiting ") + t
    }

    var tint: NightWatch.RGBA? {
        switch chip {
        case .irreversible: return NightWatch.Palette.red
        case .considered: return NightWatch.Palette.sky
        case .looksStuck, .forecast, .rateLimited, .question: return NightWatch.Palette.amber
        case .undoable: return NightWatch.Palette.green
        case .review: return NightWatch.Palette.teal
        }
    }
}

/// The header line of a card: chip, project, how long it has waited.
private struct NWCardTopLine: View {
    var row: NowRow
    var now: Date
    var body: some View {
        HStack(spacing: 10) {
            NWChip(kind: row.chip, pill: true)
            Text(row.projectName)
                .font(NightWatch.Typo.monoSmall)
                .foregroundColor(NightWatch.Palette.textSecondary.color)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(row.waitingText(now: now))
                .font(NightWatch.Typo.caption)
                .foregroundColor(NightWatch.Palette.textTertiary.color)
                .lineLimit(1)
        }
    }
}

/// What the card's action area says once an action is under way: the 1.2 s
/// cancel ring (nothing has been sent; tapping cancels), then the wait for
/// the Mac, then the Mac's word. Only a confirmed delivery is teal. Given
/// the delivery state (`receipt`), it is drawn as the Receipt thread.
struct NWOutcomeStrip: View {
    var outcome: CardOutcome
    var pending: PendingAction?
    var receipt: ReceiptThreadInput? = nil
    var onCancel: () -> Void = {}
    @Environment(\.nwFixedNow) private var fixedNow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let receipt, !receipt.isEmpty, outcome != .none {
            NWReceiptThreadView(input: receipt, onTap: onCancel)
        } else {
            plain
        }
    }

    @ViewBuilder private var plain: some View {
        switch outcome {
        case .none: EmptyView()
        case .arming:
            if let pending {
                if let fixedNow {
                    arming(pending, now: fixedNow)
                } else if reduceMotion {
                    TimelineView(.periodic(from: .now, by: 0.1)) { tl in arming(pending, now: tl.date) }
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in arming(pending, now: tl.date) }
                }
            }
        case .sending:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(NightWatch.Palette.textSecondary.color)
                Text("Waiting for your Mac to confirm…").font(NightWatch.Typo.monoMicro)
                    .foregroundColor(NightWatch.Palette.textSecondary.color)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: NightWatch.Radius.button, style: .continuous).fill(Color.white.opacity(0.06)))
            .accessibilityElement(children: .combine)
        case .delivered(let detail):
            NWReceiptLine(text: "Delivered · \(detail)")
        case .problem(let why):
            // Tapping opens the decision, to see what happened and try again.
            Button(action: onCancel) { NWReceiptLine(text: why, failed: true) }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Opens the decision to try again"))
        }
    }

    private func arming(_ p: PendingAction, now: Date) -> some View {
        let progress: Double
        if case .arming(let v) = p.phase(now: now) { progress = v } else { progress = 1 }
        return Button(action: onCancel) {
            HStack(spacing: 12) {
                NWRing(progress: progress, color: NightWatch.Palette.amber, lineWidth: 3.5, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.armLabel(now: now)).font(NightWatch.Typo.bodyStrong)
                        .foregroundColor(NightWatch.Palette.textPrimary.color)
                    if let preview = p.preview {
                        Text(preview).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textTertiary.color)
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                Text("Cancel").font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.amber.color)
            }
            .padding(.horizontal, 14).padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: NightWatch.Radius.button, style: .continuous).fill(NightWatch.Palette.amber.opacity(0.12).color))
            .overlay(RoundedRectangle(cornerRadius: NightWatch.Radius.button, style: .continuous)
                .strokeBorder(NightWatch.Palette.amber.opacity(0.4).color, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Sending, tap to cancel"))
    }
}

/// A Decide card for a Considered or Irreversible approval: the command in
/// full, the delivery preview, then Deny and the approve control. Considered
/// approves with a tap (then the 1.2 s cancel ring); Irreversible with
/// press-and-hold plus biometrics. Tapping the card opens the Decision sheet.
struct NWDecideCard: View {
    var row: NowRow
    var now: Date
    var outcome: CardOutcome = .none
    var pending: PendingAction? = nil
    var receipt: ReceiptThreadInput? = nil
    var fixedHold: Double? = nil
    var onApprove: () -> Void = {}
    var onHoldComplete: () -> Void = {}
    var onDeny: () -> Void = {}
    var onOpen: () -> Void = {}
    var onCancel: () -> Void = {}

    var body: some View {
        let irreversible = row.chip == .irreversible
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 14) {
                    NWCardTopLine(row: row, now: now)
                    Text(row.headline)
                        .font(NightWatch.Typo.headline)
                        .foregroundColor(NightWatch.Palette.textPrimary.color)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    commandBox(irreversible: irreversible)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens the decision"))
            // The buttons below are the visible way; these are the same, named, for VoiceOver.
            .accessibilityActions {
                // Same condition as the visible buttons: Deny present, Approve beside it.
                if outcome == .none, row.action(.deny) != nil {
                    Button("Deny") { onDeny() }
                    if row.action(.approve) != nil {
                        // The hold's own path: it still asks the phone to confirm before anything is sent.
                        if irreversible { Button("Approve, then confirm with your device") { onHoldComplete() } }
                        else { Button("Approve") { onApprove() } }
                    }
                }
            }
            actions(irreversible: irreversible)
        }
        .padding(NightWatch.Space.lg)
        .background(NWGlassBackground(radius: NightWatch.Radius.card, tint: row.tint))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func actions(irreversible: Bool) -> some View {
        if outcome != .none {
            NWOutcomeStrip(outcome: outcome, pending: pending, receipt: receipt, onCancel: onCancel)
        } else if let deny = row.action(.deny) {
            HStack(spacing: 10) {
                Button(deny.label, action: onDeny).buttonStyle(NWButtonStyle(kind: .quiet))
                if let approve = row.action(.approve) {
                    if irreversible {
                        NWHoldButton(fixedProgress: fixedHold, onComplete: onHoldComplete)
                    } else {
                        Button(approve.label, action: onApprove).buttonStyle(NWButtonStyle(kind: .bright))
                    }
                }
            }
        } else if row.action(.openOnMac) != nil {
            Button("Open on Mac", action: onOpen).buttonStyle(NWButtonStyle(kind: .quiet))
        }
    }

    private func commandBox(irreversible: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("$").foregroundColor((irreversible ? NightWatch.Palette.red : NightWatch.Palette.textTertiary).color)
                Text(row.summary).foregroundColor((irreversible ? NightWatch.Palette.red.mixed(with: .init(1, 1, 1), 0.2) : NightWatch.Palette.textPrimary).color)
                    .lineLimit(3)
            }
            .font(NightWatch.Typo.mono)
            if let p = row.focusPreview {
                Text(p).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: NightWatch.Radius.inset, style: .continuous)
            .fill(NightWatch.Palette.inset.opacity(0.85).color))
    }
}

/// A question: the agent is waiting for words, not a yes or no. The answer is
/// written in the sheet (Esc, then your message, then Return).
struct NWQuestionCard: View {
    var row: NowRow
    var now: Date
    /// The Mac sent the question itself, so the sheet offers tap-to-tick answers.
    var answerable = false
    var onOpen: () -> Void = {}

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 12) {
                NWCardTopLine(row: row, now: now)
                Text(row.summary)
                    .font(NightWatch.Typo.title)
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                if let p = row.focusPreview {
                    Text(p).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textTertiary.color)
                        .multilineTextAlignment(.leading)
                }
                HStack {
                    Spacer()
                    Text(answerable ? "Answer" : (row.action(.tellInstead)?.label ?? "Open"))
                        .font(NightWatch.Typo.button).foregroundColor(NightWatch.Palette.onBright.color)
                        .padding(.horizontal, 22).frame(minHeight: 44)
                        .background(Capsule().fill(LinearGradient(colors: [NightWatch.Palette.yellow.color, NightWatch.Palette.amber.color],
                                                                  startPoint: .leading, endPoint: .trailing)))
                }
            }
            .padding(NightWatch.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NWGlassBackground(radius: NightWatch.Radius.card, tint: row.tint))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens the question"))
    }
}

/// An Undoable row: swipe right to approve. The Approve affordance sits behind
/// the row and is revealed as it moves; past the threshold a haptic ticks and
/// the 1.2 s cancel ring starts (nothing is sent until it runs out). A tap
/// opens the Decision sheet.
struct NWUndoableRow: View {
    var row: NowRow
    var now: Date
    var outcome: CardOutcome = .none
    var pending: PendingAction? = nil
    var receipt: ReceiptThreadInput? = nil
    /// Draws the row part-way through a swipe (the render harness).
    var fixedDrag: CGFloat? = nil
    var onApprove: () -> Void = {}
    var onOpen: () -> Void = {}
    var onCancel: () -> Void = {}
    @State private var drag: CGFloat = 0
    @State private var passed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nwChromeGlassOn) private var glass
    private let commitAt: CGFloat = 110

    var body: some View {
        if outcome != .none {
            VStack(alignment: .leading, spacing: 10) {
                rowBody.background(NWGlassBackground(radius: NightWatch.Radius.row, fill: NightWatch.Palette.surface))
                NWOutcomeStrip(outcome: outcome, pending: pending, receipt: receipt, onCancel: onCancel)
            }
        } else {
            swipeable
        }
    }

    private var swipeable: some View {
        // A row with no Approve action (Open on Mac only) is never swipeable, whatever its chip says.
        let can = row.canSwipeApprove
        let x = can ? (fixedDrag ?? drag) : 0
        return ZStack(alignment: .leading) {
            if can {
            // The well is chrome the row uncovers: green glass, greener as the swipe nears the threshold.
            // Glass only while the row is moved, so a row at rest has nothing showing round its rim.
            let reach = Double(min(1, x / commitAt))
            if x > 0 || !glass {
                Color.clear
                    .nwChromeGlass(in: RoundedRectangle(cornerRadius: NightWatch.Radius.row, style: .continuous),
                                   tint: NightWatch.Palette.chromeGlass.mixed(with: NightWatch.Palette.green.opacity(0.6), 0.22 + 0.2 * reach),
                                   interactive: false) {
                        RoundedRectangle(cornerRadius: NightWatch.Radius.row, style: .continuous)
                            .fill(NightWatch.Palette.green.opacity(0.14 + 0.10 * reach).color)
                    }
                    .overlay(HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                        Text("Approve").font(NightWatch.Typo.bodyStrong)
                    }
                    .foregroundColor(NightWatch.Palette.green.color)
                    .padding(.leading, 18), alignment: .leading)
            }
            }
            rowBody
                // Opaque, so the Approve well never shows through the row.
                .background(NWGlassBackground(radius: NightWatch.Radius.row, fill: NightWatch.Palette.surface.opacity(1)))
                .offset(x: x)
                .onTapGesture(perform: onOpen)
                // Beside the list's own scrolling; only a clearly sideways drag moves the row.
                .simultaneousGesture(DragGesture(minimumDistance: 12)
                    .onChanged { v in
                        guard can, NWDestination.isHorizontal(dx: Double(v.translation.width), dy: Double(v.translation.height)) else { drag = 0; return }
                        drag = max(0, min(160, v.translation.width))
                        if drag >= commitAt, !passed { passed = true; NWHaptics.tick() }
                        if drag < commitAt { passed = false }
                    }
                    .onEnded { v in
                        let go = can && v.translation.width >= commitAt
                            && NWDestination.isHorizontal(dx: Double(v.translation.width), dy: Double(v.translation.height))
                        passed = false
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { drag = 0 }
                        if go { onApprove() }
                    })
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(row.summary), \(row.projectName), undoable"))
        .accessibilityActions { if can { Button("Approve") { onApprove() } } }
        .accessibilityAction(named: Text("Open")) { onOpen() }
    }

    private var rowBody: some View {
        HStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(.body, weight: .medium))
                .foregroundColor(NightWatch.Palette.green.color)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NightWatch.Palette.green.opacity(0.14).color))
            VStack(alignment: .leading, spacing: 3) {
                Text(row.summary).font(NightWatch.Typo.mono)
                    .foregroundColor(NightWatch.Palette.textPrimary.color).lineLimit(1)
                Text("\(row.projectName) · undoable · swipe to run")
                    .font(NightWatch.Typo.caption)
                    .foregroundColor(NightWatch.Palette.textTertiary.color).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }
}

/// A Look card: a stuck agent, a rate limit, a forecast. Tapping opens the
/// sheet; the button acts (Steer opens the composer, Stop it arms the cancel ring).
struct NWLookCard: View {
    var row: NowRow
    var now: Date
    var outcome: CardOutcome = .none
    var pending: PendingAction? = nil
    var receipt: ReceiptThreadInput? = nil
    var onSteer: () -> Void = {}
    var onOpen: () -> Void = {}
    var onCancel: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: row.chip.symbol)
                    .font(.system(.title3, weight: .medium))
                    .foregroundColor(NightWatch.Palette.amber.color)
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NightWatch.Palette.amber.opacity(0.14).color))
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.headline).font(NightWatch.Typo.title)
                        .foregroundColor(NightWatch.Palette.textPrimary.color).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(subtitle).font(NightWatch.Typo.caption)
                        .foregroundColor(NightWatch.Palette.textSecondary.color).lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                if outcome == .none, let steer = row.action(.tellInstead) {
                    Button(steer.label, action: onSteer)
                        .buttonStyle(NWButtonStyle(kind: .amber))
                        .frame(width: 92)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            if outcome != .none { NWOutcomeStrip(outcome: outcome, pending: pending, receipt: receipt, onCancel: onCancel) }
        }
        .padding(NightWatch.Space.md)
        .background(NWGlassBackground(radius: NightWatch.Radius.card, tint: NightWatch.Palette.amber))
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Open")) { onOpen() }
        .accessibilityActions { if outcome == .none, let steer = row.action(.tellInstead) { Button(steer.label) { onSteer() } } }
    }

    /// "cargo test failed 6× · since 00:58" style: the summary, then how long.
    private var subtitle: String { "\(row.summary) · \(row.waitingText(now: now))" }
}

/// A Review card: a finished turn, with what changed and Looks good.
struct NWReviewCard: View {
    var row: NowRow
    var now: Date
    var outcome: CardOutcome = .none
    var pending: PendingAction? = nil
    var receipt: ReceiptThreadInput? = nil
    var onLooksGood: () -> Void = {}
    var onSteer: () -> Void = {}
    var onOpen: () -> Void = {}
    var onCancel: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(row.projectName).font(NightWatch.Typo.mono)
                            .foregroundColor(NightWatch.Palette.textPrimary.color).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(row.waitingText(now: now)).font(NightWatch.Typo.caption)
                            .foregroundColor(NightWatch.Palette.textTertiary.color)
                    }
                    let chips = TurnSummaryChips.parse(row.summary)
                    if chips.isEmpty {
                        Text(row.summary).font(NightWatch.Typo.body)
                            .foregroundColor(NightWatch.Palette.textSecondary.color).lineLimit(2)
                            .multilineTextAlignment(.leading)
                    } else {
                        HStack(spacing: 8) { ForEach(Array(chips.enumerated()), id: \.offset) { _, c in NWTurnChip(chip: c) } }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens the finished turn"))
            .accessibilityActions {
                if outcome == .none {
                    if row.action(.carryOn) != nil { Button("Looks good") { onLooksGood() } }
                    if let steer = row.action(.tellInstead) { Button(steer.label) { onSteer() } }
                }
            }
            if outcome != .none {
                NWOutcomeStrip(outcome: outcome, pending: pending, receipt: receipt, onCancel: onCancel)
            } else {
                HStack(spacing: 10) {
                    if let steer = row.action(.tellInstead) { Button(steer.label, action: onSteer).buttonStyle(NWButtonStyle(kind: .quiet)) }
                    if row.action(.carryOn) != nil {
                        Button(action: onLooksGood) { Text("Looks good ✦") }.buttonStyle(NWButtonStyle(kind: .bright))
                    } else if row.action(.openOnMac) != nil {
                        Button("Open on Mac", action: onOpen).buttonStyle(NWButtonStyle(kind: .quiet))
                    }
                }
            }
        }
        .padding(NightWatch.Space.lg)
        .background(NWGlassBackground(radius: NightWatch.Radius.card, tint: NightWatch.Palette.teal))
        .accessibilityElement(children: .contain)
    }
}

struct NWTurnChip: View {
    var chip: TurnChip
    var body: some View {
        let c: NightWatch.RGBA
        switch chip.tone {
        case .neutral: c = NightWatch.Palette.textPrimary
        case .added, .pass: c = NightWatch.Palette.green
        // A failed test is amber, never red: red is for two press-and-hold commits only.
        case .removed: c = NightWatch.Palette.red
        case .fail: c = NightWatch.Palette.amber
        }
        return Text(chip.text)
            .font(NightWatch.Typo.monoSmall)
            .foregroundColor(c.opacity(0.95).color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(c.opacity(chip.tone == .neutral ? 0.09 : 0.14).color))
    }
}
