package de.tobwil.vetmed.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.Memory
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import de.tobwil.vetmed.AppViewModel
import de.tobwil.vetmed.core.VocabularyEntry
import de.tobwil.vetmed.data.SpeechStatus

@Composable
private fun SettingsScaffold(title: String, nav: NavHostController, content: @Composable () -> Unit) {
    Box(Modifier.fillMaxSize()) {
        AmbientBackground()
        Scaffold(containerColor = Color.Transparent, contentColor = MaterialTheme.colorScheme.onBackground, topBar = { BackTopBar(title, nav) }) { padding ->
            Column(
                Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) { content(); Spacer(Modifier.size(32.dp)) }
        }
    }
}

@Composable
private fun Group(content: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth().vetCard(LocalVetColors.current, RoundedCornerShape(26.dp)), verticalArrangement = Arrangement.spacedBy(10.dp)) { content() }
}

@Composable
private fun Caption(text: String) = Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

@Composable
private fun LinkRow(title: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).clickable(onClick = onClick).padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, modifier = Modifier.weight(1f))
        Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f))
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(model: AppViewModel, nav: NavHostController) {
    val appearance = LocalAppearance.current
    val online by model.online.collectAsStateWithLifecycle()
    val hasKey by model.hasKey.collectAsStateWithLifecycle()
    val haptics = LocalHapticFeedback.current
    SettingsScaffold("Einstellungen", nav) {
        SectionTitle("Darstellung")
        Group {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                AppearanceMode.entries.forEachIndexed { index, value ->
                    SegmentedButton(
                        selected = appearance.mode == value, onClick = { appearance.setMode(value, null) },
                        shape = SegmentedButtonDefaults.itemShape(index, AppearanceMode.entries.size),
                    ) { Text(value.title) }
                }
            }
            Text("Farbthema", fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 6.dp))
            AccentTheme.entries.chunked(3).forEach { row ->
                Row(Modifier.fillMaxWidth()) {
                    row.forEach { value ->
                        ThemeSwatch(value, appearance.theme == value, Modifier.weight(1f)) {
                            haptics.performHapticFeedback(HapticFeedbackType.SegmentTick); appearance.setTheme(value)
                        }
                    }
                }
            }
        }
        SectionTitle("Online-Zugang")
        Group {
            LinkRow("API-Key & Modell") { nav.navigate(OnlineRoute) }
            Caption(if (hasKey) "OpenAI · ${online.modelID.ifEmpty { "kein Modell gewählt" }}" else "Noch kein API-Key hinterlegt")
            Caption("Mit aktivierter Konfiguration ist Online der Standard. Offline kannst du pro Bericht ausdrücklich auswählen, sobald das lokale Modell verfügbar ist.")
        }
        SectionTitle("Optionales Offline-Modell")
        Group {
            Row(verticalAlignment = Alignment.CenterVertically) { Icon(Icons.Rounded.Memory, null, tint = LocalVetColors.current.primary); Spacer(Modifier.width(8.dp)); Text("Gemma 4 E2B über LiteRT-LM") }
            Caption("Auf Android noch nicht verfügbar. Geplant ist ein eigener LiteRT-LM-Adapter mit demselben Berichtsvertrag; es gibt keinen stillen Wechsel zwischen Online und Offline.")
        }
        SectionTitle("Spracherkennung")
        Group {
            val speech by model.speechStatus.collectAsStateWithLifecycle()
            val busy by model.busy.collectAsStateWithLifecycle()
            LaunchedEffect(Unit) { model.refreshSpeechStatus() }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.GraphicEq, null, tint = LocalVetColors.current.primary); Spacer(Modifier.width(8.dp))
                Column(Modifier.weight(1f)) {
                    Text("Android On-Device · Deutsch")
                    Text(speech?.title ?: "Wird geprüft …", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("speech-status"))
                }
            }
            if (speech == SpeechStatus.DOWNLOADABLE) {
                TextButton(onClick = { model.installSpeech() }, enabled = !busy, modifier = Modifier.testTag("install-speech")) { Text("Deutsche Sprachressourcen installieren") }
            }
            Caption("Transkribiert wird ausschließlich mit dem Offline-Erkenner des Systems. Fehlen die deutschen Ressourcen, bleibt die Aufnahme gespeichert; es gibt keinen Cloud-Fallback.")
            LinkRow("Eigene Fachwortkorrekturen") { nav.navigate(VocabularyRoute) }
        }
        SectionTitle("Lokale Daten")
        Group {
            Row(verticalAlignment = Alignment.CenterVertically) { Icon(Icons.Rounded.Lock, null, tint = LocalVetColors.current.primary); Spacer(Modifier.width(8.dp)); Text("Verschlüsselt auf diesem Gerät") }
            Caption("AES-256-GCM mit einem Schlüssel im Android Keystore. Keine Cloud-Synchronisation und kein Backup. Deinstallation oder Geräteverlust kann zum Datenverlust führen.")
        }
        SectionTitle("Entwicklungsstand")
        Group {
            Text("Android-Vorschau · 0.1", fontWeight = FontWeight.SemiBold)
            Caption("Fälle, Texteingabe, Online-Berichte mit Quellenprüfung, Freigabe und Teilen. Aufnahme, Offline-Modell und Chat stehen noch aus. Nicht auf einem Pixel 9 abgenommen.")
        }
    }
}

@Composable
private fun ThemeSwatch(theme: AccentTheme, selected: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val dark = LocalVetColors.current.dark
    val scale by animateFloatAsState(if (selected) 1.08f else 1f, spring(dampingRatio = 0.55f), label = "swatch")
    Column(
        modifier.clip(RoundedCornerShape(16.dp)).clickable(onClick = onClick).padding(vertical = 8.dp)
            .semantics(mergeDescendants = true) { contentDescription = "Farbthema ${theme.title}"; this.selected = selected },
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            Modifier.scale(scale).size(52.dp)
                .border(BorderStroke(2.dp, if (selected) theme.primary(dark) else Color.Transparent), CircleShape).padding(4.dp)
                .shadow(if (selected) 8.dp else 0.dp, CircleShape, spotColor = theme.primary(dark)).clip(CircleShape)
                .background(Brush.linearGradient(listOf(theme.primary(dark), theme.secondary(dark)))),
            contentAlignment = Alignment.Center,
        ) {
            androidx.compose.animation.AnimatedVisibility(selected, enter = scaleIn(), exit = scaleOut()) { Icon(Icons.Rounded.Check, null, tint = Color.White) }
        }
        Spacer(Modifier.size(6.dp))
        Text(theme.title, style = MaterialTheme.typography.labelMedium, color = if (selected) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
fun OnlineSettingsScreen(model: AppViewModel, nav: NavHostController) {
    val online by model.online.collectAsStateWithLifecycle()
    val hasKey by model.hasKey.collectAsStateWithLifecycle()
    val busy by model.busy.collectAsStateWithLifecycle()
    val models by model.onlineModels.collectAsStateWithLifecycle()
    val status by model.onlineStatus.collectAsStateWithLifecycle()
    val colors = LocalVetColors.current
    val uri = LocalUriHandler.current
    var keyDraft by remember { mutableStateOf("") }
    var modelID by rememberSaveable { mutableStateOf(online.modelID) }
    var menu by remember { mutableStateOf(false) }
    SettingsScaffold("Online-Zugang", nav) {
        SectionTitle("OpenAI")
        Group {
            OutlinedTextField(
                keyDraft, { keyDraft = it.trim() }, Modifier.fillMaxWidth(), singleLine = true, enabled = !busy,
                label = { Text(if (hasKey) "API-Key ersetzen (optional)" else "Eigenen API-Key eingeben") },
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
            )
            Box {
                OutlinedTextField(modelID, { modelID = it.trim() }, Modifier.fillMaxWidth(), singleLine = true, enabled = !busy, label = { Text("Modell-ID") })
                DropdownMenu(menu, { menu = false }) { models.forEach { id -> DropdownMenuItem(text = { Text(id) }, onClick = { modelID = id; menu = false }) } }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = { model.loadOnlineModels(keyDraft) }, enabled = !busy) { Text("Modelle laden") }
                if (models.isNotEmpty()) TextButton(onClick = { menu = true }, enabled = !busy) { Text("Aus Konto wählen") }
            }
            TextButton(onClick = { model.testOnlineModel(modelID, keyDraft) }, enabled = !busy && modelID.isNotBlank()) { Text("Modell mit synthetischem Text testen") }
            Caption("Modelltest und Berichte verwenden deinen API-Zugang und können Kosten verursachen. Der Modelltest überträgt ausschließlich einen festen synthetischen Text.")
            status?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = colors.primary) }
        }
        SectionTitle("Online als Standard aktivieren")
        Group {
            Text("Mit Online aktivieren richtest du deinen OpenAI-Zugang ein. Bericht online erstellen sendet das geprüfte Transkript. Eingabe und Speicherung bleiben lokal.", style = MaterialTheme.typography.bodyMedium)
            Caption("Der API-Key wird mit einem Android-Keystore-Schlüssel verschlüsselt gespeichert. Die abrufbare Antwortspeicherung ist deaktiviert (store=false); weitere Aufbewahrung beim Anbieter richtet sich nach deinem API-Vertrag.")
            TextButton(onClick = { uri.openUri("https://developers.openai.com/api/docs/guides/your-data") }) { Text("OpenAI-Datenkontrollen") }
            Button(
                onClick = { if (model.saveOnlineConfiguration(modelID, keyDraft)) keyDraft = "" },
                enabled = !busy && modelID.isNotBlank() && (hasKey || keyDraft.isNotEmpty()), shape = CircleShape, modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = colors.primary),
            ) { Text(if (online.isEnabled) "Konfiguration speichern" else "Online aktivieren") }
            if (hasKey) TextButton(onClick = { model.removeOnlineKey(); keyDraft = "" }, enabled = !busy) { Text("API-Key entfernen", color = Color(0xFFFF3B30)) }
            Caption("Bei Verbindungs- oder Anbieterfehlern bleibt der Auftrag lokal. Es gibt keinen automatischen Wechsel zu einem anderen Anbieter und keinen Versand bei späterer Netzrückkehr.")
        }
    }
}

@Composable
fun VocabularyScreen(model: AppViewModel, nav: NavHostController) {
    val entries by model.vocabulary.collectAsStateWithLifecycle()
    var recognized by remember { mutableStateOf("") }
    var preferred by remember { mutableStateOf("") }
    SettingsScaffold("Fachwortliste", nav) {
        SectionTitle("Korrektur vorschlagen")
        Group {
            OutlinedTextField(recognized, { recognized = it }, Modifier.fillMaxWidth(), singleLine = true, label = { Text("Erkannter Ausdruck") })
            OutlinedTextField(preferred, { preferred = it }, Modifier.fillMaxWidth(), singleLine = true, label = { Text("Gewünschter Fachbegriff") })
            TextButton(
                enabled = recognized.isNotBlank() && preferred.isNotBlank() && recognized.trim() != preferred.trim(),
                onClick = { model.saveVocabulary(entries + VocabularyEntry(recognized = recognized.trim(), preferred = preferred.trim())); recognized = ""; preferred = "" },
            ) { Text("Zur Fachwortliste hinzufügen") }
            Caption("Die Liste macht Vorschläge im Texteditor. Du übernimmst eine Korrektur ausdrücklich; das Original bleibt erhalten.")
        }
        if (entries.isNotEmpty()) {
            SectionTitle("Eigene Einträge")
            Group {
                entries.forEach { entry ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) { Text(entry.preferred); Caption(entry.recognized) }
                        IconButton(onClick = { model.saveVocabulary(entries - entry) }) { Icon(Icons.Rounded.Delete, "Eintrag löschen", tint = Color(0xFFFF3B30)) }
                    }
                }
            }
        }
    }
}
