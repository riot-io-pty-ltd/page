import Foundation

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
    private let api: APIClient

    /// `api` is resolved here, on the main actor, rather than in a default
    /// argument (which is evaluated outside it).
    init(api: APIClient? = nil) { self.api = api ?? .shared }

    /// The active Mac changed: nothing started against the old one may carry
    /// on or report against the new one. Cancels every ring and clears every
    /// entry. Nothing is sent by this; a send already in flight is the relay's.
    func reset() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        pending = [:]
        localProblems = [:]
    }

    /// Starts an action on a row. Every action arms first (a 1.2 s ring that
    /// names what will be typed; cancel works until it ends), except an
    /// Irreversible approve, whose hold plus biometrics is the arm.
    /// `onResult` gets the relay's answer for a send that happened.
    func begin(row: NowRow, kind: RowAction.Kind, text: String = "", onResult: ((ReplyOutcome) -> Void)? = nil) {
        guard pending[row.id] == nil, ActionGate.isSendable(kind),
              ActionGate.requiresBiometrics(kind: kind, commit: row.commit) == false,
              let request = ReplyMapping.request(for: kind, text: text) else { return }
        localProblems[row.id] = nil
        let armed = ActionGate.requiresArm(kind: kind, commit: row.commit)
        pending[row.id] = PendingAction(rowId: row.id, kind: kind, text: request.text, commit: row.commit, startedAt: Date(), armed: armed,
                                        preview: row.action(kind)?.preview)
        tasks[row.id] = Task { [weak self] in
            if armed { try? await Task.sleep(nanoseconds: UInt64(ArmSpec.duration * 1_000_000_000)) }
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
    }

    func isArming(_ rowId: String, now: Date = Date()) -> Bool {
        if let p = pending[rowId], case .arming = p.phase(now: now) { return true }
        return false
    }

    private func fire(rowId: String, request: ReplyRequest, onResult: ((ReplyOutcome) -> Void)?) async {
        // Still-live check: if the page was answered at the Mac while the ring
        // ran, nothing is sent.
        guard api.inbox.contains(where: { $0.id == rowId }) else {
            pending[rowId] = nil
            tasks[rowId] = nil
            localProblems[rowId] = "Already answered at the Mac"
            return
        }
        if var p = pending[rowId] { p.armed = false; pending[rowId] = p }
        let outcome = await api.reply(to: rowId, text: request.text, action: request.action)
        pending[rowId] = nil
        tasks[rowId] = nil
        onResult?(outcome)
    }
}
