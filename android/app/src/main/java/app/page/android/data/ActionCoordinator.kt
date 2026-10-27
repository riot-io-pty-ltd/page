package app.page.android.data

import app.page.android.model.ActionGate
import app.page.android.model.CommitGesture
import app.page.android.model.HoldRingSpec
import app.page.android.model.NowRow
import app.page.android.model.PendingAction
import app.page.android.model.ReplyMapping
import app.page.android.model.ReplyOutcome
import app.page.android.model.ReplyRequest
import app.page.android.model.RowAction
import app.page.android.model.ArmSpec
import app.page.android.model.ReplyAction
import java.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Sends the actions a card or sheet asks for, through the one path that exists ([RelayClient.reply]). It adds
 * the Receipt thread's first phase (ARM: a 1.2 s local ring with Cancel, during which nothing has left the
 * phone), the biometric check for an Irreversible approve, and a still-live check before every send. It never
 * retries an approval by itself. (iOS ActionCoordinator.swift.)
 *
 * What it sends, by action: approve is option 1, deny is Esc, a written reply is Esc, then the text, then
 * Return (the Mac's reply planner does that; the phone only says `custom`), carry on is the user's carry-on
 * message. There is no "2" and no standing permission here.
 */
object ActionCoordinator {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private val _pending = MutableStateFlow<Map<String, PendingAction>>(emptyMap())

    /** Actions in the 1.2 s arm window, or just fired and not yet in `deliveries`. */
    val pending: StateFlow<Map<String, PendingAction>> = _pending.asStateFlow()

    private val _localProblems = MutableStateFlow<Map<String, String>>(emptyMap())

    /** A local reason an action did not start (no screen lock, the check failed). */
    val localProblems: StateFlow<Map<String, String>> = _localProblems.asStateFlow()

    private val jobs = HashMap<String, Job>()

    /**
     * The active Mac changed: nothing started against the old one may carry on or report against the new one.
     * Cancels every ring and clears every entry. Nothing is sent by this; a send already in flight is the relay's.
     */
    fun reset() {
        jobs.values.forEach { it.cancel() }
        jobs.clear()
        _pending.value = emptyMap()
        _localProblems.value = emptyMap()
    }

    /** The render harness's fixture: actions mid-arm (and local problems), shown as they are, never sent. */
    fun seedForRender(pending: Map<String, PendingAction>, problems: Map<String, String> = emptyMap()) {
        _pending.value = pending
        _localProblems.value = problems
    }

    private fun setPending(id: String, p: PendingAction?) {
        _pending.value = if (p == null) _pending.value - id else _pending.value + (id to p)
    }

    private fun setProblem(id: String, why: String?) {
        _localProblems.value = if (why == null) _localProblems.value - id else _localProblems.value + (id to why)
    }

    /**
     * Starts an action on a row. Every action arms first (a 1.2 s ring that names what will be typed; cancel
     * works until it ends), except an Irreversible approve, whose hold plus biometrics is the arm. [onResult]
     * gets the relay's answer for a send that happened.
     */
    fun begin(row: NowRow, kind: RowAction.Kind, text: String = "", onResult: ((ReplyOutcome) -> Unit)? = null) {
        if (_pending.value[row.id] != null || !ActionGate.isSendable(kind) || ActionGate.requiresBiometrics(kind, row.commit)) return
        // The backstop: a row only ever sends what it offers. A row the phone cannot type into has no Approve.
        if (!canBegin(row, kind)) return
        val request = ReplyMapping.request(kind, text) ?: return
        setProblem(row.id, null)
        val armed = ActionGate.requiresArm(kind, row.commit)
        setPending(row.id, PendingAction(row.id, kind, request.text, row.commit, Instant.now(), armed, row.action(kind)?.preview))
        jobs[row.id] = scope.launch {
            if (armed) delay((ArmSpec.duration * 1000).toLong())
            if (!isActive) return@launch
            fire(row.id, request, onResult)
        }
    }

    /** A row sends an action only when it has that action; a row that can only Open on Mac sends nothing. */
    fun canBegin(row: NowRow, kind: RowAction.Kind): Boolean = row.action(kind) != null

    /**
     * An Irreversible approve: the hold ring has filled. Ask for the fingerprint / face / screen lock; only if
     * the owner confirms does anything send.
     */
    fun commitHold(row: NowRow, macName: String, onResult: ((ReplyOutcome) -> Unit)? = null) {
        if (_pending.value[row.id] != null || row.commit != CommitGesture.HOLD || row.action(RowAction.Kind.APPROVE) == null) return
        setProblem(row.id, null)
        jobs[row.id] = scope.launch {
            val reason = HoldRingSpec.biometricReasonApproving(row.summary, macName)
            when (val result = BiometricGate.confirm(reason)) {
                BiometricGate.Outcome.Passed -> {
                    setPending(row.id, PendingAction(row.id, RowAction.Kind.APPROVE, "", CommitGesture.HOLD, Instant.now(), false))
                    fire(row.id, ReplyRequest(ReplyAction.APPROVE, ""), onResult)
                }
                BiometricGate.Outcome.Cancelled -> Unit
                is BiometricGate.Outcome.Unavailable -> setProblem(row.id, result.why)
            }
        }
    }

    /** Cancels a ring that has not run out. Once the send began there is nothing to cancel: a keystroke cannot be taken back. */
    fun cancel(rowId: String) {
        val p = _pending.value[rowId] ?: return
        if (!p.armed || p.phase(Instant.now()) !is PendingAction.Phase.Arming) return
        jobs.remove(rowId)?.cancel()
        setPending(rowId, null)
    }

    fun isArming(rowId: String, now: Instant = Instant.now()): Boolean =
        _pending.value[rowId]?.phase(now) is PendingAction.Phase.Arming

    private suspend fun fire(rowId: String, request: ReplyRequest, onResult: ((ReplyOutcome) -> Unit)?) {
        // Still-live check: if the page was answered at the Mac while the ring ran, nothing is sent.
        if (RelayClient.inbox.value.none { it.id == rowId }) {
            setPending(rowId, null)
            jobs.remove(rowId)
            setProblem(rowId, "Already answered at the Mac")
            return
        }
        _pending.value[rowId]?.let { setPending(rowId, it.copy(armed = false)) }
        val outcome = RelayClient.reply(rowId, request.text, request.action)
        setPending(rowId, null)
        jobs.remove(rowId)
        onResult?.invoke(outcome)
    }
}
