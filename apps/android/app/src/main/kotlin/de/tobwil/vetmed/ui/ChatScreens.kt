package de.tobwil.vetmed.ui

import android.content.ClipData
import android.content.ClipDescription
import android.graphics.BitmapFactory
import android.os.PersistableBundle
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import de.tobwil.vetmed.core.MedicationSafety
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.AttachFile
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Description
import androidx.compose.material.icons.rounded.EditNote
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.MenuBook
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Science
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.Stop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import de.tobwil.vetmed.AppViewModel
import de.tobwil.vetmed.core.AnalysisRun
import de.tobwil.vetmed.core.AnalysisStatus
import de.tobwil.vetmed.core.AppFailure
import de.tobwil.vetmed.core.AttachmentKind
import de.tobwil.vetmed.core.ChatAttachment
import de.tobwil.vetmed.core.ChatLocation
import de.tobwil.vetmed.core.ChatMarkdown
import de.tobwil.vetmed.core.ChatReportSelection
import de.tobwil.vetmed.core.SparringDraft
import de.tobwil.vetmed.core.SparringMode
import de.tobwil.vetmed.core.SparringRequestBuilder
import de.tobwil.vetmed.core.SparringSnapshot
import de.tobwil.vetmed.core.germanDateTime
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

// Chat list -------------------------------------------------------------------------------------------

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatListScreen(model: AppViewModel, nav: NavHostController) {
    val document by model.document.collectAsStateWithLifecycle()
    val busy by model.busy.collectAsStateWithLifecycle()
    var search by rememberSaveable { mutableStateOf("") }
    val scroll = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    val checks = remember(document, search) {
        document.quickChecks.orEmpty().filter { search.isEmpty() || it.title.contains(search, true) }
            .sortedByDescending { it.runs.lastOrNull()?.createdAt ?: it.createdAt }
    }
    val caseChats = remember(document, search) {
        document.cases.flatMap { item -> item.encounters.filter { it.hasChat }.map { item to it } }
            .filter { (item, encounter) -> search.isEmpty() || item.label.contains(search, true) || encounter.sparringDraft?.question.orEmpty().contains(search, true) }
            .sortedByDescending { it.second.lastActivity }
    }
    Box(Modifier.fillMaxSize()) {
        AmbientBackground()
        Scaffold(
            modifier = Modifier.nestedScroll(scroll.nestedScrollConnection), containerColor = Color.Transparent,
            contentColor = MaterialTheme.colorScheme.onBackground,
            topBar = {
                LargeTopAppBar(
                    title = { Text("Chats", fontWeight = FontWeight.Bold) }, scrollBehavior = scroll,
                    actions = {
                        IconButton(enabled = !busy, modifier = Modifier.testTag("new-quick-check"), onClick = {
                            model.newQuickCheck { nav.navigate(ChatConversationRoute(it.caseID, it.encounterID)) }
                        }) { Icon(Icons.Rounded.EditNote, "Neuer Chat") }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent, scrolledContainerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f)),
                )
            },
        ) { padding ->
            LazyColumn(
                contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = padding.calculateTopPadding(), bottom = 32.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                item {
                    OutlinedTextField(
                        search, { search = it }, Modifier.fillMaxWidth(), singleLine = true, shape = RoundedCornerShape(18.dp),
                        placeholder = { Text("Frage oder Fall suchen") }, leadingIcon = { Icon(Icons.Rounded.Search, null) },
                    )
                }
                if (checks.isEmpty() && caseChats.isEmpty()) item {
                    EmptyState(
                        Icons.Rounded.AutoAwesome,
                        if (search.isEmpty()) "Was möchtest du besprechen?" else "Kein passender Chat",
                        if (search.isEmpty()) "Starte einen Chat und füge bei Bedarf Bilder oder Befunde hinzu. Ein Fall ist dafür nicht nötig." else "Suche nach einer Frage oder Fallkennung.",
                    )
                }
                if (checks.isNotEmpty()) item { SectionTitle("Ohne Fall") }
                items(checks, key = { it.id }) { check ->
                    val last = check.runs.lastOrNull()?.text.orEmpty()
                    ChatRow(Icons.Rounded.AutoAwesome, check.title, if (last.isEmpty()) "Entwurf" else ChatMarkdown.plainText(last).take(100), "chat-row-" + check.id) {
                        nav.navigate(ChatConversationRoute(null, check.id))
                    }
                }
                if (caseChats.isNotEmpty()) item { SectionTitle("Zu einem Fall") }
                items(caseChats, key = { it.second.id }) { (item, encounter) ->
                    val question = encounter.analysisRuns?.firstOrNull()?.snapshot?.draft?.question ?: encounter.sparringDraft?.question ?: "Fall-Chat"
                    ChatRow(SpeciesIcon.forSpecies(item.species), item.label, question, "chat-row-" + encounter.id) {
                        nav.navigate(ChatConversationRoute(item.id, encounter.id))
                    }
                }
            }
        }
    }
}

@Composable
private fun ChatRow(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, subtitle: String, tag: String, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).clickable(onClick = onClick).vetCard(LocalVetColors.current, padding = 14.dp)
            .testTag(tag).semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
    ) {
        GradientIcon(icon, size = 38.dp)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f))
    }
}

// Conversation ----------------------------------------------------------------------------------------

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatConversationScreen(model: AppViewModel, nav: NavHostController, location: ChatLocation) {
    val document by model.document.collectAsStateWithLifecycle()
    val busy by model.busy.collectAsStateWithLifecycle()
    val online by model.online.collectAsStateWithLifecycle()
    val hasKey by model.hasKey.collectAsStateWithLifecycle()
    val hasGeminiKey by model.hasGeminiKey.collectAsStateWithLifecycle()
    val activeID by model.activeAnalysisID.collectAsStateWithLifecycle()
    val colors = LocalVetColors.current
    val haptics = LocalHapticFeedback.current
    val clipboard = LocalClipboard.current
    val scope = rememberCoroutineScope()
    val encounter = remember(document, location) { model.chatContext(location) }
    val caseItem = document.cases.firstOrNull { it.id == location.caseID }
    val runs = encounter?.analysisRuns.orEmpty()
    val attachments = encounter?.chatAttachments.orEmpty()
    val sending = runs.any { it.id == activeID }

    var loaded by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf(SparringDraft()) }
    var savedDraft by remember { mutableStateOf<SparringDraft?>(null) }
    var review by remember { mutableStateOf<ChatAttachment?>(null) }
    // Lab results open the table review; "als Text prüfen" switches one of them to the plain text review.
    var labAsText by remember { mutableStateOf(setOf<String>()) }
    var details by remember { mutableStateOf(false) }
    var reportsSheet by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    var copiedID by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(encounter == null) { if (encounter == null) nav.popBackStack() }
    LaunchedEffect(encounter != null) {
        if (!loaded && encounter != null) {
            var initial = encounter.sparringDraft ?: SparringDraft()
            // First opening of a case chat selects the latest report as knowledge; [] keeps an explicit opt-out.
            if (initial.reportIDs == null && caseItem != null) initial = initial.copy(reportIDs = ChatReportSelection.defaultIDs(caseItem, location.encounterID))
            draft = initial; savedDraft = encounter.sparringDraft; loaded = true
        }
    }
    LaunchedEffect(draft) {
        if (!loaded || draft == savedDraft) return@LaunchedEffect
        delay(700)
        val value = draft
        if (model.saveSparringDraft(value, location)) savedDraft = value
    }
    val pending by rememberUpdatedState(draft.takeIf { loaded && it != savedDraft })
    DisposableEffect(Unit) { onDispose { pending?.let { model.flushDraft(it, location) } } }

    val selected = attachments.filter { it.id in draft.attachmentIDs.orEmpty() }
    val prepared = draft.copy(
        historyIDs = runs.filter { it.status == AnalysisStatus.COMPLETED }.map { it.id }, mode = SparringMode.QUESTION,
        question = draft.question.ifBlank { if (draft.attachmentIDs.isNullOrEmpty()) draft.question else "Bitte diese Anhänge fachlich einordnen." },
    )
    val snapshot: Result<SparringSnapshot> = remember(prepared, encounter, online.modelID, caseItem, online.usesSourceSearch) {
        runCatching {
            SparringRequestBuilder.prepare(
                location.caseID, encounter ?: throw AppFailure("Dieser Chat ist nicht mehr vorhanden."), prepared, online.modelID, caseItem,
                sourceSearch = online.usesSourceSearch,
            )
        }
    }
    // A sent message clears the composer only when the stored run matches what was typed.
    val lastRunID = runs.lastOrNull()?.id
    LaunchedEffect(lastRunID) {
        val run = runs.lastOrNull() ?: return@LaunchedEffect
        if (loaded && run.snapshot.draft.question == prepared.question && run.snapshot.draft.attachmentIDs == prepared.attachmentIDs) {
            draft = SparringDraft(reportIDs = draft.reportIDs)
        }
    }

    val photoPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri?.let {
            model.importAttachment(it, location) { attachment ->
                draft = draft.copy(attachmentIDs = draft.attachmentIDs.orEmpty() + attachment.id)
                // A photo of a document is read like a PDF; its review opens while the reading runs.
                if (attachment.kind == AttachmentKind.DOCUMENT) review = attachment
            }
        }
    }
    val filePicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let {
            model.importAttachment(it, location) { attachment ->
                draft = draft.copy(attachmentIDs = draft.attachmentIDs.orEmpty() + attachment.id)
                if (attachment.kind == AttachmentKind.DOCUMENT) review = attachment
            }
        }
    }
    val context = androidx.compose.ui.platform.LocalContext.current
    val voicePermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) model.startVoice(location, draft)
        else model.reportError("Ohne Mikrofonzugriff ist der Sprachmodus nicht möglich. Du kannst den Zugriff in den Android-Einstellungen erlauben.")
    }
    val startVoice = {
        if (androidx.core.content.ContextCompat.checkSelfPermission(context, android.Manifest.permission.RECORD_AUDIO) == android.content.pm.PackageManager.PERMISSION_GRANTED) model.startVoice(location, draft)
        else voicePermission.launch(android.Manifest.permission.RECORD_AUDIO)
    }
    val share = rememberShareLauncher("Antwort teilen") {}
    val listState = rememberLazyListState()
    LaunchedEffect(runs.size, runs.lastOrNull()?.text?.length) { if (runs.isNotEmpty()) listState.animateScrollToItem(runs.size) }

    if (encounter == null) return
    Box(Modifier.fillMaxSize()) {
        AmbientBackground()
        Scaffold(
            containerColor = Color.Transparent, contentColor = MaterialTheme.colorScheme.onBackground,
            topBar = {
                BackTopBar("Chat", nav) {
                    if (hasGeminiKey) IconButton(enabled = !busy, onClick = startVoice, modifier = Modifier.testTag("start-voice")) {
                        Icon(Icons.Rounded.GraphicEq, "Sprechen")
                    }
                    IconButton(enabled = !busy, onClick = { model.newQuickCheck { nav.navigate(ChatConversationRoute(it.caseID, it.encounterID)) } }) { Icon(Icons.Rounded.EditNote, "Neuer Chat") }
                    Box {
                        IconButton(enabled = !busy, onClick = { menu = true }, modifier = Modifier.testTag("chat-menu")) { Icon(Icons.Rounded.MoreVert, "Chat-Menü") }
                        DropdownMenu(menu, { menu = false }) {
                            DropdownMenuItem(text = { Text("Chat-Details") }, leadingIcon = { Icon(Icons.Rounded.Info, null) }, onClick = { menu = false; details = true })
                            if (location.caseID == null) DropdownMenuItem(
                                text = { Text("Chat löschen", color = Color(0xFFFF3B30)) }, leadingIcon = { Icon(Icons.Rounded.Delete, null, tint = Color(0xFFFF3B30)) },
                                onClick = { menu = false; deleting = true },
                            )
                        }
                    }
                }
            },
            bottomBar = {
                Composer(
                    draft = draft, onDraft = { draft = it }, selected = selected, attachments = attachments, sending = sending, busy = busy,
                    location = location, model = model, hasTranscript = encounter.transcripts.isNotEmpty(), isCaseChat = caseItem != null,
                    configured = online.isEnabled && hasKey, saved = savedDraft == draft,
                    onPhoto = { photoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                    onFile = { filePicker.launch(arrayOf("application/pdf", "text/plain", "text/markdown", "image/*")) },
                    onReview = { review = it }, onReports = { reportsSheet = true }, onSetup = { details = true },
                    onTranscript = { encounter.transcripts.lastOrNull()?.let { t -> draft = draft.copy(context = t.editedText, transcriptVersionID = t.id) } },
                    onSend = {
                        if (sending) { model.cancel(); return@Composer }
                        selected.firstOrNull { it.kind == AttachmentKind.DOCUMENT && it.reviewedAt == null }?.let { review = it; return@Composer }
                        snapshot.fold(
                            onSuccess = { value -> haptics.performHapticFeedback(HapticFeedbackType.Confirm); scope.launch { if (model.saveSparringDraft(draft, location)) savedDraft = draft }; model.startAnalysis(value) },
                            onFailure = { model.reportError(it.message ?: "Die Nachricht konnte nicht vorbereitet werden.") },
                        )
                    },
                )
            },
        ) { padding ->
            LazyColumn(
                state = listState,
                contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = padding.calculateTopPadding() + 4.dp, bottom = padding.calculateBottomPadding() + 16.dp),
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                item {
                    Row(
                        Modifier.fillMaxWidth().shadow(4.dp, CircleShape).clip(CircleShape).background(MaterialTheme.colorScheme.surface.copy(alpha = 0.92f))
                            .padding(horizontal = 16.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(if (caseItem == null) Icons.Rounded.AutoAwesome else Icons.Rounded.Folder, null, tint = colors.primary, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(caseItem?.label ?: "Ohne Fall", fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f).testTag("chat-scope"))
                        if (caseItem != null) Text(encounter.date.germanDateTime(), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                if (runs.isEmpty()) item { EmptyChat { title -> draft = draft.copy(question = "$title: ") } }
                items(runs, key = { it.id }) { run ->
                    Column(Modifier.animateItem(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        UserBubble(run, location, model) { id -> attachments.firstOrNull { it.id == id }?.let { review = it } }
                        if (run.status.isActive || run.text.isNotEmpty()) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                GradientIcon(Icons.Rounded.AutoAwesome, size = 26.dp)
                                Spacer(Modifier.width(8.dp))
                                Text("VetMed", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                if (run.status.isActive && run.text.isEmpty()) {
                                    Spacer(Modifier.width(10.dp)); TypingIndicator(); Spacer(Modifier.width(8.dp))
                                    Text("Denke nach …", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                        }
                        if (run.text.isNotEmpty()) {
                            MarkdownText(run.text, Modifier.fillMaxWidth().vetCard(colors, RoundedCornerShape(20.dp)))
                            if (!run.status.isActive) MedicationNotice(run)
                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                AssistChip(
                                    enabled = !run.status.isActive, modifier = Modifier.testTag("copy-answer-" + run.id),
                                    onClick = {
                                        val clip = ClipData.newPlainText("VetMed-Antwort", ChatMarkdown.export(run)).apply {
                                            description.extras = PersistableBundle().apply { putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true) }
                                        }
                                        scope.launch { clipboard.setClipEntry(ClipEntry(clip)) }; copiedID = run.id
                                        haptics.performHapticFeedback(HapticFeedbackType.Confirm)
                                    },
                                    label = { Text(if (copiedID == run.id) "Kopiert" else "Kopieren") },
                                    leadingIcon = { Icon(if (copiedID == run.id) Icons.Rounded.Check else Icons.Rounded.ContentCopy, null, Modifier.size(16.dp)) },
                                )
                                AssistChip(
                                    enabled = !run.status.isActive, modifier = Modifier.testTag("share-answer-" + run.id),
                                    onClick = { share.text(ChatMarkdown.export(run), "Chat") },
                                    label = { Text("Teilen") }, leadingIcon = { Icon(Icons.Rounded.Share, null, Modifier.size(16.dp)) },
                                )
                            }
                        }
                        if (!run.status.isActive) Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                if (run.status == AnalysisStatus.COMPLETED) "KI-Antwort · fachlich prüfen" else run.status.title,
                                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f),
                            )
                            if (run.status != AnalysisStatus.COMPLETED) TextButton(onClick = { draft = run.snapshot.draft }) { Text("Erneut versuchen") }
                        }
                        run.notice?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                    }
                }
            }
        }
    }

    val voice by model.voice.collectAsStateWithLifecycle()
    val voiceQuestion by model.voiceQuestion.collectAsStateWithLifecycle()
    voice?.takeIf { it.location == location }?.let { VoiceOverlay(model, it) }
    if (voiceQuestion?.first == location) VoiceConsentDialog { model.decideVoice(it) }
    review?.let { attachment ->
        val use: (String) -> Unit = { id ->
            if (id !in draft.attachmentIDs.orEmpty()) draft = draft.copy(attachmentIDs = draft.attachmentIDs.orEmpty() + id)
            review = null
        }
        val current = attachments.firstOrNull { it.id == attachment.id } ?: attachment
        if (current.isLab == true && current.id !in labAsText) {
            LabReviewSheet(model, location, current.id, onDismiss = { review = null }, asText = { labAsText = labAsText + current.id }, use = use)
        } else AttachmentReviewSheet(model, location, current, onDismiss = { review = null }, use = use)
    }
    if (reportsSheet && caseItem != null) ReportSelectionSheet(caseItem, draft.reportIDs.orEmpty(), onDismiss = { reportsSheet = false }) { draft = draft.copy(reportIDs = it) }
    if (details) ChatDetailsSheet(snapshot, runs, online.modelID.takeIf { it.isNotEmpty() }?.let { "${online.provider.title} · $it" } ?: "Noch nicht eingerichtet", encounter.transcripts.isNotEmpty(),
        onTranscript = { encounter.transcripts.lastOrNull()?.let { t -> draft = draft.copy(context = t.editedText, transcriptVersionID = t.id) }; details = false },
        onSettings = { details = false; nav.navigate(OnlineRoute) }, onDismiss = { details = false })
    if (deleting) AlertDialog(
        onDismissRequest = { deleting = false },
        title = { Text("Chat löschen?") }, text = { Text("Diesen Chat mit allen Nachrichten und Anhängen löschen?") },
        confirmButton = { TextButton(onClick = { deleting = false; model.deleteQuickCheck(location.encounterID) { nav.popBackStack() } }) { Text("Chat löschen", color = Color(0xFFFF3B30)) } },
        dismissButton = { TextButton(onClick = { deleting = false }) { Text("Behalten") } },
    )
}

@Composable
private fun EmptyChat(suggest: (String) -> Unit) {
    Column(Modifier.padding(vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        GradientIcon(Icons.Rounded.AutoAwesome, size = 64.dp)
        Text("Was möchtest du besprechen?", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        Text("Schreib einfach los. Über + kannst du Bilder und Befunde hinzufügen.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        listOf("Befund erklären", "Nächste Schritte", "Differenzialdiagnosen", "Dosierung prüfen").chunked(2).forEach { pair ->
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                pair.forEach { title -> OutlinedButton(onClick = { suggest(title) }, shape = RoundedCornerShape(16.dp), modifier = Modifier.weight(1f)) { Text(title, maxLines = 1) } }
            }
        }
    }
}

@Composable
private fun UserBubble(run: AnalysisRun, location: ChatLocation, model: AppViewModel, openAttachment: (String) -> Unit) {
    val colors = LocalVetColors.current
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
        Column(
            Modifier.widthIn(max = 320.dp).shadow(8.dp, RoundedCornerShape(20.dp, 20.dp, 6.dp, 20.dp), spotColor = colors.primary)
                .clip(RoundedCornerShape(20.dp, 20.dp, 6.dp, 20.dp)).background(colors.gradient).padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            val images = run.snapshot.images.orEmpty()
            if (images.isNotEmpty()) Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                images.forEach { image -> Thumbnail(model, location, image.attachmentID, Modifier.clickable { openAttachment(image.attachmentID) }) }
            }
            if (!run.snapshot.documents.isNullOrEmpty()) Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.Description, null, tint = Color.White, modifier = Modifier.size(16.dp)); Spacer(Modifier.width(4.dp))
                val count = run.snapshot.documents!!.size
                Text("$count ${if (count == 1) "Dokumenttext" else "Dokumenttexte"}", color = Color.White, style = MaterialTheme.typography.labelMedium)
            }
            if (!run.snapshot.reports.isNullOrEmpty()) Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.MenuBook, null, tint = Color.White, modifier = Modifier.size(16.dp)); Spacer(Modifier.width(4.dp))
                val count = run.snapshot.reports!!.size
                Text("$count ${if (count == 1) "Bericht" else "Berichte"} als Wissen", color = Color.White, style = MaterialTheme.typography.labelMedium)
            }
            SelectionContainer { Text(run.snapshot.draft.question, color = Color.White) }
        }
    }
}

@Composable
private fun Thumbnail(model: AppViewModel, location: ChatLocation, id: String, modifier: Modifier = Modifier) {
    val bitmap by produceState<android.graphics.Bitmap?>(null, id) {
        value = runCatching {
            val data = model.attachmentData(location, id, upload = true)
            BitmapFactory.decodeByteArray(data, 0, data.size, BitmapFactory.Options().apply { inSampleSize = 4 })
        }.getOrNull()
    }
    Box(modifier.size(72.dp, 64.dp).clip(RoundedCornerShape(8.dp)).background(Color.White.copy(alpha = 0.2f)), contentAlignment = Alignment.Center) {
        bitmap?.let { Image(it.asImageBitmap(), "Bild", contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) } ?: Icon(Icons.Rounded.Image, "Bild", tint = Color.White)
    }
}

@Composable
private fun Composer(
    draft: SparringDraft, onDraft: (SparringDraft) -> Unit, selected: List<ChatAttachment>, attachments: List<ChatAttachment>,
    sending: Boolean, busy: Boolean, location: ChatLocation, model: AppViewModel, hasTranscript: Boolean, isCaseChat: Boolean,
    configured: Boolean, saved: Boolean, onPhoto: () -> Unit, onFile: () -> Unit, onReview: (ChatAttachment) -> Unit,
    onReports: () -> Unit, onSetup: () -> Unit, onTranscript: () -> Unit, onSend: () -> Unit,
) {
    val colors = LocalVetColors.current
    var focused by remember { mutableStateOf(false) }
    var plus by remember { mutableStateOf(false) }
    val disabled = (busy && !sending) || (!sending && draft.question.isBlank() && selected.isEmpty())
    val border by animateColorAsState(if (focused) colors.primary.copy(alpha = 0.6f) else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f), label = "composer")
    Column(
        Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface.copy(alpha = 0.94f)).navigationBarsPadding().imePadding()
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (selected.isNotEmpty()) Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            selected.forEach { item ->
                Row(Modifier.clip(RoundedCornerShape(12.dp)).background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.07f)).padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.clickable { onReview(item) }) {
                        if (item.kind == AttachmentKind.IMAGE) Thumbnail(model, location, item.id)
                        else Row(Modifier.padding(6.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Rounded.Description, null, Modifier.size(16.dp), tint = if (item.reviewedAt == null) Color(0xFFFF9F0A) else colors.primary)
                            Spacer(Modifier.width(4.dp)); Text(item.originalName, style = MaterialTheme.typography.labelMedium, maxLines = 1, modifier = Modifier.widthIn(max = 140.dp))
                        }
                    }
                    IconButton(onClick = { onDraft(draft.copy(attachmentIDs = draft.attachmentIDs.orEmpty() - item.id)) }, modifier = Modifier.size(28.dp)) {
                        Icon(Icons.Rounded.Close, "Anhang entfernen", Modifier.size(16.dp))
                    }
                }
            }
        }
        if (draft.context.isNotEmpty()) Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.Description, null, Modifier.size(16.dp), tint = colors.primary); Spacer(Modifier.width(6.dp))
            Text("Falltext hinzugefügt", style = MaterialTheme.typography.labelMedium, modifier = Modifier.weight(1f))
            TextButton(onClick = { onDraft(draft.copy(context = "", transcriptVersionID = null)) }) { Text("Entfernen") }
        }
        if (isCaseChat) Row(Modifier.clip(CircleShape).clickable(onClick = onReports).padding(horizontal = 4.dp, vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.MenuBook, null, Modifier.size(16.dp), tint = colors.primary); Spacer(Modifier.width(6.dp))
            val count = draft.reportIDs.orEmpty().size
            Text(if (count == 0) "Keine Berichte als Wissen" else "$count ${if (count == 1) "Bericht" else "Berichte"} als Wissen", style = MaterialTheme.typography.labelMedium, color = colors.primary)
        }
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(MaterialTheme.colorScheme.surface).border(BorderStroke(if (focused) 1.5.dp else 1.dp, border), RoundedCornerShape(24.dp)).padding(6.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            Box {
                IconButton(enabled = !busy, onClick = { plus = true }, modifier = Modifier.size(40.dp).clip(CircleShape).background(colors.primary.copy(alpha = 0.14f)).testTag("chat-add-attachment")) {
                    Icon(Icons.Rounded.Add, "Anhang hinzufügen", tint = colors.primary)
                }
                DropdownMenu(plus, { plus = false }) {
                    DropdownMenuItem(text = { Text("Foto auswählen") }, leadingIcon = { Icon(Icons.Rounded.Image, null) }, onClick = { plus = false; onPhoto() })
                    DropdownMenuItem(text = { Text("Datei hinzufügen") }, leadingIcon = { Icon(Icons.Rounded.AttachFile, null) }, onClick = { plus = false; onFile() })
                    attachments.filter { it.id !in draft.attachmentIDs.orEmpty() }.forEach { item ->
                        DropdownMenuItem(text = { Text("Vorhanden: " + item.displayName, maxLines = 1) }, onClick = { plus = false; onReview(item) })
                    }
                    if (hasTranscript) DropdownMenuItem(text = { Text("Falltranskript hinzufügen") }, leadingIcon = { Icon(Icons.Rounded.Description, null) }, onClick = { plus = false; onTranscript() })
                    if (isCaseChat) DropdownMenuItem(text = { Text("Berichte als Wissen") }, leadingIcon = { Icon(Icons.Rounded.MenuBook, null) }, onClick = { plus = false; onReports() })
                }
            }
            TextField(
                draft.question, { onDraft(draft.copy(question = it)) },
                Modifier.weight(1f).testTag("sparring-question").onFocusChanged { focused = it.isFocused },
                placeholder = { Text("Frag mich etwas …") }, maxLines = 6,
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent, disabledContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent,
                ),
            )
            Box(
                Modifier.size(40.dp).clip(CircleShape)
                    .background(if (disabled) androidx.compose.ui.graphics.SolidColor(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.2f)) else if (sending) androidx.compose.ui.graphics.SolidColor(Color(0xFFFF3B30)) else colors.gradient)
                    .clickable(enabled = !disabled, onClick = onSend)
                    .testTag("send-analysis").semantics { contentDescription = if (sending) "Antwort abbrechen" else "Senden" },
                contentAlignment = Alignment.Center,
            ) { Icon(if (sending) Icons.Rounded.Stop else Icons.Rounded.ArrowUpward, null, tint = Color.White) }
        }
        if (!configured) TextButton(onClick = onSetup, modifier = Modifier.align(Alignment.CenterHorizontally)) { Text("Zum Senden einmalig API-Zugang einrichten") }
        Text(
            if (saved) "Lokal gespeichert · KI-Antworten fachlich prüfen" else "Entwurf wird gespeichert …",
            style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.align(Alignment.CenterHorizontally).testTag("chat-save-status"),
        )
    }
}


// Sheets ----------------------------------------------------------------------------------------------

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AttachmentReviewSheet(model: AppViewModel, location: ChatLocation, attachment: ChatAttachment, onDismiss: () -> Unit, use: (String) -> Unit) {
    val colors = LocalVetColors.current
    var text by remember(attachment.id) { mutableStateOf(attachment.reviewedText ?: attachment.extractedText.orEmpty()) }
    var failure by remember { mutableStateOf<String?>(null) }
    val image by produceState<android.graphics.Bitmap?>(null, attachment.id) {
        if (attachment.kind == AttachmentKind.IMAGE) value = runCatching {
            val data = model.attachmentData(location, attachment.id, upload = true)
            BitmapFactory.decodeByteArray(data, 0, data.size)
        }.onFailure { failure = it.message }.getOrNull()
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(if (attachment.kind == AttachmentKind.IMAGE) "Bildvorschau" else "Dokument prüfen", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            if (attachment.kind == AttachmentKind.IMAGE) {
                image?.let { Image(it.asImageBitmap(), "Versandbild", Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)), contentScale = ContentScale.FillWidth) }
                    ?: failure?.let { Text(it) } ?: CircularProgressIndicator()
                Text("Dieses Bild wird gesendet: ${attachment.width ?: 0} × ${attachment.height ?: 0} Pixel. Das Original bleibt lokal; Standort- und Kameradaten sind aus dieser Version entfernt.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("Bitte eingeblendete Namen oder Kontaktdaten im Bild vor dem Anhängen entfernen.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Button(onClick = { use(attachment.id) }, enabled = image != null, shape = CircleShape, modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = colors.primary)) { Text("Verwenden") }
            } else {
                Text(
                    if (attachment.usedOCR) "Text wurde lokal erkannt. Bitte besonders Zahlen, Einheiten und Tabellen am Original prüfen."
                    else "Prüfe den ausgelesenen Text am Original. Nur dieser Text wird an den Chat übergeben.",
                    style = MaterialTheme.typography.bodySmall,
                )
                Text(attachment.originalName, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                OutlinedTextField(text, { text = it }, Modifier.fillMaxWidth().heightIn(min = 300.dp), textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Default))
                Button(
                    onClick = { model.reviewDocument(location, attachment.id, text) { use(attachment.id) } }, shape = CircleShape, modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                ) { Text("Text geprüft übernehmen") }
            }
            Spacer(Modifier.size(24.dp))
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ReportSelectionSheet(item: de.tobwil.vetmed.core.VetCase, selected: List<String>, onDismiss: () -> Unit, onChange: (List<String>) -> Unit) {
    val reports = remember(item) { ChatReportSelection.available(item) }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Berichte als Wissen", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            Text("Ausgewählte Berichte werden mit deiner nächsten Nachricht gesendet. Die Auswahl bleibt für weitere Fragen erhalten. Frühere Nachrichten bleiben im Verlauf; abgewählte Berichte werden nicht erneut gesendet.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (reports.isEmpty()) Text("Dieser Fall hat noch keine Berichte.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            reports.forEach { report ->
                Row(Modifier.fillMaxWidth().vetCard(LocalVetColors.current, RoundedCornerShape(18.dp), 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(report.title, fontWeight = FontWeight.SemiBold)
                        Text("Vorgang: ${report.encounterDate.germanDateTime()} · Version: ${report.createdAt.germanDateTime()}", style = MaterialTheme.typography.labelSmall)
                        Text(report.status + if (report.isOlderVersion) " · ältere Version" else "", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Checkbox(report.id in selected, { checked -> onChange(if (checked) selected + report.id else selected - report.id) })
                }
            }
            if (selected.isNotEmpty()) TextButton(onClick = { onChange(emptyList()) }) { Text("Alle Berichte abwählen") }
            Spacer(Modifier.size(24.dp))
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ChatDetailsSheet(
    snapshot: Result<SparringSnapshot>, runs: List<AnalysisRun>, connection: String, hasTranscript: Boolean,
    onTranscript: () -> Unit, onSettings: () -> Unit, onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Chat-Details", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            SectionTitle("Verbindung")
            Text(connection)
            TextButton(onClick = onSettings) { Text("API-Key & Modell") }
            Text("Nur beim Senden wird dein Chat übertragen. Kein automatischer Neuversand.", style = MaterialTheme.typography.bodySmall)
            Text(
                if (snapshot.getOrNull()?.sourceSearch == true) "Quellensuche: an, nur amtliche Arzneimittelquellen (EU, EMA, PharmNet.Bund, BVL, BASG)."
                else "Quellensuche: aus. Präparatangaben sind dann nur aus deiner Frage oder Anhängen belegbar.",
                style = MaterialTheme.typography.bodySmall,
            )
            if (hasTranscript) TextButton(onClick = onTranscript) { Text("Falltranskript hinzufügen") }
            SectionTitle("Nächste Anfrage")
            snapshot.fold(onSuccess = { PayloadPreview(it) }, onFailure = { Text(it.message.orEmpty(), style = MaterialTheme.typography.bodySmall) })
            runs.forEach { run ->
                SectionTitle(run.createdAt.germanDateTime())
                Text(run.actualModelID ?: run.snapshot.modelID, style = MaterialTheme.typography.labelSmall)
                run.usage?.let { Text("Tokens: ${it.inputTokens} Eingabe · ${it.outputTokens} Ausgabe · Preis unbekannt", style = MaterialTheme.typography.labelSmall) }
                PayloadPreview(run.snapshot)
            }
            Spacer(Modifier.size(24.dp))
        }
    }
}

@Composable
private fun PayloadPreview(snapshot: SparringSnapshot) {
    var open by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SelectionContainer { Text(snapshot.userText, style = MaterialTheme.typography.bodySmall) }
        Text("${snapshot.draft.historyIDs.size} frühere Antworten · ${snapshot.requestImages?.size ?: 0} Bilder im Anfragekontext",
            style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        TextButton(onClick = { open = !open }) { Text(if (open) "Anfragedetails ausblenden" else "Anfragedetails") }
        AnimatedVisibility(open, enter = fadeIn() + slideInVertically()) {
            SelectionContainer { Text(snapshot.payload.decodeToString(), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelSmall) }
        }
    }
}

/**
 * Medication guard under an answer: official sources when the provider cited some, otherwise a clearly visible
 * warning with a link to the EU database. Shown for every answer that talks about medication or doses.
 */
@Composable
private fun MedicationNotice(run: AnalysisRun) {
    val official = remember(run.sources) { MedicationSafety.officialSources(run) }
    val warn = remember(run.text, run.sources) { MedicationSafety.needsWarning(run) }
    val uri = androidx.compose.ui.platform.LocalUriHandler.current
    if (official.isNotEmpty()) Column(Modifier.fillMaxWidth().testTag("answer-sources-" + run.id), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text("Amtliche Quellen", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
        official.forEach { source ->
            TextButton(onClick = { runCatching { uri.openUri(source.url) } }) {
                Text(source.title ?: source.url, style = MaterialTheme.typography.bodySmall, maxLines = 2)
            }
        }
        Text("Angaben in der verlinkten Quelle prüfen.", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    if (warn) Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Color(0xFFFF9F0A).copy(alpha = 0.16f)).padding(12.dp).testTag("medication-warning-" + run.id),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.Warning, null, tint = Color(0xFFE08600), modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text("Arzneimittelangaben ungeprüft", fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.labelLarge)
        }
        Text(MedicationSafety.WARNING, style = MaterialTheme.typography.bodySmall)
        TextButton(onClick = { runCatching { uri.openUri(MedicationSafety.DATABASE_URL) } }) { Text("EU-Tierarzneimitteldatenbank öffnen") }
    }
}
