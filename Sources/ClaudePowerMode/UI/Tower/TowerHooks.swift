import SwiftUI
import Combine

private typealias P = NightWatch.Palette

// MARK: - Model

/// Where Page's hook script is and the installer that edits the agents' hook
/// files. Made once, when the page first needs it (`locateScript` runs then).
struct TowerHookSource {
    let installer: HookInstaller
    /// nil when Page's hook script wasn't found inside the app.
    let scriptPath: String?
}

/// The words of the Phone approvals page, in one place and pure.
enum TowerHookText {
    static let scriptMissing = "Page's hook script wasn't found inside Page.app — reinstall Page to use phone approvals."

    /// Pure. One agent's status line.
    static func describe(_ st: HookStatus, agent: HookAgent) -> String {
        switch st.state {
        case .installed:
            return agent == .codex && st.codexStopEnabled
                ? "Installed (approvals and reply-to-continue)."
                : "Installed."
        case .needsUpdate:
            let paths = Set(st.pageCommands).sorted().joined(separator: ", ")
            return "An older or partial Page hook is installed (\(paths)). Update replaces it with the current one."
        case .notInstalled:
            return "Not installed."
        case .agentMissing:
            return agent == .claude ? "Claude Code doesn't seem to be set up for this user (~/.claude is missing)."
                                    : "Codex doesn't seem to be set up for this user (~/.codex is missing)."
        case .unreadable(let why):
            return why
        }
    }

    /// Pure. The note when cmux adds its own approval hook, or nil.
    static func cmuxNote(_ info: CmuxHookInfo) -> String? {
        guard info.withPermissionRequestHook > 0 else { return nil }
        return "cmux adds its own approval hook to its sessions (\(info.withPermissionRequestHook) found). "
            + "Both hooks run for those sessions, and Claude Code doesn't document how it combines two different approval answers, "
            + "so don't count on one overriding the other. "
            + "For one alert and one predictable decision per prompt, turn off \"Forward notifications to my iPhone\" in cmux and let Page page you."
    }

    /// Pure. What in ~/.codex/config.toml works against the hooks, or nil.
    static func codexWarning(_ info: CodexConfigInfo) -> String? {
        var warnings: [String] = []
        if info.hooksFeatureDisabled {
            warnings.append("Hooks are switched off in ~/.codex/config.toml ([features] hooks = false); Codex won't run Page's hook until you turn them back on.")
        }
        if info.hasInlineHooks {
            warnings.append("~/.codex/config.toml also defines [hooks]; Codex merges both and warns about it at startup.")
        }
        return warnings.isEmpty ? nil : warnings.joined(separator: "\n")
    }

    /// Pure. `~/…` for a path under `home`.
    static func displayPath(_ url: URL, home: String) -> String {
        url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    /// Pure. The question before anything is written: what changes, and where the backup goes.
    static func confirmSpec(_ plan: HookChangePlan, action: HookChangePlan.Action, agent: HookAgent,
                            path: String, diff: String) -> NWDialogSpec {
        let install = action == .install
        let text = "Page will change \(path) as shown. "
            + (plan.originalData == nil ? "The file doesn't exist yet and will be created."
                                        : "The current file is saved first as \(plan.writeURL.lastPathComponent).page-backup-<date> next to it.")
            + (install ? "" : " Other tools' hooks are left alone.")
        return NWDialogSpec.confirm(install ? "Install Page's \(agent.displayName) hooks?" : "Remove Page's \(agent.displayName) hooks?",
                                    text, ok: install ? "Install" : "Remove",
                                    tone: install ? .info : .warning, destructive: !install, detail: .diff(diff))
    }

    /// Pure. What the success dialog says after a write.
    static func doneText(action: HookChangePlan.Action, agent: HookAgent, backupPath: String?) -> String {
        var msg = backupPath.map { "Backup: \($0)" } ?? ""
        if action == .install && agent == .codex {
            msg = "Now open Codex and run /hooks to trust Page's hook — Codex won't run it until you do."
                + (msg.isEmpty ? "" : "\n\n" + msg)
        }
        if action == .install && agent == .claude {
            msg = "Claude Code picks this up automatically, including sessions that are already running."
                + (msg.isEmpty ? "" : "\n\n" + msg)
        }
        return msg
    }
}

/// Phone approvals: whether Page's hooks are in Claude Code's and Codex's
/// files, and the Install / Uninstall flow. This only presents `HookInstaller`
/// (merge, backup, atomic write, refusing on concurrent edits all live there).
/// Nothing is written without a click and a confirmation showing the diff.
/// Main thread only.
final class TowerHooksModel: ObservableObject {
    struct AgentRow: Equatable {
        enum Chip: Equatable { case installed, needsUpdate, notInstalled, unavailable }
        var text = "Checking…"
        var chip: Chip = .unavailable
        var installTitle = "Install…"
        var canInstall = false
        var canUninstall = false
    }

    struct Preview: Equatable {
        var path = ""
        var text = ""
        var isDiff = false
    }

    @Published private(set) var claude = AgentRow()
    @Published private(set) var codex = AgentRow()
    /// Also let a typed reply continue Codex after it finishes.
    @Published var codexStop = false {
        didSet { if codexStop != oldValue { refreshPreview() } }
    }
    @Published var previewAgent: HookAgent = .claude {
        didSet { if previewAgent != oldValue { refreshPreview() } }
    }
    @Published private(set) var preview = Preview()
    @Published private(set) var cmuxNote: String?
    @Published private(set) var codexWarning: String?

    private weak var store: TowerStore?
    private var source: TowerHookSource?
    private var sourceAsked = false

    init(store: TowerStore) { self.store = store }

    func row(_ agent: HookAgent) -> AgentRow { agent == .claude ? claude : codex }

    /// The installer, asked for once (the live window makes it then).
    private var live: TowerHookSource? {
        if !sourceAsked {
            sourceAsked = true
            source = store?.env.hookSource()
        }
        return source
    }

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    // MARK: state

    /// Reads both agents' files again. Runs when the page opens and when the
    /// window comes back, so an edit made elsewhere shows up.
    func refresh() {
        guard let src = live else { return }
        let installer = src.installer
        let scriptOK = src.scriptPath != nil
        for agent in HookAgent.allCases {
            let st = installer.status(agent)
            var r = AgentRow()
            r.text = scriptOK ? TowerHookText.describe(st, agent: agent) : TowerHookText.scriptMissing
            switch st.state {
            case .installed:
                r.chip = .installed
                r.installTitle = "Reinstall…"
                r.canInstall = scriptOK
                r.canUninstall = true
            case .needsUpdate:
                r.chip = .needsUpdate
                r.installTitle = "Update…"
                r.canInstall = scriptOK
                r.canUninstall = true
            case .notInstalled:
                r.chip = .notInstalled
                r.canInstall = scriptOK
            case .agentMissing, .unreadable:
                r.chip = .unavailable
            }
            if agent == .claude { claude = r } else { codex = r }
            if agent == .codex {
                switch st.state {
                case .installed, .needsUpdate: codexStop = st.codexStopEnabled
                default: break
                }
            }
        }
        cmuxNote = TowerHookText.cmuxNote(installer.cmuxHookInfo())
        codexWarning = TowerHookText.codexWarning(installer.codexConfigInfo())
        refreshPreview()
    }

    func refreshPreview() {
        guard let src = live else { return }
        let agent = previewAgent
        let path = displayPath(src.installer.fileURL(for: agent))
        guard src.scriptPath != nil else {
            preview = Preview(path: path, text: "Page's hook script wasn't found, so there's nothing to preview.", isDiff: false)
            return
        }
        do {
            let plan = try src.installer.planInstall(agent, codexStop: agent == .codex && codexStop)
            if !plan.changed {
                preview = Preview(path: path, text: "\(path) already has exactly these entries — Install would change nothing.", isDiff: false)
            } else {
                preview = Preview(path: path, text: diffText(plan), isDiff: true)
            }
        } catch {
            preview = Preview(path: path, text: (error as? LocalizedError)?.errorDescription ?? "\(error)", isDiff: false)
        }
    }

    /// Sets what the page shows without reading anything: the render harness and tests.
    func setFixture(claude: AgentRow, codex: AgentRow, codexStop: Bool = false, previewAgent: HookAgent = .claude,
                    preview: Preview, cmuxNote: String? = nil, codexWarning: String? = nil) {
        sourceAsked = true
        self.claude = claude
        self.codex = codex
        self.codexStop = codexStop
        self.previewAgent = previewAgent
        self.preview = preview
        self.cmuxNote = cmuxNote
        self.codexWarning = codexWarning
    }

    // MARK: actions

    func displayPath(_ url: URL) -> String { TowerHookText.displayPath(url, home: home) }

    private func diffText(_ plan: HookChangePlan) -> String {
        let path = displayPath(plan.fileURL)
        return HookInstaller.unifiedDiff(old: plan.originalText, new: plan.newText,
                                         oldLabel: plan.originalData == nil ? "/dev/null" : path,
                                         newLabel: path)
    }

    private func notice(_ title: String, _ text: String, tone: NWDialogSpec.Tone = .warning) {
        _ = store?.ask(.notice(title, text, tone: tone))
    }

    /// Install… / Uninstall…: plan, show the exact change, and write only if confirmed.
    func run(_ action: HookChangePlan.Action, _ agent: HookAgent) {
        guard let src = live, let store else { return }
        if action == .install, src.scriptPath == nil {
            notice("Can't install the \(agent.displayName) hooks", TowerHookText.scriptMissing)
            return
        }
        let installer = src.installer
        let plan: HookChangePlan
        do {
            plan = action == .install
                ? try installer.planInstall(agent, codexStop: agent == .codex && codexStop)
                : try installer.planUninstall(agent)
        } catch {
            notice("Can't \(action.rawValue) the \(agent.displayName) hooks", (error as? LocalizedError)?.errorDescription ?? "\(error)")
            return
        }
        guard plan.changed else {
            notice(action == .install ? "Already up to date" : "Nothing to remove",
                   action == .install ? "\(displayPath(plan.fileURL)) already has Page's current hook entries."
                                      : "\(displayPath(plan.fileURL)) has no Page hook entries.", tone: .info)
            refresh()
            return
        }
        // Explicit confirmation showing the exact change.
        let spec = TowerHookText.confirmSpec(plan, action: action, agent: agent, path: displayPath(plan.fileURL), diff: diffText(plan))
        guard store.ask(spec) == 0 else { return }
        do {
            let backup = try installer.apply(plan)
            refresh()
            notice(action == .install ? "Hooks installed" : "Hooks removed",
                   TowerHookText.doneText(action: action, agent: agent, backupPath: backup.map { displayPath($0) }), tone: .info)
        } catch {
            refresh()
            notice("Couldn't \(action.rawValue) the \(agent.displayName) hooks", (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }
}

// MARK: - Page

/// Phone approvals: Page's hooks in Claude Code and Codex, so approvals reach
/// the phone from every app, with the exact change shown first.
struct NWPhoneApprovalsPage: View {
    @ObservedObject var store: TowerStore
    @ObservedObject var model: TowerHooksModel

    init(store: TowerStore) {
        self.store = store
        self.model = store.hooks
    }

    var body: some View {
        NWPage(section: .phoneApprovals) {
            NWCard(title: "HOW IT WORKS") {
                NWRow(title: "Approve from your phone, in any app",
                      detail: "When you're away from this Mac, Claude Code and Codex ask your phone instead of waiting at a dialog: "
                        + "approve, deny or type a reply. This uses the agents' own hooks, so it works wherever they run on this Mac — "
                        + "the terminal, cmux, the Claude desktop app, VS Code and JetBrains, the Codex CLI and app.") {
                    Image(systemName: "iphone").font(Font.system(size: 18)).foregroundColor(P.teal.color)
                }
                NWDivider()
                NWRow(title: "Away only",
                      detail: "If you've used the keyboard or mouse in the last 2 minutes, the normal dialog appears as usual, "
                        + "and touching the Mac while it waits brings the dialog back. Page never approves or denies on its own — "
                        + "no answer within \(HookInstaller.hookWaitSeconds / 60) minutes, relay down or anything unexpected, and the agent shows its normal dialog.") {
                    Image(systemName: "moon.zzz").font(Font.system(size: 16)).foregroundColor(P.textTertiary.color)
                }
            }
            NWNote(text: "Install and Uninstall write to the agents’ own files straight away, once you confirm the change shown. They are not part of Apply.")
                .padding(.horizontal, 4).padding(.top, -10)

            NWCard(title: "CLAUDE CODE") {
                NWHookAgentRow(agent: .claude, row: model.claude) { model.run($0, .claude) }
                NWDivider()
                NWNote(text: "Adds three entries to ~/.claude/settings.json: approvals (PermissionRequest), Claude's questions and plans "
                       + "(AskUserQuestion, ExitPlanMode) and notifications. Cloud sessions don't read this file.")
                    .padding(.horizontal, 16).padding(.vertical, 12)
                if let note = model.cmuxNote {
                    NWDivider()
                    NWNote(text: note).padding(.horizontal, 16).padding(.vertical, 12)
                }
            }

            NWCard(title: "CODEX") {
                NWHookAgentRow(agent: .codex, row: model.codex) { model.run($0, .codex) }
                NWDivider()
                NWToggleRow(title: "Also let a typed reply continue Codex after it finishes",
                            detail: "keeps the finished turn open while you're away",
                            isOn: Binding(get: { model.codexStop }, set: { model.codexStop = $0 }))
                NWDivider()
                NWNote(text: "One-time step after installing: open Codex and run /hooks, then trust Page's hooks. Codex skips new or "
                       + "changed hooks until you do, and asks again whenever the hook command changes (e.g. after moving Page.app).")
                    .padding(.horizontal, 16).padding(.vertical, 12)
                if let warning = model.codexWarning {
                    NWDivider()
                    NWNote(text: warning, tone: .bad).padding(.horizontal, 16).padding(.vertical, 12)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("WHAT INSTALL CHANGES IN").nwLabel().padding(.leading, 4)
                    Text(model.preview.path)
                        .font(Font.system(size: 11.5, design: .monospaced))
                        .foregroundColor(P.textSecondary.color)
                    Spacer(minLength: 8)
                    NWSegmented(options: [(HookAgent.claude, "Claude Code"), (HookAgent.codex, "Codex")],
                                selection: Binding(get: { model.previewAgent }, set: { model.previewAgent = $0 }), height: 28)
                }
                NWCodeBlock(text: model.preview.text.isEmpty ? " " : model.preview.text,
                            diff: model.preview.isDiff, maxHeight: 300)
            }
        }
    }
}

/// One agent: name, what is true now, a chip, and Install / Uninstall.
struct NWHookAgentRow: View {
    var agent: HookAgent
    var row: TowerHooksModel.AgentRow
    var run: (HookChangePlan.Action) -> Void

    private var chip: (text: String, color: NightWatch.RGBA, symbol: String?) {
        switch row.chip {
        case .installed: return ("Installed", P.teal, "checkmark.circle.fill")
        case .needsUpdate: return ("Update available", P.amber, "exclamationmark.triangle.fill")
        case .notInstalled: return ("Not installed", P.textTertiary, nil)
        case .unavailable: return ("Unavailable", P.textTertiary, nil)
        }
    }

    var body: some View {
        let c = chip
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.displayName)
                    .font(Font.system(size: 13.5, weight: .semibold))
                    .foregroundColor(P.textPrimary.color)
                Text(row.text)
                    .font(Font.system(size: 11.5))
                    .foregroundColor((row.chip == .installed ? P.green : P.textTertiary).color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            NWStateChip(text: c.text, color: c.color, symbol: c.symbol)
            HStack(spacing: 8) {
                NWButton(title: row.installTitle, kind: row.chip == .installed ? .secondary : .primary, enabled: row.canInstall) { run(.install) }
                NWButton(title: "Uninstall…", kind: .secondary, enabled: row.canUninstall) { run(.uninstall) }
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(minHeight: 60)
    }
}
