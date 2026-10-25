package app.page.android.ui.pairing

import android.Manifest
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.KeyOff
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.PairingStore
import app.page.android.data.RelayClient
import app.page.android.demo.Demo
import app.page.android.model.PairingResult
import app.page.android.model.PairingValidator
import app.page.android.model.TokenRetirement
import app.page.android.model.ValidatedPairing
import app.page.android.ui.components.BannerTone
import app.page.android.ui.components.PrimaryButton
import app.page.android.ui.components.PulseMark
import app.page.android.ui.components.StatusBanner
import app.page.android.ui.components.TextLink
import app.page.android.ui.components.card
import app.page.android.ui.theme.MinTouch
import app.page.android.ui.theme.PageType
import app.page.android.ui.theme.Space
import app.page.android.ui.theme.colors
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
 * First-run pairing (iOS PairMacView.swift). A scanned or pasted code is
 * validated locally, then probed against the relay (is it a Page relay, does
 * it accept the token?) and only saved after the user confirms the Mac and
 * relay it points at.
 */
@Composable
fun PairScreen() {
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
                    "Can't reach the relay",
                    "${result.why} Check your phone's connection, and that relayURL in your Mac's Page settings is your deployed Worker (${p.relayHost}).",
                    p, false,
                )
                RelayClient.ProbeResult.NotPageRelay -> Stage.Problem(
                    "That's not a Page relay",
                    "${p.relayHost} didn't answer like a Page relay. Check relayURL in your Mac's Page settings, then show the pairing code again.",
                    p, false,
                )
                RelayClient.ProbeResult.Unauthorized -> Stage.Problem(
                    "The relay rejected this code", "Show the pairing code on your Mac again and scan the new one.", null, false,
                )
                is RelayClient.ProbeResult.Retired -> Stage.Problem(
                    "This code was replaced",
                    "${TokenRetirement.sentence(result.why)} On your Mac, open Page → Pair phone… and scan the code shown there now.",
                    null, false,
                )
            }
        }
    }

    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) showingScanner = true else stage = cameraDeniedProblem()
    }

    fun openScanner() {
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)) {
            stage = Stage.Problem(
                "No camera available",
                "This device can't scan codes. Use “Paste pairing code” and paste the pairing JSON from your Mac (Pair phone… → Copy pairing JSON).",
                null, false,
            )
            return
        }
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            showingScanner = true
        } else {
            cameraPermission.launch(Manifest.permission.CAMERA)
        }
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(colors.surface)
            .safeDrawingPadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = Space.xxl)
            .padding(bottom = 34.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Space.xxl),
    ) {
        Spacer(Modifier.height(40.dp))
        PulseMark(size = 96.dp)
        Text("Pair your Mac", style = PageType.display22, color = colors.text, modifier = Modifier.semantics { heading() })
        Text(
            "On your Mac, click the Page icon in the menu bar → Pair phone…, then scan the QR code shown there.",
            style = PageType.body15, color = colors.textMuted, textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = Space.l),
        )
        retirementNotice?.let { notice ->
            StatusBanner(
                BannerTone.ERROR, Icons.Filled.KeyOff,
                title = "Pair again",
                message = "${TokenRetirement.sentence(notice)} Your old inbox and history were cleared.",
                actionTitle = "Dismiss",
            ) { PairingStore.dismissRetirementNotice() }
        }
        when (val s = stage) {
            Stage.Idle -> Column(
                Modifier.fillMaxWidth().padding(top = Space.l),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(Space.m),
            ) {
                PrimaryButton("Scan pairing code") { openScanner() }
                TextLink("Paste pairing code", color = colors.textMuted) { showingManual = true }
                if (Demo.available) {
                    TextLink("Try the demo (debug build)", color = colors.textMuted) { Demo.start() }
                }
            }
            is Stage.Checking -> Column(
                Modifier.fillMaxWidth().padding(top = Space.l).semantics { liveRegion = LiveRegionMode.Polite },
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(Space.m),
            ) {
                CircularProgressIndicator(color = colors.textMuted)
                Text("Checking ${s.pairing.relayHost}…", style = PageType.body15, color = colors.textMuted)
                TextLink("Cancel", color = colors.textMuted) {
                    probeJob?.cancel()
                    probeJob = null
                    stage = Stage.Idle
                }
            }
            is Stage.Confirm -> ConfirmCard(s, onPair = {
                if (!PairingStore.adopt(s.pairing)) {
                    stage = Stage.Problem(
                        "Couldn't save the pairing",
                        "Android refused to store the pairing securely. Try again; if it keeps failing, restart your phone.",
                        s.pairing, false,
                    )
                }
            }, onCancel = { stage = Stage.Idle })
            is Stage.Problem -> Column(verticalArrangement = Arrangement.spacedBy(Space.m), horizontalAlignment = Alignment.CenterHorizontally) {
                StatusBanner(BannerTone.ERROR, Icons.Filled.Warning, s.title, s.message)
                if (s.openSettings) PrimaryButton("Open settings") { openAppSettings(context) }
                s.retry?.let { retry -> PrimaryButton("Try again") { startProbe(retry) } }
                TextLink("Start over", color = colors.textMuted) { stage = Stage.Idle }
            }
        }
    }

    if (showingScanner) {
        ScannerDialog(
            onValidCode = { showingScanner = false; startProbe(it) },
            onCancel = { showingScanner = false },
            onCameraFailure = { message ->
                showingScanner = false
                stage = Stage.Problem("Camera unavailable", message, null, false)
            },
        )
    }
    if (showingManual) {
        ManualPairDialog(
            onPair = { p -> showingManual = false; startProbe(p) },
            onCancel = { showingManual = false },
        )
    }
}

private fun cameraDeniedProblem(): Stage = Stage.Problem(
    "Camera access is off",
    "Allow camera access for Page in Settings to scan the code, or paste the pairing code instead.",
    null, true,
)

private fun openAppSettings(context: Context) {
    context.startActivity(
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    )
}

@Composable
private fun ConfirmCard(s: Stage.Confirm, onPair: () -> Unit, onCancel: () -> Unit) {
    Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(Space.m)) {
        Text("Pair with ${s.pairing.macName}?", style = PageType.title17, color = colors.text)
        Text("Relay: ${s.pairing.relayHost}", style = PageType.mono13, color = colors.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        when {
            s.macOnline == true -> IconLine(Icons.Outlined.CheckCircle, "Your Mac is connected to this relay.", colors.success)
            s.macOnline == false && s.unused -> IconLine(
                Icons.Filled.Warning,
                "No Mac has connected to this relay with this code yet. If it's an old screenshot or you regenerated the token on your Mac, show the pairing code on your Mac again and scan the new one.",
                colors.destructiveText,
            )
            s.macOnline == false -> IconLine(
                Icons.Filled.ErrorOutline,
                "Your Mac isn't connected to this relay right now. That's fine — pages will arrive once it is.",
                colors.warning,
            )
        }
        Text(
            "Only pair with a code from your own Mac: whoever runs this relay sees your pages and replies.",
            style = PageType.caption12, color = colors.textMuted,
        )
        PrimaryButton("Pair", onClick = onPair)
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            TextLink("Cancel", color = colors.textMuted, onClick = onCancel)
        }
    }
}

@Composable
private fun IconLine(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String, tint: Color) {
    Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp).padding(top = 1.dp))
        Text(text, style = PageType.caption12, color = tint)
    }
}

/**
 * Full-screen scanner with a viewfinder, instructions and Cancel. Codes that
 * aren't Page pairing codes show an inline hint and scanning carries on,
 * instead of closing and silently doing nothing.
 */
@Composable
private fun ScannerDialog(onValidCode: (ValidatedPairing) -> Unit, onCancel: () -> Unit, onCameraFailure: (String) -> Unit) {
    var hint by remember { mutableStateOf<String?>(null) }
    var accepted by remember { mutableStateOf(false) }
    Dialog(onDismissRequest = onCancel, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            QrScanner(
                onCode = { text ->
                    if (accepted) return@QrScanner
                    when (val r = PairingValidator.validate(text)) {
                        is PairingResult.Success -> {
                            accepted = true
                            onValidCode(r.pairing)
                        }
                        is PairingResult.Failure -> hint = r.error.message
                    }
                },
                onFailure = onCameraFailure,
                modifier = Modifier.fillMaxSize(),
            )
            Column(Modifier.fillMaxSize().safeDrawingPadding(), horizontalAlignment = Alignment.CenterHorizontally) {
                Row(Modifier.fillMaxWidth().padding(Space.l), horizontalArrangement = Arrangement.End) {
                    Box(
                        Modifier
                            .clip(RoundedCornerShape(50))
                            .background(Color.Black.copy(alpha = 0.4f))
                            .heightIn(min = MinTouch),
                        contentAlignment = Alignment.Center,
                    ) {
                        TextLink("Cancel", color = Color.White, modifier = Modifier.padding(horizontal = Space.l), onClick = onCancel)
                    }
                }
                Spacer(Modifier.weight(1f))
                Box(
                    Modifier
                        .size(240.dp)
                        .border(3.dp, Color.White.copy(alpha = 0.85f), RoundedCornerShape(24.dp))
                )
                Spacer(Modifier.weight(1f))
                Text(
                    hint ?: "Point the camera at the QR code in Page on your Mac.",
                    style = PageType.bodyEm, color = Color.White, textAlign = TextAlign.Center,
                    modifier = Modifier
                        .padding(horizontal = Space.xl)
                        .padding(bottom = 40.dp)
                        .clip(RoundedCornerShape(14.dp))
                        .background(Color.Black.copy(alpha = 0.55f))
                        .padding(Space.l)
                        .semantics { liveRegion = LiveRegionMode.Polite },
                )
            }
        }
    }
}

/**
 * Paste the pairing JSON (or link) from the Mac's "Copy pairing JSON". The
 * only way to pair an emulator, which has no camera pointed at a Mac.
 */
@Composable
private fun ManualPairDialog(onPair: (ValidatedPairing) -> Unit, onCancel: () -> Unit) {
    val context = LocalContext.current
    var text by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    fun attempt() {
        when (val r = PairingValidator.validate(text)) {
            is PairingResult.Success -> onPair(r.pairing)
            is PairingResult.Failure -> error = r.error.message
        }
    }
    Dialog(onDismissRequest = onCancel, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Column(
            Modifier
                .fillMaxSize()
                .background(colors.surface)
                .safeDrawingPadding()
                .imePadding()
        ) {
            Row(Modifier.fillMaxWidth().padding(horizontal = Space.l), verticalAlignment = Alignment.CenterVertically) {
                TextLink("Cancel", color = colors.textMuted, onClick = onCancel)
                Text(
                    "Paste pairing code", style = PageType.bodyEm, color = colors.text, textAlign = TextAlign.Center,
                    modifier = Modifier.weight(1f).semantics { heading() },
                )
                TextLink("Pair", color = if (text.isBlank()) colors.textMuted else colors.text) { if (text.isNotBlank()) attempt() }
            }
            Column(
                Modifier.verticalScroll(rememberScrollState()).padding(Space.xxl),
                verticalArrangement = Arrangement.spacedBy(Space.l),
            ) {
                Text(
                    "On your Mac, click the Page menu-bar icon → Pair phone… → Copy pairing JSON, then paste it here.",
                    style = PageType.body15, color = colors.textMuted,
                )
                val shape = RoundedCornerShape(12.dp)
                Box(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(min = 160.dp)
                        .clip(shape)
                        .background(colors.surfaceRaised)
                        .border(1.dp, colors.hairline, shape)
                        .padding(Space.m)
                ) {
                    if (text.isEmpty()) Text("{\"v\":1,\"token\":…}", style = PageType.mono13, color = colors.textMuted)
                    BasicTextField(
                        value = text,
                        onValueChange = { text = it; error = null },
                        textStyle = PageType.mono13.copy(color = colors.text),
                        cursorBrush = SolidColor(colors.text),
                        keyboardOptions = KeyboardOptions(
                            capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false,
                            keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done,
                        ),
                        modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Pairing code" },
                    )
                }
                Row(
                    Modifier.heightIn(min = MinTouch),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Space.s),
                ) {
                    Icon(Icons.Filled.ContentPaste, contentDescription = null, tint = colors.text, modifier = Modifier.size(18.dp))
                    TextLink("Paste from clipboard") {
                        val clip = (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).primaryClip
                        clip?.getItemAt(0)?.coerceToText(context)?.toString()?.let { text = it }
                        error = null
                    }
                }
                error?.let {
                    Text(it, style = PageType.caption12, color = colors.destructiveText, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Assertive })
                }
            }
        }
    }
}
