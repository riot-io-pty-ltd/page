package app.page.android.data

import app.page.android.model.StopFlowPhase
import app.page.android.model.StopOutcome
import app.page.android.model.StopPlan
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * The Stop flow behind the pulse's long press: the ring has filled, so ask for the fingerprint / face / screen
 * lock (naming the scope), then press Esc in every busy session through the existing path
 * ([SessionStore.interruptAll]). Letting go early never reaches here, and with nothing busy nothing is sent.
 * (iOS StopCoordinator.swift.)
 */
object StopCoordinator {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val _phase = MutableStateFlow<StopFlowPhase>(StopFlowPhase.Idle)
    val phase: StateFlow<StopFlowPhase> = _phase.asStateFlow()
    private var clearJob: Job? = null

    fun holdCompleted(plan: StopPlan) {
        if (_phase.value != StopFlowPhase.Idle) return
        if (!plan.canStop) { show(StopOutcome.NothingBusy); return }
        _phase.value = StopFlowPhase.Authenticating
        scope.launch {
            when (val result = BiometricGate.confirm(plan.biometricReason)) {
                BiometricGate.Outcome.Cancelled -> show(StopOutcome.Cancelled)
                is BiometricGate.Outcome.Unavailable -> show(StopOutcome.Unavailable(result.why))
                BiometricGate.Outcome.Passed -> {
                    _phase.value = StopFlowPhase.Sending
                    val outcome = SessionStore.interruptAll()
                    val why = outcome.failureMessage
                    show(if (why != null) StopOutcome.Failed(why) else StopOutcome.Asked)
                }
            }
        }
    }

    private fun show(outcome: StopOutcome) {
        _phase.value = StopFlowPhase.Result(outcome)
        clearJob?.cancel()
        clearJob = scope.launch {
            delay(if (outcome.isSuccess) 2500 else 3500)
            _phase.value = StopFlowPhase.Idle
        }
    }

    /** The render harness's fixture: a given phase, shown as is. */
    fun overrideForRender(phase: StopFlowPhase) {
        clearJob?.cancel()
        _phase.value = phase
    }
}
