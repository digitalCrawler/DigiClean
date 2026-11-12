import 'package:digiclean/src/rust/api/types.dart';
import 'package:digiclean/src/state/history.dart';
import 'package:digiclean/src/state/settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('only space released for good counts as freed', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    ProviderContainer open() => ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);

    final c = open();
    final history = c.read(historyProvider.notifier);
    history.record(
      const CleanupEvent(
        kind: CleanupKind.cleanup,
        atMs: 1,
        items: 3,
        action: ActionType.trash,
        bytesInBin: 5000,
        systemTrash: true,
      ),
    );
    history.record(
      const CleanupEvent(
        kind: CleanupKind.cleanup,
        atMs: 2,
        items: 2,
        action: ActionType.deletePermanently,
        bytesFreed: 700,
      ),
    );
    history.record(const CleanupEvent(kind: CleanupKind.systemTrash, atMs: 3, items: 4, bytesFreed: 9000));
    history.record(const CleanupEvent(kind: CleanupKind.recoveryBin, atMs: 4, items: 0)); // nothing happened
    expect(c.read(historyProvider), hasLength(3));
    expect(c.read(totalFreedProvider), 9700);
    c.dispose();

    final reopened = open();
    addTearDown(reopened.dispose);
    final saved = reopened.read(historyProvider);
    expect(saved.map((e) => e.atMs), [3, 2, 1], reason: 'newest first');
    expect(saved.last.action, ActionType.trash);
    expect(saved.last.systemTrash, isTrue);
    expect(saved.last.bytesInBin, 5000);
    expect(reopened.read(totalFreedProvider), 9700);
  });

  test('history is capped', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(c.dispose);
    for (var i = 0; i < HistoryController.maxEntries + 10; i++) {
      c.read(historyProvider.notifier).record(CleanupEvent(kind: CleanupKind.systemTrash, atMs: i, items: 1));
    }
    expect(c.read(historyProvider), hasLength(HistoryController.maxEntries));
    expect(c.read(historyProvider).first.atMs, HistoryController.maxEntries + 9);
  });
}
