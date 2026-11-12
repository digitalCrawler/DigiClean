import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api/types.dart';
import 'settings.dart';

/// What a history entry records.
enum CleanupKind {
  /// Removed, moved or linked items from scan results.
  cleanup,

  /// Deleted items from DigiClean's Recovery Bin (by hand or after expiry).
  recoveryBin,

  /// Emptied the system Recycle Bin / Trash.
  systemTrash,
}

/// One thing DigiClean did to free space, with honest numbers: bytes moved
/// into a bin are not counted as freed until that bin is emptied.
@immutable
class CleanupEvent {
  const CleanupEvent({
    required this.kind,
    required this.atMs,
    required this.items,
    this.action,
    this.bytesFreed = 0,
    this.bytesInBin = 0,
    this.bytesMoved = 0,
    this.systemTrash = false,
  });

  factory CleanupEvent.fromReport(ActionReportDto r, ActionType action) => CleanupEvent(
    kind: CleanupKind.cleanup,
    atMs: DateTime.now().millisecondsSinceEpoch,
    items: r.succeeded.toInt(),
    action: action,
    bytesFreed: r.bytesFreed.toInt(),
    bytesInBin: r.bytesInBin.toInt(),
    bytesMoved: r.bytesMoved.toInt(),
    systemTrash: r.usedSystemTrash,
  );

  factory CleanupEvent.fromJson(Map<String, Object?> j) => CleanupEvent(
    kind: CleanupKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => CleanupKind.cleanup),
    atMs: j['at'] as int? ?? 0,
    items: j['items'] as int? ?? 0,
    action: ActionType.values.where((a) => a.name == j['action']).firstOrNull,
    bytesFreed: j['freed'] as int? ?? 0,
    bytesInBin: j['inBin'] as int? ?? 0,
    bytesMoved: j['moved'] as int? ?? 0,
    systemTrash: j['systemTrash'] as bool? ?? false,
  );

  final CleanupKind kind;
  final int atMs;
  final int items;

  /// For [CleanupKind.cleanup]: what was done.
  final ActionType? action;
  final int bytesFreed;
  final int bytesInBin;
  final int bytesMoved;

  /// Items went to the system Recycle Bin / Trash rather than DigiClean's.
  final bool systemTrash;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'at': atMs,
    'items': items,
    if (action != null) 'action': action!.name,
    if (bytesFreed > 0) 'freed': bytesFreed,
    if (bytesInBin > 0) 'inBin': bytesInBin,
    if (bytesMoved > 0) 'moved': bytesMoved,
    if (systemTrash) 'systemTrash': true,
  };
}

/// Cleanup history, newest first, capped at [maxEntries].
class HistoryController extends Notifier<List<CleanupEvent>> {
  static const _key = 'history.v1';
  static const maxEntries = 500;

  @override
  List<CleanupEvent> build() {
    final raw = ref.watch(sharedPreferencesProvider).getString(_key);
    if (raw == null) return const [];
    try {
      return [
        for (final e in jsonDecode(raw) as List<Object?>) CleanupEvent.fromJson((e! as Map).cast<String, Object?>()),
      ];
    } catch (_) {
      return const [];
    }
  }

  void _save(List<CleanupEvent> list) {
    state = List.unmodifiable(list);
    ref.read(sharedPreferencesProvider).setString(_key, jsonEncode([for (final e in list) e.toJson()]));
  }

  void record(CleanupEvent event) {
    if (event.items <= 0 && event.bytesFreed <= 0) return;
    _save([event, ...state.take(maxEntries - 1)]);
  }

  void clear() => _save(const []);
}

final historyProvider = NotifierProvider<HistoryController, List<CleanupEvent>>(HistoryController.new);

/// Space actually released by DigiClean, over the whole history.
final totalFreedProvider = Provider<int>((ref) => ref.watch(historyProvider).fold(0, (sum, e) => sum + e.bytesFreed));
