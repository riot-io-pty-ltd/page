import Foundation

/// cmux's half of answering a question dialog (AnswerDelivery): reading the pane's screen and pressing one
/// key into the open dialog. Measured on cmux with Claude Code 2.1.311: `read-screen` returns the dialog as
/// plain text; `send --force -- <digit>`, `send-key --force -- tab|down|up|right|left|enter` and
/// `paste --force -` (the Other text, no Return added) each act exactly as in tmux.
extension CmuxBridge {
    /// The pane's visible screen as plain text.
    static func screen(_ target: Target) -> String? {
        guard ClaudeSessionRegistry.isValidSessionId(target.surfaceId),
              case .success(let client) = connect(cliPath: target.cliPath),
              case .success(let text) = client.run(["read-screen", "--surface", target.surfaceId],
                                                     timeout: 5, fallback: "Couldn't read that cmux pane") else { return nil }
        return text
    }

    /// Claude Code's last dialog screen, where `1` submits the answers.
    static func isReviewScreen(_ screen: String) -> Bool {
        screen.contains("Review your answers") && screen.contains("Ready to submit your answers?")
            && screen.contains("1. Submit answers")
    }

    /// Pastes the Other text into an open dialog. No `--submit`: the Enter is its own key.
    static func pasteIntoDialog(_ client: Client, surface: String, text: String) -> Result<Void, Failure> {
        guard ClaudeSessionRegistry.isValidSessionId(surface) else { return .failure(Failure(paneNotFoundDetail)) }
        return client.run(["paste", "--surface", surface, "--force", "-"], stdin: Data(text.utf8),
                          fallback: "Couldn't type into that cmux pane").map { _ in () }
    }
}

extension InjectionExecutor {
    /// The screen reader the answer flow uses: `screenReader(for:)`, plus cmux (which the reply and approval
    /// flows deliberately leave unread, since cmux gates those on its own input state).
    static func answerScreenReader(for host: TerminalHost) -> (() -> String?)? {
        if case .cmux(let target) = host { return { CmuxBridge.screen(target) } }
        return screenReader(for: host)
    }

    /// One answer key into a cmux pane. The pane's input row must still read as an open dialog first; cmux's
    /// `--force` is only used after that check, and never for Esc.
    static func sendOneKeyViaCmux(_ key: Keystroke, to target: CmuxBridge.Target) -> String? {
        let client: CmuxBridge.Client
        switch CmuxBridge.connect(cliPath: target.cliPath) {
        case .failure(let f): return f.detail
        case .success(let c): client = c
        }
        switch client.inputState(surface: target.surfaceId) {
        case .failure(let f): return f.detail
        case .success(let state):
            switch state {
            case .dialog: break
            // cmux reads the question screens as a dialog but not the final "Review your answers" screen
            // (it reports `unknown`, lifecycle running). Accept that one only when the screen shows it.
            case .unknown:
                guard let screen = CmuxBridge.screen(target), CmuxBridge.isReviewScreen(screen) else {
                    return CmuxBridge.noInputBoxDetail
                }
            case .empty, .draft: return promptGoneMessage
            }
        }
        let sent: Swift.Result<Void, CmuxBridge.Failure>
        switch key {
        case .text(let s):
            if s.count == 1, let digit = s.first, digit.isASCII, digit.isNumber {
                sent = client.sendDialogDigit(surface: target.surfaceId, digit: digit)
            } else {
                sent = CmuxBridge.pasteIntoDialog(client, surface: target.surfaceId, text: s)
            }
        case .enter: sent = client.sendKey(surface: target.surfaceId, key: "enter", force: true)
        case .key(let k): sent = client.sendKey(surface: target.surfaceId, key: k.rawValue, force: true)
        case .escape, .pause, .awaitPromptClosed, .paste: return "Page can't press that key in cmux"
        }
        if case .failure(let f) = sent { return f.detail }
        return nil
    }
}
