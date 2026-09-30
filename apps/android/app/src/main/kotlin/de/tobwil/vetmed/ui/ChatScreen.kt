package de.tobwil.vetmed.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/** The chat (P3.3) is not built on Android yet; the tab says so instead of pretending to work. */
@Composable
fun ChatScreen() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        AmbientBackground()
        Box(Modifier.padding(32.dp)) {
            EmptyState(
                Icons.Rounded.AutoAwesome,
                "Chat folgt auf Android",
                "Fragen mit Bildern und Befunden, mit und ohne Fall, kommen in einem der nächsten Schritte. Auf dem iPhone ist der Chat bereits verfügbar.",
            )
        }
    }
}
