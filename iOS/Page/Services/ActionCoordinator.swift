import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Sends the actions a card or sheet asks for, through the one path that
/// exists (`APIClient.reply`). It adds the Receipt thread's first phase
/// (ARM: a 1.2 s local ring with Cancel, during which nothing has left the
/// phone), the biometric check for an Irreversible approve, and a still-live
/// check before every send. It never retries an approval by itself.
///
/// What it sends, by action: approve is option 1, deny is Esc, a written reply
/// is Esc, then the text, then Return (the Mac's reply planner does that; the
/// phone only says `custom`), carry on is the user's carry-on message. There is
/// no "2" and no standing permission here.
@MainActor
final class ActionCoordinator: ObservableObject {
    /// Actions in the 1.2 s arm window, or just fired and not yet in `deliveries`.
    @Published private(set) var pending: [String: PendingAction] = [:]
    /// A local reason an action did not start (no passcode, the check failed).
    @Published private(set) var localProblems: [String: String] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]
    /// Rows whose written reply is waiting out its 10 s Undo (and so is on disk, in case the app is killed).
    private var countdowns: Set<String> = []
    #if canImport(UIKit)
    /// Keeps Page awake through a countdown and its send if the person leaves the app, as the room's outbox does.
    private var background: [String: UIBackgroundTaskIdentifier] = [:]
    #endif
    private let api: APIClient

    private static func outboxId(_ rowId: String) -> String { "page-reply:" + rowId }

    /// `api` is resolved here, on the main actor, rather than in a default
    /// argument (which is evaluated outside it).
    init(api: APIClient? = nil) { self.api = api ?? .shared }

    /// The active Mac changed: nothing started against the old one may carry
    /// on or report against the new one. Cancels every ring and clears every
    /// entry. Nothing is sent by this; a send already in flight is the relay's.
    func reset() {
        for task in tasks.values { task.cancel() }
        for id in countdowns { OutboxFile.remove(id: Self.outboxId(id)); endBackground(id) }
        countdowns = []
        tasks = [:]
        pending = [:]
        localProblems = [:]
    }

    /// Starts an action on a row. Every action arms first (a 1.2 s ring that
    /// names what will be typed; cancel works until it ends), except an
    /// Irreversible approve, whose hold plus biometrics is the arm.
    /// `onResult` gets the relay's answer for a send that happened.
    ///
    /// `countdown`: a written reply to a busy session waits this long (10 s, with Undo) instead of the 1.2 s
    /// ring. It lives here, not in the sheet, so closing the sheet doesn't cancel it.
    func begin(row: NowRow, kind: RowAction.Kind, text: String = "", countdown: TimeInterval? = nil,
               onResult: ((ReplyOutcome) -> Void)? = nil) {
        guard pending[row.id] == nil, ActionGate.isSendable(kind), ActionGate.canBegin(row: row, kind: kind),
              ActionGate.requiresBiometrics(kind: kind, commit: row.commit) == false,
              let request = ReplyMapping.request(for: kind, text: text) else { return }
        localProblems[row.id] = nil
        let armed = ActionGate.requiresArm(kind: kind, commit: row.commit)
        let duration = armed && kind == .tellInstead ? (countdown ?? ArmSpec.duration) : ArmSpec.duration
        let startedAt = Date()
        pending[row.id] = PendingAction(rowId: row.id, kind: kind, text: request.text, commit: row.commit, startedAt: startedAt, armed: armed,
                                        preview: row.action(kind)?.preview, armDuration: duration)
        if armed, duration > 2 {
            // The words are on disk only while the countdown runs: a kill before it ends gives them back as a draft.
            countdowns.insert(row.id)
            OutboxFile.add(PersistedSend(id: Self.outboxId(row.id), scope: OutboxRestore.scope(pageId: row.id), text: request.text,
                                         startedAt: startedAt.timeIntervalSince1970))
            beginBackground(row.id)
        }
        tasks[row.id] = Task { [weak self] in
            if armed { try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) }
            guard let self, !Task.isCancelled else { return }
            await self.fire(rowId: row.id, request: request, onResult: onResult)
        }
    }

    /// An Irreversible approve: the hold ring has filled. Ask for Face ID /
    /// Touch ID / passcode; only if the owner confirms does anything send.
    func commitHold(row: NowRow, macName: String, onResult: ((ReplyOutcome) -> Void)? = nil) {
        guard pending[row.id] == nil, row.commit == .hold, row.action(.approve) != nil else { return }
        localProblems[row.id] = nil
        tasks[row.id] = Task { [weak self] in
            let reason = HoldRingSpec.biometricReason(approving: row.summary, mac: macName)
            let result = await BiometricGate.confirm(reason: reason)
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .passed:
                self.pending[row.id] = PendingAction(rowId: row.id, kind: .approve, text: "", commit: .hold, startedAt: Date(), armed: false)
                await self.fire(rowId: row.id, request: ReplyRequest(action: .approve, text: ""), onResult: onResult)
            case .cancelled:
                break
            case .unavailable(let why):
                self.localProblems[row.id] = why
            }
        }
    }

    /// Cancels a ring that has not run out. Once the send began there is
    /// nothing to cancel: a keystroke cannot be taken back.
    func cancel(_ rowId: String) {
        guard let p = pending[rowId], p.armed, case .arming = p.phase(now: Date()) else { return }
        tasks[rowId]?.cancel()
        tasks[rowId] = nil
        pending[rowId] = nil
        // Undo of a written reply's countdown: nothing was sent, and the words go back to the page's sheet.
        // From a card the sheet that held them may be gone; only a cancel that landed gives them back.
        if countdowns.contains(rowId), p.kind == .tellInstead {
            SessionStore.shared.restoreDraft(scope: OutboxRestore.scope(pageId: rowId), text: p.text, note: RestoredDraft.undoneNote)
        }
        endCountdown(rowId)
        endBackground(rowId)
    }

    func isArming(_ rowId: String, now: Date = Date()) -> Bool {
        if let p = pending[rowId], case .arming = p.phase(now: now) { return true }
        return false
    }

    private func endCountdown(_ rowId: String) {
        guard countdowns.remove(rowId) != nil else { return }
        OutboxFile.remove(id: Self.outboxId(rowId))
    }

    private func beginBackground(_ rowId: String) {
        #if canImport(UIKit)
        guard background[rowId] == nil else { return }
        background[rowId] = UIApplication.shared.beginBackgroundTask(withName: "page-reply-countdown") { [weak self] in
            Task { @MainActor in self?.endBackground(rowId) }
        }
        #endif
    }

    private func endBackground(_ rowId: String) {
        #if canImport(UIKit)
        if let t = background.removeValue(forKey: rowId), t != .invalid { UIApplication.shared.endBackgroundTask(t) }
        #endif
    }

    private func fire(rowId: String, request: ReplyRequest, onResult: ((ReplyOutcome) -> Void)?) async {
        let wasCountdown = countdowns.contains(rowId)
        endCountdown(rowId)
        defer { endBackground(rowId) }
        // A countdown Page slept through (suspended with the sheet closed) is not sent late: the words come back.
        if wasCountdown, let p = pending[rowId],
           SendCountdown(startedAt: p.startedAt, duration: p.armDuration).verdict(now: Date()) == .stale {
            pending[rowId] = nil
            tasks[rowId] = nil
            SessionStore.shared.restoreDraft(scope: OutboxRestore.scope(pageId: rowId), text: request.text, note: RestoredDraft.slept)
            return
        }
        // Still-live check: if the page was answered at the Mac while the ring
        // ran, nothing is sent.
        guard api.inbox.contains(where: { $0.id == rowId }) else {
            pending[rowId] = nil
            tasks[rowId] = nil
            localProblems[rowId] = "Already answered at the Mac"
            // A message that waited 10 s for nothing isn't lost: it is back in the box.
            if wasCountdown, request.action == .custom {
                SessionStore.shared.restoreDraft(scope: OutboxRestore.scope(pageId: rowId), text: request.text)
            }
            return
        }
        if var p = pending[rowId] { p.armed = false; pending[rowId] = p }
        let outcome = await api.reply(to: rowId, text: request.text, action: request.action)
        pending[rowId] = nil
        tasks[rowId] = nil
        onResult?(outcome)
    }
}
