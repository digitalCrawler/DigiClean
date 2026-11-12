package com.digiclean.digiclean

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.text.format.Formatter
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Daily background check: notifies when storage is almost full, or when the
 * user's automatic rescan is due. Scanning itself happens in the app, which
 * starts the due rescan when it is opened. Never removes anything.
 */
class CheckWorker(context: Context, params: WorkerParameters) : Worker(context, params) {

    override fun doWork(): Result {
        val context = applicationContext
        val settings = readSettings(context)
        if (!settings.optBoolean("backgroundCheck", false)) return Result.success()
        val state = context.getSharedPreferences(STATE_PREFS, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        val day = TimeUnit.DAYS.toMillis(1)

        val stat = StatFs(Environment.getExternalStorageDirectory().path)
        val free = stat.availableBytes
        val total = stat.totalBytes
        val lastLowSpace = state.getLong(KEY_LOW_SPACE, 0)
        if (total > 0 && free * 100 < total * LOW_SPACE_PERCENT && now - lastLowSpace > 3 * day) {
            notify(
                context,
                "Your storage is almost full",
                "${Formatter.formatShortFileSize(context, free)} free of " +
                    "${Formatter.formatShortFileSize(context, total)}. Open DigiClean to free up space.",
            )
            state.edit().putLong(KEY_LOW_SPACE, now).apply()
            return Result.success()
        }

        val rescanDays = settings.optInt("autoRescanDays", 0)
        val snapshot = inputData.getString(KEY_SNAPSHOT)?.let(::File)
        val lastScan = snapshot?.takeIf { it.exists() }?.lastModified() ?: 0L
        val lastReminder = state.getLong(KEY_RESCAN, 0)
        if (rescanDays > 0 && now - lastScan >= rescanDays * day && now - lastReminder >= rescanDays * day) {
            notify(
                context,
                "Time for a clean-up",
                if (lastScan == 0L) "Scan your folders to find duplicates and junk."
                else "Your last scan was ${(now - lastScan) / day} days ago. Open DigiClean to scan again.",
            )
            state.edit().putLong(KEY_RESCAN, now).apply()
        }
        return Result.success()
    }

    companion object {
        private const val WORK_NAME = "digiclean-check"
        private const val CHANNEL_ID = "storage_checks"
        private const val NOTIFICATION_ID = 4712
        private const val STATE_PREFS = "digiclean_check"
        private const val KEY_LOW_SPACE = "lastLowSpaceNotice"
        private const val KEY_RESCAN = "lastRescanNotice"
        private const val KEY_SNAPSHOT = "snapshot"
        private const val LOW_SPACE_PERCENT = 10

        /** Settings as saved by the Flutter app (shared_preferences). */
        private fun readSettings(context: Context): JSONObject {
            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val raw = prefs.getString("flutter.settings.v1", null) ?: return JSONObject()
            return try {
                JSONObject(raw)
            } catch (_: Exception) {
                JSONObject()
            }
        }

        fun schedule(context: Context, enabled: Boolean, snapshotPath: String?) {
            val work = WorkManager.getInstance(context)
            if (!enabled) {
                work.cancelUniqueWork(WORK_NAME)
                return
            }
            val request = PeriodicWorkRequestBuilder<CheckWorker>(1, TimeUnit.DAYS)
                .setConstraints(Constraints.Builder().setRequiresBatteryNotLow(true).build())
                .setInputData(workDataOf(KEY_SNAPSHOT to snapshotPath))
                .build()
            work.enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.UPDATE, request)
        }

        private fun notify(context: Context, title: String, text: String) {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && manager.getNotificationChannel(CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Storage checks", NotificationManager.IMPORTANCE_DEFAULT).apply {
                        description = "Low storage and clean-up reminders"
                    },
                )
            }
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            val pending = PendingIntent.getActivity(
                context, 1, launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_menu_search)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                .setContentIntent(pending)
                .setAutoCancel(true)
                .build()
            // Without the notification permission (Android 13+) this is a no-op.
            if (NotificationManagerCompat.from(context).areNotificationsEnabled()) {
                manager.notify(NOTIFICATION_ID, notification)
            }
        }
    }
}
