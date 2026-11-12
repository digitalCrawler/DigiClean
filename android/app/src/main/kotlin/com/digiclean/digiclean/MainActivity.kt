package com.digiclean.digiclean

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Hosts the `digiclean/platform` channel: storage permissions, storage
 * volumes, the scan foreground service and media-index refresh after
 * deletions.
 */
class MainActivity : FlutterActivity() {
    /** Pending permission request, completed when the user returns. */
    private var pendingPermission: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                        "storageAccessStatus" -> result.success(storageStatus())
                        "requestStorageAccess" -> requestStorageAccess(result)
                        "requestNotifications" -> requestNotifications(result)
                        "openAppSettings" -> {
                            startActivity(
                                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                            result.success(null)
                        }
                        "storageVolumes" -> result.success(storageVolumes())
                        "startScanService" -> {
                            startScanService(call)
                            result.success(null)
                        }
                        "updateScanService" -> {
                            ScanService.update(
                                applicationContext,
                                call.argument<String>("text") ?: "",
                                call.argument<Int>("progress") ?: -1,
                            )
                            result.success(null)
                        }
                        "stopScanService" -> {
                            stopService(Intent(applicationContext, ScanService::class.java))
                            result.success(null)
                        }
                        "openFile" -> result.success(openFile(call.argument<String>("path") ?: ""))
                        "scheduleBackgroundCheck" -> {
                            CheckWorker.schedule(
                                applicationContext,
                                call.argument<Boolean>("enabled") ?: false,
                                call.argument<String>("snapshot"),
                            )
                            result.success(null)
                        }
                        "mediaScan" -> {
                            mediaScan(call.argument<List<String>>("paths") ?: emptyList())
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("native_error", e.message, null)
                }
            }
    }

    // ── Permissions ─────────────────────────────────────────────────────

    private fun hasLegacyStorage(): Boolean {
        val read = ContextCompat.checkSelfPermission(this, Manifest.permission.READ_EXTERNAL_STORAGE)
        val write = ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE)
        return read == PackageManager.PERMISSION_GRANTED && write == PackageManager.PERMISSION_GRANTED
    }

    /** "granted", "denied" or "permanentlyDenied". */
    private fun storageStatus(): String = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
            if (Environment.isExternalStorageManager()) "granted" else "denied"
        hasLegacyStorage() -> "granted"
        else -> "denied"
    }

    private fun requestStorageAccess(result: MethodChannel.Result) {
        if (storageStatus() == "granted") {
            result.success("granted")
            return
        }
        if (pendingPermission != null) {
            result.error("busy", "A permission request is already in progress", null)
            return
        }
        pendingPermission = result
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // "All files access" is granted on a system settings screen.
            val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName"))
            try {
                startActivityForResult(intent, REQUEST_ALL_FILES)
            } catch (e: Exception) {
                try {
                    // Some OEM builds only expose the generic list screen.
                    startActivityForResult(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION), REQUEST_ALL_FILES)
                } catch (e2: Exception) {
                    pendingPermission = null
                    result.success(storageStatus())
                }
            }
        } else {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.WRITE_EXTERNAL_STORAGE),
                REQUEST_LEGACY_STORAGE,
            )
        }
    }

    private fun requestNotifications(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        // Fire and forget: the scan works without the notification.
        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
        result.success(false)
    }

    @Deprecated("Deprecated in Android API, still required for FlutterActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_ALL_FILES) {
            pendingPermission?.success(storageStatus())
            pendingPermission = null
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_LEGACY_STORAGE) {
            val status = when {
                hasLegacyStorage() -> "granted"
                !ActivityCompat.shouldShowRequestPermissionRationale(this, Manifest.permission.READ_EXTERNAL_STORAGE) -> "permanentlyDenied"
                else -> "denied"
            }
            pendingPermission?.success(status)
            pendingPermission = null
        }
    }

    // ── Background scanning ─────────────────────────────────────────────

    private fun startScanService(call: MethodCall) {
        val intent = Intent(applicationContext, ScanService::class.java)
            .putExtra(ScanService.EXTRA_TITLE, call.argument<String>("title") ?: "Scanning")
            .putExtra(ScanService.EXTRA_TEXT, call.argument<String>("text") ?: "")
        ContextCompat.startForegroundService(applicationContext, intent)
    }

    /**
     * Every mounted volume with its root path and the app-specific directory
     * on it (used for the recovery bin so deletions are same-volume renames).
     */
    private fun storageVolumes(): List<Map<String, Any?>> {
        val appDirs = getExternalFilesDirs(null).filterNotNull()
        fun appDirFor(root: String): String? =
            appDirs.firstOrNull { it.absolutePath.startsWith("$root/") }?.absolutePath

        val out = mutableListOf<Map<String, Any?>>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val sm = getSystemService(Context.STORAGE_SERVICE) as StorageManager
            for (v in sm.storageVolumes) {
                if (v.state != Environment.MEDIA_MOUNTED) continue
                val dir = v.directory ?: continue
                out.add(
                    mapOf(
                        "path" to dir.absolutePath,
                        "label" to v.getDescription(this),
                        "isPrimary" to v.isPrimary,
                        "isRemovable" to v.isRemovable,
                        "appDir" to appDirFor(dir.absolutePath),
                    )
                )
            }
        } else {
            // Derive volume roots from the per-volume app directories:
            // <root>/Android/data/<package>/files
            appDirs.forEachIndexed { index, appDir ->
                val root = appDir.absolutePath.substringBefore("/Android/data/")
                out.add(
                    mapOf(
                        "path" to root,
                        "label" to if (index == 0) "Internal storage" else "SD card",
                        "isPrimary" to (index == 0),
                        "isRemovable" to (index != 0),
                        "appDir" to appDir.absolutePath,
                    )
                )
            }
        }
        return out
    }

    /** Opens a file in another app via a content URI. Returns false if no app can. */
    private fun openFile(path: String): Boolean {
        val file = File(path)
        if (!file.isFile) return false
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: "*/*"
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    /** Lets the MediaStore drop entries for files that no longer exist. */
    private fun mediaScan(paths: List<String>) {
        if (paths.isEmpty()) return
        // Scanning parent folders is cheaper than thousands of single files.
        val targets = if (paths.size > 500) paths.map { File(it).parent ?: it }.distinct() else paths
        MediaScannerConnection.scanFile(applicationContext, targets.toTypedArray(), null, null)
    }

    companion object {
        private const val CHANNEL = "digiclean/platform"
        private const val REQUEST_ALL_FILES = 7101
        private const val REQUEST_LEGACY_STORAGE = 7102
        private const val REQUEST_NOTIFICATIONS = 7103
    }
}
