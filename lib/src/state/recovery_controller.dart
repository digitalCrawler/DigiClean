import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api/maintenance.dart';
import '../rust/api/types.dart';
import 'history.dart';
import 'locations.dart';

/// Items in the app-managed recovery bin, newest first.
class RecoveryNotifier extends AsyncNotifier<List<RecoveryItemDto>> {
  List<String> get _roots => ref.read(appPathsProvider).recoveryRoots;

  @override
  Future<List<RecoveryItemDto>> build() => recoveryList(roots: _roots);

  Future<void> refresh() async {
    state = await AsyncValue.guard(() => recoveryList(roots: _roots));
  }

  Future<RestoreReportDto> restore(List<String> ids) async {
    final report = await recoveryRestore(roots: _roots, ids: ids);
    await refresh();
    return report;
  }

  Future<RestoreReportDto> restoreBatch(String batchId) async {
    final report = await recoveryRestoreBatch(roots: _roots, batchId: batchId);
    await refresh();
    return report;
  }

  void _record(int items, int freed) => ref
      .read(historyProvider.notifier)
      .record(
        CleanupEvent(
          kind: CleanupKind.recoveryBin,
          atMs: DateTime.now().millisecondsSinceEpoch,
          items: items,
          bytesFreed: freed,
        ),
      );

  Future<int> purge(List<String> ids) async {
    final freed = await recoveryPurge(roots: _roots, ids: ids);
    _record(ids.length, freed);
    await refresh();
    return freed;
  }

  Future<int> purgeAll() async {
    final items = state.value?.length ?? 0;
    final freed = await recoveryPurgeAll(roots: _roots);
    _record(items, freed);
    await refresh();
    return freed;
  }

  /// Applies the retention policy; called at startup.
  Future<void> purgeExpired(int days) async {
    if (days <= 0) return;
    final freed = await recoveryPurgeOlderThan(roots: _roots, days: days);
    if (freed > 0) {
      _record(0, freed);
      await refresh();
    }
  }
}

final recoveryProvider = AsyncNotifierProvider<RecoveryNotifier, List<RecoveryItemDto>>(RecoveryNotifier.new);
