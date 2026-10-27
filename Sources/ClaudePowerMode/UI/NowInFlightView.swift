import SwiftUI

// The In-flight group: sessions working right now, as cards as big as the
// review rows, so the whole state of the work reads at a glance: what each
// one is doing now and did just before, how long this turn and the session
// have run, the workflows inside it, and whether it looks well. A card has
// two buttons in words, "Open" (its terminal pane) and "Steer" (a message to
// it, in a composer inside the card with a live preview of what Return will
// do and a receipt after). Clicking the card itself opens it. All state lives
// in `NowStore`, so the render harness can set any of it.

// MARK: - Group

struct NWInFlightGroup: View {
    @ObservedObject var store: NowStore
    /// The tallest the cards may be before they scroll (the popover must fit the screen).
    var maxCardsHeight: CGFloat = 640

    var body: some View {
        let rows = store.flightRows
        let collapsed = store.state.inFlightCollapsed
        let layout = InFlightLayout.visible(rows, collapsed: collapsed, expanded: store.state.inFlightExpanded)
        VStack(alignment: .leading, spacing: 8) {
            header(rows: rows, collapsed: collapsed)
            if !collapsed {
                let summary = InFlightLayout.summary(rows)
                if !summary.isEmpty {
                    Text(summary)
                        .font(NightWatch.Typo.monoMicro)
                        .foregroundColor(NightWatch.Palette.textTertiary.color)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 6)
                        .accessibilityLabel(Text(summary))
                }
                cards(layout.shown, firstId: rows.first?.id)
                if layout.more > 0 {
                    Button { store.setInFlightExpanded(true) } label: {
                        Text(InFlightLayout.showAllTitle(total: rows.count))
                            .font(Font.system(size: 11.5, weight: .medium))
                            .foregroundColor(NightWatch.Palette.teal.color)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Show all \(rows.count) sessions in flight"))
                } else if store.state.inFlightExpanded && rows.count > InFlightLayout.cap {
                    Button { store.setInFlightExpanded(false) } label: {
                        Text("Show fewer")
                            .font(Font.system(size: 11.5, weight: .medium))
                            .foregroundColor(NightWatch.Palette.textTertiary.color)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .id(InFlightLayout.anchorId)
    }

    /// The cards, in a scroller that only scrolls once they outgrow the screen.
    private func cards(_ shown: [InFlightRow], firstId: String?) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 8) {
                    ForEach(shown) { row in
                        NWInFlightRowView(store: store, row: row)
                    }
                }
                .padding(.trailing, 1)
            }
            .frame(maxHeight: maxCardsHeight)
            .onChange(of: store.flightJumpToken) { _ in
                if let id = firstId { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .top) } }
            }
        }
    }

    private func header(rows: [InFlightRow], collapsed: Bool) -> some View {
        let working = rows.filter(\.working)
        return Button { store.setInFlightCollapsed(!collapsed) } label: {
            HStack(spacing: 8) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(Font.system(size: 8, weight: .bold))
                    .foregroundColor(NightWatch.Palette.textTertiary.color)
                    .frame(width: 10)
                Circle().fill(NightWatch.Palette.teal.color).frame(width: 6, height: 6)
                Text(InFlightLayout.title(count: working.count).uppercased()).nwLabel()
                if collapsed {
                    Text(InFlightLayout.names(working))
                        .font(NightWatch.Typo.monoMicro)
                        .foregroundColor(NightWatch.Palette.textSecondary.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show the sessions in flight" : "Hide the sessions in flight")
        .accessibilityLabel(Text("\(InFlightLayout.title(count: working.count)), \(collapsed ? "collapsed" : "expanded")"))
        .accessibilityHint(Text("Shows or hides the working sessions"))
    }
}

// MARK: - Card

struct NWInFlightRowView: View {
    @ObservedObject var store: NowStore
    var row: InFlightRow

    private var selected: Bool { store.selectedId == row.id }
    private var composer: NowPanelState.Composer? {
        guard let c = store.composer, c.rowId == row.id, c.kind == .type else { return nil }
        return c
    }
    private var receipt: InFlightReceipt? { store.flightReceipts[row.id] }
    private var accent: NightWatch.RGBA { row.working ? NightWatch.Palette.teal : NightWatch.Palette.textQuiet }
    private var attention: Bool { row.working && row.card.health.needsAttention }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: NightWatch.Radius.row, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if row.hasCard {
                // The card itself is the Open button: everything above the buttons.
                info
                    .contentShape(Rectangle())
                    .onTapGesture { store.clickFlight(.open, on: row) }
                    .help(row.actions.canOpen || row.actions.checking ? "Open · \(PanelKeys.open) · shows its terminal pane, types nothing"
                                                                        : (row.actions.openBlocker ?? "Page can't open this one"))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(row.accessibilityText))
                    .accessibilityHint(Text("Opens its terminal"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { store.clickFlight(.open, on: row) }
                actions
            } else {
                compact
            }
            if let c = composer {
                NWFlightComposer(store: store, row: row, composer: c)
            }
            if let r = receipt {
                receiptLine(r)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Color.white.opacity(selected ? 0.08 : 0.045)))
        .overlay(shape.strokeBorder(border, lineWidth: selected || attention ? 1.5 : 1))
        .contentShape(shape)
        .onHover { inside in if inside { store.hoverFlight(row.id, pointer: NSEvent.mouseLocation) } }
        .id(row.id)
    }

    private var border: Color {
        if selected { return NightWatch.Palette.glass.opacity(0.75).color }
        if attention { return NightWatch.Palette.amber.opacity(0.45).color }
        return Color.white.opacity(0.06)
    }

    // MARK: what it is doing

    private var info: some View {
        let card = row.card
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent.opacity(0.8).color)
                    .frame(width: 3, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(row.project)
                            .font(NightWatch.Typo.mono)
                            .foregroundColor(NightWatch.Palette.textPrimary.color)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Spacer(minLength: 4)
                        if !row.working {
                            Text("FINISHED").font(NightWatch.Typo.label).kerning(NightWatch.Typo.labelTracking)
                                .foregroundColor(NightWatch.Palette.textTertiary.color)
                        } else if attention {
                            healthChip
                        }
                    }
                    let who = [card.backendName, card.model, row.route].compactMap { $0 }.joined(separator: " · ")
                    if !who.isEmpty {
                        Text(who)
                            .font(NightWatch.Typo.monoMicro)
                            .foregroundColor(NightWatch.Palette.textTertiary.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            if row.working {
                steps(card)
                if let time = card.timeLine {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(Font.system(size: 10, weight: .medium))
                            .foregroundColor(NightWatch.Palette.textTertiary.color)
                        Text(time)
                            .font(NightWatch.Typo.monoSmall)
                            .foregroundColor(NightWatch.Palette.textSecondary.color)
                            .lineLimit(1)
                    }
                    .help("How long this turn has been working, and how long the session has been open")
                }
                if !card.workflows.isEmpty { workflows(card) }
                healthLine(card)
            } else {
                Text(row.doing)
                    .font(NightWatch.Typo.monoBody)
                    .foregroundColor(NightWatch.Palette.textSecondary.opacity(0.78).color)
            }
        }
    }

    /// NOW: the current step, with the few before it as a timeline.
    private func steps(_ card: InFlightCardInfo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("NOW").nwLabel()
            ZStack(alignment: .topLeading) {
                if !card.earlier.isEmpty {
                    Rectangle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 1)
                        .padding(.leading, 3)
                        .padding(.vertical, 6)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle().fill(NightWatch.Palette.teal.color).frame(width: 7, height: 7)
                            .offset(x: -1)
                        Text(card.now)
                            .font(NightWatch.Typo.monoBody)
                            .foregroundColor(NightWatch.Palette.textPrimary.color)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    ForEach(Array(card.earlier.enumerated()), id: \.offset) { _, text in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Circle().strokeBorder(NightWatch.Palette.textQuiet.color, lineWidth: 1).frame(width: 5, height: 5)
                            Text(text)
                                .font(NightWatch.Typo.monoSmall)
                                .foregroundColor(NightWatch.Palette.textTertiary.color)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            }
        }
    }

    private func workflows(_ card: InFlightCardInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WORKFLOWS · \(card.workflows.count) RUNNING").nwLabel()
            ForEach(Array(card.workflows.prefix(InFlightWire.maxWorkflows).enumerated()), id: \.offset) { _, w in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(w.name)
                            .font(NightWatch.Typo.monoSmall)
                            .foregroundColor(NightWatch.Palette.textPrimary.color)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(w.detail)
                            .font(NightWatch.Typo.monoMicro)
                            .foregroundColor(NightWatch.Palette.textTertiary.color)
                            .lineLimit(1)
                    }
                    if let f = w.fraction {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.08))
                                Capsule().fill(NightWatch.Palette.teal.opacity(0.85).color)
                                    .frame(width: max(3, g.size.width * CGFloat(f)))
                            }
                        }
                        .frame(height: 3)
                    }
                }
            }
            if card.workflows.count > InFlightWire.maxWorkflows {
                Text("+\(card.workflows.count - InFlightWire.maxWorkflows) more")
                    .font(NightWatch.Typo.monoMicro)
                    .foregroundColor(NightWatch.Palette.textTertiary.color)
            }
        }
    }

    private var healthChip: some View {
        let (label, color): (String, NightWatch.RGBA) = {
            switch row.card.health {
            case .looksStuck: return ("LOOKS STUCK", NightWatch.Palette.amber)
            case .rateLimited: return ("RATE LIMITED", NightWatch.Palette.amber)
            case .longStep: return ("LONG STEP", NightWatch.Palette.sky)
            case .normal: return ("", NightWatch.Palette.teal)
            }
        }()
        return Text(label).font(NightWatch.Typo.label).kerning(NightWatch.Typo.labelTracking).foregroundColor(color.color)
    }

    private func healthLine(_ card: InFlightCardInfo) -> some View {
        let attention = card.health.needsAttention
        let color: NightWatch.RGBA = attention ? NightWatch.Palette.amber : NightWatch.Palette.green
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: attention ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .font(Font.system(size: 10, weight: .medium))
                .foregroundColor(color.opacity(attention ? 0.95 : 0.75).color)
            Text(card.health.line(now: store.now()))
                .font(NightWatch.Typo.monoMicro)
                .foregroundColor(color.opacity(attention ? 0.95 : 0.75).color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: buttons

    /// A local model's compact row: it has no terminal to open or type into.
    private var compact: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent.opacity(0.8).color)
                .frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.project)
                    .font(NightWatch.Typo.mono)
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    .lineLimit(1)
                Text(row.doing)
                    .font(NightWatch.Typo.monoBody)
                    .foregroundColor(NightWatch.Palette.textSecondary.opacity(0.78).color)
                    .lineLimit(1)
                Text("Local model · Page can't open or steer it")
                    .font(NightWatch.Typo.monoMicro)
                    .foregroundColor(NightWatch.Palette.textTertiary.color)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(row.accessibilityText))
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                NWActionButton(title: InFlightAction.open.title,
                               enabled: row.actions.canOpen, fills: true,
                               help: row.actions.openBlocker ?? InFlightAction.open.tooltip) {
                    store.clickFlight(.open, on: row)
                }
                NWActionButton(title: InFlightAction.steer.title,
                               enabled: row.actions.canType || row.actions.checking, emphasised: composer != nil, fills: true,
                               help: row.actions.canType ? InFlightAction.steer.tooltip
                                   : (row.actions.typeBlocker ?? InFlightAction.steer.tooltip)) {
                    store.clickFlight(.steer, on: row)
                }
            }
            if let why = blocker {
                Text(why)
                    .font(NightWatch.Typo.monoMicro)
                    .foregroundColor(NightWatch.Palette.textTertiary.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Why a button is dimmed, in words (a tooltip alone can be missed).
    private var blocker: String? {
        if row.actions.checking { return row.actions.typeBlocker }
        if !row.actions.canOpen, let why = row.actions.openBlocker { return why }
        if !row.actions.canType, let why = row.actions.typeBlocker { return "Can't steer here · \(why)" }
        return nil
    }

    // MARK: receipt

    private func receiptLine(_ r: InFlightReceipt) -> some View {
        let color: NightWatch.RGBA = r.failed ? NightWatch.Palette.amber : NightWatch.Palette.teal
        let symbol: String
        switch r.outcome {
        case .sending: symbol = "ellipsis"
        case .typed: symbol = "checkmark"
        case .queued: symbol = "clock"
        case .refused: symbol = "exclamationmark.triangle"
        case .unconfirmed: symbol = "questionmark.circle"
        }
        return HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(Font.system(size: 10, weight: .bold))
                .foregroundColor(color.color)
            Text(r.line())
                .font(NightWatch.Typo.monoMicro)
                .foregroundColor(color.opacity(0.95).color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Composer

/// "Steer": a one-line field in the card. Send (or Return) hands the message
/// to the local session input path; Cancel (or Esc) closes it. Under it, what
/// Return will do, live.
struct NWFlightComposer: View {
    @ObservedObject var store: NowStore
    var row: InFlightRow
    var composer: NowPanelState.Composer
    @FocusState private var focused: Bool
    @Environment(\.nwFixedPhase) private var fixedPhase

    var body: some View {
        let preview = InFlightPreview.line(for: row, text: composer.text, macName: store.model.macName)
        let ready = !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && preview.ok
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(Font.system(size: 12, weight: .medium))
                    .foregroundColor(NightWatch.Palette.teal.color)
                TextField("Steer \(row.card.backendName ?? row.project)…",
                          text: Binding(get: { store.composerText }, set: { store.composerText = $0 }))
                    .textFieldStyle(.plain)
                    .font(Font.system(size: 13))
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    .focused($focused)
                    .accessibilityLabel(Text("Steer \(row.project)"))
                Button { store.submitComposer() } label: {
                    Text("Send")
                        .font(Font.system(size: 12, weight: .semibold))
                        .foregroundColor((ready ? NightWatch.Palette.teal : NightWatch.Palette.textQuiet).color)
                        .padding(.horizontal, 4)
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!ready)
                .help("Send · Return")
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.4)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(NightWatch.Palette.glass.opacity(0.6).color, lineWidth: 1))
            HStack(alignment: .top, spacing: 6) {
                Text(preview.text)
                    .font(NightWatch.Typo.monoMicro)
                    .foregroundColor((preview.ok ? NightWatch.Palette.textTertiary : NightWatch.Palette.amber).color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { store.cancelComposer() } label: {
                    Text("Cancel")
                        .font(Font.system(size: 11, weight: .medium))
                        .foregroundColor(NightWatch.Palette.textTertiary.color)
                        .frame(minHeight: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close the message box · Esc")
            }
            .padding(.leading, 4)
        }
        .onAppear { if fixedPhase == nil { focused = true } }
        .onChange(of: store.composerFocusToken) { _ in focused = true }
    }
}

// MARK: - First-run tip

/// "Click a row for actions · ? shows every shortcut", once, until dismissed.
struct NWTipStrip: View {
    var text: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "lightbulb")
                .font(Font.system(size: 11, weight: .medium))
                .foregroundColor(NightWatch.Palette.teal.color)
            Text(text)
                .font(Font.system(size: 11, weight: .medium))
                .foregroundColor(NightWatch.Palette.textSecondary.color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button(action: onDismiss) {
                Text("Got it")
                    .font(Font.system(size: 11, weight: .semibold))
                    .foregroundColor(NightWatch.Palette.teal.color)
            }
            .buttonStyle(.plain)
            .help("Hide this tip")
            .accessibilityLabel(Text("Dismiss tip"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: NightWatch.Radius.row, style: .continuous)
            .fill(NightWatch.Palette.teal.opacity(0.08).color))
        .overlay(RoundedRectangle(cornerRadius: NightWatch.Radius.row, style: .continuous)
            .strokeBorder(NightWatch.Palette.teal.opacity(0.22).color, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Shortcuts sheet

/// Every key the panel answers to, from `ShortcutCatalog` (the same list as
/// Preferences → Shortcuts), compact, in place of the rows. Esc or ? closes it.
struct NWShortcutsSheet: View {
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SHORTCUTS").nwLabel()
                Spacer()
                Button(action: onClose) {
                    Text("Close")
                        .font(Font.system(size: 11, weight: .medium))
                        .foregroundColor(NightWatch.Palette.textTertiary.color)
                        .padding(.horizontal, 4)
                        .frame(minHeight: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close the shortcuts · Esc")
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
            ForEach(ShortcutCatalog.groups) { group in
                Text(group.title).nwLabel(NightWatch.Palette.textQuiet)
                    .padding(.top, 8)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 3)
                ForEach(group.items) { item in
                    HStack(alignment: .center, spacing: 10) {
                        HStack(spacing: 3) {
                            ForEach(Array(item.keys.enumerated()), id: \.offset) { _, k in
                                NWKeyCap(label: k, compact: true)
                            }
                        }
                        .frame(width: 92, alignment: .leading)
                        Text(item.title)
                            .font(Font.system(size: 11.5, weight: .regular))
                            .foregroundColor(NightWatch.Palette.textSecondary.color)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .frame(minHeight: 22)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("\(item.keys.joined(separator: " ")): \(item.title)"))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
