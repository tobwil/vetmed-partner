package de.tobwil.vetmed.ui

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import java.io.File
import java.util.UUID

/** Share actions; [onChosen] receives the format once the user actually picked a target app. */
class ShareLauncher(val text: (String, String) -> Unit, val file: (File, String, String) -> Unit)

/**
 * Opens the Android share sheet and reports back only when the user picks a target, like the iOS completion
 * callback. Delivery to the recipient stays unknown. Files are shared read-only through the FileProvider.
 */
@Composable
fun rememberShareLauncher(title: String = "Bericht teilen", onChosen: (String) -> Unit): ShareLauncher {
    val context = LocalContext.current
    val chosen by rememberUpdatedState(onChosen)
    val action = remember { "de.tobwil.vetmed.SHARE_CHOSEN." + UUID.randomUUID() }
    val pending = remember { arrayOfNulls<String>(1) }
    DisposableEffect(action) {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) { pending[0]?.let(chosen); pending[0] = null }
        }
        ContextCompat.registerReceiver(context, receiver, IntentFilter(action), ContextCompat.RECEIVER_NOT_EXPORTED)
        onDispose { context.unregisterReceiver(receiver) }
    }
    fun launch(send: Intent, format: String) {
        pending[0] = format
        val callback = PendingIntent.getBroadcast(
            context, 0, Intent(action).setPackage(context.packageName), PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        context.startActivity(Intent.createChooser(send, title, callback.intentSender))
    }
    return remember(context) {
        ShareLauncher(
            text = { text, format -> launch(Intent(Intent.ACTION_SEND).apply { type = "text/plain"; putExtra(Intent.EXTRA_TEXT, text) }, format) },
            file = { file, mime, format ->
                val uri = FileProvider.getUriForFile(context, context.packageName + ".exports", file)
                launch(Intent(Intent.ACTION_SEND).apply {
                    type = mime; putExtra(Intent.EXTRA_STREAM, uri)
                    clipData = ClipData.newRawUri(file.name, uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }, format)
            },
        )
    }
}
