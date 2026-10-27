import SwiftUI
import Combine

private typealias P = NightWatch.Palette

// MARK: - Terminals page

/// Every terminal Page can type into: what it does there, whether it is
/// installed, in use or needs a step, and the one button for that step. The
/// rows come from `TerminalCatalog` (pure); the facts from `TerminalProbe`,
/// looked at when the page opens and every few seconds while it is on screen.
struct NWTerminalsPage: View {
    @ObservedObject var store: TowerStore

    /// `@State`: the view struct is rebuilt on every snapshot, and a timer
    /// made in each rebuild would start its 8 seconds over every time.
    @State private var tick = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    var body: some View {
        let rows = store.terminalRows
        if store.cmuxSetupOpen {
            NWCmuxSetupPage(store: store)
        } else {
        NWPage(section: .terminals) {
            NWCard(title: rows.isEmpty ? "WORKS WITH" : "WORKS WITH · " + TerminalCatalog.summary(rows).uppercased()) {
                if rows.isEmpty {
                    ForEach(Array(TerminalCatalog.entries.enumerated()), id: \.element.id) { n, entry in
                        if n > 0 { NWDivider() }
                        NWTerminalRow(name: entry.name, symbol: entry.symbol, capabilityLine: entry.capabilities.line,
                                      note: "Looking at this Mac…", status: nil, action: nil, perform: {})
                    }
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { n, row in
                        if n > 0 { NWDivider() }
                        NWTerminalRow(name: row.name, symbol: row.symbol, capabilityLine: row.capabilityLine,
                                      note: row.note, noteIsWarning: row.noteIsWarning, status: row.status, action: row.action) {
                            if let action = row.action { store.perform(action, on: row.id) }
                        }
                    }
                }
            }
            if let notice = store.terminalNotice {
                NWNote(text: notice.text, tone: notice.tone).padding(.horizontal, 4)
            }
            NWNote(text: "Run Claude Code inside any of these and it shows up on your phone, ready to answer. Page types only into the exact pane or tab the session runs in, and checks it is still that session first. Anything else (Ghostty, Warp, VS Code’s terminal…) can’t be typed into yet: run the agent inside tmux, or install the agent hooks so approvals work from any terminal. Nothing here is installed for you.")
                .padding(.horizontal, 4)
            NWCard(title: "ANY OTHER TERMINAL") {
                NWRow(title: "Agent hooks", detail: "phone approvals for Claude Code and Codex in any terminal, with a diff and a backup first") {
                    NWButton(title: "Install agent hooks…", kind: .secondary) { store.openPhoneApprovals() }
                }
            }
        }
        .onAppear { store.refreshTerminals() }
        .onReceive(tick) { _ in store.refreshTerminalsIfVisible() }
        }
    }
}

/// One host: icon, name, what Page can do there, what is true now; a status
/// chip and the one action on the right.
struct NWTerminalRow: View {
    var name: String
    var symbol: String
    var capabilityLine: String
    var note: String
    var noteIsWarning = false
    var status: TerminalCatalog.Status?
    var action: TerminalCatalog.Action?
    var perform: () -> Void

    static let chipWidth: CGFloat = 118
    static let buttonWidth: CGFloat = 100

    private var chipColor: NightWatch.RGBA {
        switch status {
        case .inUse?: return P.teal
        case .ready?: return P.green
        case .notChecked?: return P.textSecondary
        case .needsSetup?: return P.amber
        case .notInstalled?, nil: return P.textTertiary
        }
    }

    private var chipSymbol: String? {
        switch status {
        case .inUse?: return "circle.fill"
        case .ready?: return "checkmark.circle.fill"
        case .notChecked?: return "questionmark.circle"
        case .needsSetup?: return "exclamationmark.triangle.fill"
        case .notInstalled?, nil: return nil
        }
    }

    private var noteColor: NightWatch.RGBA {
        if noteIsWarning { return P.amber }
        return P.textTertiary
    }

    private var installed: Bool {
        if case .notInstalled? = status { return false }
        return true
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(Font.system(size: 15, weight: .medium))
                .foregroundColor((installed ? P.textSecondary : P.textQuiet).color)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(Font.system(size: 13.5, weight: .semibold))
                    .foregroundColor((installed ? P.textPrimary : P.textSecondary).color)
                Text(capabilityLine)
                    .font(Font.system(size: 11.5))
                    .foregroundColor(P.textTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
                Text(note)
                    .font(Font.system(size: 11.5))
                    .foregroundColor(noteColor.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            NWStateChip(text: status?.chipText ?? "Checking…", color: chipColor, symbol: chipSymbol)
                .frame(width: Self.chipWidth, alignment: .trailing)
            Group {
                if let action {
                    NWButton(title: action.title, kind: isNeedsSetup && action != .undo ? .primary : .secondary, action: perform)
                } else {
                    Color.clear
                }
            }
            .frame(width: Self.buttonWidth, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 66)
        .accessibilityElement(children: .combine)
    }

    private var isNeedsSetup: Bool {
        if case .needsSetup? = status { return true }
        return false
    }
}
