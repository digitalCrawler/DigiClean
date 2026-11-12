package com.digiclean.digiclean

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Keeps the process alive with a progress notification while a scan runs,
 * and holds a partial wake lock so the CPU keeps working with the screen
 * off. Both are released as soon as the scan ends.
 */
class ScanService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel(this)
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Scanning"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        } else {
            0
        }
        ServiceCompat.startForeground(this, NOTIFICATION_ID, build(this, title, text, -1), type)
        acquireWakeLock()
        return START_NOT_STICKY
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "DigiClean:scan").apply {
            setReferenceCounted(false)
            // Safety net: never hold the lock longer than a very long scan.
            acquire(4 * 60 * 60 * 1000L)
        }
    }

    override fun onTimeout(startId: Int) {
        // Android 15 limits dataSync services; stop gracefully when asked.
        stopSelf()
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    companion object {
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        private const val CHANNEL_ID = "scan_progress"
        private const val NOTIFICATION_ID = 4711
        private var currentTitle = "Scanning for duplicates"

        private fun createChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(CHANNEL_ID, "Scan progress", NotificationManager.IMPORTANCE_LOW)
            channel.description = "Shows progress while DigiClean scans your storage"
            channel.setShowBadge(false)
            manager.createNotificationChannel(channel)
        }

        private fun build(context: Context, title: String, text: String, progress: Int): Notification {
            currentTitle = title
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            val pending = PendingIntent.getActivity(
                context, 0, launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            return NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_menu_search)
                .setContentTitle(title)
                .setContentText(text)
                .setOnlyAlertOnce(true)
                .setOngoing(true)
                .setSilent(true)
                .setContentIntent(pending)
                .setProgress(100, progress.coerceIn(0, 100), progress < 0)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .build()
        }

        fun update(context: Context, text: String, progress: Int) {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(NOTIFICATION_ID, build(context, currentTitle, text, progress))
        }
    }
}
