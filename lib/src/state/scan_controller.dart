import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_paths.dart';
import '../core/format.dart';
import '../core/native.dart';
import '../rust/api/maintenance.dart';
import '../rust/api/scanner.dart';
import '../rust/api/types.dart';
import 'locations.dart';
import 'results_controller.dart';
import 'settings.dart';

enum ScanStatus { idle, running, completed, cancelled, failed }

@immutable
class ScanState {
  const ScanState({
    this.status = ScanStatus.idle,
    this.progress,
    this.error,
    this.paused = false,
    this.roots = const [],
  });

  final ScanStatus status;
  final ScanProgress? progress;
  final String? error;
  final bool paused;
  final List<String> roots;

  bool get isRunning => status == ScanStatus.running;

  ScanState copyWith({ScanStatus? status, ScanProgress? progress, String? error, bool? paused, List<String>? roots}) =>
      ScanState(
        status: status ?? this.status,
        progress: progress ?? this.progress,
        error: error ?? this.error,
        paused: paused ?? this.paused,
        roots: roots ?? this.roots,
      );
}

/// Translates settings + locations into engine options.
ScanOptions buildScanOptions(AppSettings s, List<String> roots, AppPaths paths) {
  return ScanOptions(
    roots: roots,
    recursive: s.recursive,
    maxDepth: s.recursive ? s.maxDepth : null,
    followSymlinks: s.followSymlinks,
    includeHidden: s.includeHidden,
    skipSystemFolders: s.skipSystemFolders,
    skipCloudPlaceholders: s.skipCloudPlaceholders,
    minSize: s.minSize,
    maxSize: s.maxSize,
    includeExtensions: s.includeExtensions,
    excludeExtensions: s.excludeExtensions,
    categories: s.categories.toList(),
    excludePaths: s.excludePaths,
    excludeGlobs: s.excludeGlobs,
    // Never scan our own data: the recovery bin and the hash cache.
    protectedPaths: [
      ...recoveryProtectedPaths(roots: paths.recoveryRoots),
      paths.cacheDir,
    ],
    hashAlgorithm: s.hashAlgorithm,
    verifyByteByByte: s.verifyByteByByte,
    detectDuplicateFolders: s.detectFolders,
    detectEmptyFolders: s.detectEmptyFolders,
    includeEmptyFiles: s.includeEmptyFiles,
    performance: s.effectivePerformance,
    threads: 0,
    cacheDir: s.useCache ? paths.cacheDir : null,
  );
}

String phaseLabel(Phase phase) => switch (phase) {
  Phase.discovering => 'Discovering files',
  Phase.groupingBySize => 'Grouping by size',
  Phase.partialHashing => 'Quick fingerprinting',
  Phase.fullHashing => 'Hashing contents',
  Phase.verifying => 'Verifying byte-by-byte',
  Phase.analyzingFolders => 'Comparing folders',
  Phase.finalizing => 'Finalizing',
  Phase.done => 'Done',
};

class ScanNotifier extends Notifier<ScanState> {
  ScanController? _controller;
  StreamSubscription<ScanEvent>? _subscription;
  DateTime _lastNotification = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  ScanState build() {
    ref.onDispose(() => _subscription?.cancel());
    return const ScanState();
  }

  /// Starts scanning the enabled locations. Throws [StateError] when no
  /// location is selected.
  Future<void> start() async {
    if (state.isRunning) return;
    final locations = ref.read(locationsProvider).where((l) => l.enabled && l.exists).toList();
    if (locations.isEmpty) throw StateError('Add at least one folder to scan.');
    final roots = locations.map((l) => l.path).toList();
    final options = buildScanOptions(ref.read(settingsProvider), roots, ref.read(appPathsProvider));

    // Free the previous session's memory before building a new one.
    ref.read(resultsProvider.notifier).clear();

    final controller = ScanController();
    _controller = controller;
    state = ScanState(status: ScanStatus.running, roots: roots);
    await NativePlatform.startBackgroundWork('Scanning for duplicates', 'Starting…');

    await _subscription?.cancel();
    _subscription = controller
        .start(options: options)
        .listen(_onEvent, onError: (Object e) => _finish(ScanStatus.failed, error: e.toString()));
  }

  void _onEvent(ScanEvent event) {
    switch (event.kind) {
      case ScanEventKind.progress:
        final p = event.progress!;
        state = state.copyWith(progress: p, paused: p.paused);
        _updateNotification(p);
      case ScanEventKind.completed:
        final results = _controller?.takeResults();
        if (results != null) {
          // The engine's roots are canonical, so they prefix the result paths.
          ref.read(resultsProvider.notifier).setResults(results, results.roots());
        }
        _finish(ScanStatus.completed);
      case ScanEventKind.cancelled:
        _finish(ScanStatus.cancelled);
      case ScanEventKind.failed:
        _finish(ScanStatus.failed, error: event.error ?? 'Scan failed');
    }
  }

  void _updateNotification(ScanProgress p) {
    final now = DateTime.now();
    if (now.difference(_lastNotification) < const Duration(seconds: 1)) return;
    _lastNotification = now;
    final percent = p.phaseBytesTotal > 0 ? (p.phaseBytesDone * 100 ~/ p.phaseBytesTotal) : -1;
    NativePlatform.updateBackgroundWork('${phaseLabel(p.phase)} · ${formatCount(p.filesDiscovered)} files', percent);
  }

  void _finish(ScanStatus status, {String? error}) {
    state = state.copyWith(status: status, error: error, paused: false);
    _subscription?.cancel();
    _subscription = null;
    _controller?.dispose();
    _controller = null;
    NativePlatform.stopBackgroundWork();
  }

  void pause() {
    _controller?.pause();
    state = state.copyWith(paused: true);
  }

  void resume() {
    _controller?.resume();
    state = state.copyWith(paused: false);
  }

  void cancel() => _controller?.cancel();

  /// Returns to idle after the user has seen a finished/failed scan.
  void acknowledge() {
    if (!state.isRunning) state = const ScanState();
  }
}

final scanProvider = NotifierProvider<ScanNotifier, ScanState>(ScanNotifier.new);
