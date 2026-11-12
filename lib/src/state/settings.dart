import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api/types.dart';

/// User preferences and default scan options. Immutable; persisted as JSON.
@immutable
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.recursive = true,
    this.maxDepth,
    this.includeHidden = false,
    this.followSymlinks = false,
    this.skipSystemFolders = true,
    this.skipCloudPlaceholders = true,
    this.minSize = 1,
    this.maxSize,
    this.includeExtensions = const [],
    this.excludeExtensions = const [],
    this.categories = const {},
    this.excludePaths = const [],
    this.excludeGlobs = const ['**/node_modules', '**/.git'],
    this.hashAlgorithm = HashAlgo.blake3,
    this.verifyByteByByte = false,
    this.detectFolders = true,
    this.detectEmptyFolders = true,
    this.includeEmptyFiles = false,
    this.performance,
    this.useCache = true,
    this.deleteAction = ActionType.trash,
    this.verifyBeforeDelete = true,
    this.recoveryRetentionDays = 30,
    this.onboardingDone = false,
    this.autoRescanDays = 0,
    this.watchDownloads = true,
    this.backgroundCheck = false,
  });

  final ThemeMode themeMode;

  final bool recursive;
  final int? maxDepth;
  final bool includeHidden;
  final bool followSymlinks;
  final bool skipSystemFolders;
  final bool skipCloudPlaceholders;
  final int minSize;
  final int? maxSize;
  final List<String> includeExtensions;
  final List<String> excludeExtensions;
  final Set<Category> categories;
  final List<String> excludePaths;
  final List<String> excludeGlobs;
  final HashAlgo hashAlgorithm;
  final bool verifyByteByByte;
  final bool detectFolders;
  final bool detectEmptyFolders;
  final bool includeEmptyFiles;

  /// `null` means "pick for this device" (see [effectivePerformance]).
  final PerformanceMode? performance;
  final bool useCache;

  /// Default action of the Delete button: [ActionType.trash] or
  /// [ActionType.recoveryBin].
  final ActionType deleteAction;
  final bool verifyBeforeDelete;
  final int recoveryRetentionDays;
  final bool onboardingDone;

  /// Rescan the saved locations when the last scan is this many days old
  /// (checked while the app is open); 0 turns it off.
  final int autoRescanDays;

  /// Flag new downloads that copy files already in the scanned folders.
  final bool watchDownloads;

  /// A daily check scheduled with the operating system (runs while the app
  /// is closed and notifies when there is space to free).
  final bool backgroundCheck;

  static bool get isMobile => Platform.isAndroid || Platform.isIOS;

  /// Mobile devices default to a battery-friendly profile.
  PerformanceMode get effectivePerformance =>
      performance ?? (isMobile ? PerformanceMode.balanced : PerformanceMode.maximum);

  /// Number of non-default filters, for the "Filters (3)" badge.
  int get activeFilterCount {
    var n = 0;
    if (minSize > 1) n++;
    if (maxSize != null) n++;
    if (includeExtensions.isNotEmpty) n++;
    if (excludeExtensions.isNotEmpty) n++;
    if (categories.isNotEmpty) n++;
    if (excludePaths.isNotEmpty) n++;
    if (!recursive || maxDepth != null) n++;
    if (includeHidden) n++;
    return n;
  }

  AppSettings copyWith({
    ThemeMode? themeMode,
    bool? recursive,
    int? Function()? maxDepth,
    bool? includeHidden,
    bool? followSymlinks,
    bool? skipSystemFolders,
    bool? skipCloudPlaceholders,
    int? minSize,
    int? Function()? maxSize,
    List<String>? includeExtensions,
    List<String>? excludeExtensions,
    Set<Category>? categories,
    List<String>? excludePaths,
    List<String>? excludeGlobs,
    HashAlgo? hashAlgorithm,
    bool? verifyByteByByte,
    bool? detectFolders,
    bool? detectEmptyFolders,
    bool? includeEmptyFiles,
    PerformanceMode? Function()? performance,
    bool? useCache,
    ActionType? deleteAction,
    bool? verifyBeforeDelete,
    int? recoveryRetentionDays,
    bool? onboardingDone,
    int? autoRescanDays,
    bool? watchDownloads,
    bool? backgroundCheck,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      recursive: recursive ?? this.recursive,
      maxDepth: maxDepth != null ? maxDepth() : this.maxDepth,
      includeHidden: includeHidden ?? this.includeHidden,
      followSymlinks: followSymlinks ?? this.followSymlinks,
      skipSystemFolders: skipSystemFolders ?? this.skipSystemFolders,
      skipCloudPlaceholders: skipCloudPlaceholders ?? this.skipCloudPlaceholders,
      minSize: minSize ?? this.minSize,
      maxSize: maxSize != null ? maxSize() : this.maxSize,
      includeExtensions: includeExtensions ?? this.includeExtensions,
      excludeExtensions: excludeExtensions ?? this.excludeExtensions,
      categories: categories ?? this.categories,
      excludePaths: excludePaths ?? this.excludePaths,
      excludeGlobs: excludeGlobs ?? this.excludeGlobs,
      hashAlgorithm: hashAlgorithm ?? this.hashAlgorithm,
      verifyByteByByte: verifyByteByByte ?? this.verifyByteByByte,
      detectFolders: detectFolders ?? this.detectFolders,
      detectEmptyFolders: detectEmptyFolders ?? this.detectEmptyFolders,
      includeEmptyFiles: includeEmptyFiles ?? this.includeEmptyFiles,
      performance: performance != null ? performance() : this.performance,
      useCache: useCache ?? this.useCache,
      deleteAction: deleteAction ?? this.deleteAction,
      verifyBeforeDelete: verifyBeforeDelete ?? this.verifyBeforeDelete,
      recoveryRetentionDays: recoveryRetentionDays ?? this.recoveryRetentionDays,
      onboardingDone: onboardingDone ?? this.onboardingDone,
      autoRescanDays: autoRescanDays ?? this.autoRescanDays,
      watchDownloads: watchDownloads ?? this.watchDownloads,
      backgroundCheck: backgroundCheck ?? this.backgroundCheck,
    );
  }

  Map<String, Object?> toJson() => {
    'themeMode': themeMode.name,
    'recursive': recursive,
    'maxDepth': maxDepth,
    'includeHidden': includeHidden,
    'followSymlinks': followSymlinks,
    'skipSystemFolders': skipSystemFolders,
    'skipCloudPlaceholders': skipCloudPlaceholders,
    'minSize': minSize,
    'maxSize': maxSize,
    'includeExtensions': includeExtensions,
    'excludeExtensions': excludeExtensions,
    'categories': categories.map((c) => c.name).toList(),
    'excludePaths': excludePaths,
    'excludeGlobs': excludeGlobs,
    'hashAlgorithm': hashAlgorithm.name,
    'verifyByteByByte': verifyByteByByte,
    'detectFolders': detectFolders,
    'detectEmptyFolders': detectEmptyFolders,
    'includeEmptyFiles': includeEmptyFiles,
    'performance': performance?.name,
    'useCache': useCache,
    'deleteAction': deleteAction.name,
    'verifyBeforeDelete': verifyBeforeDelete,
    'recoveryRetentionDays': recoveryRetentionDays,
    'onboardingDone': onboardingDone,
    'autoRescanDays': autoRescanDays,
    'watchDownloads': watchDownloads,
    'backgroundCheck': backgroundCheck,
  };

  static T _enum<T extends Enum>(List<T> values, Object? name, T fallback) =>
      values.where((v) => v.name == name).firstOrNull ?? fallback;

  static List<String> _strings(Object? v) => v is List ? v.whereType<String>().toList() : const [];

  factory AppSettings.fromJson(Map<String, Object?> j) {
    const d = AppSettings();
    return AppSettings(
      themeMode: _enum(ThemeMode.values, j['themeMode'], d.themeMode),
      recursive: j['recursive'] as bool? ?? d.recursive,
      maxDepth: j['maxDepth'] as int?,
      includeHidden: j['includeHidden'] as bool? ?? d.includeHidden,
      followSymlinks: j['followSymlinks'] as bool? ?? d.followSymlinks,
      skipSystemFolders: j['skipSystemFolders'] as bool? ?? d.skipSystemFolders,
      skipCloudPlaceholders: j['skipCloudPlaceholders'] as bool? ?? d.skipCloudPlaceholders,
      minSize: j['minSize'] as int? ?? d.minSize,
      maxSize: j['maxSize'] as int?,
      includeExtensions: _strings(j['includeExtensions']),
      excludeExtensions: _strings(j['excludeExtensions']),
      categories: _strings(
        j['categories'],
      ).map((n) => Category.values.where((c) => c.name == n).firstOrNull).nonNulls.toSet(),
      excludePaths: _strings(j['excludePaths']),
      excludeGlobs: j.containsKey('excludeGlobs') ? _strings(j['excludeGlobs']) : d.excludeGlobs,
      hashAlgorithm: _enum(HashAlgo.values, j['hashAlgorithm'], d.hashAlgorithm),
      verifyByteByByte: j['verifyByteByByte'] as bool? ?? d.verifyByteByByte,
      detectFolders: j['detectFolders'] as bool? ?? d.detectFolders,
      detectEmptyFolders: j['detectEmptyFolders'] as bool? ?? d.detectEmptyFolders,
      includeEmptyFiles: j['includeEmptyFiles'] as bool? ?? d.includeEmptyFiles,
      performance: j['performance'] == null
          ? null
          : _enum(PerformanceMode.values, j['performance'], PerformanceMode.balanced),
      useCache: j['useCache'] as bool? ?? d.useCache,
      deleteAction: _enum(ActionType.values, j['deleteAction'], d.deleteAction),
      verifyBeforeDelete: j['verifyBeforeDelete'] as bool? ?? d.verifyBeforeDelete,
      recoveryRetentionDays: j['recoveryRetentionDays'] as int? ?? d.recoveryRetentionDays,
      onboardingDone: j['onboardingDone'] as bool? ?? d.onboardingDone,
      autoRescanDays: j['autoRescanDays'] as int? ?? d.autoRescanDays,
      watchDownloads: j['watchDownloads'] as bool? ?? d.watchDownloads,
      backgroundCheck: j['backgroundCheck'] as bool? ?? d.backgroundCheck,
    );
  }
}

/// Provided by `main()` after `SharedPreferences.getInstance()`.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('override in ProviderScope'),
);

class SettingsController extends Notifier<AppSettings> {
  static const _key = 'settings.v1';

  @override
  AppSettings build() {
    final raw = ref.watch(sharedPreferencesProvider).getString(_key);
    if (raw == null) return const AppSettings();
    try {
      return AppSettings.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } catch (_) {
      return const AppSettings();
    }
  }

  void update(AppSettings Function(AppSettings) change) {
    state = change(state);
    ref.read(sharedPreferencesProvider).setString(_key, jsonEncode(state.toJson()));
  }

  void reset() => update((s) => AppSettings(themeMode: s.themeMode, onboardingDone: s.onboardingDone));
}

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(SettingsController.new);
