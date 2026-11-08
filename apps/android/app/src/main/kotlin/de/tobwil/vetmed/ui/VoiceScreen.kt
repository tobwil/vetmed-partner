package de.tobwil.vetmed.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CallEnd
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.MicOff
import androidx.compose.material.icons.rounded.PanTool
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import de.tobwil.vetmed.AppViewModel
import de.tobwil.vetmed.core.GeminiLive
import de.tobwil.vetmed.core.LiveState
import java.util.Locale

private val EndRed = Color(0xFFFF3B30)

/**
 * The voice conversation over the chat (ADR 0016): a circle that follows the voice, the live transcript of both
 * sides, mute, interrupt and end. The circle moves with the audio level only, so nothing animates without sound.
 */
@Composable
fun VoiceOverlay(model: AppViewModel, voice: AppViewModel.Voice) {
    val colors = LocalVetColors.current
    val state by voice.session.state.collectAsStateWithLifecycle()
    val turns by voice.session.turns.collectAsStateWithLifecycle()
    val seconds by voice.session.audioSeconds.collectAsStateWithLifecycle()
    val muted by voice.muted.collectAsStateWithLifecycle()
    val level by voice.audio.level.collectAsStateWithLifecycle()
    val scale by animateFloatAsState(1f + level.coerceIn(0f, 1f) * 0.35f, spring(dampingRatio = 0.6f), label = "voice-level")
    val list = rememberLazyListState()
    LaunchedEffect(turns.size, turns.lastOrNull()?.text?.length) { if (turns.isNotEmpty()) list.animateScrollToItem(turns.lastIndex) }
    BackHandler { model.endVoice() }

    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).testTag("voice-overlay")) {
        AmbientBackground()
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Sprachmodus", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            Text(
                when (val current = state) {
                    LiveState.Idle, LiveState.Connecting -> "Verbinde mit Gemini …"
                    LiveState.Live -> if (muted) "Mikrofon aus" else "Hört zu · einfach sprechen"
                    LiveState.Resuming -> "Verbindung wird erneuert …"
                    is LiveState.Ended -> current.message ?: "Gespräch beendet"
                },
                style = MaterialTheme.typography.bodyMedium, color = if (state is LiveState.Ended) EndRed else MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.testTag("voice-status"),
            )
            Spacer(Modifier.size(20.dp))
            Box(Modifier.size(150.dp), contentAlignment = Alignment.Center) {
                Box(Modifier.size(120.dp).scale(scale).clip(CircleShape).background(colors.primary.copy(alpha = 0.18f)))
                Box(Modifier.size(96.dp).clip(CircleShape).background(if (muted) androidx.compose.ui.graphics.SolidColor(Color.Gray) else colors.gradient), contentAlignment = Alignment.Center) {
                    Icon(if (muted) Icons.Rounded.MicOff else Icons.Rounded.Mic, null, tint = Color.White, modifier = Modifier.size(42.dp))
                }
            }
            Spacer(Modifier.size(8.dp))
            val (input, output) = seconds
            Text(
                "Gesprochen ${clock(input)} · Antwort ${clock(output)} · ca. ${String.format(Locale.GERMANY, "%.2f", GeminiLive.costUSD(input, output))} US-$",
                style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("voice-cost"),
            )
            Spacer(Modifier.size(12.dp))
            LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = list, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(turns) { turn ->
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = if (turn.fromUser) Arrangement.End else Arrangement.Start) {
                        Text(
                            turn.text + if (turn.interrupted) " (unterbrochen)" else "",
                            Modifier.widthIn(max = 300.dp).clip(RoundedCornerShape(16.dp))
                                .background(if (turn.fromUser) colors.primary.copy(alpha = 0.16f) else MaterialTheme.colorScheme.surface.copy(alpha = 0.9f)).padding(12.dp),
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                }
            }
            Text("Gespeichert wird nur die Mitschrift, kein Audio. Keine Websuche. Antworten fachlich prüfen.",
                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(vertical = 8.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                FilledTonalButton(onClick = { model.setVoiceMuted(!muted) }, enabled = state == LiveState.Live, modifier = Modifier.weight(1f).testTag("voice-mute")) {
                    Icon(if (muted) Icons.Rounded.Mic else Icons.Rounded.MicOff, null); Spacer(Modifier.size(6.dp)); Text(if (muted) "Mikro an" else "Stumm")
                }
                FilledTonalButton(onClick = { model.interruptVoice() }, enabled = state == LiveState.Live, modifier = Modifier.weight(1f).testTag("voice-interrupt")) {
                    Icon(Icons.Rounded.PanTool, null); Spacer(Modifier.size(6.dp)); Text("Unterbrechen", maxLines = 1)
                }
            }
            Spacer(Modifier.size(10.dp))
            Button(onClick = { model.endVoice() }, colors = ButtonDefaults.buttonColors(containerColor = EndRed), modifier = Modifier.fillMaxWidth().testTag("voice-end")) {
                Icon(Icons.Rounded.CallEnd, null); Spacer(Modifier.size(6.dp)); Text("Beenden und Mitschrift speichern")
            }
        }
    }
}

private fun clock(seconds: Double): String = (seconds.toInt()).let { "%d:%02d".format(it / 60, it % 60) }

/** Once before the first voice conversation: what leaves the device, costs and the paid-tier requirement. */
@Composable
fun VoiceConsentDialog(onDecision: (Boolean) -> Unit) {
    AlertDialog(
        onDismissRequest = { onDecision(false) },
        title = { Text("Sprachmodus starten?") },
        text = {
            Text(
                "Im Sprachmodus gehen deine Stimme und der gewählte Fallkontext (ausgewählte Berichte, Falltext und bestätigte Labortabellen) live an Google Gemini. " +
                    "Gespeichert wird nur die Mitschrift im Chat, kein Audio. Eine Websuche gibt es nicht.\n\n" +
                    "Kosten im bezahlten Kontingent: ca. 0,5 US-Cent pro Minute Sprechen und 1,8 US-Cent pro Minute Antwort. " +
                    "Für Patienten- und Halterdaten nur einen Key mit aktivierter Abrechnung verwenden: Im kostenlosen Kontingent darf Google Eingaben zur Produktverbesserung nutzen.",
            )
        },
        confirmButton = { TextButton(onClick = { onDecision(true) }, modifier = Modifier.testTag("voice-consent")) { Text("Starten") } },
        dismissButton = { TextButton(onClick = { onDecision(false) }) { Text("Abbrechen") } },
    )
}
