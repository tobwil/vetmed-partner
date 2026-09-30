package de.tobwil.vetmed

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import de.tobwil.vetmed.ui.VetMedApp

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // Like the iOS privacy cover: no case content in the recent-apps preview. Screenshots stay possible.
        setRecentsScreenshotEnabled(false)
        setContent { VetMedApp() }
    }
}
