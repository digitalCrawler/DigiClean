import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'native.dart';

/// A suggested place to scan.
class LocationSuggestion {
  const LocationSuggestion(this.label, this.path, {this.isVolume = false});

  final String label;
  final String path;
  final bool isVolume;
}

/// Directories the app owns plus OS-specific scan suggestions. Resolved
/// once at startup.
class AppPaths {
  AppPaths._({
    required this.supportDir,
    required this.cacheDir,
    required this.recoveryRoots,
    required this.suggestions,
    required this.volumes,
  });

  final String supportDir;

  /// The user's download folders (for old-file and recommendation rules).
  List<String> get downloadDirs => [
    for (final s in suggestions)
      if (s.label == 'Downloads') s.path,
  ];

  /// Results of the last scan, reopened at the next start.
  String get snapshotPath => p.join(supportDir, 'last-results.dcsnap');

  /// Persistent hash cache location.
  final String cacheDir;

  /// Recovery-bin candidates, one per storage volume, primary first.
  final List<String> recoveryRoots;

  final List<LocationSuggestion> suggestions;
  final List<StorageVolume> volumes;

  /// Paths under a custom directory, for tests.
  @visibleForTesting
  factory AppPaths.forTesting(String base, {List<String> downloads = const []}) => AppPaths._(
    supportDir: base,
    cacheDir: p.join(base, 'hash-cache'),
    recoveryRoots: [base],
    suggestions: [for (final d in downloads) LocationSuggestion('Downloads', d)],
    volumes: const [],
  );

  static Future<AppPaths> resolve() async {
    final support = await getApplicationSupportDirectory();
    final cacheDir = p.join(support.path, 'hash-cache');
    final volumes = await NativePlatform.storageVolumes();

    final recoveryRoots = <String>[];
    if (Platform.isAndroid) {
      // App-specific dirs exist on every volume and need no permission;
      // the primary volume comes first.
      for (final v in volumes) {
        if (v.appDir != null) recoveryRoots.add(v.appDir!);
      }
      if (recoveryRoots.isEmpty) {
        final ext = await getExternalStorageDirectories();
        recoveryRoots.addAll((ext ?? const <Directory>[]).map((d) => d.path));
      }
    }
    recoveryRoots.add(support.path);

    return AppPaths._(
      supportDir: support.path,
      cacheDir: cacheDir,
      recoveryRoots: recoveryRoots.toSet().toList(),
      suggestions: await _suggestions(volumes),
      volumes: volumes,
    );
  }

  static Future<List<LocationSuggestion>> _suggestions(List<StorageVolume> volumes) async {
    final out = <LocationSuggestion>[];
    void add(String label, String path, {bool volume = false}) {
      if (Directory(path).existsSync() && !out.any((s) => s.path == path)) {
        out.add(LocationSuggestion(label, path, isVolume: volume));
      }
    }

    if (Platform.isAndroid) {
      final primary = volumes.where((v) => v.isPrimary).map((v) => v.path).firstOrNull ?? '/storage/emulated/0';
      for (final v in volumes) {
        add(v.label, v.path, volume: true);
      }
      add('Downloads', p.join(primary, 'Download'));
      add('Camera', p.join(primary, 'DCIM'));
      add('Pictures', p.join(primary, 'Pictures'));
      add('Documents', p.join(primary, 'Documents'));
      add('Movies', p.join(primary, 'Movies'));
      add('Music', p.join(primary, 'Music'));
      // Messaging apps keep a copy of every photo and video sent or received.
      add('WhatsApp media', p.join(primary, 'Android', 'media', 'com.whatsapp', 'WhatsApp', 'Media'));
      add('WhatsApp media', p.join(primary, 'WhatsApp', 'Media')); // before Android 11
      add('WhatsApp Business', p.join(primary, 'Android', 'media', 'com.whatsapp.w4b', 'WhatsApp Business', 'Media'));
      add('Telegram', p.join(primary, 'Android', 'media', 'org.telegram.messenger', 'Telegram'));
      add('Telegram', p.join(primary, 'Telegram'));
    } else if (Platform.isIOS) {
      final docs = await getApplicationDocumentsDirectory();
      add('On My iPhone · DigiClean', docs.path);
    } else {
      final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
      if (home != null) {
        add('Home', home);
        add('Downloads', p.join(home, 'Downloads'));
        add('Documents', p.join(home, 'Documents'));
        add('Pictures', p.join(home, 'Pictures'));
        add('Videos', p.join(home, Platform.isMacOS ? 'Movies' : 'Videos'));
        add('Music', p.join(home, 'Music'));
        add('Desktop', p.join(home, 'Desktop'));
        add('OneDrive', p.join(home, 'OneDrive'));
        add('Telegram downloads', p.join(home, 'Downloads', 'Telegram Desktop'));
      }
      if (Platform.isWindows) {
        for (final letter in 'CDEFGHIJKLMNOPQRSTUVWXYZ'.split('')) {
          add('Drive $letter:', '$letter:\\', volume: true);
        }
      } else if (Platform.isLinux) {
        final user = Platform.environment['USER'];
        for (final base in ['/media/$user', '/run/media/$user', '/mnt']) {
          final dir = Directory(base);
          if (!dir.existsSync()) continue;
          for (final e in dir.listSync().whereType<Directory>()) {
            add(p.basename(e.path), e.path, volume: true);
          }
        }
      } else if (Platform.isMacOS) {
        final volumesDir = Directory('/Volumes');
        if (volumesDir.existsSync()) {
          for (final e in volumesDir.listSync().whereType<Directory>()) {
            add(p.basename(e.path), e.path, volume: true);
          }
        }
      }
    }
    return out;
  }
}
