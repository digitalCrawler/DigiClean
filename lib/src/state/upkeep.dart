import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api/types.dart';
import 'locations.dart';
import 'results_controller.dart';
import 'scan_controller.dart';
import 'settings.dart';

/// How often download folders are checked while the app is open.
const _watchInterval = Duration(minutes: 10);

/// How often the rescan schedule is looked at while the app is open.
const _scheduleInterval = Duration(hours: 1);

@immutable
class UpkeepState {
  const UpkeepState({this.newCopies = const [], this.lastCheck});

  /// New downloads whose content already exists in the scanned folders.
  final List<CopyMatchDto> newCopies;
  final DateTime? lastCheck;

  int get newCopyBytes => newCopies.fold(0, (s, c) => s + c.size);
}

/// Keeps storage tidy while DigiClean is open: rescans on the user's
/// schedule and notices new downloads that copy files already kept.
class UpkeepController extends Notifier<UpkeepState> {
  static const _lastCheckKey = 'upkeep.lastCheckMs';
  Timer? _watch;
  Timer? _schedule;
  bool _checking = false;

  @override
  UpkeepState build() {
    ref.onDispose(() {
      _watch?.cancel();
      _schedule?.cancel();
    });
    final ms = ref.read(sharedPreferencesProvider).getInt(_lastCheckKey);
    return UpkeepState(lastCheck: ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms));
  }

  /// Starts the timers; call once the app has restored its state.
  void start() {
    _watch ??= Timer.periodic(_watchInterval, (_) => checkDownloads());
    _schedule ??= Timer.periodic(_scheduleInterval, (_) => rescanIfDue());
    rescanIfDue();
    checkDownloads();
  }

  /// Starts a scan when automatic rescans are on and the last one is older
  /// than the chosen interval. Returns whether a scan was started.
  Future<bool> rescanIfDue({DateTime? now}) async {
    final days = ref.read(settingsProvider).autoRescanDays;
    if (days <= 0 || ref.read(scanProvider).isRunning) return false;
    final hasLocations = ref.read(locationsProvider).any((l) => l.enabled && l.exists);
    if (!hasLocations) return false;
    final last = ref.read(resultsProvider).finishedAt;
    final due = last == null || (now ?? DateTime.now()).difference(last) >= Duration(days: days);
    if (!due) return false;
    try {
      await ref.read(scanProvider.notifier).start();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Looks for files added to the download folders since the last check
  /// that are copies of scanned files.
  Future<void> checkDownloads({DateTime? now}) async {
    final results = ref.read(resultsProvider).results;
    if (!ref.read(settingsProvider).watchDownloads || results == null || _checking) return;
    if (ref.read(scanProvider).isRunning) return;
    _checking = true;
    try {
      final since = state.lastCheck ?? ref.read(resultsProvider).finishedAt ?? DateTime.now();
      final checkedAt = now ?? DateTime.now();
      final fresh = <String>[];
      for (final dir in ref.read(appPathsProvider).downloadDirs) {
        final d = Directory(dir);
        if (!d.existsSync()) continue;
        for (final e in d.listSync(followLinks: false).whereType<File>()) {
          try {
            if (e.lastModifiedSync().isAfter(since)) fresh.add(e.path);
          } catch (_) {}
        }
      }
      final found = fresh.isEmpty
          ? const <CopyMatchDto>[]
          : await results.findCopies(paths: fresh, cacheDir: ref.read(appPathsProvider).cacheDir);
      final known = {for (final c in state.newCopies) c.path};
      final merged = [
        ...state.newCopies.where((c) => File(c.path).existsSync()),
        for (final c in found)
          if (!known.contains(c.path)) c,
      ];
      ref.read(sharedPreferencesProvider).setInt(_lastCheckKey, checkedAt.millisecondsSinceEpoch);
      state = UpkeepState(newCopies: merged, lastCheck: checkedAt);
    } catch (_) {
      // Busy session or unreadable folder: the next check retries.
    } finally {
      _checking = false;
    }
  }

  /// Forgets reported copies (handled or dismissed).
  void clear([Iterable<String>? paths]) {
    final drop = paths?.toSet();
    state = UpkeepState(
      newCopies: drop == null ? const [] : state.newCopies.where((c) => !drop.contains(c.path)).toList(),
      lastCheck: state.lastCheck,
    );
  }
}

final upkeepProvider = NotifierProvider<UpkeepController, UpkeepState>(UpkeepController.new);
