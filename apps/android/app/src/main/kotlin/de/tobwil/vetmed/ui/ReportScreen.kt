package de.tobwil.vetmed.ui

import android.content.ClipData
import android.content.ClipDescription
import android.os.PersistableBundle
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.ExpandLess
import androidx.compose.material.icons.rounded.ExpandMore
import androidx.compose.material.icons.rounded.PendingActions
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.Verified
import androidx.compose.material.icons.rounded.WarningAmber
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import de.tobwil.vetmed.AppViewModel
import de.tobwil.vetmed.core.EncounterLocation
import de.tobwil.vetmed.core.germanDateTime
import kotlinx.coroutines.launch

@Composable
fun ReportReviewScreen(model: AppViewModel, nav: NavHostController, location: EncounterLocation, reportID: String) {
    val document by model.document.collectAsStateWithLifecycle()
    val encounter = document.cases.firstOrNull { it.id == location.caseID }?.encounters?.firstOrNull { it.id == location.encounterID }
    val report = encounter?.reports?.firstOrNull { it.id == reportID }
    val colors = LocalVetColors.current
    val clipboard = LocalClipboard.current
    val haptics = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    var edited by rememberSaveable(reportID) { mutableStateOf(report?.text ?: "") }
    var reviewed by rememberSaveable(reportID) { mutableStateOf(false) }
    var sources by remember { mutableStateOf(false) }
    var copied by remember { mutableStateOf(false) }
    val share = rememberShareLauncher { model.recordShare(reportID, "Text", location) }
    LaunchedEffect(report == null) { if (report == null) nav.popBackStack() }
    if (report == null) return
    val approved = report.approvedAt != null
    val unchanged = edited == report.text
    val badgeScale by animateFloatAsState(if (approved) 1f else 0.96f, spring(dampingRatio = 0.4f), label = "badge")

    Box(Modifier.fillMaxSize()) {
        AmbientBackground()
        Scaffold(
            containerColor = Color.Transparent,
            contentColor = MaterialTheme.colorScheme.onBackground,
            topBar = { BackTopBar("Bericht prüfen", nav) },
            bottomBar = {
                Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    FilledTonalButton(
                        enabled = unchanged, shape = CircleShape, modifier = Modifier.weight(1f).testTag("copy-report"),
                        onClick = {
                            // Marked sensitive so Android does not preview clinical text in the clipboard overlay.
                            val clip = ClipData.newPlainText("VetMed-Bericht", report.exportText).apply {
                                description.extras = PersistableBundle().apply { putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true) }
                            }
                            scope.launch { clipboard.setClipEntry(ClipEntry(clip)) }
                            copied = true; haptics.performHapticFeedback(HapticFeedbackType.Confirm)
                            model.recordShare(report.id, "Zwischenablage", location)
                        },
                    ) {
                        AnimatedContent(copied, label = "copied") { done -> Icon(if (done) Icons.Rounded.Check else Icons.Rounded.ContentCopy, null) }
                        Spacer(Modifier.width(8.dp)); Text(if (copied) "Text kopiert" else "Kopieren")
                    }
                    Button(
                        enabled = unchanged, shape = CircleShape, modifier = Modifier.weight(1f).testTag("share-report-text"),
                        colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                        onClick = { share(report.exportText) },
                    ) { Icon(Icons.Rounded.Share, null); Spacer(Modifier.width(8.dp)); Text("Teilen") }
                }
            },
        ) { padding ->
            Column(
                Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Column(Modifier.fillMaxWidth().vetCard(colors, RoundedCornerShape(26.dp))) {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.scale(badgeScale)) {
                        Icon(if (approved) Icons.Rounded.Verified else Icons.Rounded.PendingActions, null, tint = if (approved) Color(0xFF34C759) else Color(0xFFFF9F0A))
                        Spacer(Modifier.width(8.dp))
                        Text(
                            if (approved) "Fachlich geprüft · ${report.approvedAt!!.germanDateTime()}" else "Entwurf · Prüfung erforderlich",
                            fontWeight = FontWeight.SemiBold, color = if (approved) Color(0xFF34C759) else Color(0xFFFF9F0A),
                        )
                    }
                    Text(
                        if (report.modelID.startsWith("openai/")) "Online erstellt · OpenAI · ${report.modelRevision}" else "Lokal erstellt · ${report.modelID}",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 4.dp, bottom = 12.dp),
                    )
                    OutlinedTextField(edited, { edited = it }, Modifier.fillMaxWidth().heightIn(min = 280.dp).testTag("report-editor"), shape = RoundedCornerShape(16.dp))
                    AnimatedVisibility(!unchanged) {
                        TextButton(onClick = { model.saveReportEdit(edited, report.id, location) { nav.popBackStack() } }) { Text("Als neue Version speichern") }
                    }
                }
                Column(Modifier.fillMaxWidth().vetCard(colors, RoundedCornerShape(26.dp))) {
                    Text("Prüfung am Original", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    report.warnings.forEach { warning ->
                        Row(Modifier.padding(top = 8.dp)) {
                            Icon(Icons.Rounded.WarningAmber, null, tint = Color(0xFFFF9F0A), modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(6.dp)); Text(warning, color = Color(0xFFFF9F0A), style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                    TextButton(onClick = { sources = !sources }) {
                        Text("Quellenbezüge"); Icon(if (sources) Icons.Rounded.ExpandLess else Icons.Rounded.ExpandMore, null)
                    }
                    AnimatedVisibility(sources) {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            report.content.sections.flatMap { it.items }.forEach { item ->
                                Column {
                                    Text(item.text, style = MaterialTheme.typography.bodyMedium)
                                    item.sourceRefs.forEach { Text("„${it.quote}“ · ${it.segmentId}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                                }
                            }
                        }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(reviewed, { reviewed = it }, enabled = !approved)
                        Text("Zahlen, Einheiten, Negationen und Vollständigkeit am Original geprüft", style = MaterialTheme.typography.bodyMedium)
                    }
                    Button(
                        enabled = reviewed && unchanged && !approved, shape = CircleShape, modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF34C759)),
                        onClick = { haptics.performHapticFeedback(HapticFeedbackType.Confirm); model.approve(report.id, location) },
                    ) { Icon(Icons.Rounded.Verified, null); Spacer(Modifier.width(8.dp)); Text("Diese Version als geprüft markieren") }
                }
                Column(Modifier.fillMaxWidth().vetCard(colors, RoundedCornerShape(26.dp))) {
                    Text("Exportvorschau", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.size(8.dp))
                    SelectionContainer { Text(report.exportText, style = MaterialTheme.typography.bodySmall) }
                }
            }
        }
    }
}

/**
 * Opens the Android share sheet and reports back only when the user actually picks a target,
 * like the iOS completion callback. Delivery to the recipient stays unknown.
 */
@Composable
fun rememberShareLauncher(onChosen: () -> Unit): (String) -> Unit {
    val context = androidx.compose.ui.platform.LocalContext.current
    val chosen by androidx.compose.runtime.rememberUpdatedState(onChosen)
    val action = remember { "de.tobwil.vetmed.SHARE_CHOSEN." + java.util.UUID.randomUUID() }
    androidx.compose.runtime.DisposableEffect(action) {
        val receiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(context: android.content.Context, intent: android.content.Intent) { chosen() }
        }
        androidx.core.content.ContextCompat.registerReceiver(context, receiver, android.content.IntentFilter(action), androidx.core.content.ContextCompat.RECEIVER_NOT_EXPORTED)
        onDispose { context.unregisterReceiver(receiver) }
    }
    return { text ->
        val send = android.content.Intent(android.content.Intent.ACTION_SEND).apply { type = "text/plain"; putExtra(android.content.Intent.EXTRA_TEXT, text) }
        val callback = android.app.PendingIntent.getBroadcast(
            context, 0, android.content.Intent(action).setPackage(context.packageName),
            android.app.PendingIntent.FLAG_MUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT,
        )
        context.startActivity(android.content.Intent.createChooser(send, "Bericht teilen", callback.intentSender))
    }
}
