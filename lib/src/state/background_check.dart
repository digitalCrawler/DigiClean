import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/app_paths.dart';
import '../core/background_schedule.dart';
import '../core/native.dart';
import '../core/storage_access.dart';
import '../rust/api/maintenance.dart';
import 'ignore_list.dart';
import 'locations.dart';
import 'scan_controller.dart';
import 'settings.dart';

String backgroundJobPath(AppPaths paths) => p.join(paths.supportDir, 'background-job.json');

/// Summary the last background check wrote.
String backgroundResultPath(AppPaths paths) => p.join(paths.supportDir, 'background-check.json');

/// Keeps the scheduled background check (desktop) in line with the app:
/// the job file mirrors the current locations, scan settings and the
/// "not duplicates" list.
class BackgroundCheckController {
  /// Desktop: the system scheduler runs a full check. Android: WorkManager
  /// notifies about low storage and due rescans.
  static bool get supported => BackgroundSchedule.supported || Platform.isAndroid || Platform.isIOS;

  BackgroundCheckController(this._ref, {BackgroundSchedule? schedule}) : _schedule = schedule ?? BackgroundSchedule();

  final Ref _ref;
  final BackgroundSchedule _schedule;

  /// Writes the job file; returns its path, or `null` without locations.
  Future<String?> writeJob() async {
    final paths = _ref.read(appPathsProvider);
    final roots = [
      for (final l in _ref.read(locationsProvider))
        if (l.enabled && l.exists) l.path,
    ];
    if (roots.isEmpty) return null;
    final json = await backgroundJobJson(
      options: buildScanOptions(_ref.read(settingsProvider), roots, paths),
      snapshot: paths.snapshotPath,
      result: backgroundResultPath(paths),
      ignored: [for (final g in _ref.read(ignoreListProvider)) g.key],
    );
    final file = File(backgroundJobPath(paths))..parent.createSync(recursive: true);
    file.writeAsStringSync(json);
    return file.path;
  }

  /// Turns the schedule on or off and saves the setting. Returns a message
  /// for the user when it cannot be done.
  Future<String?> setEnabled(bool enabled) async {
    if (!supported) return 'Not available on this device.';
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        if (enabled && Platform.isAndroid) await StorageAccess.requestNotifications();
        await NativePlatform.scheduleBackgroundCheck(
          enabled: enabled,
          snapshot: _ref.read(appPathsProvider).snapshotPath,
        );
      } else if (enabled) {
        final checker = BackgroundSchedule.findChecker();
        if (checker == null) {
          return 'The background checker (${BackgroundSchedule.checkerName}) is not installed next to DigiClean.';
        }
        final job = await writeJob();
        if (job == null) return 'Add a folder to scan first.';
        await _schedule.enable(checker: checker, job: job);
      } else {
        await _schedule.disable();
      }
    } catch (e) {
      return 'Could not ${enabled ? 'schedule' : 'remove'} the background check: $e';
    }
    _ref.read(settingsProvider.notifier).update((s) => s.copyWith(backgroundCheck: enabled));
    return null;
  }

  /// Refreshes the job file (desktop) or the schedule (Android) when the
  /// background check is on.
  Future<void> refresh() async {
    if (!_ref.read(settingsProvider).backgroundCheck || !supported) return;
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        await NativePlatform.scheduleBackgroundCheck(enabled: true, snapshot: _ref.read(appPathsProvider).snapshotPath);
        return;
      }
      await writeJob();
    } catch (_) {
      // The previous job file stays in place.
    }
  }
}

final backgroundCheckProvider = Provider<BackgroundCheckController>(BackgroundCheckController.new);
