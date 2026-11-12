import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api/results.dart';
import '../rust/api/types.dart';
import 'ignore_list.dart';
import 'locations.dart';

@immutable
class ResultsState {
  const ResultsState({
    this.results,
    this.stats,
    this.summary,
    this.roots = const [],
    this.finishedAt,
    this.generation = 0,
    this.selectionVersion = 0,
    this.restored = false,
  });

  final ScanResults? results;
  final ScanStatsDto? stats;
  final SelectionSummaryDto? summary;
  final List<String> roots;
  final DateTime? finishedAt;

  /// Bumped when the result set changes (after actions); paged lists reload.
  final int generation;

  /// Bumped when only the selection changes.
  final int selectionVersion;

  /// Reopened from the results saved by an earlier session.
  final bool restored;

  bool get hasResults => results != null;
}

class ResultsNotifier extends Notifier<ResultsState> {
  @override
  ResultsState build() {
    ref.listen(ignoreListProvider, (_, next) => _applyIgnoreList(next));
    ref.onDispose(() => _saveTimer?.cancel());
    return const ResultsState();
  }

  Timer? _saveTimer;
  Future<void> _saving = Future.value();

  String get _snapshotPath => ref.read(appPathsProvider).snapshotPath;

  void setResults(ScanResults results, List<String> roots, {DateTime? finishedAt, bool restored = false}) {
    _saveTimer?.cancel();
    state.results?.dispose();
    try {
      results.setIgnored(keys: [for (final g in ref.read(ignoreListProvider)) g.key]);
    } catch (_) {
      // Busy right after a scan is not expected; groups simply stay visible.
    }
    state = ResultsState(
      results: results,
      stats: results.stats(),
      summary: results.selectionSummary(),
      roots: roots,
      finishedAt: finishedAt ?? DateTime.now(),
      generation: state.generation + 1,
      restored: restored,
    );
    if (!restored) save();
  }

  void clear() {
    _saveTimer?.cancel();
    state.results?.dispose();
    state = ResultsState(generation: state.generation + 1);
    _saving = _saving
        .then((_) {
          final file = File(_snapshotPath);
          if (file.existsSync()) file.deleteSync();
        })
        .catchError((_) {});
  }

  /// Saves the results, with removals and the selection, so the next start
  /// reopens them. Called after scans and actions, and when the app is
  /// hidden or closed. Saves run one at a time.
  Future<void> save() {
    _saveTimer?.cancel();
    final results = state.results;
    final finishedAt = state.finishedAt;
    if (results == null || finishedAt == null) return _saving;
    final path = _snapshotPath;
    return _saving = _saving
        .then((_) => results.saveSnapshot(path: path, finishedMs: finishedAt.millisecondsSinceEpoch))
        .catchError((_) {
          // Disk full or results replaced meanwhile; the next save retries.
        });
  }

  void _saveSoon() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), save);
  }

  /// Reopens the results saved by the previous session, if there are any.
  Future<void> restoreSaved() async {
    final path = _snapshotPath;
    if (state.results != null || !File(path).existsSync()) return;
    try {
      final results = await ScanResults.loadSnapshot(path: path);
      if (state.results != null) {
        // A scan finished while loading; it wins.
        results.dispose();
        return;
      }
      final ms = results.savedFinishedMs();
      setResults(
        results,
        results.roots(),
        finishedAt: ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms),
        restored: true,
      );
    } catch (_) {
      // Damaged or from another app version: start fresh.
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
  }

  /// Updates the selection summary after a selection call.
  void selectionChanged(SelectionSummaryDto summary, {bool reloadLists = false}) {
    state = ResultsState(
      results: state.results,
      stats: state.stats,
      summary: summary,
      roots: state.roots,
      finishedAt: state.finishedAt,
      generation: reloadLists ? state.generation + 1 : state.generation,
      selectionVersion: state.selectionVersion + 1,
      restored: state.restored,
    );
    // Removals and restores change what is saved; plain selection changes
    // are saved when the app is hidden or closed.
    if (reloadLists) _saveSoon();
  }

  void _applyIgnoreList(List<IgnoredGroup> list) {
    final results = state.results;
    if (results == null) return;
    try {
      selectionChanged(results.setIgnored(keys: [for (final g in list) g.key]), reloadLists: true);
    } catch (_) {
      // An action is running; the list applies to the next scan.
    }
  }

  /// Reloads summary and lists after the underlying data changed.
  void refresh() {
    final results = state.results;
    if (results == null) return;
    try {
      selectionChanged(results.selectionSummary(), reloadLists: true);
    } catch (_) {
      // The session is busy; the next interaction refreshes it.
    }
  }
}

final resultsProvider = NotifierProvider<ResultsNotifier, ResultsState>(ResultsNotifier.new);
