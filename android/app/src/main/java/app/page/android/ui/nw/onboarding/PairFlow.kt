package app.page.android.ui.nw.onboarding

import android.Manifest
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.AppRouter
import app.page.android.data.NowStore
import app.page.android.data.PairingStore
import app.page.android.data.RelayClient
import app.page.android.data.SessionStore
import app.page.android.demo.Demo
import app.page.android.model.NotificationsState
import app.page.android.model.PairedWelcome
import app.page.android.model.PairingResult
import app.page.android.model.PairingValidator
import app.page.android.model.TokenRetirement
import app.page.android.model.ValidatedPairing
import app.page.android.notify.NotificationAccess
import app.page.android.ui.nw.components.NWBackdrop
import app.page.android.ui.nw.components.NWButton
import app.page.android.ui.nw.components.NWButtonKind
import app.page.android.ui.nw.components.NWTextField
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.pairing.QrScanner
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

private sealed interface Stage {
    data object Idle : Stage
    data class Checking(val pairing: ValidatedPairing) : Stage

    /** [unused]: the relay has never seen a Mac with this token. */
    data class Confirm(val pairing: ValidatedPairing, val macOnline: Boolean?, val unused: Boolean) : Stage
    data class Problem(val title: String, val message: String, val retry: ValidatedPairing?, val openSettings: Boolean) : Stage
}

/**
 * First-run pairing (iOS PairMacView). A scanned or pasted code is validated locally, then probed against the relay
 * (is it a Page relay, does it accept the token?) and only saved after the user confirms the Mac and relay it
 * points at. Welcome, the scanner, the steps and the paste screen are the Night Watch ones. (The pairing logic is
 * unchanged.)
 */
@Composable
fun PairFlow() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val retirementNotice by PairingStore.retirementNotice.collectAsStateWithLifecycle()
    var stage by remember { mutableStateOf<Stage>(Stage.Idle) }
    var showingScanner by remember { mutableStateOf(false) }
    var showingManual by remember { mutableStateOf(false) }
    var probeJob by remember { mutableStateOf<Job?>(null) }

    DisposableEffect(Unit) { onDispose { probeJob?.cancel() } }

    fun startProbe(p: ValidatedPairing) {
        probeJob?.cancel()
        stage = Stage.Checking(p)
        probeJob = scope.launch {
            val result = RelayClient.probe(p)
            if (stage != Stage.Checking(p)) return@launch
            stage = when (result) {
                is RelayClient.ProbeResult.Ok -> Stage.Confirm(p, result.snapshot?.macConnected, result.snapshot?.looksUnused ?: false)
                is RelayClient.ProbeResult.Unreachable -> Stage.Problem(
                    "Can't reach the relay", "${result.why} Check your phone's connection, and that relayURL in your Mac's Page settings is your deployed Worker (${p.relayHost}).", p, false,
                )
                RelayClient.ProbeResult.NotPageRelay -> Stage.Problem(
                    "That's not a Page relay", "${p.relayHost} didn't answer like a Page relay. Check relayURL in your Mac's Page settings, then show the pairing code again.", p, false,
                )
                RelayClient.ProbeResult.Unauthorized -> Stage.Problem("The relay rejected this code", "Show the pairing code on your Mac again and scan the new one.", null, false)
                is RelayClient.ProbeResult.Retired -> Stage.Problem(
                    "This code was replaced", "${TokenRetirement.sentence(result.why)} On your Mac, open Page → Pair phone… and scan the code shown there now.", null, false,
                )
            }
        }
    }

    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) showingScanner = true else stage = Stage.Problem("Camera access is off", "Allow camera access for Page in Settings to scan the code, or paste the pairing code instead.", null, true)
    }

    fun openScanner() {
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)) {
            stage = Stage.Problem(
                "No camera available",
                "This device can't scan codes. Use “Paste a pairing link instead” and paste the pairing JSON from your Mac (Pair phone… → Copy pairing JSON).", null, false,
            )
            return
        }
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) showingScanner = true
        else cameraPermission.launch(Manifest.permission.CAMERA)
    }

    when {
        showingScanner -> ScannerScreen(
            onValidCode = { showingScanner = false; startProbe(it) },
            onCancel = { showingScanner = false },
            onPaste = { showingScanner = false; showingManual = true },
            onCameraFailure = { message -> showingScanner = false; stage = Stage.Problem("Camera unavailable", message, null, false) },
        )
        showingManual -> ManualPairScreen(onPair = { p -> showingManual = false; startProbe(p) }, onCancel = { showingManual = false })
        else -> when (val s = stage) {
            Stage.Idle -> NWWelcomeScreen(
                notice = retirementNotice?.let { "Pair again" to "${TokenRetirement.sentence(it)} Your old inbox and history were cleared." },
                onPair = ::openScanner, onDismissNotice = { PairingStore.dismissRetirementNotice() },
                onTryDemo = if (Demo.available) ({ Demo.start() }) else null,
            )
            is Stage.Checking -> {
                BackHandler { probeJob?.cancel(); probeJob = null; stage = Stage.Idle }
                NWPairStep(PairStepContent.Checking(s.pairing.relayHost), secondaryTitle = "Cancel", onSecondary = { probeJob?.cancel(); probeJob = null; stage = Stage.Idle })
            }
            is Stage.Confirm -> NWPairStep(
                PairStepContent.Confirm(s.pairing.macName, s.pairing.relayHost, s.macOnline, s.unused), primaryTitle = "Pair", secondaryTitle = "Cancel", onSecondary = { stage = Stage.Idle },
                onPrimary = {
                    // The Paired screen follows a first pairing; it is the one place notifications are asked for.
                    AppRouter.setPairedWelcome(true)
                    if (!PairingStore.adopt(s.pairing)) {
                        AppRouter.setPairedWelcome(false)
                        stage = Stage.Problem("Couldn't save the pairing", "Android refused to store the pairing securely. Try again; if it keeps failing, restart your phone.", s.pairing, false)
                    }
                },
            )
            is Stage.Problem -> NWPairStep(
                PairStepContent.Problem(s.title, s.message), primaryTitle = if (s.openSettings) "Open settings" else "Try again",
                onPrimary = if (s.openSettings) ({ openAppSettings(context) }) else s.retry?.let { r -> { startProbe(r) } },
                secondaryTitle = "Start over", onSecondary = { stage = Stage.Idle },
            )
        }
    }
}

private fun openAppSettings(context: Context) {
    context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}

/** The camera in the viewfinder. Codes that aren't Page pairing codes show an inline hint and scanning carries on, instead of closing and silently doing nothing. */
@Composable
private fun ScannerScreen(onValidCode: (ValidatedPairing) -> Unit, onCancel: () -> Unit, onPaste: () -> Unit, onCameraFailure: (String) -> Unit) {
    var hint by remember { mutableStateOf<String?>(null) }
    var accepted by remember { mutableStateOf(false) }
    BackHandler(onBack = onCancel)
    NWScanScreen(hint = hint, onPaste = onPaste, onCancel = onCancel) {
        QrScanner(
            onCode = { text ->
                if (accepted) return@QrScanner
                when (val r = PairingValidator.validate(text)) {
                    is PairingResult.Success -> { accepted = true; onValidCode(r.pairing) }
                    is PairingResult.Failure -> hint = r.error.message
                }
            },
            onFailure = onCameraFailure, modifier = Modifier.fillMaxSize(),
        )
    }
}

/** Paste the pairing JSON (or link) from the Mac's "Copy pairing JSON". The only way to pair an emulator, which has no camera pointed at a Mac. */
@Composable
private fun ManualPairScreen(onPair: (ValidatedPairing) -> Unit, onCancel: () -> Unit) {
    val context = LocalContext.current
    var text by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    fun attempt() {
        when (val r = PairingValidator.validate(text)) {
            is PairingResult.Success -> onPair(r.pairing)
            is PairingResult.Failure -> error = r.error.message
        }
    }
    BackHandler(onBack = onCancel)
    Box(Modifier.fillMaxSize().background(NW.Palette.backgroundDeep.color)) {
        NWBackdrop()
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("Paste a pairing link", style = NW.Typo.headline, color = NW.Palette.textPrimary.color, modifier = Modifier.semantics { heading() })
            Text("On your Mac, click the Page menu-bar icon → Pair phone… → Copy pairing JSON, then paste it here.", style = NW.Typo.subline, color = NW.Palette.textSecondary.color)
            NWTextField(text, { text = it; error = null }, "{\"v\":1,\"token\":…}", Modifier.fillMaxWidth().heightIn(min = 160.dp), maxLines = 12, label = "Pairing code", imeAction = ImeAction.Done, onImeAction = { if (text.isNotBlank()) attempt() })
            NWButton("Paste from clipboard", {
                val clip = (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).primaryClip
                clip?.getItemAt(0)?.coerceToText(context)?.toString()?.let { text = it }
                error = null
            }, Modifier.fillMaxWidth(), leading = Icons.Outlined.ContentPaste)
            error?.let { Text(it, style = NW.Typo.caption, color = NW.Palette.amber.color, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Assertive }) }
            NWButton("Pair", { attempt() }, Modifier.fillMaxWidth(), kind = NWButtonKind.BRIGHT, enabled = text.isNotBlank())
            NWButton("Cancel", onCancel, Modifier.fillMaxWidth())
        }
    }
}

/** The Paired screen, live: the Mac's name, how many sessions it is already reporting, and the one button that asks for notifications. "Not now" leaves the choice for later. (iOS PairedContainer.) */
@Composable
fun PairedContainer(onRequestNotifications: () -> Unit) {
    val mac by PairingStore.pairedMac.collectAsStateWithLifecycle()
    val sessions by SessionStore.state.collectAsStateWithLifecycle()
    val screen by NowStore.screen.collectAsStateWithLifecycle()
    val notif by NotificationAccess.authorization.collectAsStateWithLifecycle()
    val context = LocalContext.current
    LaunchedEffect(Unit) {
        NotificationAccess.refresh(context)
        // The count of live sessions arrives over the relay connection, which the shell would otherwise start.
        if (!RelayClient.isDemoMode) RelayClient.activate()
    }
    val state = when (notif) {
        NotificationAccess.Authorization.AUTHORIZED -> NotificationsState.ALLOWED
        NotificationAccess.Authorization.DENIED -> NotificationsState.OFF
        NotificationAccess.Authorization.NOT_DETERMINED -> NotificationsState.NOT_SET
        NotificationAccess.Authorization.UNKNOWN -> NotificationsState.CHECKING
    }
    val count = if (sessions.hasList) sessions.sessions.size else screen.status?.activeSessions
    val model = PairedWelcome.build(mac?.name ?: "", count, true, state)
    fun done() = AppRouter.setPairedWelcome(false)
    NWPairedScreen(
        model,
        onAction = {
            when (model.action) {
                PairedWelcome.Action.ALLOW_NOTIFICATIONS -> { onRequestNotifications(); done() }
                PairedWelcome.Action.OPEN_SETTINGS -> { NotificationAccess.openSettings(context); done() }
                PairedWelcome.Action.CONTINUE_TO_NOW -> done()
            }
        },
        onSkip = ::done,
    )
}
