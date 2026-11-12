import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api/types.dart';
import 'settings.dart';

/// Duplicate content the user marked as "not duplicates". Matched by content
/// hash, so the group stays hidden in later scans even if files move.
@immutable
class IgnoredGroup {
  const IgnoredGroup({
    required this.kind,
    required this.algorithm,
    required this.digest,
    required this.name,
    required this.path,
    required this.copies,
    required this.size,
    required this.addedMs,
  });

  factory IgnoredGroup.fromDto(IgnoredGroupDto d) => IgnoredGroup(
    kind: d.key.kind,
    algorithm: d.key.algorithm,
    digest: d.key.digest,
    name: d.name,
    path: d.path,
    copies: d.copies,
    size: d.size,
    addedMs: DateTime.now().millisecondsSinceEpoch,
  );

  factory IgnoredGroup.fromJson(Map<String, Object?> j) => IgnoredGroup(
    kind: j['kind'] == 'folders' ? ResultKind.folders : ResultKind.files,
    algorithm: j['algorithm'] == 'sha256' ? HashAlgo.sha256 : HashAlgo.blake3,
    digest: j['digest']! as String,
    name: j['name'] as String? ?? '',
    path: j['path'] as String? ?? '',
    copies: j['copies'] as int? ?? 0,
    size: j['size'] as int? ?? 0,
    addedMs: j['addedMs'] as int? ?? 0,
  );

  /// `ResultKind.files` or `ResultKind.folders`.
  final ResultKind kind;
  final HashAlgo algorithm;
  final String digest;

  /// Name and location of one copy when it was ignored, for display.
  final String name;
  final String path;
  final int copies;

  /// Size of one copy.
  final int size;
  final int addedMs;

  String get id => '${kind.name}:${algorithm.name}:$digest';

  IgnoreKeyDto get key => IgnoreKeyDto(kind: kind, algorithm: algorithm, digest: digest);

  Map<String, Object?> toJson() => {
    'kind': kind == ResultKind.folders ? 'folders' : 'files',
    'algorithm': algorithm == HashAlgo.sha256 ? 'sha256' : 'blake3',
    'digest': digest,
    'name': name,
    'path': path,
    'copies': copies,
    'size': size,
    'addedMs': addedMs,
  };
}

/// The persisted ignore list, newest first.
class IgnoreListController extends Notifier<List<IgnoredGroup>> {
  static const _key = 'ignored.v1';

  @override
  List<IgnoredGroup> build() {
    final raw = ref.watch(sharedPreferencesProvider).getString(_key);
    if (raw == null) return const [];
    try {
      return [
        for (final e in jsonDecode(raw) as List<Object?>) IgnoredGroup.fromJson((e! as Map).cast<String, Object?>()),
      ];
    } catch (_) {
      return const [];
    }
  }

  void _save(List<IgnoredGroup> list) {
    state = List.unmodifiable(list);
    ref.read(sharedPreferencesProvider).setString(_key, jsonEncode([for (final g in list) g.toJson()]));
  }

  void add(IgnoredGroup group) => _save([group, ...state.where((g) => g.id != group.id)]);

  void remove(IgnoredGroup group) => _save(state.where((g) => g.id != group.id).toList());

  void clear() => _save(const []);
}

final ignoreListProvider = NotifierProvider<IgnoreListController, List<IgnoredGroup>>(IgnoreListController.new);
