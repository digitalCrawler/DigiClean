// End-to-end test through the real Rust engine and generated bindings.
// Run on a desktop or device:  flutter test integration_test -d windows
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:digiclean/src/app.dart';
import 'package:digiclean/src/core/app_paths.dart';
import 'package:digiclean/src/rust/api/maintenance.dart';
import 'package:digiclean/src/rust/api/scanner.dart';
import 'package:digiclean/src/rust/api/types.dart';
import 'package:digiclean/src/rust/frb_generated.dart';
import 'package:digiclean/src/ui/results/group_cards.dart';
import 'package:digiclean/src/state/history.dart';
import 'package:digiclean/src/state/ignore_list.dart';
import 'package:digiclean/src/state/locations.dart';
import 'package:digiclean/src/state/results_controller.dart';
import 'package:digiclean/src/core/background_schedule.dart';
import 'package:digiclean/src/core/photo_library.dart';
import 'package:digiclean/src/state/background_check.dart';
import 'package:digiclean/src/state/settings.dart';
import 'package:digiclean/src/state/upkeep.dart';
import 'package:flutter/material.dart'
    show FilledButton, ScaffoldMessenger, ScaffoldMessengerState, Scrollable, SizedBox;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show AnyhowException;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

ScanOptions options(List<String> roots, {String? cacheDir}) => ScanOptions(
  roots: roots,
  recursive: true,
  followSymlinks: false,
  includeHidden: false,
  skipSystemFolders: true,
  skipCloudPlaceholders: true,
  minSize: 1,
  includeExtensions: const [],
  excludeExtensions: const [],
  categories: const [],
  excludePaths: const [],
  excludeGlobs: const [],
  protectedPaths: const [],
  hashAlgorithm: HashAlgo.blake3,
  verifyByteByByte: false,
  detectDuplicateFolders: true,
  detectEmptyFolders: true,
  includeEmptyFiles: false,
  performance: PerformanceMode.balanced,
  threads: 2,
  cacheDir: cacheDir,
);

/// A photo-like PNG: gradient sky, sun and hills, drawn at any size.
Future<void> writeScene(String path, int seed, int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)..scale(width / 800, height / 600);
  final rnd = Random(seed);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 800, 600),
    ui.Paint()
      ..shader = ui.Gradient.linear(const ui.Offset(0, 0), const ui.Offset(0, 600), [
        ui.Color(0xFF000000 | rnd.nextInt(0xFFFFFF)),
        ui.Color(0xFF000000 | rnd.nextInt(0xFFFFFF)),
      ]),
  );
  for (var i = 0; i < 6; i++) {
    canvas.drawCircle(
      ui.Offset(rnd.nextDouble() * 800, rnd.nextDouble() * 600),
      40 + rnd.nextDouble() * 120,
      ui.Paint()..color = ui.Color(0xFF000000 | rnd.nextInt(0xFFFFFF)),
    );
  }
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(data!.buffer.asUint8List());
}

/// A synthetic song (a melody with harmonics) as a mono 16-bit WAV.
void writeSong(String path, int seed, int rate, double seconds, double gain) {
  final rnd = Random(seed);
  final notes = [for (var i = 0; i <= seconds * 4; i++) 220.0 * pow(2, rnd.nextInt(24) / 12)];
  final n = (seconds * rate).round();
  final data = ByteData(44 + n * 2);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + n * 2, Endian.little);
  ascii(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, n * 2, Endian.little);
  final phase = [0.0, 0.0, 0.0];
  for (var i = 0; i < n; i++) {
    final f = notes[(i / rate * 4).floor()];
    var v = 0.0;
    for (var h = 0; h < 3; h++) {
      phase[h] = (phase[h] + 2 * pi * f * (h + 1) / rate) % (2 * pi);
      v += sin(phase[h]) / (h + 1);
    }
    data.setInt16(44 + i * 2, (v * 9000 * gain).round().clamp(-32768, 32767), Endian.little);
  }
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(data.buffer.asUint8List());
}

void writeRandom(String path, int seed, int length) {
  final rnd = Random(seed);
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(List<int>.generate(length, (_) => rnd.nextInt(256)));
}

/// A photo library for tests: serves prepared previews, records deletions.
class FakePhotoLibrary implements PhotoLibrarySource {
  FakePhotoLibrary(this.photos);

  final List<LibraryPhoto> photos;
  final deleted = <String>[];

  @override
  Future<LibraryAccess> requestAccess() async => LibraryAccess.granted;

  @override
  Future<List<LibraryPhoto>> exportPreviews(String dir) async => photos;

  @override
  Future<int> delete(List<String> ids) async {
    deleted.addAll(ids);
    return ids.length;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async => RustLib.init());

  late Directory root;
  late Directory bin;

  setUp(() {
    root = Directory.systemTemp.createTempSync('digiclean_it_');
    bin = Directory.systemTemp.createTempSync('digiclean_bin_');
    for (final album in ['Photos', 'Backup/Photos copy']) {
      writeRandom(p.join(root.path, album, 'beach.jpg'), 1, 120000);
      writeRandom(p.join(root.path, album, 'trip', 'day1.jpg'), 2, 50000);
    }
    writeRandom(p.join(root.path, 'Downloads', 'beach (1).jpg'), 1, 120000);
    writeRandom(p.join(root.path, 'unique.bin'), 9, 5000);
    writeRandom(p.join(root.path, 'Videos', 'holiday.mp4'), 7, 3 << 20);
    File(p.join(root.path, 'Photos', 'Thumbs.db')).writeAsBytesSync(List.filled(1200, 7));
    Directory(p.join(root.path, 'Empty', 'Nested')).createSync(recursive: true);
  });

  tearDown(() {
    for (final d in [root, bin]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  testWidgets('scan, select, remove to recovery bin and undo', (tester) async {
    final controller = ScanController();
    final events = <ScanEvent>[];
    final done = Completer<void>();
    controller.start(options: options([root.path], cacheDir: p.join(bin.path, 'cache'))).listen((e) {
      events.add(e);
      if (e.kind != ScanEventKind.progress) done.complete();
    });
    await done.future.timeout(const Duration(seconds: 30));

    expect(events.last.kind, ScanEventKind.completed, reason: events.last.error);
    expect(events.where((e) => e.kind == ScanEventKind.progress), isNotEmpty);

    final results = controller.takeResults()!;
    final stats = results.stats();
    expect(stats.duplicateGroups, 2);
    expect(stats.duplicateFiles, 3); // beach.jpg ×3, day1.jpg ×2
    expect(stats.wastedBytes, 2 * 120000 + 50000);
    expect(stats.folderGroups, 1);
    expect(stats.emptyFolders, 1);
    expect(stats.largeFiles, 1);
    expect(stats.junkItems, 1);

    final csv = utf8.decode(await results.exportReport(format: ReportFormat.csv, utcOffsetMin: 0));
    expect(csv.split(RegExp(r'[\r\n]+')).where((r) => r.startsWith('duplicate_file,')), hasLength(5));
    expect(csv, contains('holiday.mp4'));

    final large = await results.largeFiles(
      query: const GroupQuery(offset: 0, limit: 10, sort: SortBy.size, descending: true),
    );
    expect(large.total, 1);
    expect(large.files.single.name, 'holiday.mp4');

    const query = GroupQuery(offset: 0, limit: 50, sort: SortBy.wasted, descending: true);
    final page = await results.fileGroups(query: query);
    expect(page.total, 2);
    final beach = page.groups.first;
    expect(beach.files.length, 3);
    expect(beach.category, Category.image);

    // Keep-one invariant is enforced by the engine.
    results.setFileSelected(fileId: beach.files[0].id, selected: true);
    results.setFileSelected(fileId: beach.files[1].id, selected: true);
    expect(() => results.setFileSelected(fileId: beach.files[2].id, selected: true), throwsA(isA<AnyhowException>()));

    results.clearSelection(kind: ResultKind.files);
    final changed = await results.applyRule(
      kind: ResultKind.files,
      rule: SelectionRuleDto(keep: KeepRule.shallowestPath, preferKeepIn: const [], onlySelectIn: const []),
    );
    expect(changed, 2);
    final summary = results.selectionSummary();
    expect(summary.files, 3);
    expect(summary.fileBytes, 2 * 120000 + 50000);

    final report = await results.executeAction(
      request: const ActionRequestDto(
        action: ActionType.recoveryBin,
        target: ResultKind.files,
        keepStructure: false,
        verifyContent: true,
      ),
      recoveryRoots: [bin.path],
    );
    expect(report.succeeded, 3);
    expect(report.bytesInBin, 2 * 120000 + 50000);
    expect(report.bytesFreed, 0);
    expect(report.failed + report.skipped, 0);
    expect(report.batchId, isNotNull);
    expect(report.affectedPaths.length, 3);
    for (final path in report.affectedPaths) {
      expect(File(path).existsSync(), isFalse);
    }
    expect(results.selectionSummary().activeFileGroups, 0);

    final items = await recoveryList(roots: [bin.path]);
    expect(items.length, 3);

    final restore = await recoveryRestoreBatch(roots: [bin.path], batchId: report.batchId!);
    expect(restore.restored, 3);
    for (final path in report.affectedPaths) {
      expect(File(path).existsSync(), isTrue);
    }
    final after = await results.markRestored(paths: report.affectedPaths);
    expect(after.activeFileGroups, 2);

    // Second scan is served from the hash cache.
    final again = ScanController();
    final second = Completer<void>();
    again.start(options: options([root.path], cacheDir: p.join(bin.path, 'cache'))).listen((e) {
      if (e.kind != ScanEventKind.progress) second.complete();
    });
    await second.future.timeout(const Duration(seconds: 30));
    final rescan = again.takeResults()!;
    expect(rescan.stats().filesFullyHashed, 0);
    expect(rescan.stats().cacheHits, greaterThan(0));

    results.dispose();
    rescan.dispose();
  });

  testWidgets('app starts and shows the scan screen', (tester) async {
    SharedPreferences.setMockInitialValues({'settings.v1': '{"onboardingDone": true}'});
    final prefs = await SharedPreferences.getInstance();
    expect(await AppPaths.resolve(), isNotNull);
    // Isolated storage, so results saved by a real installation are not reopened.
    final paths = AppPaths.forTesting(bin.path);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs), appPathsProvider.overrideWithValue(paths)],
        child: const DigiCleanApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Storage'), findsWidgets);
    expect(find.text('WHERE TO LOOK'), findsOneWidget);
    expect(find.text('Select a folder to scan'), findsOneWidget);

    // Navigate to the other destinations.
    await tester.tap(find.text('Recovery').first);
    await tester.pumpAndSettle();
    expect(find.text('Recovery Bin'), findsWidgets);
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    expect(find.text('APPEARANCE'), findsOneWidget);
    await tester.tap(find.text('Results').first);
    await tester.pumpAndSettle();
    expect(find.text('No results yet'), findsOneWidget);
  });

  testWidgets('UI flow: scan, smart select, remove to recovery bin, undo', (tester) async {
    SharedPreferences.setMockInitialValues({'settings.v1': '{"onboardingDone": true, "deleteAction": "recoveryBin"}'});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        appPathsProvider.overrideWithValue(AppPaths.forTesting(bin.path)),
      ],
    );
    addTearDown(container.dispose);
    container.read(locationsProvider.notifier).add(root.path);

    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const DigiCleanApp()));
    await tester.pumpAndSettle();

    Future<void> waitFor(bool Function() condition, {int seconds = 30}) async {
      final end = DateTime.now().add(Duration(seconds: seconds));
      while (!condition()) {
        if (DateTime.now().isAfter(end)) fail('timed out');
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await tester.pump();
    }

    await tester.tap(find.text('Scan 1 location'));
    await waitFor(() => container.read(resultsProvider).hasResults);
    await tester.pumpAndSettle();

    // Shell switched to the results tab automatically.
    expect(find.text('Files (2)'), findsOneWidget);
    expect(find.text('Folders (1)'), findsOneWidget);
    expect(find.text('Large files (1)'), findsOneWidget);
    expect(find.text('Junk (1)'), findsOneWidget);
    expect(find.text('Empty folders (1)'), findsOneWidget);
    expect(find.text('beach.jpg'), findsWidgets);

    await tester.tap(find.text('Smart select'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await waitFor(() => find.text('3 selected').evaluate().isNotEmpty);

    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Move to Recovery Bin?'), findsOneWidget);
    await tester.tap(find.text('Move to bin'));
    await waitFor(() => find.textContaining('to the Recovery Bin').evaluate().isNotEmpty);

    final remaining = Directory(
      root.path,
    ).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.jpg')).length;
    expect(remaining, 2, reason: 'one copy of each duplicate group is kept');
    final cleanup = container.read(historyProvider).single;
    expect(cleanup.bytesInBin, 2 * 120000 + 50000);
    expect(cleanup.bytesFreed, 0, reason: 'nothing is freed until the bin is emptied');
    expect(find.text('No duplicate files left'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await waitFor(() => find.textContaining('Restored').evaluate().isNotEmpty);
    final restored = Directory(
      root.path,
    ).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.jpg')).length;
    expect(restored, 5);
    await tester.pumpAndSettle();
    expect(find.text('Files (2)'), findsOneWidget);

    // Large files are listed on their own tab, without Smart select.
    await tester.tap(find.text('Large files (1)'));
    await tester.pumpAndSettle();
    expect(find.text('holiday.mp4'), findsOneWidget);
    expect(find.text('Smart select'), findsNothing);

    // Junk: "Select safe" picks the system cache only.
    await tester.tap(find.text('Junk (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Thumbs.db'), findsOneWidget);
    // A snackbar from the previous step may cover the bar.
    tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first).clearSnackBars();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select safe'));
    await waitFor(() => find.text('1 selected').evaluate().isNotEmpty);
  });

  testWidgets('UI flow: "not duplicates" and ignored folders stay hidden', (tester) async {
    SharedPreferences.setMockInitialValues({'settings.v1': '{"onboardingDone": true}'});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        appPathsProvider.overrideWithValue(AppPaths.forTesting(bin.path)),
      ],
    );
    addTearDown(container.dispose);
    container.read(locationsProvider.notifier).add(root.path);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const DigiCleanApp()));
    await tester.pumpAndSettle();

    Future<void> waitFor(bool Function() condition) async {
      final end = DateTime.now().add(const Duration(seconds: 30));
      while (!condition()) {
        if (DateTime.now().isAfter(end)) fail('timed out');
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
    }

    Future<void> scan() async {
      final before = container.read(resultsProvider).finishedAt;
      await tester.tap(find.text('Storage').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Scan 1 location'));
      await waitFor(() => container.read(resultsProvider).finishedAt != before);
    }

    Future<void> openCopyMenu() async {
      await tester.tap(find.descendant(of: find.byType(FileGroupCard).first, matching: find.byTooltip('More')).first);
      await tester.pumpAndSettle();
    }

    await scan();
    expect(find.text('Files (2)'), findsOneWidget);

    // beach.jpg (largest group, listed first): not duplicates.
    await openCopyMenu();
    await tester.tap(find.text('Not duplicates'));
    await tester.pumpAndSettle();
    expect(find.text('Files (1)'), findsOneWidget);
    expect(container.read(ignoreListProvider).single.name, 'beach.jpg');

    // day1.jpg: ignore the folder of its first copy.
    await openCopyMenu();
    await tester.tap(find.textContaining('Ignore “trip”'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ignore folder'));
    await waitFor(() => find.text('Files (0)').evaluate().isNotEmpty);
    expect(find.text('Folders (0)'), findsOneWidget, reason: 'Photos no longer matches its copy');
    expect(container.read(settingsProvider).excludePaths, hasLength(1));

    // Both stay hidden in a new scan.
    await scan();
    expect(find.text('Files (0)'), findsOneWidget);

    // Showing the group again from Settings brings it straight back.
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not duplicates'));
    await tester.pumpAndSettle();
    expect(find.text('beach.jpg'), findsOneWidget);
    await tester.tap(find.byTooltip('Show again'));
    await tester.pumpAndSettle();
    expect(container.read(ignoreListProvider), isEmpty);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Results').first);
    await tester.pumpAndSettle();
    expect(find.text('Files (1)'), findsOneWidget);
  });

  testWidgets('results are saved and reopened after a restart', (tester) async {
    SharedPreferences.setMockInitialValues({'settings.v1': '{"onboardingDone": true}'});
    final prefs = await SharedPreferences.getInstance();
    ProviderContainer open() => ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        appPathsProvider.overrideWithValue(AppPaths.forTesting(bin.path)),
      ],
    );
    Future<void> waitFor(bool Function() condition) async {
      final end = DateTime.now().add(const Duration(seconds: 30));
      while (!condition()) {
        if (DateTime.now().isAfter(end)) fail('timed out');
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
    }

    var container = open();
    container.read(locationsProvider.notifier).add(root.path);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const DigiCleanApp()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scan 1 location'));
    await waitFor(() => container.read(resultsProvider).hasResults);
    await tester.tap(find.text('Smart select'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await waitFor(() => find.text('3 selected').evaluate().isNotEmpty);
    // What the app does when it is hidden or closed.
    await container.read(resultsProvider.notifier).save();
    expect(File(AppPaths.forTesting(bin.path).snapshotPath).existsSync(), isTrue);

    // "Restart": a new app on the same storage reopens the results.
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    container = open();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const DigiCleanApp()));
    await waitFor(() => container.read(resultsProvider).hasResults);
    final state = container.read(resultsProvider);
    expect(state.restored, isTrue);
    expect(state.summary!.files, 3, reason: 'the selection is kept');
    await tester.tap(find.text('Results').first);
    await tester.pumpAndSettle();
    expect(find.text('Files (2)'), findsOneWidget);
    expect(find.textContaining('Saved results from'), findsOneWidget);
    expect(find.text('3 selected'), findsOneWidget);
  });

  testWidgets('storage overview: recommendations, space map and old files', (tester) async {
    SharedPreferences.setMockInitialValues({'settings.v1': '{"onboardingDone": true, "deleteAction": "recoveryBin"}'});
    final prefs = await SharedPreferences.getInstance();
    // The scanned folder's "Downloads" stands in for the user's downloads.
    final paths = AppPaths.forTesting(bin.path, downloads: [p.join(root.path, 'Downloads')]);
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs), appPathsProvider.overrideWithValue(paths)],
    );
    addTearDown(container.dispose);
    container.read(locationsProvider.notifier).add(root.path);
    final old = File(p.join(root.path, 'Downloads', 'setup-2019.exe'))..writeAsBytesSync(List.filled(4000, 1));
    old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 800)));
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const DigiCleanApp()));
    await tester.pumpAndSettle();

    Future<void> waitFor(bool Function() condition) async {
      final end = DateTime.now().add(const Duration(seconds: 30));
      while (!condition()) {
        if (DateTime.now().isAfter(end)) fail('timed out');
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
    }

    await tester.tap(find.text('Scan 1 location'));
    await waitFor(() => container.read(resultsProvider).hasResults);

    // The dashboard summarises the scan.
    await tester.tap(find.text('Storage').first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('LAST SCAN'), 200, scrollable: find.byType(Scrollable).first);
    await tester.scrollUntilVisible(
      find.text('WHAT USES SPACE IN THE SCANNED FOLDERS'),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    // Space map: the scanned folder opens on its sub-folders.
    await tester.ensureVisible(find.text('Space map'));
    await tester.tap(find.text('Space map'));
    await waitFor(() => find.text('Photos').evaluate().isNotEmpty);
    expect(find.text('Videos'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Recommended cleanup: the duplicate in Downloads and the thumbnail cache.
    await tester.ensureVisible(find.text('Recommended cleanup'));
    await tester.tap(find.text('Recommended cleanup'));
    await waitFor(() => find.text('Duplicate downloads').evaluate().isNotEmpty);
    expect(find.text('Thumbnail caches'), findsOneWidget);
    expect(find.text('Empty folders'), findsOneWidget);
    await tester.tap(find.textContaining(RegExp(r'^Clean up ')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clean up'));
    await waitFor(() => container.read(historyProvider).length == 3);
    expect(File(p.join(root.path, 'Downloads', 'beach (1).jpg')).existsSync(), isFalse);
    expect(File(p.join(root.path, 'Photos', 'beach.jpg')).existsSync(), isTrue);
    expect(File(p.join(root.path, 'Photos', 'Thumbs.db')).existsSync(), isFalse);
    expect(Directory(p.join(root.path, 'Empty')).existsSync(), isFalse);

    // Old files: the dashboard opens the list; the old installer is in it.
    await tester.ensureVisible(find.text('Old files'));
    await tester.tap(find.text('Old files'));
    await waitFor(() => find.text('setup-2019.exe').evaluate().isNotEmpty);
    await tester.tap(find.text('Installers'));
    await tester.pumpAndSettle();
    expect(find.text('setup-2019.exe'), findsOneWidget);
  });

  testWidgets('photos: similar shots keep the best, screenshots are listed', (tester) async {
    final photos = Directory.systemTemp.createTempSync('digiclean_photos_');
    addTearDown(() => photos.deleteSync(recursive: true));
    await tester.runAsync(() async {
      await writeScene(p.join(photos.path, 'Camera', 'IMG_0001.png'), 1, 1200, 900);
      await writeScene(p.join(photos.path, 'WhatsApp', 'IMG-WA0001.png'), 1, 480, 360);
      await writeScene(p.join(photos.path, 'Camera', 'IMG_0002.png'), 2, 1200, 900);
      await writeScene(p.join(photos.path, 'Pictures', 'Screenshot 2024-05-01.png'), 3, 600, 1200);
    });
    writeSong(p.join(photos.path, 'Music', 'Song.wav'), 5, 44100, 20, 1.0);
    writeSong(p.join(photos.path, 'Phone', 'Song (low).wav'), 5, 22050, 20, 0.6);
    writeSong(p.join(photos.path, 'Music', 'Other.wav'), 6, 44100, 20, 1.0);
    SharedPreferences.setMockInitialValues({'settings.v1': '{"onboardingDone": true, "deleteAction": "recoveryBin"}'});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        appPathsProvider.overrideWithValue(AppPaths.forTesting(bin.path)),
      ],
    );
    addTearDown(container.dispose);
    container.read(locationsProvider.notifier).add(photos.path);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const DigiCleanApp()));
    await tester.pumpAndSettle();

    Future<void> waitFor(bool Function() condition) async {
      final end = DateTime.now().add(const Duration(seconds: 60));
      while (!condition()) {
        if (DateTime.now().isAfter(end)) fail('timed out');
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
    }

    await tester.tap(find.text('Scan 1 location'));
    await waitFor(() => container.read(resultsProvider).hasResults);
    await tester.tap(find.text('Media'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Analyse media'));
    await waitFor(() => container.read(resultsProvider).summary?.mediaAnalyzed ?? false);
    expect(container.read(resultsProvider).summary!.similarGroups, 1);
    expect(container.read(resultsProvider).summary!.mediaGroups, 1);
    expect(find.textContaining('2 similar photos'), findsOneWidget);
    expect(find.text('BEST'), findsOneWidget);

    tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first).clearSnackBars();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep best'));
    await waitFor(() => find.text('1 selected').evaluate().isNotEmpty);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to bin'));
    await waitFor(() => !File(p.join(photos.path, 'WhatsApp', 'IMG-WA0001.png')).existsSync());
    expect(File(p.join(photos.path, 'Camera', 'IMG_0001.png')).existsSync(), isTrue, reason: 'the best is kept');

    await tester.tap(find.text('To review'));
    await tester.pumpAndSettle();
    expect(find.text('Screenshot 2024-05-01.png'), findsOneWidget);

    // The same song in two qualities: keep the bigger one.
    await tester.tap(find.text('Music & video'));
    await tester.pumpAndSettle();
    expect(find.text('2 copies of the same song'), findsOneWidget);
    tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first).clearSnackBars();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep best'));
    await waitFor(() => find.text('1 selected').evaluate().isNotEmpty);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to bin'));
    await waitFor(() => !File(p.join(photos.path, 'Phone', 'Song (low).wav')).existsSync());
    expect(File(p.join(photos.path, 'Music', 'Song.wav')).existsSync(), isTrue);
    expect(File(p.join(photos.path, 'Music', 'Other.wav')).existsSync(), isTrue);
  });

  testWidgets('keep it clean: new duplicate downloads and scheduled rescans', (tester) async {
    final downloads = Directory.systemTemp.createTempSync('digiclean_dl_');
    addTearDown(() => downloads.deleteSync(recursive: true));
    SharedPreferences.setMockInitialValues({
      'settings.v1': '{"onboardingDone": true, "deleteAction": "recoveryBin", "autoRescanDays": 7}',
    });
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        appPathsProvider.overrideWithValue(AppPaths.forTesting(bin.path, downloads: [downloads.path])),
      ],
    );
    addTearDown(container.dispose);
    container.read(locationsProvider.notifier).add(root.path);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const DigiCleanApp()));
    await tester.pumpAndSettle();

    Future<void> waitFor(bool Function() condition) async {
      final end = DateTime.now().add(const Duration(seconds: 30));
      while (!condition()) {
        if (DateTime.now().isAfter(end)) fail('timed out');
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
    }

    // No results yet: the schedule starts the first scan when the app opens.
    final upkeep = container.read(upkeepProvider.notifier);
    await waitFor(() => container.read(resultsProvider).hasResults);
    final firstScan = container.read(resultsProvider).finishedAt!;
    expect(await upkeep.rescanIfDue(), isFalse, reason: 'the scan is fresh');

    // A download that copies a kept photo is pointed out on the dashboard.
    await Future<void>.delayed(const Duration(milliseconds: 1100)); // newer mtime than the scan
    writeRandom(p.join(downloads.path, 'beach (2).jpg'), 1, 120000);
    writeRandom(p.join(downloads.path, 'notes.bin'), 77, 120000);
    await upkeep.checkDownloads();
    expect(container.read(upkeepProvider).newCopies.single.path, endsWith('beach (2).jpg'));
    await tester.tap(find.text('Storage').first);
    await tester.pumpAndSettle();
    expect(find.text('1 new download you already have'), findsOneWidget);
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove downloads'));
    await waitFor(() => container.read(upkeepProvider).newCopies.isEmpty);
    expect(File(p.join(downloads.path, 'beach (2).jpg')).existsSync(), isFalse);
    expect(File(p.join(downloads.path, 'notes.bin')).existsSync(), isTrue);
    expect(find.text('1 new download you already have'), findsNothing);

    // A week later the schedule rescans.
    expect(await upkeep.rescanIfDue(now: DateTime.now().add(const Duration(days: 8))), isTrue);
    await waitFor(() => container.read(resultsProvider).finishedAt != firstScan);
  });

  testWidgets('background check: Task Scheduler runs the checker and the app reopens its results', (tester) async {
    // Built with `cargo build -p digiclean-cli --bin digiclean-check`.
    final checker = p.join(Directory.current.path, 'target', 'debug', 'digiclean-check.exe');
    if (!Platform.isWindows || !File(checker).existsSync()) {
      markTestSkipped('needs Windows and a built digiclean-check');
      return;
    }
    SharedPreferences.setMockInitialValues({'settings.v1': '{"onboardingDone": true}'});
    final prefs = await SharedPreferences.getInstance();
    final paths = AppPaths.forTesting(bin.path);
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs), appPathsProvider.overrideWithValue(paths)],
    );
    addTearDown(container.dispose);
    container.read(locationsProvider.notifier).add(root.path);

    final job = await container.read(backgroundCheckProvider).writeJob();
    expect(job, isNotNull);
    final schedule = BackgroundSchedule(windowsTaskName: r'DigiClean\Integration test check');
    addTearDown(schedule.disable);
    await schedule.enable(checker: checker, job: job!);
    expect(await schedule.isEnabled(), isTrue);

    // Run it now instead of waiting for 13:00.
    final run = await Process.run('schtasks', ['/Run', '/TN', schedule.windowsTaskName]);
    expect(run.exitCode, 0, reason: '${run.stderr}');
    final result = File(backgroundResultPath(paths));
    final end = DateTime.now().add(const Duration(seconds: 60));
    while (!result.existsSync()) {
      if (DateTime.now().isAfter(end)) fail('the scheduled check did not write its result');
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final summary = jsonDecode(result.readAsStringSync()) as Map<String, Object?>;
    expect(summary['duplicate_groups'], 2);
    expect(File(paths.snapshotPath).existsSync(), isTrue);

    // The app opens on the results the background check saved.
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const DigiCleanApp()));
    final opened = DateTime.now().add(const Duration(seconds: 30));
    while (!container.read(resultsProvider).hasResults) {
      if (DateTime.now().isAfter(opened)) fail('results not reopened');
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(container.read(resultsProvider).summary!.activeFileGroups, 2);

    await schedule.disable();
    expect(await schedule.isEnabled(), isFalse);
  });

  testWidgets('photo library (iOS flow): similar shots keep the best, the rest are deleted', (tester) async {
    final previews = Directory.systemTemp.createTempSync('digiclean_library_');
    addTearDown(() => previews.deleteSync(recursive: true));
    await tester.runAsync(() async {
      await writeScene(p.join(previews.path, 'a.png'), 1, 512, 384);
      await writeScene(p.join(previews.path, 'b.png'), 1, 512, 384);
      await writeScene(p.join(previews.path, 'c.png'), 2, 512, 384);
      await writeScene(p.join(previews.path, 'd.png'), 3, 236, 512);
    });
    LibraryPhoto photo(String id, String file, int w, int h, {bool screenshot = false}) => LibraryPhoto(
      id: id,
      preview: p.join(previews.path, file),
      width: w,
      height: h,
      createdMs: 0,
      screenshot: screenshot,
    );
    final library = FakePhotoLibrary([
      photo('IMG_1', 'a.png', 4032, 3024), // the original
      photo('IMG_1_saved', 'b.png', 1280, 960), // a smaller saved copy
      photo('IMG_2', 'c.png', 4032, 3024),
      photo('SCREEN_1', 'd.png', 1170, 2532, screenshot: true),
    ]);
    SharedPreferences.setMockInitialValues({'settings.v1': '{"onboardingDone": true}'});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        appPathsProvider.overrideWithValue(AppPaths.forTesting(bin.path)),
        photoLibrarySourceProvider.overrideWithValue(library),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const DigiCleanApp()));
    await tester.pumpAndSettle();

    Future<void> waitFor(bool Function() condition) async {
      final end = DateTime.now().add(const Duration(seconds: 30));
      while (!condition()) {
        if (DateTime.now().isAfter(end)) fail('timed out');
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
    }

    await tester.scrollUntilVisible(find.text('Photos library'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Photos library'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Analyse my photos'));
    await waitFor(() => find.text('Similar (1)').evaluate().isNotEmpty);
    expect(find.text('2 similar photos'), findsOneWidget);
    expect(find.text('To review (1)'), findsOneWidget);

    await tester.tap(find.text('Keep best'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete 1 photo'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await waitFor(() => library.deleted.isNotEmpty);
    expect(library.deleted, ['IMG_1_saved'], reason: 'the larger original is kept');
    expect(find.text('Similar (0)'), findsOneWidget);

    await tester.tap(find.text('To review (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Screenshot'), findsOneWidget);
  });
}
