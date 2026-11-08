package de.tobwil.vetmed.ui

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import de.tobwil.vetmed.AppViewModel
import de.tobwil.vetmed.core.ChatLocation
import de.tobwil.vetmed.core.LabAssessment
import de.tobwil.vetmed.core.LabEvidence
import de.tobwil.vetmed.core.LabHistory
import de.tobwil.vetmed.core.LabReport
import de.tobwil.vetmed.core.LabValue
import de.tobwil.vetmed.core.ProcessingRoute

private val Red = Color(0xFFFF3B30)
private val Orange = Color(0xFFFF9F0A)

/**
 * Lab result review (ADR 0015): the page next to the table, every row editable, rows that could not be found in the
 * original marked red. Only "Tabelle bestätigen" makes the table usable in the chat.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun LabReviewSheet(
    model: AppViewModel, location: ChatLocation, attachmentID: String, autoRead: Boolean,
    onDismiss: () -> Unit, asText: () -> Unit, use: (String) -> Unit,
) {
    val colors = LocalVetColors.current
    val document by model.document.collectAsStateWithLifecycle()
    val busy by model.busy.collectAsStateWithLifecycle()
    val status by model.workStatus.collectAsStateWithLifecycle()
    val attachment = model.chatContext(location)?.chatAttachments?.firstOrNull { it.id == attachmentID }
    val stored = attachment?.lab
    var values by remember(stored?.readAt) { mutableStateOf(stored?.values.orEmpty()) }
    var editing by remember { mutableStateOf<LabValue?>(null) }
    var page by remember { mutableIntStateOf(0) }
    val pages by produceState<List<android.graphics.Bitmap>?>(null, attachmentID) {
        value = runCatching { model.labPages(location, attachmentID).map { BitmapFactory.decodeByteArray(it, 0, it.size) } }.getOrDefault(emptyList())
    }
    val history = remember(document, attachmentID) { LabHistory.previous(document, location.caseID, attachmentID) }
    if (attachment == null) { LaunchedEffect(Unit) { onDismiss() }; return }
    // A freshly added result is read right away along the default route; nothing is read twice.
    var started by remember { mutableStateOf(false) }
    LaunchedEffect(busy) { if (autoRead && stored == null && !busy && !started) { started = true; model.readLab(location, attachmentID) } }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Laborbefund prüfen", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            // The original page, zoomable, so every row can be checked against it.
            pages?.let { list ->
                if (list.isNotEmpty()) {
                    var scale by remember { mutableFloatStateOf(1f) }
                    var offset by remember { mutableStateOf(androidx.compose.ui.geometry.Offset.Zero) }
                    val zoom = rememberTransformableState { change, pan, _ -> scale = (scale * change).coerceIn(1f, 5f); offset = if (scale == 1f) androidx.compose.ui.geometry.Offset.Zero else offset + pan }
                    Box(Modifier.fillMaxWidth().heightIn(max = 420.dp).clip(RoundedCornerShape(16.dp)).background(Color.White).transformable(zoom).testTag("lab-page")) {
                        Image(list[page.coerceIn(0, list.lastIndex)].asImageBitmap(), "Befundseite ${page + 1}", Modifier.fillMaxWidth()
                            .graphicsLayer { scaleX = scale; scaleY = scale; translationX = offset.x; translationY = offset.y }, contentScale = ContentScale.FillWidth)
                    }
                    if (list.size > 1) Row(verticalAlignment = Alignment.CenterVertically) {
                        TextButton(onClick = { page = (page - 1).coerceAtLeast(0) }, enabled = page > 0) { Text("Zurück") }
                        Text("Seite ${page + 1} von ${list.size}", Modifier.weight(1f), style = MaterialTheme.typography.labelMedium)
                        TextButton(onClick = { page = (page + 1).coerceAtMost(list.lastIndex) }, enabled = page < list.lastIndex) { Text("Weiter") }
                    }
                    Text("Mit zwei Fingern zoomen.", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            } ?: Text("Befundseiten werden geladen …", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

            if (stored == null) {
                Text(
                    if (busy) status.ifEmpty { "Wird gelesen …" } else "Die Werte sind noch nicht gelesen.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                if (busy) androidx.compose.material3.LinearProgressIndicator(progress = { 0.5f }, modifier = Modifier.fillMaxWidth())
                else {
                    if (model.labRoute == ProcessingRoute.ONLINE) Button(
                        onClick = { model.readLab(location, attachmentID, ProcessingRoute.ONLINE) }, shape = CircleShape, modifier = Modifier.fillMaxWidth().testTag("lab-read-online"),
                        colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                    ) { Text("Werte online lesen (beste Qualität)") }
                    OutlinedButton(onClick = { model.readLab(location, attachmentID, ProcessingRoute.DEVICE) }, shape = CircleShape, modifier = Modifier.fillMaxWidth().testTag("lab-read-device")) {
                        Text("Auf dem Gerät lesen (jede Zeile prüfen)")
                    }
                    Text("Online gehen nur die Seitenbilder an deinen Anbieter. Namen von Tier und Halter auf dem Befund vorher abdecken, wenn sie nicht gesendet werden sollen.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            } else {
                val open = values.count { it.needsCheck }
                Text(listOfNotNull(stored.laboratory.takeIf { it.isNotEmpty() }, stored.sampleDate.takeIf { it.isNotEmpty() }?.let { "Probe vom $it" }, stored.method).joinToString(" · "),
                    style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(
                    if (open == 0) "${values.size} Werte. Bitte jede Zeile am Original vergleichen."
                    else "${values.size} Werte, davon $open rot oder orange markiert: bitte besonders genau am Original prüfen.",
                    style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.testTag("lab-summary"),
                )
                Text("Referenz und Kennzeichnung stammen vom Labor. Die Bewertung berechnet die App nur aus dem gedruckten Referenzbereich.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                val save: (LabValue, LabValue) -> Unit = { original, changed ->
                    val edited = changed.copy(evidence = LabEvidence.EDITED, uncertain = false)
                    values = if (values.any { it.id == original.id }) values.map { if (it.id == original.id) edited else it } else values + edited
                    editing = null
                }
                values.forEach { value ->
                    if (editing?.id == value.id) LabValueEditor(value, onCancel = { editing = null }, onDelete = { values = values.filter { it.id != value.id }; editing = null }) { save(value, it) }
                    else LabRow(value, history[LabHistory.key(value.parameter, value.unit)].orEmpty()) { if (editing == null) editing = value }
                }
                editing?.takeIf { current -> values.none { it.id == current.id } }?.let { added ->
                    LabValueEditor(added, onCancel = { editing = null }, onDelete = null) { save(added, it) }
                }
                if (editing == null) TextButton(onClick = { editing = LabValue(parameter = "", value = "", evidence = LabEvidence.EDITED) }, modifier = Modifier.testTag("lab-add-row")) {
                    Icon(Icons.Rounded.Add, null); Spacer(Modifier.size(6.dp)); Text("Zeile hinzufügen")
                }
                Button(
                    onClick = { model.confirmLab(location, attachmentID, stored.copy(values = values)) { use(attachmentID) } },
                    enabled = !busy && values.isNotEmpty() && editing == null, shape = CircleShape, modifier = Modifier.fillMaxWidth().testTag("lab-confirm"),
                    colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
                ) { Text("Tabelle am Original geprüft · bestätigen") }
                TextButton(onClick = { model.readLab(location, attachmentID) }, enabled = !busy) { Text("Neu lesen") }
            }
            TextButton(onClick = asText, enabled = !busy) { Text("Stattdessen als Text prüfen") }
            Spacer(Modifier.size(24.dp))
        }
    }

}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun LabRow(value: LabValue, earlier: List<LabHistory.Entry>, onClick: () -> Unit) {
    val colors = LocalVetColors.current
    val assessment = value.assessment
    val mark = when {
        value.evidence == LabEvidence.NOT_FOUND -> Red
        value.uncertain || value.flagConflict || value.evidence == LabEvidence.LOCAL -> Orange
        else -> null
    }
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).clickable(onClick = onClick)
            .background((mark ?: MaterialTheme.colorScheme.onSurface).copy(alpha = if (mark != null) 0.10f else 0.04f)).padding(12.dp)
            .testTag("lab-row-${value.parameter}"),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(value.parameter.ifEmpty { "–" }, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            Text("${value.value} ${value.unit}".trim(), fontWeight = FontWeight.SemiBold,
                color = when (assessment) { LabAssessment.LOW, LabAssessment.HIGH -> Red; else -> MaterialTheme.colorScheme.onSurface })
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Ref. " + value.reference.ifEmpty { "keine" }, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (value.flag.isNotEmpty()) Text("Labor: ${value.flag}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("App: " + (assessment.symbol + " " + assessment.label).trim(), style = MaterialTheme.typography.labelSmall, color = colors.primary)
            Text("S. ${value.page}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        when {
            value.evidence == LabEvidence.NOT_FOUND -> Text("Nicht im Original gefunden. Bitte am Befund prüfen.", style = MaterialTheme.typography.labelSmall, color = Red)
            value.flagConflict -> Text("Kennzeichnung des Labors passt nicht zum Wert. Bitte Wert und Referenz am Befund prüfen.", style = MaterialTheme.typography.labelSmall, color = Orange)
            value.evidence == LabEvidence.LOCAL -> Text("Auf dem Gerät gelesen. Bitte am Befund prüfen.", style = MaterialTheme.typography.labelSmall, color = Orange)
            value.uncertain -> Text("Als schwer lesbar markiert. Bitte am Befund prüfen.", style = MaterialTheme.typography.labelSmall, color = Orange)
            value.evidence == LabEvidence.UNCHECKED -> Text("Kein lokaler Text zum Abgleich. Bitte am Befund prüfen.", style = MaterialTheme.typography.labelSmall, color = Orange)
            value.evidence == LabEvidence.EDITED -> Text("Von dir eingetragen", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (earlier.isNotEmpty()) Text(
            "Vorher: " + earlier.take(3).joinToString(" · ") { "${it.value.value} (${it.date})" },
            style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** Inline editor in place of a row: no stacked dialog over the sheet. Saving requires "am Original verglichen". */
@Composable
private fun LabValueEditor(value: LabValue, onCancel: () -> Unit, onDelete: (() -> Unit)?, onSave: (LabValue) -> Unit) {
    val colors = LocalVetColors.current
    var parameter by remember(value.id) { mutableStateOf(value.parameter) }
    var number by remember(value.id) { mutableStateOf(value.value) }
    var unit by remember(value.id) { mutableStateOf(value.unit) }
    var reference by remember(value.id) { mutableStateOf(value.reference) }
    var flag by remember(value.id) { mutableStateOf(value.flag) }
    var checked by remember(value.id) { mutableStateOf(false) }
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(colors.primary.copy(alpha = 0.08f)).padding(12.dp).testTag("lab-editor"),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(if (value.parameter.isEmpty()) "Zeile hinzufügen" else "Zeile bearbeiten", fontWeight = FontWeight.SemiBold)
        OutlinedTextField(parameter, { parameter = it }, Modifier.fillMaxWidth(), label = { Text("Parameter") }, singleLine = true)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(number, { number = it }, Modifier.weight(1f).testTag("lab-edit-value"), label = { Text("Wert") }, singleLine = true)
            OutlinedTextField(unit, { unit = it }, Modifier.weight(1f), label = { Text("Einheit") }, singleLine = true)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(reference, { reference = it }, Modifier.weight(1.4f), label = { Text("Referenz wie gedruckt") }, singleLine = true)
            OutlinedTextField(flag, { flag = it }, Modifier.weight(1f), label = { Text("Kennz. Labor") }, singleLine = true)
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(checked, { checked = it }, modifier = Modifier.testTag("lab-edit-checked"))
            Text("Am Original verglichen", style = MaterialTheme.typography.bodySmall)
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            onDelete?.let { IconButton(onClick = it) { Icon(Icons.Rounded.Delete, "Zeile löschen", tint = Red) } }
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onCancel) { Text("Abbrechen") }
            TextButton(enabled = checked && parameter.isNotBlank() && number.isNotBlank(), modifier = Modifier.testTag("lab-edit-save"), onClick = {
                onSave(value.copy(parameter = parameter.trim(), value = number.trim(), unit = unit.trim(), reference = reference.trim(), flag = flag.trim()))
            }) { Text("Übernehmen") }
        }
    }
}
