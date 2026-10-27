package app.page.android.data

import android.content.Context
import android.content.pm.PackageManager
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_WEAK
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import app.page.android.BuildConfig
import java.lang.ref.WeakReference
import kotlin.coroutines.resume
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * The fingerprint / face / screen-lock check behind the two deliberate actions: an Irreversible approve and
 * Stop-all. It only answers "did the owner confirm"; what happens next goes through the existing services. The
 * device credential (PIN, pattern, password) stands in when biometrics fail or are not enrolled.
 * (iOS BiometricGate.swift.)
 *
 * On an emulator with nothing enrolled the real prompt reports "unavailable", so only the debug demo has a
 * bypass ([demoBypass]); it exists only in debug builds and only over a demo pairing, never a real one.
 */
object BiometricGate {
    sealed interface Outcome {
        data object Passed : Outcome

        /** The owner cancelled or failed the check: nothing is sent. */
        data object Cancelled : Outcome

        /** This device has no screen lock or biometrics to check against. */
        data class Unavailable(val why: String) : Outcome
    }

    private var activityRef: WeakReference<FragmentActivity>? = null

    /** The activity that can host the prompt (set by MainActivity while it is alive). */
    fun attach(activity: FragmentActivity?) {
        activityRef = activity?.let { WeakReference(it) }
    }

    private const val AUTHENTICATORS = BIOMETRIC_WEAK or DEVICE_CREDENTIAL

    /** True only in a debug build, over the demo pairing: the hold flow can be exercised without enrolled biometrics. */
    val demoBypass: Boolean get() = BuildConfig.DEBUG && PairingStore.isDemoPairing

    /** "fingerprint", "face" or "screen lock", for the line under the hold ring. */
    fun methodName(context: Context): String {
        val pm = context.packageManager
        val usable = BiometricManager.from(context).canAuthenticate(AUTHENTICATORS) == BiometricManager.BIOMETRIC_SUCCESS
        if (!usable) return "screen lock"
        return when {
            pm.hasSystemFeature(PackageManager.FEATURE_FINGERPRINT) -> "fingerprint"
            android.os.Build.VERSION.SDK_INT >= 29 && pm.hasSystemFeature(PackageManager.FEATURE_FACE) -> "face"
            else -> "screen lock"
        }
    }

    /**
     * Asks the owner to confirm. [reason] names the scope ("Stop 4 busy sessions on Studio MBP"), because the
     * prompt is the last thing they read.
     */
    suspend fun confirm(reason: String, title: String = "Confirm with Page"): Outcome {
        if (demoBypass) {
            delay(250)
            return Outcome.Passed
        }
        val activity = activityRef?.get() ?: return Outcome.Unavailable("Confirmation isn't available right now. Open Page and try again.")
        if (BiometricManager.from(activity).canAuthenticate(AUTHENTICATORS) != BiometricManager.BIOMETRIC_SUCCESS) {
            return Outcome.Unavailable("Set a screen lock on this phone to confirm this.")
        }
        return suspendCancellableCoroutine { cont: CancellableContinuation<Outcome> ->
            val executor = ContextCompat.getMainExecutor(activity)
            val prompt = BiometricPrompt(
                activity, executor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        if (cont.isActive) cont.resume(Outcome.Passed)
                    }

                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        // A cancel, a lockout, a dismissed sheet: nothing is sent.
                        if (cont.isActive) cont.resume(Outcome.Cancelled)
                    }
                },
            )
            val info = BiometricPrompt.PromptInfo.Builder()
                .setTitle(title)
                .setDescription(reason)
                .setAllowedAuthenticators(AUTHENTICATORS)
                .build()
            prompt.authenticate(info)
            cont.invokeOnCancellation { runCatching { prompt.cancelAuthentication() } }
        }
    }
}
