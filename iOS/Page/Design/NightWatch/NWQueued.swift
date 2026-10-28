import SwiftUI

// Queued messages, drawn: the "Now" / "When it finishes" choice, the 10 s Undo receipt, a message held
// on the Mac with its Delete, a reply queued somewhere deletable, and the 1.2 s ring on the room's Yes
// and No. Plain views over the pure values in `Models/QueuedMessages.swift`; the containers route every
// closure through the stores.

// MARK: - The choice

/// How a message to a busy session goes. Two ways with a segmented control; one fixed way (a session Page
/// can only hold for) in words. Each way gets one short line the first time.
struct NWSendChoiceControl: View {
    var plan: SendChoicePlan
    var agent: String
    /// Say what each way means: until a message has gone out with the choice in front of the person.
    var explain: Bool
    var onChoose: (SendChoice) -> Void

    var body: some View {
        switch plan.mode {
        case .none:
            EmptyView()
        case .holdOnly:
            line(symbol: "clock.badge.checkmark",
                 text: "Held on your Mac: \(agent) can't be typed to mid-turn, so Page types it when it finishes. Delete it any time before.")
        case .choice:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(SendChoice.allCases, id: \.self) { segment($0) }
                }
                .padding(3)
                .background(Capsule().fill(Color.white.opacity(0.07)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                .accessibilityElement(children: .contain)
                if explain {
                    ForEach(SendChoice.allCases, id: \.self) { c in
                        (Text(c.title + "  ").font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.textSecondary.color)
                            + Text(c.explanation(agent: agent)).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 6)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private func segment(_ c: SendChoice) -> some View {
        let on = plan.selected == c
        return Button { onChoose(c) } label: {
            Text(c.title)
                .font(NightWatch.Typo.captionStrong)
                .foregroundColor((on ? NightWatch.Palette.textPrimary : NightWatch.Palette.textTertiary).color)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Capsule().fill(on ? Color.white.opacity(0.14) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(c.spokenTitle))
        .accessibilityHint(Text(c.explanation(agent: agent)))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func line(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(.caption, weight: .semibold)).foregroundColor(NightWatch.Palette.sky.color)
            Text(text).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The receipt for a message

/// The line under the room (and in the Decision sheet's dock) after a send: where the message went, or
/// the countdown it is waiting out, or the Mac holding it. Undo while it counts down, Delete while it
/// is held; every other state reads as before.
struct NWSendReceiptView: View {
    var receipt: SendReceipt
    var onUndo: (String) -> Void = { _ in }
    var onDelete: (String) -> Void = { _ in }
    var onDismiss: (String) -> Void = { _ in }

    var body: some View {
        // The countdown ticks on the display clock until its deadline, then settles.
        NWLiveClock(until: receipt.countdown?.deadline) { now in content(now: now) }
    }

    private var tone: NightWatch.RGBA {
        switch receipt.tone {
        case .good: return NightWatch.Palette.teal
        case .problem: return NightWatch.Palette.amber
        case .held: return NightWatch.Palette.sky
        case .working, .neutral: return NightWatch.Palette.textSecondary
        }
    }

    private func content(now: Date) -> some View {
        let r = receipt
        let deleting = r.note?.isBusy == true
        return HStack(alignment: .top, spacing: 8) {
            icon(now: now)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.countdown?.label(now: now) ?? r.headline)
                    .font(NightWatch.Typo.captionStrong).foregroundColor(tone.color).fixedSize(horizontal: false, vertical: true)
                if let d = r.detail {
                    Text(d).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textTertiary.color).fixedSize(horizontal: false, vertical: true)
                }
                // A photo upload: how far the pieces have got.
                if let p = r.progress {
                    ProgressView(value: min(1, max(0, p))).tint(tone.color).padding(.top, 2).accessibilityHidden(true)
                }
                if let n = r.note {
                    Text(n.text).font(NightWatch.Typo.caption)
                        .foregroundColor((n.isFinal ? NightWatch.Palette.textSecondary : NightWatch.Palette.amber).color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            // The tick is not read out; what is read is the promise (it sends in N seconds unless undone).
            .accessibilityLabel(Text(spoken))
            Spacer(minLength: 0)
            if r.countdown != nil {
                action("Undo", color: NightWatch.Palette.textPrimary, hint: "Nothing is sent and your message goes back in the message box.") { onUndo(r.id) }
            }
            if r.canDelete || deleting {
                if deleting { ProgressView().controlSize(.small).tint(NightWatch.Palette.textSecondary.color).frame(width: 44, height: 44) }
                else { action("Delete", color: NightWatch.Palette.red, hint: "Takes the message back so it is never typed.") { onDelete(r.id) } }
            }
            if r.tone == .problem {
                Button { onDismiss(r.id) } label: {
                    Image(systemName: "xmark").font(.system(.caption, weight: .bold)).foregroundColor(NightWatch.Palette.textTertiary.color)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, r.countdown != nil || r.canDelete ? 4 : 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tone.opacity(0.09).color))
        .accessibilityElement(children: .contain)
    }

    private var spoken: String {
        var parts: [String] = []
        if let cd = receipt.countdown { parts.append("Sending in \(Int(cd.duration)) seconds unless you undo") } else { parts.append(receipt.headline) }
        if let d = receipt.detail { parts.append(d) }
        if let n = receipt.note { parts.append(n.text) }
        return parts.joined(separator: ". ")
    }

    @ViewBuilder private func icon(now: Date) -> some View {
        if let cd = receipt.countdown {
            NWRing(progress: cd.progress(now: now), color: tone, lineWidth: 3, size: 22).padding(.top, 10)
        } else {
            switch receipt.tone {
            case .working: ProgressView().controlSize(.small).tint(tone.color).padding(.top, 2)
            case .good: Image(systemName: "checkmark.circle").foregroundColor(tone.color)
            case .held: Image(systemName: "clock").foregroundColor(tone.color)
            case .neutral: Image(systemName: "trash").foregroundColor(tone.color)
            case .problem: Image(systemName: "exclamationmark.triangle").foregroundColor(tone.color)
            }
        }
    }

    private func action(_ title: String, color: NightWatch.RGBA, hint: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title).font(NightWatch.Typo.captionStrong).foregroundColor(color.color)
                .padding(.horizontal, 6).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(hint))
    }
}

// MARK: - A held message in the story

/// Under a held (or deleted) bubble: Delete, and where a Delete stands.
struct NWHeldActions: View {
    var clientId: String
    var note: RetractNote?
    var canDelete: Bool
    var onDelete: (String) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let n = note {
                Text(n.text).font(NightWatch.Typo.caption)
                    .foregroundColor((n.isFinal ? NightWatch.Palette.textTertiary : NightWatch.Palette.amber).color)
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }
            if canDelete, note?.isBusy != true {
                Button { onDelete(clientId) } label: {
                    Text("Delete").font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.red.color)
                        .padding(.horizontal, 10).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Takes the message back so it is never typed."))
            }
        }
        .padding(.leading, 56)
    }
}

// MARK: - A Yes or No in its ring

/// A Yes or No tapped in the room: the 1.2 s ring and Cancel the decision sheet uses, so a mis-tap on
/// "Should I deploy?" can still be taken back. Nothing is sent until the ring is full.
struct NWArmedReply: View {
    var arm: YesNoArm
    var onCancel: () -> Void

    var body: some View {
        NWLiveClock(until: arm.countdown.deadline) { now in
            Button(action: onCancel) {
                HStack(spacing: 12) {
                    NWRing(progress: arm.countdown.progress(now: now), color: NightWatch.Palette.amber, lineWidth: 3.5, size: 26)
                    Text(arm.label(now: now)).font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                    Spacer(minLength: 0)
                    Text("Cancel").font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.amber.color)
                }
                .padding(.horizontal, 14).padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: NightWatch.Radius.button, style: .continuous).fill(NightWatch.Palette.amber.opacity(0.12).color))
                .overlay(RoundedRectangle(cornerRadius: NightWatch.Radius.button, style: .continuous)
                    .strokeBorder(NightWatch.Palette.amber.opacity(0.4).color, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Sending \(arm.word), tap to cancel"))
            .accessibilityAddTraits(.isButton)
        }
    }
}

// MARK: - A reply that is queued somewhere deletable

/// Under a page reply that is waiting at the relay for an offline Mac, or held on the Mac until a rate
/// limit resets: where it is, a Delete while it can be taken back, and what a Delete said.
struct NWReplyQueueBlock: View {
    var status: ReplyQueueStatus
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                // Asking the Mac (the relay already handed it over): a spinner where the icon is.
                if status.asking {
                    ProgressView().controlSize(.small).tint(NightWatch.Palette.amber.color)
                } else {
                    Image(systemName: status.layer == .relay ? "icloud.and.arrow.up" : "clock.badge.checkmark")
                        .foregroundColor(NightWatch.Palette.amber.color)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.headline).font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                    if let d = status.detail {
                        Text(d).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let n = status.note, !n.isBusy {
                        Text(n.text).font(NightWatch.Typo.caption)
                            .foregroundColor((n.isFinal ? NightWatch.Palette.textSecondary : NightWatch.Palette.amber).color)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if status.note == nil, let why = status.whyNot {
                        // Said up front, so nothing reads as deletable that isn't (old relay, old Mac).
                        Text(why).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            if status.canDelete || status.deleting {
                Button(action: onDelete) {
                    HStack(spacing: 8) {
                        if status.deleting { ProgressView().controlSize(.small).tint(NightWatch.Palette.textSecondary.color) }
                        Text(status.deleting ? "Deleting…" : "Delete")
                    }
                }
                .buttonStyle(NWButtonStyle(kind: .danger))
                .disabled(status.deleting)
                .accessibilityHint(Text(status.layer == .relay ? "Takes the reply back from the relay so it is never typed."
                                        : "Takes the reply back from your Mac so it is never typed."))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: NightWatch.Radius.inset, style: .continuous).fill(NightWatch.Palette.amber.opacity(0.08).color))
    }
}
