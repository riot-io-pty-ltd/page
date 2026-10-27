package app.page.android.demo

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import app.page.android.model.NotificationsState
import app.page.android.model.PairedWelcome
import app.page.android.ui.nw.onboarding.NWPairStep
import app.page.android.ui.nw.onboarding.NWPairedScreen
import app.page.android.ui.nw.onboarding.NWScanScreen
import app.page.android.ui.nw.onboarding.NWWelcomeScreen
import app.page.android.ui.nw.onboarding.PairStepContent

/** First run, drawn from fixtures (iOS HarnessOnboarding). */
object DemoOnboarding {
    @Composable
    fun Screen(screen: String) {
        when (screen) {
            "welcome" -> NWWelcomeScreen(onTryDemo = {})
            "welcome-notice" -> NWWelcomeScreen(notice = "Pair again" to "Your relay retired the old pairing token. Your old inbox and history were cleared.", onTryDemo = {})
            "scan", "scan-hint" -> NWScanScreen(hint = if (screen == "scan-hint") "That QR code isn't a Page pairing code." else null) {
                Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0.20f, 0.20f, 0.20f), Color(0.13f, 0.13f, 0.13f)))))
            }
            "pair-checking" -> NWPairStep(PairStepContent.Checking("page-relay.workers.dev"), secondaryTitle = "Cancel")
            "pair-confirm" -> NWPairStep(PairStepContent.Confirm("Studio MBP", "page-relay.workers.dev", true, false), onPrimary = {}, primaryTitle = "Pair", secondaryTitle = "Cancel")
            "pair-problem" -> NWPairStep(PairStepContent.Problem("The relay rejected this code", "Show the pairing code on your Mac again and scan the new one."), secondaryTitle = "Start over")
            "paired-denied" -> NWPairedScreen(PairedWelcome.build("Studio MBP", 14, true, NotificationsState.OFF))
            else -> NWPairedScreen(PairedWelcome.build("Studio MBP", 14, true, NotificationsState.NOT_SET))
        }
    }
}
