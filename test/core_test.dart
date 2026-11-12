import 'package:digiclean/src/core/format.dart';
import 'package:digiclean/src/rust/api/types.dart';
import 'package:digiclean/src/state/paged_list.dart';
import 'package:digiclean/src/state/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('format', () {
    test('bytes', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1023), '1023 B');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(150 << 20), '150 MB');
      expect(formatBytes(3 * (1 << 30) + (1 << 29)), '3.5 GB');
    });

    test('parseSize', () {
      expect(parseSize('10'), 10);
      expect(parseSize('1k'), 1024);
      expect(parseSize('1.5 MB'), (1.5 * (1 << 20)).round());
      expect(parseSize('2G'), 2 << 30);
      expect(parseSize('abc'), isNull);
      expect(parseSize(''), isNull);
    });

    test('duration', () {
      expect(formatDuration(const Duration(milliseconds: 250)), '250 ms');
      expect(formatDuration(const Duration(seconds: 42)), '42s');
      expect(formatDuration(const Duration(minutes: 3, seconds: 5)), '3m 05s');
      expect(formatDuration(const Duration(hours: 1, minutes: 2)), '1h 02m');
    });

    test('middleEllipsis keeps both ends', () {
      final s = middleEllipsis('/storage/emulated/0/DCIM/Camera/IMG_20240101_123456.jpg', 30);
      expect(s.length, 30);
      expect(s, startsWith('/storage'));
      expect(s, endsWith('123456.jpg'));
    });

    test('plural', () {
      expect(plural(1, 'file'), '1 file');
      expect(plural(2, 'file'), '2 files');
      expect(plural(3, 'copy', 'copies'), '3 copies');
    });
  });

  group('settings', () {
    test('JSON round trip preserves every field', () {
      const s = AppSettings(
        themeMode: ThemeMode.dark,
        recursive: false,
        maxDepth: 4,
        includeHidden: true,
        minSize: 4096,
        maxSize: 1 << 30,
        includeExtensions: ['jpg', 'png'],
        categories: {Category.image, Category.video},
        excludePaths: ['/tmp'],
        excludeGlobs: ['**/cache'],
        hashAlgorithm: HashAlgo.sha256,
        verifyByteByByte: true,
        performance: PerformanceMode.batterySaver,
        deleteAction: ActionType.recoveryBin,
        recoveryRetentionDays: 7,
        onboardingDone: true,
      );
      final r = AppSettings.fromJson(s.toJson());
      expect(r.themeMode, s.themeMode);
      expect(r.recursive, s.recursive);
      expect(r.maxDepth, s.maxDepth);
      expect(r.includeHidden, s.includeHidden);
      expect(r.minSize, s.minSize);
      expect(r.maxSize, s.maxSize);
      expect(r.includeExtensions, s.includeExtensions);
      expect(r.categories, s.categories);
      expect(r.excludePaths, s.excludePaths);
      expect(r.excludeGlobs, s.excludeGlobs);
      expect(r.hashAlgorithm, s.hashAlgorithm);
      expect(r.verifyByteByByte, s.verifyByteByByte);
      expect(r.performance, s.performance);
      expect(r.deleteAction, s.deleteAction);
      expect(r.recoveryRetentionDays, s.recoveryRetentionDays);
      expect(r.onboardingDone, isTrue);
    });

    test('unknown or missing values fall back to defaults', () {
      final r = AppSettings.fromJson({
        'hashAlgorithm': 'md5',
        'categories': ['nope', 'image'],
      });
      expect(r.hashAlgorithm, HashAlgo.blake3);
      expect(r.categories, {Category.image});
      expect(r.excludeGlobs, const AppSettings().excludeGlobs);
      expect(r.performance, isNull);
    });

    test('copyWith can clear nullable fields', () {
      const s = AppSettings(maxDepth: 3, maxSize: 10);
      final r = s.copyWith(maxDepth: () => null, maxSize: () => null);
      expect(r.maxDepth, isNull);
      expect(r.maxSize, isNull);
    });

    test('filter count', () {
      expect(const AppSettings().activeFilterCount, 0);
      expect(const AppSettings(minSize: 1024, categories: {Category.audio}).activeFilterCount, 2);
    });
  });

  group('PagedList', () {
    test('loads pages lazily and resets', () async {
      var calls = 0;
      final list = PagedList<int>((offset, limit) async {
        calls++;
        return (95, [for (var i = offset; i < (offset + limit).clamp(0, 95); i++) i]);
      }, pageSize: 40);

      expect(list.itemAt(0), isNull);
      await Future<void>.delayed(Duration.zero);
      expect(list.total, 95);
      expect(list.itemAt(39), 39);
      expect(list.itemAt(41), isNull); // page 2 starts loading
      await Future<void>.delayed(Duration.zero);
      expect(list.itemAt(41), 41);
      expect(list.itemAt(94), isNull);
      await Future<void>.delayed(Duration.zero);
      expect(list.itemAt(94), 94);
      expect(calls, 3);

      list.replaceWhere((x) => x == 41, (_) => -41);
      expect(list.itemAt(41), -41);

      await list.reset();
      expect(calls, 4);
      expect(list.itemAt(0), 0);
      expect(list.itemAt(41), isNull, reason: 'cached pages are dropped on reset');
    });

    test('stale responses after reset are ignored', () async {
      var generation = 0;
      final list = PagedList<int>((offset, limit) async {
        final g = generation;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return (1, [g]);
      });
      list.itemAt(0);
      generation = 1;
      await list.reset();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(list.itemAt(0), 1);
    });
  });
}
