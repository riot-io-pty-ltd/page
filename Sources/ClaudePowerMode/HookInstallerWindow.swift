import AppKit

/// Opt-in installer for Page's Claude Code / Codex hooks: the approval
/// channel that works in every surface that reads the user's hook config
/// (terminal, cmux, the Claude desktop app's Code sessions, the IDE
/// extensions, Codex CLI / app).
///
/// Nothing is written without an explicit click, and every write is shown
/// first as a diff of the exact file change. The file logic (merge, backup,
/// atomic write, refusing on concurrent edits) lives in HookInstaller; this
/// controller only presents it. Main thread only.
final class HookInstallerWindowController: NSWindowController, NSWindowDelegate {
    static let shared = HookInstallerWindowController()

    private let scriptPath: String?
    private let installer: HookInstaller

    private let claudeStatus = NSTextField(wrappingLabelWithString: "")
    private let codexStatus = NSTextField(wrappingLabelWithString: "")
    private let claudeInstallButton = NSButton(title: "Install…", target: nil, action: nil)
    private let claudeUninstallButton = NSButton(title: "Uninstall…", target: nil, action: nil)
    private let codexInstallButton = NSButton(title: "Install…", target: nil, action: nil)
    private let codexUninstallButton = NSButton(title: "Uninstall…", target: nil, action: nil)
    private let codexStopToggle = NSButton(checkboxWithTitle: "Also let a typed reply continue Codex after it finishes (keeps the finished turn open while you're away)",
                                           target: nil, action: nil)
    private let cmuxNote = NSTextField(wrappingLabelWithString: "")
    private let codexWarning = NSTextField(wrappingLabelWithString: "")
    private let previewPicker = NSSegmentedControl(labels: ["Claude Code", "Codex"], trackingMode: .selectOne, target: nil, action: nil)
    private let previewTitle = NSTextField(labelWithString: "")
    private let previewText = NSTextView()

    private init() {
        let located = HookInstaller.locateScript()
        scriptPath = located
        installer = HookInstaller(homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                                  scriptPath: located ?? "")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Phone Approvals in Every App"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 620)
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // Edits made elsewhere (by hand, by Claude Code) show up on return.
    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    // MARK: layout

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        root.addArrangedSubview(text(
            "When you're away from this Mac, Claude Code and Codex ask your phone instead of waiting at a dialog: "
            + "approve, deny or type a reply. This uses the agents' own hooks, so it works wherever they run on this Mac — "
            + "the terminal, cmux, the Claude desktop app, VS Code and JetBrains, the Codex CLI and app.",
            size: 13, color: .labelColor))
        root.addArrangedSubview(text(
            "Away only: if you've used the keyboard or mouse in the last 2 minutes, the normal dialog appears as usual, "
            + "and touching the Mac while it waits brings the dialog back. Page never approves or denies on its own — "
            + "no answer within \(HookInstaller.hookWaitSeconds / 60) minutes, relay down or anything unexpected, and the agent shows its normal dialog.",
            size: 11, color: .secondaryLabelColor))

        // Claude Code
        root.addArrangedSubview(heading("Claude Code"))
        root.addArrangedSubview(claudeStatus)
        claudeStatus.preferredMaxLayoutWidth = 640
        root.addArrangedSubview(buttonRow(claudeInstallButton, #selector(installClaude),
                                          claudeUninstallButton, #selector(uninstallClaude)))
        root.addArrangedSubview(text(
            "Adds three entries to ~/.claude/settings.json: approvals (PermissionRequest), Claude's questions and plans "
            + "(AskUserQuestion, ExitPlanMode) and notifications. Cloud sessions don't read this file.",
            size: 11, color: .secondaryLabelColor))
        cmuxNote.font = .systemFont(ofSize: 11)
        cmuxNote.textColor = .secondaryLabelColor
        cmuxNote.preferredMaxLayoutWidth = 640
        root.addArrangedSubview(cmuxNote)

        // Codex
        root.addArrangedSubview(heading("Codex"))
        root.addArrangedSubview(codexStatus)
        codexStatus.preferredMaxLayoutWidth = 640
        codexStopToggle.target = self
        codexStopToggle.action = #selector(refreshPreview)
        codexStopToggle.font = .systemFont(ofSize: 12)
        root.addArrangedSubview(codexStopToggle)
        root.addArrangedSubview(buttonRow(codexInstallButton, #selector(installCodex),
                                          codexUninstallButton, #selector(uninstallCodex)))
        root.addArrangedSubview(text(
            "One-time step after installing: open Codex and run /hooks, then trust Page's hooks. Codex skips new or "
            + "changed hooks until you do, and asks again whenever the hook command changes (e.g. after moving Page.app).",
            size: 11, color: .secondaryLabelColor))
        codexWarning.font = .systemFont(ofSize: 11)
        codexWarning.textColor = .systemOrange
        codexWarning.preferredMaxLayoutWidth = 640
        root.addArrangedSubview(codexWarning)

        // Preview
        let previewRow = NSStackView()
        previewRow.orientation = .horizontal
        previewRow.spacing = 10
        previewPicker.selectedSegment = 0
        previewPicker.target = self
        previewPicker.action = #selector(refreshPreview)
        previewTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        previewRow.addArrangedSubview(previewTitle)
        previewRow.addArrangedSubview(previewPicker)
        root.addArrangedSubview(previewRow)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        previewText.isEditable = false
        previewText.isSelectable = true
        previewText.isRichText = true
        previewText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        previewText.textContainerInset = NSSize(width: 6, height: 6)
        previewText.isHorizontallyResizable = true
        previewText.textContainer?.widthTracksTextView = false
        previewText.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        previewText.autoresizingMask = [.width]
        scroll.documentView = previewText
        root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        let footer = NSStackView()
        footer.orientation = .horizontal
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let close = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        footer.addArrangedSubview(spacer)
        footer.addArrangedSubview(close)
        root.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
    }

    private func text(_ s: String, size: CGFloat, color: NSColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: size)
        l.textColor = color
        l.preferredMaxLayoutWidth = 640
        return l
    }

    private func heading(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        return l
    }

    private func buttonRow(_ a: NSButton, _ aAction: Selector, _ b: NSButton, _ bAction: Selector) -> NSStackView {
        a.target = self; a.action = aAction; a.bezelStyle = .rounded
        b.target = self; b.action = bAction; b.bezelStyle = .rounded
        let row = NSStackView(views: [a, b])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    // MARK: state

    private func refresh() {
        let scriptOK = scriptPath != nil
        for (agent, label, install, uninstall) in [
            (HookAgent.claude, claudeStatus, claudeInstallButton, claudeUninstallButton),
            (HookAgent.codex, codexStatus, codexInstallButton, codexUninstallButton)
        ] {
            let st = installer.status(agent)
            label.stringValue = describe(st, agent: agent)
            label.textColor = st.state == .installed ? .systemGreen : .labelColor
            switch st.state {
            case .installed:
                install.title = "Reinstall…"
                install.isEnabled = scriptOK
                uninstall.isEnabled = true
            case .needsUpdate:
                install.title = "Update…"
                install.isEnabled = scriptOK
                uninstall.isEnabled = true
            case .notInstalled:
                install.title = "Install…"
                install.isEnabled = scriptOK
                uninstall.isEnabled = false
            case .agentMissing, .unreadable:
                install.title = "Install…"
                install.isEnabled = false
                uninstall.isEnabled = false
            }
            if agent == .codex, case .installed = st.state { codexStopToggle.state = st.codexStopEnabled ? .on : .off }
            if agent == .codex, case .needsUpdate = st.state { codexStopToggle.state = st.codexStopEnabled ? .on : .off }
        }
        if !scriptOK {
            claudeStatus.stringValue = "Page's hook script wasn't found inside Page.app — reinstall Page to use phone approvals."
            codexStatus.stringValue = claudeStatus.stringValue
        }

        let cmux = installer.cmuxHookInfo()
        if cmux.withPermissionRequestHook > 0 {
            cmuxNote.stringValue = "cmux adds its own approval hook to its sessions (\(cmux.withPermissionRequestHook) found). "
                + "Both hooks run for those sessions, and Claude Code doesn't document how it combines two different approval answers, "
                + "so don't count on one overriding the other. "
                + "For one alert and one predictable decision per prompt, turn off \"Forward notifications to my iPhone\" in cmux and let Page page you."
            cmuxNote.isHidden = false
        } else {
            cmuxNote.isHidden = true
        }

        let codexConfig = installer.codexConfigInfo()
        var warnings: [String] = []
        if codexConfig.hooksFeatureDisabled {
            warnings.append("Hooks are switched off in ~/.codex/config.toml ([features] hooks = false); Codex won't run Page's hook until you turn them back on.")
        }
        if codexConfig.hasInlineHooks {
            warnings.append("~/.codex/config.toml also defines [hooks]; Codex merges both and warns about it at startup.")
        }
        codexWarning.stringValue = warnings.joined(separator: "\n")
        codexWarning.isHidden = warnings.isEmpty
        refreshPreview()
    }

    private func describe(_ st: HookStatus, agent: HookAgent) -> String {
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

    private var previewAgent: HookAgent { previewPicker.selectedSegment == 1 ? .codex : .claude }

    @objc private func refreshPreview() {
        let agent = previewAgent
        previewTitle.stringValue = "What Install changes in:"
        let path = displayPath(installer.fileURL(for: agent))
        guard scriptPath != nil else { setPreview("Page's hook script wasn't found, so there's nothing to preview."); return }
        do {
            let plan = try installer.planInstall(agent, codexStop: agent == .codex && codexStopToggle.state == .on)
            if !plan.changed {
                setPreview("\(path) already has exactly these entries — Install would change nothing.")
            } else {
                setPreview(diffText(plan), isDiff: true)
            }
        } catch {
            setPreview((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private func diffText(_ plan: HookChangePlan) -> String {
        let path = displayPath(plan.fileURL)
        return HookInstaller.unifiedDiff(old: plan.originalText, new: plan.newText,
                                         oldLabel: plan.originalData == nil ? "/dev/null" : path,
                                         newLabel: path)
    }

    private func setPreview(_ s: String, isDiff: Bool = false) {
        previewText.textStorage?.setAttributedString(colored(s, isDiff: isDiff))
        previewText.scrollToBeginningOfDocument(nil)
    }

    private func colored(_ s: String, isDiff: Bool) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let out = NSMutableAttributedString()
        for line in s.components(separatedBy: "\n") {
            var color = NSColor.labelColor
            if isDiff {
                if line.hasPrefix("+++") || line.hasPrefix("---") { color = .secondaryLabelColor }
                else if line.hasPrefix("@@") { color = .systemBlue }
                else if line.hasPrefix("+") { color = .systemGreen }
                else if line.hasPrefix("-") { color = .systemRed }
            }
            out.append(NSAttributedString(string: line + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
        return out
    }

    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    // MARK: actions

    @objc private func installClaude() { run(.install, .claude) }
    @objc private func uninstallClaude() { run(.uninstall, .claude) }
    @objc private func installCodex() { run(.install, .codex) }
    @objc private func uninstallCodex() { run(.uninstall, .codex) }
    @objc private func closeWindow() { window?.close() }

    private func run(_ action: HookChangePlan.Action, _ agent: HookAgent) {
        let plan: HookChangePlan
        do {
            plan = action == .install
                ? try installer.planInstall(agent, codexStop: agent == .codex && codexStopToggle.state == .on)
                : try installer.planUninstall(agent)
        } catch {
            alert("Can't \(action.rawValue) the \(agent.displayName) hooks", (error as? LocalizedError)?.errorDescription ?? "\(error)")
            return
        }
        guard plan.changed else {
            alert(action == .install ? "Already up to date" : "Nothing to remove",
                  action == .install ? "\(displayPath(plan.fileURL)) already has Page's current hook entries."
                                     : "\(displayPath(plan.fileURL)) has no Page hook entries.", style: .informational)
            refresh()
            return
        }

        // Explicit confirmation showing the exact change.
        let confirm = NSAlert()
        confirm.messageText = action == .install
            ? "Install Page's \(agent.displayName) hooks?"
            : "Remove Page's \(agent.displayName) hooks?"
        confirm.informativeText = "Page will change \(displayPath(plan.fileURL)) as shown. "
            + (plan.originalData == nil ? "The file doesn't exist yet and will be created."
                                        : "The current file is saved first as \(plan.writeURL.lastPathComponent).page-backup-<date> next to it.")
            + (action == .uninstall ? " Other tools' hooks are left alone." : "")
        confirm.addButton(withTitle: action == .install ? "Install" : "Remove")
        confirm.addButton(withTitle: "Cancel")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 260))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textStorage?.setAttributedString(colored(diffText(plan), isDiff: true))
        scroll.documentView = tv
        confirm.accessoryView = scroll
        guard let window else { return }
        confirm.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                let backup = try self.installer.apply(plan)
                self.refresh()
                var msg = backup.map { "Backup: \(self.displayPath($0))" } ?? ""
                if action == .install && agent == .codex {
                    msg = "Now open Codex and run /hooks to trust Page's hook — Codex won't run it until you do."
                        + (msg.isEmpty ? "" : "\n\n" + msg)
                }
                if action == .install && agent == .claude {
                    msg = "Claude Code picks this up automatically, including sessions that are already running."
                        + (msg.isEmpty ? "" : "\n\n" + msg)
                }
                self.alert(action == .install ? "Hooks installed" : "Hooks removed", msg, style: .informational)
            } catch {
                self.refresh()
                self.alert("Couldn't \(action.rawValue) the \(agent.displayName) hooks",
                           (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    private func alert(_ title: String, _ text: String, style: NSAlert.Style = .warning) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = style
        if let window, window.isVisible { a.beginSheetModal(for: window) } else { a.runModal() }
    }
}
