import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/app_paths.dart';
import '../core/native.dart';
import 'settings.dart';

/// Provided by `main()` once directories are resolved.
final appPathsProvider = Provider<AppPaths>((ref) => throw UnimplementedError('override in ProviderScope'));

class ScanLocation {
  const ScanLocation({required this.path, required this.label, this.bookmark, this.enabled = true});

  final String path;
  final String label;

  /// iOS security-scoped bookmark (base64).
  final String? bookmark;

  /// Disabled locations are remembered but not scanned.
  final bool enabled;

  bool get exists => Directory(path).existsSync() || File(path).existsSync();

  ScanLocation copyWith({String? path, String? bookmark, bool? enabled}) => ScanLocation(
    path: path ?? this.path,
    label: label,
    bookmark: bookmark ?? this.bookmark,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object?> toJson() => {'path': path, 'label': label, 'bookmark': bookmark, 'enabled': enabled};

  factory ScanLocation.fromJson(Map<String, Object?> j) => ScanLocation(
    path: j['path'] as String,
    label: j['label'] as String? ?? p.basename(j['path'] as String),
    bookmark: j['bookmark'] as String?,
    enabled: j['enabled'] as bool? ?? true,
  );
}

class LocationsController extends Notifier<List<ScanLocation>> {
  static const _key = 'locations.v1';

  @override
  List<ScanLocation> build() {
    final raw = ref.watch(sharedPreferencesProvider).getString(_key);
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List).cast<Map<String, Object?>>().map(ScanLocation.fromJson).toList();
    } catch (_) {
      return const [];
    }
  }

  void _save(List<ScanLocation> list) {
    state = list;
    ref.read(sharedPreferencesProvider).setString(_key, jsonEncode(list.map((l) => l.toJson()).toList()));
  }

  /// Re-establishes iOS folder access after a restart. Bookmarks can
  /// resolve to new paths (e.g. after the app container moves).
  Future<void> restoreAccess() async {
    if (!Platform.isIOS) return;
    final withBookmarks = state.where((l) => l.bookmark != null).toList();
    if (withBookmarks.isEmpty) return;
    final resolved = await NativePlatform.resolveBookmarksIOS(withBookmarks.map((l) => l.bookmark!).toList());
    final updated = [...state];
    for (var i = 0; i < withBookmarks.length && i < resolved.length; i++) {
      final folder = resolved[i];
      final index = updated.indexOf(withBookmarks[i]);
      // Unresolvable bookmarks keep their entry; it shows as unavailable.
      if (index >= 0 && folder != null) {
        updated[index] = updated[index].copyWith(path: folder.path, bookmark: folder.bookmark);
      }
    }
    _save(updated);
  }

  /// Shows the platform folder picker. Returns the added location.
  Future<ScanLocation?> pickAndAdd() async {
    if (Platform.isIOS) {
      final picked = await NativePlatform.pickFolderIOS();
      if (picked == null) return null;
      return add(picked.path, bookmark: picked.bookmark);
    }
    final path = await FilePicker.getDirectoryPath(dialogTitle: 'Choose a folder to scan');
    if (path == null || path.isEmpty) return null;
    return add(path);
  }

  ScanLocation? add(String path, {String? label, String? bookmark}) {
    final normalized = p.normalize(path);
    if (state.any((l) => _same(l.path, normalized))) return null;
    final name = p.basename(normalized);
    final location = ScanLocation(
      path: normalized,
      label: label ?? (name.isEmpty ? normalized : name),
      bookmark: bookmark,
    );
    _save([...state, location]);
    return location;
  }

  void remove(ScanLocation location) {
    if (location.bookmark != null) NativePlatform.releaseFolderIOS(location.path);
    _save(state.where((l) => l != location).toList());
  }

  void toggle(ScanLocation location) {
    _save([
      for (final l in state)
        if (l == location) l.copyWith(enabled: !l.enabled) else l,
    ]);
  }

  static bool _same(String a, String b) =>
      Platform.isWindows || Platform.isMacOS || Platform.isIOS ? a.toLowerCase() == b.toLowerCase() : a == b;
}

final locationsProvider = NotifierProvider<LocationsController, List<ScanLocation>>(LocationsController.new);
