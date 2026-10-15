package de.tobwil.vetmed.data

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import de.tobwil.vetmed.MainActivity

/**
 * Microphone foreground service: Android silences background microphone access otherwise. It records nothing
 * itself; it only keeps the running [AudioRecorder] allowed while the app is in the background and shows the
 * mandatory notification. Started when a recording starts on screen, stopped when it ends.
 */
class RecordingService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Laufende Aufnahme", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Zeigt an, dass VetMed gerade aufnimmt."
        })
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("VetMed nimmt auf")
            .setContentText("Jedes Segment wird sofort verschlüsselt gespeichert. Tippen zum Öffnen.")
            .setContentIntent(open)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
        startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        return START_NOT_STICKY
    }

    companion object {
        private const val CHANNEL = "recording"
        private const val NOTIFICATION_ID = 1

        fun start(context: Context) { context.startForegroundService(Intent(context, RecordingService::class.java)) }
        fun stop(context: Context) { context.stopService(Intent(context, RecordingService::class.java)) }
    }
}
