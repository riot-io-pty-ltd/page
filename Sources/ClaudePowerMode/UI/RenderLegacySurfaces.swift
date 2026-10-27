import SwiftUI
import AppKit

/// Harness surfaces for what used to be plain AppKit windows and alerts: the
/// Phone approvals page, the cmux setup, the pairing QR and the dialogs. Every
/// one is built from fixtures (`setFixture`), so nothing reads ~/.claude, the
/// Keychain, a token, cmux or the network.
extension RenderSurfaces {
    @MainActor
    static func legacySurfaces() -> [Surface] {
        let pad: CGFloat = 28
        let w = NWTowerWindow.size.width, h = NWTowerWindow.size.height
        let tall: CGFloat = 1500
        func window(_ store: TowerStore, height: CGFloat = h) -> AnyView {
            AnyView(NWTowerWindow(store: store, height: height).padding(pad).background(NWBackdrop()))
        }
        func surface(_ name: String, _ store: TowerStore, height: CGFloat = h) -> Surface {
            Surface(name: name, width: w + pad * 2, height: height + pad * 2, view: window(store, height: height))
        }
        /// The Tower with a dialog over it, as the live window shows one.
        func dialog(_ name: String, _ spec: NWDialogSpec, store: TowerStore) -> Surface {
            let v = NWTowerWindow(store: store)
                .overlay(ZStack {
                    Color.black.opacity(0.42)
                    NWDialogCard(spec: spec, choose: { _ in })
                })
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(pad).background(NWBackdrop())
            return Surface(name: name, width: w + pad * 2, height: h + pad * 2, view: AnyView(v))
        }

        // MARK: Phone approvals
        typealias Row = TowerHooksModel.AgentRow
        let installed = Row(text: "Installed.", chip: .installed, installTitle: "Reinstall…", canInstall: true, canUninstall: true)
        let notInstalled = Row(text: "Not installed.", chip: .notInstalled, installTitle: "Install…", canInstall: true, canUninstall: false)
        let stale = Row(text: "An older or partial Page hook is installed (/Users/studio/.claude/hooks/page-notify.sh --codex). Update replaces it with the current one.",
                        chip: .needsUpdate, installTitle: "Update…", canInstall: true, canUninstall: true)
        let missing = Row(text: "Codex doesn't seem to be set up for this user (~/.codex is missing).", chip: .unavailable,
                          installTitle: "Install…", canInstall: false, canUninstall: false)
        let claudeDiff = """
        --- ~/.claude/settings.json
        +++ ~/.claude/settings.json
        @@ -1,6 +1,38 @@
         {
           "theme": "dark",
        +  "hooks": {
        +    "PermissionRequest": [
        +      {
        +        "hooks": [
        +          {
        +            "type": "command",
        +            "command": "'/Applications/Page.app/Contents/Resources/hooks/page-notify.sh'",
        +            "timeout": 570,
        +            "statusMessage": "Page: asking your phone (only when you're away)"
        +          }
        +        ]
        +      }
        +    ],
        +    "Notification": [
        +      {
        +        "hooks": [
        +          { "type": "command", "command": "'/Applications/Page.app/Contents/Resources/hooks/page-notify.sh'", "timeout": 30 }
        +        ]
        +      }
        +    ]
        +  },
           "statusLine": { "type": "command", "command": "~/.claude/statusline.sh" }
         }
        """
        let codexDiff = """
        --- ~/.codex/hooks.json
        +++ ~/.codex/hooks.json
        @@ -3,7 +3,7 @@
               "hooks": [
                 {
                   "type": "command",
        -          "command": "'/Users/studio/.claude/hooks/page-notify.sh' --codex",
        +          "command": "'/Applications/Page.app/Contents/Resources/hooks/page-notify.sh' --codex",
                   "timeout": 570
                 }
               ]
        """

        let approvals = TowerFixtures.store(section: .phoneApprovals)
        approvals.hooks.setFixture(claude: installed, codex: stale, codexStop: true, previewAgent: .codex,
                                   preview: .init(path: "~/.codex/hooks.json", text: codexDiff, isDiff: true),
                                   cmuxNote: TowerHookText.cmuxNote(CmuxHookInfo(settingsFiles: 2, withPermissionRequestHook: 2)),
                                   codexWarning: TowerHookText.codexWarning(CodexConfigInfo(hooksFeatureDisabled: true, hasInlineHooks: true)))
        let fresh = TowerFixtures.store(section: .phoneApprovals)
        fresh.hooks.setFixture(claude: notInstalled, codex: missing, previewAgent: .claude,
                               preview: .init(path: "~/.claude/settings.json", text: claudeDiff, isDiff: true))

        // MARK: cmux setup
        let cmuxBlocked = TowerFixtures.store(section: .terminals)
        cmuxBlocked.cmuxSetupOpen = true
        cmuxBlocked.cmux.setFixture(
            version: .init(text: "cmux: cmux 0.62.1 (build 4180)"),
            mode: .init(text: "Socket mode: cmux processes only — cmux blocks Page. Follow the steps below.", tone: .warn),
            passwordStatus: .init(text: "No password saved."))
        let cmuxGood = TowerFixtures.store(section: .terminals)
        cmuxGood.cmuxSetupOpen = true
        cmuxGood.cmux.setFixture(
            version: .init(text: "cmux: cmux 0.62.1 (build 4180)"),
            mode: .init(text: "Socket mode: Automation — Page can connect (no password needed).", tone: .good),
            passwordStatus: .init(text: "A password is saved in your Keychain."), canRemovePassword: true,
            testStatus: .init(text: "Connected — Page can reach your cmux sessions.", tone: .good),
            enableStatus: .init(text: "Done — Page can type into your cmux sessions.", tone: .good))

        // MARK: pairing
        let qr = QRCode.image(from: "page-render-fixture: not a real pairing payload", size: CGSize(width: 300, height: 300))
        let pairing = TowerFixtures.store(section: .pairing)
        pairing.pairing.setFixture(state: .ready(host: "page-relay.roy.workers.dev"), qr: qr, payload: "fixture",
                                   health: .result(text: "✓ Relay is reachable", ok: true))
        let pairingBad = TowerFixtures.store(section: .pairing)
        pairingBad.pairing.setFixture(state: .ready(host: "page-relay.roy.workers.dev"), qr: qr, payload: "fixture",
                                      health: .result(text: "✗ Can’t reach the relay: The request timed out.", ok: false))
        let pairingHidden = TowerFixtures.store(section: .pairing)
        pairingHidden.pairing.setFixture(state: .unknown, revealed: false)
        let pairingSetup = TowerFixtures.store(section: .pairing)
        pairingSetup.pairing.setFixture(state: .setupNeeded(reason: TowerPairingModel.setupReason(relayEnabled: false, urlProblem: nil)))

        // MARK: dialogs
        let hookDialog = TowerHookText.confirmSpec(
            HookChangePlan(agent: .claude, action: .install, fileURL: URL(fileURLWithPath: "/Users/studio/.claude/settings.json"),
                           writeURL: URL(fileURLWithPath: "/Users/studio/.claude/settings.json"),
                           originalData: Data("{}".utf8), originalText: "{}", newText: "{ }"),
            action: .install, agent: .claude, path: "~/.claude/settings.json", diff: claudeDiff)
        let removeDialog = TowerHookText.confirmSpec(
            HookChangePlan(agent: .codex, action: .uninstall, fileURL: URL(fileURLWithPath: "/Users/studio/.codex/hooks.json"),
                           writeURL: URL(fileURLWithPath: "/Users/studio/.codex/hooks.json"),
                           originalData: Data("{}".utf8), originalText: "{}", newText: "{ }"),
            action: .uninstall, agent: .codex, path: "~/.codex/hooks.json", diff: codexDiff)
        let kittyDialog = NWDialogSpec.confirm(
            "Turn on kitty remote control?",
            TerminalCatalog.kittyConfirmText(path: "/Users/studio/.config/kitty/kitty.conf",
                                             added: [KittyConfigFile.allowLine, KittyConfigFile.listenLine],
                                             creating: false),
            ok: "Add the lines", tone: .info)
        let regenerate = NWDialogSpec.confirm(
            "Regenerate the pairing token?",
            "Phones paired with the current token stop receiving pages until they scan the new QR code. Page asks the relay to retire the old token, so (on an up-to-date relay) those phones are told to re-pair. This Mac reconnects with the new token right away.",
            ok: "Regenerate", tone: .warning, destructive: true)
        let lid = NWDialogSpec.confirm(
            "Keep agents running with the lid closed on battery?",
            "While an agent is mid-turn, Page will stop the Mac sleeping when you close the lid on battery. At your low-battery level it asks the agents to pause, then lets the Mac sleep. A closed MacBook in a bag will stay awake and warm while agents work.\n\nmacOS will ask for your password once to allow this.",
            ok: "Turn On", tone: .warning)
        let broken = NWDialogSpec.confirm(
            "config.json couldn’t be read",
            TowerApply.replaceWarning(problem: "Unexpected character at line 14.", backupName: "config.broken-20261027.json"),
            ok: "Replace config.json", tone: .warning, destructive: true)
        let notice = NWDialogSpec.notice("Couldn’t install the power helper",
                                         "The administrator prompt was dismissed, so nothing was installed.")

        return [
            surface("legacy-phone-approvals", approvals),
            surface("legacy-phone-approvals-tall", approvals, height: tall),
            surface("legacy-phone-approvals-fresh-tall", fresh, height: tall),
            surface("legacy-cmux-setup", cmuxBlocked),
            surface("legacy-cmux-setup-tall", cmuxBlocked, height: tall),
            surface("legacy-cmux-setup-good-tall", cmuxGood, height: tall),
            surface("legacy-pairing", pairing),
            surface("legacy-pairing-hidden", pairingHidden),
            surface("legacy-pairing-unreachable", pairingBad),
            surface("legacy-pairing-setup-needed", pairingSetup),
            dialog("legacy-dialog-install-hooks", hookDialog, store: approvals),
            dialog("legacy-dialog-remove-hooks", removeDialog, store: approvals),
            dialog("legacy-dialog-kitty", kittyDialog, store: TowerFixtures.store(section: .terminals)),
            dialog("legacy-dialog-regenerate", regenerate, store: pairing),
            dialog("legacy-dialog-lid-battery", lid, store: TowerFixtures.store(section: .power)),
            dialog("legacy-dialog-broken-config", broken, store: TowerFixtures.store(section: .power)),
            dialog("legacy-dialog-notice", notice, store: TowerFixtures.store(section: .power)),
        ]
    }
}
