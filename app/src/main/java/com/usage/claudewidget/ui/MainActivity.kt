package com.usage.claudewidget.ui

import android.os.Build
import android.os.Bundle
import android.text.format.DateUtils
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.usage.claudewidget.data.FetchResult
import com.usage.claudewidget.data.LinkState
import com.usage.claudewidget.data.OrcaAccountsParser
import com.usage.claudewidget.data.Provider
import com.usage.claudewidget.data.Storage
import com.usage.claudewidget.data.UsageRepository
import com.usage.claudewidget.orca.OrcaPairingCodec
import com.usage.claudewidget.watch.WatchBridge
import com.usage.claudewidget.widget.ProviderUsageWidget
import com.usage.claudewidget.work.RefreshScheduler
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Opening the app re-registers the 15-minute background refresh with the system, in
        // case the OEM's background management dropped it (see RefreshScheduler). Only once
        // paired - before that there is nothing to fetch; pairing schedules it itself.
        if (Storage.get(this).isPaired) {
            RefreshScheduler.ensurePeriodic(this)
        }
        setContent {
            AppTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    SetupScreen()
                }
            }
        }
    }
}

/**
 * Follows the system light/dark setting. A bare `MaterialTheme {}` always uses the light
 * scheme, which is why this screen stayed white in dark mode.
 *
 * On Android 12+ the scheme is the wallpaper-derived dynamic one, the same palette the
 * home-screen widget gets from GlanceTheme, so the app and the widget match. Older devices
 * fall back to the stock Material 3 light/dark schemes.
 */
@androidx.compose.runtime.Composable
private fun AppTheme(content: @androidx.compose.runtime.Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val scheme = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
            if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialTheme(colorScheme = scheme, content = content)
}

@androidx.compose.runtime.Composable
private fun SetupScreen() {
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val storage = remember { Storage.get(context) }
    val scope = rememberCoroutineScope()

    var status by remember { mutableStateOf(describe(storage)) }
    var debug by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }

    // Pairing inputs. The address starts as the saved one, and a newly read code replaces it
    // with the address that code names - which the user can still edit before saving.
    var code by remember { mutableStateOf("") }
    var address by remember { mutableStateOf(storage.pairing?.endpoint.orEmpty()) }
    var pairMessage by remember { mutableStateOf("") }

    // Background-activity prompt. Re-evaluated every time the screen resumes, which is how
    // it notices the user coming back from the system settings it sent them to.
    var bg by remember { mutableStateOf(BackgroundAccess.status(context, storage)) }
    var showBgDialog by remember { mutableStateOf(storage.isPaired && bg.shouldPrompt) }
    LifecycleResumeEffect(Unit) {
        bg = BackgroundAccess.status(context, storage)
        status = describe(storage)
        onPauseOrDispose { }
    }

    if (showBgDialog) {
        BackgroundDialog(
            status = bg,
            garminInstalled = remember {
                BackgroundAccess.isInstalled(context, BackgroundAccess.GARMIN_CONNECT_PACKAGE)
            },
            onBatteryExemption = { BackgroundAccess.requestBatteryExemption(context) },
            onAppInfo = { BackgroundAccess.openAppInfo(context) },
            onGarminInfo = {
                BackgroundAccess.openAppInfo(context, BackgroundAccess.GARMIN_CONNECT_PACKAGE)
            },
            onDone = {
                storage.backgroundHelpAckAt = System.currentTimeMillis()
                bg = BackgroundAccess.status(context, storage)
                showBgDialog = false
            },
            onLater = { showBgDialog = false },
        )
    }

    /** A code was scanned or pasted: check it now, and take its address into the field. */
    fun takeCode(input: String) {
        code = input.trim()
        pairMessage = when (val parsed = OrcaPairingCodec.parse(code)) {
            is OrcaPairingCodec.ParseResult.Ok -> {
                address = parsed.pairing.endpoint
                "Pairing code read. Check the address, then tap Save and test."
            }
            is OrcaPairingCodec.ParseResult.Invalid -> parsed.reason
        }
    }

    // Runs the same fetch -> widgets -> watch sequence as the background refresh, and shows
    // each step's outcome. The watch step used to be skipped here, so a watch that was
    // not receiving pushes looked fine from this button.
    suspend fun testFetch() {
        debug = "Contacting Orca…"
        when (val r = UsageRepository(context).refresh()) {
            is FetchResult.Success -> {
                ProviderUsageWidget.updateAll(context)
                val usage = Provider.entries.joinToString("\n") { provider ->
                    r.usage[provider]?.let(OrcaAccountsParser::summarize) ?: "${provider.displayName}: -"
                }
                val claude = r.claudeWatch
                if (claude == null) {
                    debug = "$usage\nWatch: no Claude numbers to send"
                } else {
                    // The push can take up to ~35 s (one attempt, a 5 s pause, one retry), so
                    // say what is happening rather than look frozen.
                    debug = "$usage\nWatch: sending…"
                    val push = WatchBridge.push(context, claude)
                    debug = "$usage\nWatch: ${WatchBridge.describe(push)}"
                }
            }
            is FetchResult.NeedsPairing -> {
                ProviderUsageWidget.updateAll(context)
                debug = "Pair again: ${r.reason}"
            }
            is FetchResult.Soft -> debug = "Couldn't fetch: ${r.reason}"
        }
    }

    Column(
        // safeDrawingPadding: targetSdk 35+ is always edge-to-edge, so without it the title
        // is drawn under the status-bar clock. Scrolls because the pairing form plus the
        // status can outgrow a small screen.
        modifier = Modifier
            .fillMaxSize()
            .safeDrawingPadding()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Claude Usage Widget", style = MaterialTheme.typography.headlineSmall)
        // The definitive "did it update?" check. VERSION_NAME is the release tag in a
        // published build (a local debug build shows the gradle default instead).
        Text(
            "v${com.usage.claudewidget.BuildConfig.VERSION_NAME}",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(status, style = MaterialTheme.typography.bodyMedium)

        // Runs the same fetch -> widgets -> watch sequence as the background refresh.
        OutlinedButton(enabled = !busy && storage.isPaired, onClick = {
            scope.launch {
                busy = true
                try {
                    testFetch()
                } finally {
                    busy = false
                    status = describe(storage)
                    // A send the phone cut off is exactly what the background prompt fixes.
                    bg = BackgroundAccess.status(context, storage)
                    if (bg.stoppedSinceAck) showBgDialog = true
                }
            }
        }) { Text("Test fetch now") }

        if (debug.isNotBlank()) {
            Text(debug, style = MaterialTheme.typography.titleMedium)
        }

        HorizontalDivider()
        Text(
            if (storage.isPaired) "Pair again with desktop Orca" else "Pair with desktop Orca",
            style = MaterialTheme.typography.titleMedium,
        )
        Text(
            "On your computer, open Orca → Settings → Mobile and pair a new device. Choose " +
                "the computer's Tailscale address (100.x.y.z) so the widget also works away " +
                "from home. Then scan the QR code here, or copy the pairing link and paste it.",
            style = MaterialTheme.typography.bodyMedium,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(enabled = !busy, onClick = {
                // Google's code scanner runs in Play services' own activity: no camera
                // permission here, and nothing to bundle beyond the client library.
                val options = GmsBarcodeScannerOptions.Builder()
                    .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                    .build()
                GmsBarcodeScanning.getClient(context, options).startScan()
                    .addOnSuccessListener { barcode -> takeCode(barcode.rawValue.orEmpty()) }
                    .addOnFailureListener { e ->
                        pairMessage = "The QR scanner isn't available (${e.message}). " +
                            "Copy the pairing link in Orca and paste it instead."
                    }
            }) { Text("Scan QR code") }
            OutlinedButton(enabled = !busy, onClick = {
                takeCode(clipboard.getText()?.text.orEmpty())
            }) { Text("Paste") }
        }
        OutlinedTextField(
            value = code,
            onValueChange = { takeCode(it) },
            label = { Text("Pairing code or orca://pair link") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = address,
            onValueChange = { address = it },
            label = { Text("Orca address") },
            placeholder = { Text("100.x.y.z or ws://host:6768") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Button(enabled = !busy, onClick = {
            val existing = storage.pairing
            val pairing = when {
                code.isNotBlank() -> when (val parsed = OrcaPairingCodec.parse(code)) {
                    is OrcaPairingCodec.ParseResult.Ok -> parsed.pairing
                    is OrcaPairingCodec.ParseResult.Invalid -> {
                        pairMessage = parsed.reason
                        return@Button
                    }
                }
                // No new code: an address change for the existing pairing.
                existing != null -> existing
                else -> {
                    pairMessage = "Scan or paste a pairing code from Orca first."
                    return@Button
                }
            }
            val endpoint = OrcaPairingCodec.normalizeEndpoint(address.ifBlank { pairing.endpoint })
            if (endpoint == null) {
                pairMessage = "\"$address\" is not an address. Enter the computer's address, " +
                    "e.g. 100.64.0.5 or ws://100.64.0.5:6768."
                return@Button
            }
            if (OrcaPairingCodec.isLoopback(endpoint)) {
                pairMessage = "$endpoint points at this phone, not your computer. In Orca, choose " +
                    "the computer's Tailscale or Wi-Fi address and copy the code again - or type " +
                    "that address here."
                return@Button
            }
            // A new code may be another computer: drop the old numbers rather than show them
            // under the new pairing. An address-only change keeps them.
            if (code.isNotBlank()) storage.clearUsage()
            storage.pairing = pairing.copy(endpoint = endpoint)
            address = endpoint
            code = ""
            pairMessage = "Saved. Testing the connection…"
            scope.launch {
                busy = true
                try {
                    testFetch()
                    pairMessage = if (storage.linkState == LinkState.OK) {
                        RefreshScheduler.ensurePeriodic(context)
                        "Paired ✓ - the widgets refresh every 15 minutes."
                    } else {
                        "Saved, but the test failed: ${storage.linkDetail}"
                    }
                } finally {
                    busy = false
                    status = describe(storage)
                }
            }
        }) { Text("Save and test") }
        if (pairMessage.isNotBlank()) {
            Text(pairMessage, style = MaterialTheme.typography.bodyMedium)
        }

        HorizontalDivider()
        // Opens the same prompt on demand; it was a bare "Disable battery optimization"
        // button, which covered only Android's layer and not the manufacturer's.
        OutlinedButton(onClick = {
            bg = BackgroundAccess.status(context, storage)
            showBgDialog = true
        }) {
            Text(if (bg.batteryExempt && !bg.stoppedSinceAck) "Background settings" else "Background settings ⚠")
        }
        if (storage.isPaired) {
            // Forgets the device token here; the device entry itself is removed in desktop
            // Orca (Settings > Mobile), which is the only place that can revoke it.
            TextButton(enabled = !busy, onClick = {
                storage.pairing = null
                storage.clearUsage()
                storage.linkState = LinkState.NEEDS_PAIRING
                storage.linkDetail = "not paired with Orca"
                address = ""
                pairMessage = "Unpaired. Also remove this device in Orca → Settings → Mobile."
                status = describe(storage)
                scope.launch { ProviderUsageWidget.updateAll(context) }
            }) { Text("Unpair") }
        }
    }
}

private fun describe(s: Storage): String = buildString {
    val pairing = s.pairing
    append(if (pairing == null) "Orca: not paired" else "Orca: ${pairing.endpoint}")
    if (pairing != null) {
        append("\nlink: ")
        when {
            s.linkAttemptAt == 0L -> append("not tried yet")
            s.linkState == LinkState.OK -> append("OK · ").append(ago(s.linkSuccessAt))
            else -> append(s.linkDetail.ifBlank { s.linkState.name.lowercase() })
                .append(" · ").append(ago(s.linkAttemptAt))
        }
        if (s.linkState != LinkState.OK && s.linkSuccessAt != 0L) {
            append("\nlast reached Orca: ").append(ago(s.linkSuccessAt))
        }
    }
    Provider.entries.forEach { provider ->
        val usage = s.usage(provider) ?: return@forEach
        append("\n").append(OrcaAccountsParser.summarize(usage))
        if (usage.hasData && usage.updatedAtEpochMs != 0L) {
            append(" · ").append(ago(usage.updatedAtEpochMs))
        }
    }
    // The watch's own "not updated recently" only says THAT it is stale; this line says why.
    append("\nwatch: ")
    if (s.watchPushAt == 0L) {
        append("no push yet")
    } else {
        append(s.watchPushDetail).append(" · ").append(ago(s.watchPushAt))
        if (!s.watchPushOk) {
            append("\nlast reached watch: ")
            append(if (s.watchLastSentAt == 0L) "never" else ago(s.watchLastSentAt))
        }
    }
}

/** "5 minutes ago" / "Yesterday" - locale-aware and needs no Context. */
private fun ago(epochMs: Long): String = DateUtils.getRelativeTimeSpanString(
    epochMs, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS
).toString()

/**
 * "Keep Claude Usage running" - what this phone must allow for the 15-minute refresh and
 * the watch send, with a button for each setting the app can open.
 *
 * Android's battery exemption is checked and requested directly. A manufacturer's own
 * background switch (ColorOS "Allow background activity") cannot be read by an app, so for
 * that the dialog names the exact path, opens the App info page it lives under, and relies
 * on the user's "Done" - re-appearing only if a later watch send is still stopped.
 */
@androidx.compose.runtime.Composable
private fun BackgroundDialog(
    status: BackgroundAccess.Status,
    garminInstalled: Boolean,
    onBatteryExemption: () -> Unit,
    onAppInfo: () -> Unit,
    onGarminInfo: () -> Unit,
    onDone: () -> Unit,
    onLater: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onLater,
        title = { Text("Keep Claude Usage running") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (status.stoppedSinceAck) {
                    Text(
                        "Your phone stopped the last watch update before it finished.",
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
                Text(
                    "The widget refreshes every 15 minutes and updates your Garmin watch in " +
                        "the background. Your phone has to allow that:",
                    style = MaterialTheme.typography.bodyMedium,
                )

                // 1. Android's own layer - readable, so show its state.
                Text(
                    if (status.batteryExempt) "✓ Battery optimisation is off for Claude Usage."
                    else "1. Turn off battery optimisation for Claude Usage.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                if (!status.batteryExempt) {
                    Button(onClick = onBatteryExemption) { Text("Allow") }
                }

                // 2. The manufacturer's layer - not readable, so give the exact path.
                Text(
                    if (status.colorOs) {
                        "${if (status.batteryExempt) "" else "2. "}On this phone (ColorOS): " +
                            "App info → Battery usage → Allow background activity — for " +
                            "Claude Usage and for Garmin Connect."
                    } else {
                        "${if (status.batteryExempt) "" else "2. "}If your phone has its own " +
                            "battery manager (Samsung, Xiaomi, OnePlus, Oppo…), allow Claude " +
                            "Usage and Garmin Connect to run in the background there too."
                    },
                    style = MaterialTheme.typography.bodyMedium,
                )
                OutlinedButton(onClick = onAppInfo) { Text("Claude Usage app info") }
                if (garminInstalled) {
                    OutlinedButton(onClick = onGarminInfo) { Text("Garmin Connect app info") }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDone) { Text("Done") } },
        dismissButton = { TextButton(onClick = onLater) { Text("Later") } },
    )
}
