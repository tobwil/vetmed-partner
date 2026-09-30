package de.tobwil.vetmed.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Chat
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.CloudDone
import androidx.compose.material.icons.rounded.Description
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.Keyboard
import androidx.compose.material.icons.rounded.ExpandLess
import androidx.compose.material.icons.rounded.ExpandMore
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayCircle
import androidx.compose.material.icons.rounded.FiberManualRecord
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material.icons.rounded.Verified
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.LinearEasing
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.core.content.ContextCompat
import de.tobwil.vetmed.core.Encounter
import androidx.navigation.NavHostController
import de.tobwil.vetmed.AppViewModel
import de.tobwil.vetmed.core.EncounterLocation
import de.tobwil.vetmed.core.EncounterStep
import de.tobwil.vetmed.core.ReportExecutionMode
import de.tobwil.vetmed.core.ReportLength
import de.tobwil.vetmed.core.ReportTemplate
import de.tobwil.vetmed.core.ReportValidator
import de.tobwil.vetmed.core.germanDateTime
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EncounterScreen(model: AppViewModel, nav: NavHostController, location: EncounterLocation) {
    val document by model.document.collectAsStateWithLifecycle()
    val busy by model.busy.collectAsStateWithLifecycle()
    val online by model.online.collectAsStateWithLifecycle()
    val vocabulary by model.vocabulary.collectAsStateWithLifecycle()
    val item = document.cases.firstOrNull { it.id == location.caseID }
    val encounter = item?.encounters?.firstOrNull { it.id == location.encounterID }
    val recordingNow by model.recorder.recording.collectAsStateWithLifecycle()
    val recordingLocation by model.recordingLocation.collectAsStateWithLifecycle()
    val recording = recordingNow && recordingLocation == location
    val colors = LocalVetColors.current
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    val context = LocalContext.current
    val microphone = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) model.record(location)
        else model.reportError("Ohne Mikrofonzugriff ist keine Aufnahme möglich. Du kannst den Text weiterhin eingeben oder in den Android-Einstellungen den Zugriff erlauben.")
    }
    val toggleRecording = {
        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
        when {
            recording -> model.pauseRecording()
            ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED -> model.record(location)
            else -> microphone.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    var step by rememberSaveable { mutableStateOf(encounter?.suggestedStep ?: EncounterStep.RECORDING) }
    var transcript by rememberSaveable { mutableStateOf(encounter?.transcripts?.lastOrNull()?.editedText ?: "") }
    var saved by rememberSaveable { mutableStateOf(transcript) }
    var template by rememberSaveable { mutableStateOf(ReportTemplate.TREATMENT_REPORT) }
    var length by rememberSaveable { mutableStateOf(ReportLength.MEDIUM) }
    var mode by rememberSaveable { mutableStateOf(online.preferredMode) }
    var options by remember { mutableStateOf(false) }
    var editingCase by remember { mutableStateOf(false) }
    val reportCount = encounter?.reports?.size ?: 0

    LaunchedEffect(encounter == null) { if (encounter == null) nav.popBackStack() }
    // Autosave one second after typing stops, like iOS.
    LaunchedEffect(transcript) {
        if (transcript == saved) return@LaunchedEffect
        delay(1000)
        val value = transcript
        if (model.saveTranscript(value, location)) saved = value
    }
    // A new report opens its review directly.
    var knownReports by rememberSaveable { mutableIntStateOf(reportCount) }
    LaunchedEffect(reportCount) {
        if (reportCount > knownReports) encounter?.reports?.lastOrNull()?.let { step = EncounterStep.REPORT; nav.navigate(ReportRoute(location.caseID, location.encounterID, it.id)) }
        knownReports = reportCount
    }
    // A finished transcription replaces the editor text unless the user has unsaved typing.
    val latestTranscriptID = encounter?.transcripts?.lastOrNull()?.id
    LaunchedEffect(latestTranscriptID) {
        val stored = model.encounter(location)?.transcripts?.lastOrNull()?.editedText ?: ""
        if (transcript == saved) transcript = stored
        saved = stored
    }
    val pendingText by rememberUpdatedState(transcript.takeIf { it != saved })
    val stillRecording by rememberUpdatedState(recording)
    DisposableEffect(Unit) {
        onDispose {
            pendingText?.let { model.flushTranscript(it, location) }
            if (stillRecording) model.pauseRecording()
        }
    }
    // Android silences background microphone access without a foreground service, so leaving the app pauses safely.
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) {
        pendingText?.let { model.flushTranscript(it, location) }
        if (stillRecording) model.pauseRecording()
    }
    val view = LocalView.current
    DisposableEffect(recording) { view.keepScreenOn = recording; onDispose { view.keepScreenOn = false } }
    if (item == null || encounter == null) return

    Box(Modifier.fillMaxSize()) {
        AmbientBackground()
        Scaffold(
            containerColor = Color.Transparent,
            contentColor = MaterialTheme.colorScheme.onBackground,
            topBar = {
                BackTopBar(item.label, nav) {
                    IconButton(enabled = !busy, modifier = Modifier.testTag("chat-from-dictation"), onClick = {
                        nav.navigate(ChatConversationRoute(location.caseID, location.encounterID))
                    }) { Icon(Icons.AutoMirrored.Rounded.Chat, "Zum Fall chatten") }
                }
            },
            bottomBar = {
                val showPrimary = !busy && (step != EncounterStep.RECORDING || recording || encounter.audio.isNotEmpty())
                AnimatedVisibility(showPrimary, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
                    Box(Modifier.fillMaxWidth().imePadding().padding(horizontal = 20.dp, vertical = 12.dp)) {
                        PrimaryAction(step, encounter.reports.lastOrNull()?.let { if (it.approvedAt == null) "Bericht prüfen" else "Bericht ansehen und teilen" }, transcript.isNotBlank()) {
                            when (step) {
                                EncounterStep.RECORDING -> model.pauseRecording {
                                    if (!model.captureInProgress) {
                                        step = EncounterStep.TRANSCRIPT
                                        if (model.encounter(location)?.hasPendingAudio == true) model.transcribe(location)
                                    }
                                }
                                EncounterStep.TRANSCRIPT -> scope.launch {
                                    val value = transcript
                                    if (model.saveTranscript(value, location)) { saved = value; model.generate(location, template, length, mode) }
                                }
                                EncounterStep.REPORT -> encounter.reports.lastOrNull()?.let { nav.navigate(ReportRoute(location.caseID, location.encounterID, it.id)) }
                            }
                        }
                    }
                }
            },
        ) { padding ->
            Column(
                Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Column(Modifier.fillMaxWidth().vetCard(colors, RoundedCornerShape(26.dp), 14.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(SpeciesIcon.forSpecies(item.species), null, tint = colors.primary, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text(item.species, modifier = Modifier.weight(1f))
                        TextButton(onClick = { editingCase = true }) { Icon(Icons.Rounded.Edit, null, Modifier.size(16.dp)); Spacer(Modifier.width(4.dp)); Text("Falldaten") }
                    }
                    StepSwitcher(step, encounter.suggestedStep, reportsAvailable = encounter.reports.isNotEmpty(), enabled = !busy) {
                        haptics.performHapticFeedback(HapticFeedbackType.SegmentTick); step = it
                    }
                }
                AnimatedContent(
                    step,
                    transitionSpec = {
                        val forward = targetState.ordinal > initialState.ordinal
                        (slideInHorizontally { if (forward) it / 5 else -it / 5 } + fadeIn()) togetherWith (slideOutHorizontally { if (forward) -it / 5 else it / 5 } + fadeOut())
                    },
                    label = "step",
                ) { current ->
                    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        when (current) {
                            EncounterStep.RECORDING -> RecordingPanel(model, encounter, recording, recordingLocation == location, enabled = !busy, toggle = toggleRecording) { step = EncounterStep.TRANSCRIPT }
                            EncounterStep.TRANSCRIPT -> {
                                Column(Modifier.fillMaxWidth().vetCard(colors, RoundedCornerShape(26.dp))) {
                                    Text("Text prüfen und ergänzen", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                                    Spacer(Modifier.size(10.dp))
                                    TextField(
                                        transcript, { transcript = it }, Modifier.fillMaxWidth().heightIn(min = 240.dp).testTag("transcript-editor"),
                                        enabled = !busy && !recording, placeholder = { Text("Diktat eingeben oder einfügen …") },
                                        shape = RoundedCornerShape(16.dp),
                                        colors = TextFieldDefaults.colors(focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent, disabledIndicatorColor = Color.Transparent),
                                    )
                                    Spacer(Modifier.size(8.dp))
                                    SaveStatus(transcript == saved)
                                    Text("Zahlen, Einheiten und Verneinungen bitte am Original prüfen.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    val numbers = remember(transcript) { ReportValidator.numbers(transcript).sorted() }
                                    if (numbers.isNotEmpty()) Text("Zahlen im Text: " + numbers.joinToString(" · "), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    vocabulary.filter { it.appears(transcript) }.forEach { entry ->
                                        TextButton(onClick = { transcript = entry.applying(transcript) }, enabled = !busy) { Text("${entry.recognized} → ${entry.preferred}") }
                                    }
                                    encounter.transcripts.lastOrNull()?.takeIf { encounter.audio.isNotEmpty() }?.let { version ->
                                        OriginalAndRecording(version.rawText, encounter.playbackSegments, enabled = !busy && !recording) { model.play(it, location) }
                                    }
                                }
                                Row(
                                    Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).clickable { options = true }.vetCard(colors).testTag("report-options"),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Column(Modifier.weight(1f)) {
                                        Text(template.title, fontWeight = FontWeight.SemiBold)
                                        Text("${length.title} · ${template.audience.title} · ${if (mode == ReportExecutionMode.ONLINE) "Online" else "Offline"}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    }
                                    Icon(Icons.Rounded.Tune, "Anpassen", tint = colors.primary)
                                }
                                encounter.reportCheckpoint?.let { checkpoint ->
                                    Column(Modifier.fillMaxWidth().vetCard(colors)) {
                                        Text("Unvollständiger Zwischenstand", fontWeight = FontWeight.SemiBold)
                                        Text("${checkpoint.completedChunks} von ${checkpoint.totalChunks} Abschnitten gespeichert", color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    }
                                }
                            }
                            EncounterStep.REPORT -> {
                                encounter.reports.reversed().forEach { report ->
                                    val approved = report.approvedAt != null
                                    val accent = if (approved) Color(0xFF34C759) else Color(0xFFFF9F0A)
                                    Row(
                                        Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).clickable { nav.navigate(ReportRoute(location.caseID, location.encounterID, report.id)) }.vetCard(colors),
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        Box(Modifier.size(44.dp).clip(CircleShape).background(accent.copy(alpha = 0.14f)), contentAlignment = Alignment.Center) {
                                            Icon(if (approved) Icons.Rounded.Verified else Icons.Rounded.Description, null, tint = accent)
                                        }
                                        Spacer(Modifier.width(14.dp))
                                        Column {
                                            Text(report.content.template.title, fontWeight = FontWeight.SemiBold)
                                            Text(if (approved) "Geprüft" else "Bitte prüfen", color = colors.primary)
                                            Text(report.createdAt.germanDateTime(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                        }
                                    }
                                }
                                TextButton(onClick = { step = EncounterStep.TRANSCRIPT }) { Text("Text bearbeiten oder weiteren Bericht erstellen") }
                            }
                        }
                        encounter.lastError?.takeIf { current != EncounterStep.RECORDING }?.let {
                            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 8.dp))
                        }
                    }
                }
                Spacer(Modifier.size(80.dp))
            }
        }
    }

    val modelInstalled by model.localModel.installed.collectAsStateWithLifecycle()
    if (options) ReportOptionsDialog(
        template, length, mode, online.isEnabled, modelInstalled, { template = it }, { length = it }, { mode = it },
        onOpenSettings = { options = false; nav.navigate(if (mode == ReportExecutionMode.ONLINE) OnlineRoute else SettingsRoute) },
    ) { options = false }
    if (editingCase) CaseEditorDialog(model, item) { editingCase = false }
}

/** Segmented step control with a gradient pill that slides to the active step. */
@Composable
private fun StepSwitcher(step: EncounterStep, suggested: EncounterStep, reportsAvailable: Boolean, enabled: Boolean, select: (EncounterStep) -> Unit) {
    val colors = LocalVetColors.current
    BoxWithConstraints(Modifier.fillMaxWidth().padding(top = 10.dp).clip(CircleShape).background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f)).padding(4.dp)) {
        val width = maxWidth / EncounterStep.entries.size
        val offset by animateDpAsState(width * step.ordinal, spring(dampingRatio = 0.78f, stiffness = 380f), label = "pill")
        Box(Modifier.offset { IntOffset(offset.roundToPx(), 0) }.width(width).heightIn(min = 40.dp).shadow(6.dp, CircleShape, spotColor = colors.primary).clip(CircleShape).background(colors.gradient))
        Row {
            EncounterStep.entries.forEach { value ->
                val selected = value == step
                val done = value.ordinal < suggested.ordinal
                val available = enabled && (value != EncounterStep.REPORT || reportsAvailable)
                val tint by animateColorAsState(
                    when { selected -> Color.White; !available -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f); done -> colors.primary; else -> MaterialTheme.colorScheme.onSurface },
                    label = "step-tint",
                )
                Row(
                    Modifier.width(width).heightIn(min = 40.dp).clip(CircleShape).clickable(enabled = available) { select(value) }
                        .semantics { this.selected = selected; role = Role.Tab }.testTag("workflow-step-${value.ordinal}"),
                    horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
                ) {
                    AnimatedContent(done && !selected, label = "check") { check ->
                        if (check) Icon(Icons.Rounded.CheckCircle, null, tint = tint, modifier = Modifier.size(16.dp))
                        else Text("${value.ordinal + 1}", color = tint, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.labelMedium)
                    }
                    Spacer(Modifier.width(5.dp))
                    Text(value.title, color = tint, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold, maxLines = 1)
                }
            }
        }
    }
}

/** Port of the iOS recording section: timer, pulsing record button and an explicit text fallback. */
@Composable
private fun RecordingPanel(
    model: AppViewModel, encounter: Encounter, recording: Boolean, ownsRecorder: Boolean, enabled: Boolean,
    toggle: () -> Unit, enterText: () -> Unit,
) {
    val colors = LocalVetColors.current
    val elapsed by model.recorder.elapsed.collectAsStateWithLifecycle()
    val recorderError by model.recorder.error.collectAsStateWithLifecycle()
    val stored = encounter.audio.sumOf { it.duration }
    val seconds = (if (ownsRecorder) maxOf(elapsed, stored) else stored).toInt()
    val red = Color(0xFFFF3B30)
    val title = when { recording -> "Aufnahme läuft"; encounter.audio.isEmpty() -> "Bereit für dein Diktat"; else -> "Aufnahme pausiert" }
    val action = when { recording -> "Pause"; encounter.audio.isEmpty() -> "Aufnahme starten"; else -> "Fortsetzen" }
    Column(Modifier.fillMaxWidth().vetCard(colors, RoundedCornerShape(26.dp), 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            val blink = rememberInfiniteTransition(label = "blink")
            val alpha by blink.animateFloat(1f, 0.25f, infiniteRepeatable(tween(700), RepeatMode.Reverse), label = "dot")
            Icon(Icons.Rounded.FiberManualRecord, null, tint = if (recording) red else MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(18.dp).graphicsLayer { this.alpha = if (recording) alpha else 1f })
            Spacer(Modifier.width(8.dp))
            AnimatedContent(title, label = "title") { Text(it, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold) }
        }
        Spacer(Modifier.size(6.dp))
        AnimatedContent(seconds, transitionSpec = { (slideInVertically { -it / 2 } + fadeIn()) togetherWith (slideOutVertically { it / 2 } + fadeOut()) }, label = "timer") { value ->
            Text(
                "%d:%02d".format(value / 60, value % 60), fontSize = androidx.compose.ui.unit.TextUnit(54f, androidx.compose.ui.unit.TextUnitType.Sp),
                fontWeight = FontWeight.SemiBold, color = if (recording) red else MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.testTag("recording-timer"),
            )
        }
        Box(Modifier.size(190.dp), contentAlignment = Alignment.Center) {
            if (recording) PulseRings(red)
            val scale by androidx.compose.animation.core.animateFloatAsState(if (recording) 1.06f else 1f, spring(dampingRatio = 0.55f, stiffness = 300f), label = "scale")
            val interaction = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }
            Box(
                Modifier.size(116.dp).graphicsLayer { scaleX = scale; scaleY = scale }.pressable(interaction)
                    .shadow(18.dp, CircleShape, spotColor = if (recording) red else colors.primary).clip(CircleShape)
                    .background(if (recording) Brush.linearGradient(listOf(Color(0xFFFF6B5E), red)) else colors.gradient)
                    .clickable(interaction, indication = null, enabled = enabled, role = Role.Button, onClick = toggle)
                    .semantics { contentDescription = action }.testTag("record-audio"),
                contentAlignment = Alignment.Center,
            ) {
                AnimatedContent(recording, label = "icon") { active ->
                    Icon(if (active) Icons.Rounded.Pause else Icons.Rounded.Mic, null, tint = Color.White, modifier = Modifier.size(44.dp))
                }
            }
        }
        AnimatedContent(action, label = "action") { Text(it, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        Spacer(Modifier.size(6.dp))
        Text("Lass die App während der Aufnahme geöffnet. Jedes Segment wird sofort verschlüsselt gespeichert.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        if (ownsRecorder) recorderError?.let { Spacer(Modifier.size(6.dp)); Text(it, style = MaterialTheme.typography.bodySmall, color = red, textAlign = TextAlign.Center) }
        encounter.lastError?.let { Spacer(Modifier.size(6.dp)); Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center) }
        AnimatedVisibility(!recording) {
            TextButton(onClick = enterText, enabled = enabled, modifier = Modifier.padding(top = 8.dp).testTag("enter-transcript")) {
                Icon(Icons.Rounded.Keyboard, null); Spacer(Modifier.width(8.dp)); Text("Text stattdessen eingeben")
            }
        }
    }
}

/** Three expanding rings behind the record button while the microphone is live. */
@Composable
private fun PulseRings(color: Color) {
    val transition = rememberInfiniteTransition(label = "pulse")
    repeat(3) { index ->
        val progress by transition.animateFloat(
            0f, 1f, infiniteRepeatable(tween(2100, delayMillis = index * 700, easing = LinearEasing), RepeatMode.Restart), label = "ring$index",
        )
        Box(
            Modifier.size(116.dp).graphicsLayer { scaleX = 1f + progress * 0.62f; scaleY = scaleX; alpha = (1f - progress) * 0.45f }
                .clip(CircleShape).background(color),
        )
    }
}

/** The recognizer's untouched output and playback per sentence, for checking numbers and negations. */
@Composable
private fun OriginalAndRecording(raw: String, segments: List<de.tobwil.vetmed.core.TranscriptSegment>, enabled: Boolean, play: (de.tobwil.vetmed.core.TranscriptSegment) -> Unit) {
    var open by rememberSaveable { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(top = 6.dp)) {
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).clickable { open = !open }.padding(vertical = 8.dp).testTag("original-recording"),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Original und Aufnahme", fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            Icon(if (open) Icons.Rounded.ExpandLess else Icons.Rounded.ExpandMore, null)
        }
        AnimatedVisibility(open) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(raw, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                segments.forEach { segment ->
                    TextButton(onClick = { play(segment) }, enabled = enabled) {
                        Icon(Icons.Rounded.PlayCircle, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp))
                        Text(segment.text, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
                    }
                }
            }
        }
    }
}

@Composable
private fun SaveStatus(isSaved: Boolean) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 4.dp)) {
        AnimatedContent(isSaved, label = "save") { done ->
            Icon(if (done) Icons.Rounded.CloudDone else Icons.Rounded.Sync, null, tint = if (done) Color(0xFF34C759) else MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(16.dp))
        }
        Spacer(Modifier.width(6.dp))
        Text(if (isSaved) "Text gespeichert" else "Text wird gespeichert …", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("transcript-save-status"))
    }
}

@Composable
private fun PrimaryAction(step: EncounterStep, reportTitle: String?, hasText: Boolean, onClick: () -> Unit) {
    val colors = LocalVetColors.current
    val (title, enabled) = when (step) {
        EncounterStep.RECORDING -> "Fertig · Text prüfen" to true
        EncounterStep.TRANSCRIPT -> "Bericht erstellen" to hasText
        EncounterStep.REPORT -> (reportTitle ?: "Bericht erstellen") to (reportTitle != null)
    }
    val interaction = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }
    Box(
        Modifier.fillMaxWidth().height(54.dp).pressable(interaction)
            .shadow(if (enabled) 12.dp else 0.dp, CircleShape, spotColor = colors.primary).clip(CircleShape)
            .background(if (enabled) colors.gradient else androidx.compose.ui.graphics.SolidColor(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.12f)))
            .clickable(interaction, indication = null, enabled = enabled, role = androidx.compose.ui.semantics.Role.Button, onClick = onClick)
            .testTag(if (step == EncounterStep.RECORDING) "finish-dictation" else "generate-report"),
        contentAlignment = Alignment.Center,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (step == EncounterStep.TRANSCRIPT) { Icon(Icons.Rounded.AutoAwesome, null, tint = Color.White); Spacer(Modifier.width(8.dp)) }
            Text(title, color = if (enabled) Color.White else MaterialTheme.colorScheme.onSurfaceVariant, fontWeight = FontWeight.SemiBold)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ReportOptionsDialog(
    template: ReportTemplate, length: ReportLength, mode: ReportExecutionMode, onlineEnabled: Boolean, modelInstalled: Boolean,
    setTemplate: (ReportTemplate) -> Unit, setLength: (ReportLength) -> Unit, setMode: (ReportExecutionMode) -> Unit,
    onOpenSettings: () -> Unit, onDone: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDone,
        title = { Text("Bericht anpassen") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                var expanded by remember { mutableStateOf(false) }
                ExposedDropdownMenuBox(expanded, { expanded = it }) {
                    OutlinedTextField(
                        template.title, {}, readOnly = true, label = { Text("Vorlage") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded) },
                        modifier = Modifier.menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable).fillMaxWidth(),
                    )
                    ExposedDropdownMenu(expanded, { expanded = false }) {
                        ReportTemplate.entries.forEach { DropdownMenuItem(text = { Text(it.title) }, onClick = { setTemplate(it); expanded = false }) }
                    }
                }
                Text("Für: ${template.audience.title}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("Länge", style = MaterialTheme.typography.labelLarge)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    ReportLength.entries.forEach { FilterChip(it == length, { setLength(it) }, label = { Text(it.title) }) }
                }
                Text("Verarbeitung", style = MaterialTheme.typography.labelLarge)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(mode == ReportExecutionMode.ONLINE, { setMode(ReportExecutionMode.ONLINE) }, label = { Text("Online") })
                    FilterChip(mode == ReportExecutionMode.OFFLINE, { setMode(ReportExecutionMode.OFFLINE) }, label = { Text("Offline") }, modifier = Modifier.testTag("mode-offline"))
                }
                if (mode == ReportExecutionMode.ONLINE) {
                    Text("Online wird nur der geprüfte Text mit deinen Berichtseinstellungen gesendet.", style = MaterialTheme.typography.bodySmall)
                    if (!onlineEnabled) TextButton(onClick = onOpenSettings) { Text("Online-Zugang einrichten") }
                } else if (modelInstalled) {
                    Text("Der Bericht entsteht mit Gemma auf diesem Gerät. Es wird nichts gesendet.", style = MaterialTheme.typography.bodySmall)
                } else {
                    Text("Für Offline-Berichte muss das lokale Modell in den Einstellungen installiert sein.", style = MaterialTheme.typography.bodySmall)
                    TextButton(onClick = onOpenSettings) { Text("Offline-Modell einrichten") }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDone) { Text("Fertig") } },
    )
}
