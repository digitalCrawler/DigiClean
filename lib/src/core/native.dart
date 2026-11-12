import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A storage volume reported by the OS (Android).
class StorageVolume {
  const StorageVolume({
    required this.path,
    required this.label,
    required this.isPrimary,
    required this.isRemovable,
    this.appDir,
  });

  final String path;
  final String label;
  final bool isPrimary;
  final bool isRemovable;

  /// App-specific directory on this volume; used for the recovery bin so
  /// that deletions are same-volume renames.
  final String? appDir;

  factory StorageVolume.fromMap(Map<dynamic, dynamic> m) => StorageVolume(
    path: m['path'] as String,
    label: (m['label'] as String?) ?? 'Storage',
    isPrimary: (m['isPrimary'] as bool?) ?? false,
    isRemovable: (m['isRemovable'] as bool?) ?? false,
    appDir: m['appDir'] as String?,
  );
}

/// A folder the user granted access to on iOS, kept across launches via a
/// security-scoped bookmark.
class PickedFolder {
  const PickedFolder({required this.path, required this.bookmark});

  final String path;
  final String bookmark;
}

/// Thin wrapper over the `digiclean/platform` method channel implemented in
/// `MainActivity.kt` (Android) and `AppDelegate.swift` (iOS). Every call is
/// a no-op on platforms that do not implement it.
class NativePlatform {
  NativePlatform._();

  static const _channel = MethodChannel('digiclean/platform');

  static Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('native $method failed: ${e.message}');
      return null;
    }
  }

  // ── Android ──────────────────────────────────────────────────────────

  static Future<int> androidSdkInt() async => Platform.isAndroid ? (await _call<int>('sdkInt')) ?? 0 : 0;

  static Future<List<StorageVolume>> storageVolumes() async {
    if (!Platform.isAndroid) return const [];
    final list = await _call<List<dynamic>>('storageVolumes') ?? const [];
    return list.whereType<Map<dynamic, dynamic>>().map(StorageVolume.fromMap).toList();
  }

  /// Starts a foreground service with a progress notification and a
  /// partial wake lock so long scans survive the screen turning off.
  static Future<void> startBackgroundWork(String title, String text) async {
    if (Platform.isAndroid) {
      await _call('startScanService', {'title': title, 'text': text});
    } else if (Platform.isIOS) {
      await _call('beginBackgroundTask');
    }
  }

  static Future<void> updateBackgroundWork(String text, int percent) async {
    if (Platform.isAndroid) {
      await _call('updateScanService', {'text': text, 'progress': percent});
    }
  }

  /// Android (WorkManager) and iOS (background refresh): schedules or cancels
  /// the daily check that notifies about low storage and due rescans.
  static Future<void> scheduleBackgroundCheck({required bool enabled, String? snapshot}) async {
    if (Platform.isAndroid || Platform.isIOS) {
      await _call('scheduleBackgroundCheck', {'enabled': enabled, 'snapshot': snapshot});
    }
  }

  static Future<void> stopBackgroundWork() async {
    if (Platform.isAndroid) {
      await _call('stopScanService');
    } else if (Platform.isIOS) {
      await _call('endBackgroundTask');
    }
  }

  /// Opens a file with another app through the app's FileProvider.
  /// Returns false when no installed app can open it.
  static Future<bool> openFileAndroid(String path) async => (await _call<bool>('openFile', {'path': path})) ?? false;

  /// Tells the media index that files were removed so galleries update.
  static Future<void> notifyMediaRemoved(List<String> paths) async {
    if (Platform.isAndroid && paths.isNotEmpty) {
      await _call('mediaScan', {'paths': paths});
    }
  }

  // ── iOS ──────────────────────────────────────────────────────────────

  static Future<PickedFolder?> pickFolderIOS() async {
    final m = await _call<Map<dynamic, dynamic>>('pickFolder');
    if (m == null) return null;
    return PickedFolder(path: m['path'] as String, bookmark: m['bookmark'] as String);
  }

  /// Resolves stored bookmarks and starts security-scoped access. Returns
  /// one entry per bookmark, in order: the refreshed folder (paths can
  /// change between launches), or `null` if access was lost.
  static Future<List<PickedFolder?>> resolveBookmarksIOS(List<String> bookmarks) async {
    if (!Platform.isIOS || bookmarks.isEmpty) return const [];
    final list = await _call<List<dynamic>>('resolveBookmarks', {'bookmarks': bookmarks}) ?? const [];
    return [
      for (final m in list.whereType<Map<dynamic, dynamic>>())
        m['path'] is String ? PickedFolder(path: m['path'] as String, bookmark: m['bookmark'] as String) : null,
    ];
  }

  static Future<void> releaseFolderIOS(String path) async {
    if (Platform.isIOS) await _call('releaseFolder', {'path': path});
  }

  // ── Desktop ──────────────────────────────────────────────────────────

  /// Opens the system file manager with the item highlighted.
  static Future<void> revealInFileManager(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', ['/select,', path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else if (Platform.isLinux) {
        // Ask the file manager to select the item; fall back to the folder.
        final r = await Process.run('dbus-send', [
          '--session',
          '--dest=org.freedesktop.FileManager1',
          '--type=method_call',
          '/org/freedesktop/FileManager1',
          'org.freedesktop.FileManager1.ShowItems',
          'array:string:${Uri.file(path)}',
          'string:',
        ]);
        if (r.exitCode != 0) {
          await Process.run('xdg-open', [File(path).parent.path]);
        }
      }
    } catch (e) {
      debugPrint('reveal failed: $e');
    }
  }

  static bool get canReveal => Platform.isWindows || Platform.isMacOS || Platform.isLinux;
}
