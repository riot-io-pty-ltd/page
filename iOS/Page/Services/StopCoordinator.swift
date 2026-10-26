import Foundation

/// The Stop flow behind the pulse's long press: the ring has filled, so ask
/// for Face ID / Touch ID / passcode (naming the scope), then press Esc in
/// every busy session through the existing path (`SessionStore.interruptAll`,
/// the same one Siri uses). Letting go early never reaches here, and with
/// nothing busy nothing is sent.
@MainActor
final class StopCoordinator: ObservableObject {
    @Published private(set) var phase: StopFlowPhase = .idle
    private var clearTask: Task<Void, Never>?

    func holdCompleted(plan: StopPlan) {
        guard phase == .idle else { return }
        guard plan.canStop else { show(.nothingBusy); return }
        phase = .authenticating
        Task {
            let result = await BiometricGate.confirm(reason: plan.biometricReason)
            switch result {
            case .cancelled: show(.cancelled)
            case .unavailable(let why): show(.unavailable(why))
            case .passed:
                phase = .sending
                let outcome = await SessionStore.shared.interruptAll()
                if let why = outcome.failureMessage { show(.failed(why)) } else { show(.asked) }
            }
        }
    }

    private func show(_ outcome: StopOutcome) {
        phase = .result(outcome)
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: outcome.isSuccess ? 2_500_000_000 : 3_500_000_000)
            guard !Task.isCancelled else { return }
            self?.phase = .idle
        }
    }
}
