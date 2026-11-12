// Renders key screens (desktop, phone, dark) to PNG for visual review.
// Not part of the suite (no _test suffix); skipped unless an output folder is given:
//   flutter test integration_test/screenshots.dart -d windows --dart-define=SHOTS=<dir>
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:digiclean/src/app.dart';
import 'package:digiclean/src/core/app_paths.dart';
import 'package:digiclean/src/rust/frb_generated.dart';
import 'package:digiclean/src/state/locations.dart';
import 'package:digiclean/src/state/results_controller.dart';
import 'package:digiclean/src/state/settings.dart';
import 'package:digiclean/src/ui/results/group_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

const shots = String.fromEnvironment('SHOTS');

/// Example cleanups for the history screen (relative to now).
final sampleHistory = () {
  final now = DateTime.now().millisecondsSinceEpoch;
  const day = 86400000;
  return [
    {'kind': 'systemTrash', 'at': now - 3600000, 'items': 575, 'freed': 1071644672},
    {'kind': 'cleanup', 'at': now - day, 'items': 12, 'action': 'trash', 'inBin': 3460300, 'systemTrash': true},
    {'kind': 'cleanup', 'at': now - 2 * day, 'items': 4, 'action': 'deletePermanently', 'freed': 734003200},
    {'kind': 'recoveryBin', 'at': now - 9 * day, 'items': 0, 'freed': 52428800},
    {'kind': 'cleanup', 'at': now - 12 * day, 'items': 30, 'action': 'moveTo', 'moved': 2147483648},
  ];
}();

Future<List<int>> pngImage(Color color, int seed) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final rnd = Random(seed);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 320, 240), Paint()..color = color);
  for (var i = 0; i < 12; i++) {
    canvas.drawCircle(
      Offset(rnd.nextDouble() * 320, rnd.nextDouble() * 240),
      10 + rnd.nextDouble() * 40,
      Paint()..color = Colors.white.withValues(alpha: 0.35),
    );
  }
  final image = await recorder.endRecording().toImage(320, 240);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// A photo-like PNG (sky gradient, sun, hills) at any size.
Future<List<int>> pngScene(int seed, int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(width / 800, height / 600);
  final rnd = Random(seed);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 800, 600),
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, const Offset(0, 600), [
        Color(0xFF000000 | rnd.nextInt(0xFFFFFF)),
        Color(0xFF000000 | rnd.nextInt(0xFFFFFF)),
      ]),
  );
  for (var i = 0; i < 6; i++) {
    canvas.drawCircle(
      Offset(rnd.nextDouble() * 800, rnd.nextDouble() * 600),
      40 + rnd.nextDouble() * 120,
      Paint()..color = Color(0xFF000000 | rnd.nextInt(0xFFFFFF)),
    );
  }
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// A synthetic song (melody with harmonics) as a mono 16-bit WAV.
void writeSong(String path, int seed, int rate, double seconds, double gain) {
  final rnd = Random(seed);
  final notes = [for (var i = 0; i <= seconds * 4; i++) 220.0 * pow(2, rnd.nextInt(24) / 12)];
  final n = (seconds * rate).round();
  final data = ByteData(44 + n * 2);
  void ascii(int at, String text) {
    for (var i = 0; i < text.length; i++) {
      data.setUint8(at + i, text.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + n * 2, Endian.little);
  ascii(8, 'WAVEfmt ');
  data
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, rate, Endian.little)
    ..setUint32(28, rate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  testWidgets('screenshots', skip: shots.isEmpty, (tester) async {
    final base = Directory.systemTemp.createTempSync('dc_shots_');
    final root = p.join(base.path, 'Users', 'Mehtab', 'Pictures');
    final colors = [Colors.teal, Colors.orange, Colors.indigo, Colors.pink, Colors.green, Colors.brown];
    final places = [
      'Camera Roll/2024/Summer Trip to the Mountains',
      'Backup/Phone backup 2024-06/DCIM/Camera',
      'WhatsApp Images/Sent',
    ];
    for (var i = 0; i < colors.length; i++) {
      final bytes = await pngImage(colors[i], i);
      for (var j = 0; j < (i % 2 == 0 ? 3 : 2); j++) {
        final f = File(p.join(root, places[j], j == 2 ? 'IMG-20240614-WA00$i.png' : 'IMG_20240614_10152$i.png'));
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(bytes);
      }
    }
    final rnd = Random(3);
    for (var i = 0; i < 4; i++) {
      final data = List<int>.generate(200000 + i * 150000, (_) => rnd.nextInt(256));
      for (final dir in ['Documents/Invoices', 'Downloads', 'Desktop/Old stuff to sort']) {
        final f = File(p.join(root, dir, 'Quarterly report Q$i final (2).pdf'));
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(data);
        if (dir == 'Documents/Invoices') f.setLastModifiedSync(DateTime.now().subtract(Duration(days: 700 + i * 90)));
      }
    }
    Directory(p.join(root, 'Empty folder', 'Nested')).createSync(recursive: true);
    writeSong(p.join(root, 'Music', 'Summer Nights.wav'), 8, 44100, 24, 1.0);
    writeSong(p.join(root, 'WhatsApp Audio', 'AUD-20240615-WA0003.wav'), 8, 22050, 24, 0.7);
    // Similar photos: originals, a burst shot and resized messaging copies.
    for (final (name, seed, w, h) in [
      ('Camera Roll/2024/Summer Trip to the Mountains/IMG_20240615_183001.png', 21, 1600, 1200),
      ('WhatsApp Images/Sent/IMG-20240615-WA0007.png', 21, 640, 480),
      ('Camera Roll/2024/IMG_20240702_090512.png', 34, 1600, 1200),
      ('Backup/Phone backup 2024-06/DCIM/Camera/IMG_20240702_090512 (small).png', 34, 800, 600),
      ('Screenshots/Screenshot 2024-06-14 101530.png', 55, 720, 1440),
    ]) {
      File(p.join(root, name))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(await pngScene(seed, w, h));
    }
    final threeDaysAgo = DateTime.now().subtract(const Duration(days: 3));
    for (final (name, bytes, old) in [
      ('Camera Roll/2024/Thumbs.db', 48 << 10, false),
      ('Downloads/ubuntu-24.04-desktop-amd64.iso.crdownload', 3 << 20, true),
      ('Documents/Invoices/~\$Invoice March.docx', 162, true),
      ('Desktop/Old stuff to sort/notes.txt', 0, false),
    ]) {
      final f = File(p.join(root, name))..parent.createSync(recursive: true);
      f.writeAsBytesSync(Uint8List(bytes));
      if (old) f.setLastModifiedSync(threeDaysAgo);
    }
    for (final (name, mb) in [
      ('Videos/Family/Birthday 2023.mp4', 14),
      ('Downloads/ubuntu-24.04-desktop-amd64.iso', 9),
      ('Camera Roll/2024/Summer Trip to the Mountains/VID_20240614_101530.mp4', 6),
      ('Documents/Scans/Tax return 2023.pdf', 2),
    ]) {
      File(p.join(root, name))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(Uint8List(mb << 20)..[0] = mb);
    }

    Future<void> capture(String name, GlobalKey key) async {
      await tester.pump();
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(p.join(shots, '$name.png'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(bytes!.buffer.asUint8List());
    }

    // Scrolls the visible page until [target] is on screen.
    Future<void> reveal(Finder target) async {
      await tester.scrollUntilVisible(target, 150, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
    }

    Future<void> waitFor(bool Function() c) async {
      final end = DateTime.now().add(const Duration(seconds: 30));
      while (!c()) {
        if (DateTime.now().isAfter(end)) fail('timeout');
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    }

    for (final (label, size, dark) in [
      ('desktop', const Size(1280, 820), false),
      ('phone', const Size(400, 860), false),
      ('phone_dark', const Size(400, 860), true),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      SharedPreferences.setMockInitialValues({
        'settings.v1': '{"onboardingDone": true, "themeMode": "${dark ? 'dark' : 'light'}"}',
        'history.v1': jsonEncode(sampleHistory),
      });
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          appPathsProvider.overrideWithValue(
            AppPaths.forTesting(p.join(base.path, 'app-$label'), downloads: [p.join(root, 'Downloads')]),
          ),
        ],
      );
      container.read(locationsProvider.notifier).add(root);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: UncontrolledProviderScope(container: container, child: const DigiCleanApp()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Scan 1 location'));
      await waitFor(() => container.read(resultsProvider).hasResults);
      await capture('${label}_1_results', key);

      await tester.tap(find.byTooltip('Compare copies').first);
      await waitFor(() => true);
      await capture('${label}_2_compare', key);
      if (label != 'desktop') {
        await tester.pageBack();
        await waitFor(() => true);
      }
      await tester.tap(find.text('Smart select'));
      await tester.pumpAndSettle();
      await capture('${label}_3_sheet', key);
      await tester.tap(find.text('Apply'));
      await waitFor(() => find.textContaining(' selected').evaluate().isNotEmpty);
      await capture('${label}_4_selected', key);
      await tester.tap(find.textContaining('Folders ('));
      await waitFor(() => true);
      await capture('${label}_5_folders', key);
      await tester.ensureVisible(find.textContaining(RegExp(r'^Large')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining(RegExp(r'^Large')));
      await waitFor(() => find.byType(Checkbox).evaluate().isNotEmpty);
      await tester.tap(find.byType(Checkbox).first);
      await waitFor(() => find.text('1 selected').evaluate().isNotEmpty);
      await capture('${label}_6_large', key);
      await tester.tap(find.text('Recovery').last);
      await waitFor(() => true);
      await capture('${label}_7_recovery', key);
      await tester.tap(find.text('Results').last);
      await waitFor(() => true);
      await tester.ensureVisible(find.textContaining(RegExp(r'^Files \(')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining(RegExp(r'^Files \(')));
      await waitFor(() => true);
      await tester.tap(find.descendant(of: find.byType(FileGroupCard).first, matching: find.byTooltip('More')).first);
      await waitFor(() => true);
      await capture('${label}_8_menu', key);
      await tester.tap(find.text('Not duplicates'));
      await waitFor(() => true);
      await tester.tap(find.text('Settings').last);
      await waitFor(() => true);
      await tester.ensureVisible(find.text('Not duplicates'));
      await tester.tap(find.text('Not duplicates'));
      await waitFor(() => true);
      await capture('${label}_9_ignored', key);
      await tester.pageBack();
      await waitFor(() => true);
      tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first).clearSnackBars();
      await reveal(find.text('Cleanup history'));
      await tester.tap(find.text('Cleanup history'));
      await waitFor(() => true);
      await capture('${label}_10_history', key);
      await tester.pageBack();
      await waitFor(() => true);
      await tester.tap(find.text('Results').last);
      await waitFor(() => true);
      await tester.ensureVisible(find.textContaining(RegExp(r'^Junk \(')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining(RegExp(r'^Junk \(')));
      await waitFor(() => true);
      // A snackbar from the previous step may cover the bar.
      tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first).clearSnackBars();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select safe'));
      await waitFor(() => find.text('1 selected').evaluate().isNotEmpty);
      await capture('${label}_11_junk', key);
      // Photos.
      await tester.ensureVisible(find.text('Media'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Media'));
      await waitFor(() => find.text('Analyse media').evaluate().isNotEmpty);
      await capture('${label}_16_photos_start', key);
      await tester.tap(find.text('Analyse media'));
      await waitFor(() => find.text('Keep best').evaluate().isNotEmpty);
      tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first).clearSnackBars();
      await waitFor(() => true);
      await capture('${label}_17_similar', key);
      await tester.tap(find.text('To review'));
      await waitFor(() => find.textContaining('Screenshot 2024').evaluate().isNotEmpty);
      await capture('${label}_18_review', key);
      await tester.tap(find.text('Music & video'));
      await waitFor(() => find.text('2 copies of the same song').evaluate().isNotEmpty);
      await capture('${label}_19_music', key);
      tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first).clearSnackBars();
      await waitFor(() => true);
      await tester.tap(find.text('Settings').last);
      await waitFor(() => true);
      // The page keeps its scroll position from the earlier visit.
      await tester.fling(find.byType(ListView).first, const Offset(0, 4000), 4000);
      await waitFor(() => true);
      await tester.dragUntilVisible(find.text('KEEP IT CLEAN'), find.byType(ListView).first, const Offset(0, -200));
      await tester.ensureVisible(find.text('KEEP IT CLEAN'));
      await waitFor(() => true);
      await capture('${label}_20_settings', key);
      await tester.tap(find.text('Results').last);
      await waitFor(() => true);
      // Storage overview.
      await tester.tap(find.text('Storage').last);
      await waitFor(() => true);
      await capture('${label}_12_dashboard', key);
      await reveal(find.text('Space map'));
      await tester.tap(find.text('Space map'));
      await waitFor(() => find.text('Camera Roll').evaluate().isNotEmpty);
      await capture('${label}_13_spacemap', key);
      await tester.pageBack();
      await waitFor(() => true);
      await reveal(find.text('Recommended cleanup'));
      await tester.tap(find.text('Recommended cleanup'));
      await waitFor(() => find.text('Duplicate downloads').evaluate().isNotEmpty);
      await capture('${label}_14_recommend', key);
      await tester.pageBack();
      await waitFor(() => true);
      await reveal(find.text('Old files'));
      await tester.tap(find.text('Old files'));
      await waitFor(() => find.textContaining('Quarterly report').evaluate().isNotEmpty);
      await capture('${label}_15_old', key);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    }
    tester.view.reset();
    base.deleteSync(recursive: true);
  });
}
