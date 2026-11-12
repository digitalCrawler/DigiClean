// Renders the screenshots used on the landing page from a realistic demo
// library. Only views that never show full paths are captured.
//
//   flutter test integration_test/marketing_shots.dart -d windows \
//     --dart-define=SHOTS=website/assets --dart-define=DEMO=build/demo
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:digiclean/src/app.dart';
import 'package:digiclean/src/core/app_paths.dart';
import 'package:digiclean/src/rust/frb_generated.dart';
import 'package:digiclean/src/state/locations.dart';
import 'package:digiclean/src/state/results_controller.dart';
import 'package:digiclean/src/state/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

const shots = String.fromEnvironment('SHOTS');
const demo = String.fromEnvironment('DEMO');

/// A small landscape "photo": gradient sky, sun and layered hills.
Future<List<int>> photo(int seed) async {
  const palettes = [
    [Color(0xFFFFB37E), Color(0xFFFF6F91), Color(0xFF6A4C93)],
    [Color(0xFF9BE7FF), Color(0xFF3FA7D6), Color(0xFF1B4965)],
    [Color(0xFFFFE29A), Color(0xFFF6A04D), Color(0xFF7A3E48)],
    [Color(0xFFC6F1E7), Color(0xFF59C3C3), Color(0xFF2E5266)],
    [Color(0xFFFAD2E1), Color(0xFFC08497), Color(0xFF5C374C)],
    [Color(0xFFE0FBFC), Color(0xFF98C1D9), Color(0xFF293241)],
  ];
  final colors = palettes[seed % palettes.length];
  final rnd = Random(seed);
  const w = 480.0, h = 360.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, w, h),
    Paint()..shader = ui.Gradient.linear(Offset.zero, const Offset(0, h), [colors[0], colors[1]]),
  );
  canvas.drawCircle(
    Offset(80 + rnd.nextDouble() * 320, 90 + rnd.nextDouble() * 60),
    34 + rnd.nextDouble() * 18,
    Paint()..color = Colors.white.withValues(alpha: 0.85),
  );
  for (var layer = 0; layer < 3; layer++) {
    final path = Path()..moveTo(0, h);
    final base = 200 + layer * 50.0;
    for (var x = 0.0; x <= w; x += 40) {
      path.lineTo(x, base - rnd.nextDouble() * 70);
    }
    path
      ..lineTo(w, h)
      ..close();
    canvas.drawPath(path, Paint()..color = Color.lerp(colors[1], colors[2], 0.4 + layer * 0.3)!);
  }
  final image = await recorder.endRecording().toImage(w.toInt(), h.toInt());
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

List<int> noise(int seed, int length) {
  final rnd = Random(seed);
  return List<int>.generate(length, (_) => rnd.nextInt(256));
}

void write(String root, String path, List<int> bytes, DateTime modified) {
  final f = File(p.join(root, path))
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes);
  f.setLastModifiedSync(modified);
}

Future<void> buildLibrary(String root) async {
  final day = DateTime(2024, 6, 14, 10, 15);
  const trip = 'Pictures/Camera Roll/2024/Lisbon trip';
  const phone = 'Backup/iPhone 2024/DCIM/100APPLE';
  for (var i = 0; i < 6; i++) {
    final bytes = await photo(i);
    final name = 'IMG_20${41 + i}.jpg';
    write(root, '$trip/$name', bytes, day.add(Duration(minutes: i)));
    write(root, '$phone/$name', bytes, day.add(Duration(days: 2, minutes: i)));
    if (i.isEven) write(root, 'Downloads/IMG_20${41 + i} (1).jpg', bytes, day.add(Duration(days: 30, minutes: i)));
  }
  // A complete copy of the trip folder.
  for (var i = 0; i < 6; i++) {
    write(root, 'Backup/Lisbon trip (copy)/IMG_20${41 + i}.jpg', await photo(i), day.add(Duration(days: 60)));
  }
  // Same videos under different names.
  write(root, 'Videos/Holiday 2024/Beach day.mp4', noise(11, 9 << 20), day.add(const Duration(days: 3)));
  write(root, '$phone/IMG_2105.MOV', noise(11, 9 << 20), day.add(const Duration(days: 2)));
  write(root, 'Videos/Family/Birthday.mp4', noise(12, 6 << 20), day.add(const Duration(days: 90)));
  write(root, 'Downloads/VID_0412.mp4', noise(12, 6 << 20), day.add(const Duration(days: 120)));
  write(root, 'Desktop/To sort/Birthday final.mp4', noise(12, 6 << 20), day.add(const Duration(days: 121)));
  // Documents.
  for (final (i, doc) in ['2024 tax return.pdf', 'Lease agreement.pdf', 'Project plan.docx'].indexed) {
    final bytes = noise(20 + i, (900 + i * 400) << 10);
    write(root, 'Documents/Paperwork/$doc', bytes, day.add(Duration(days: 100 + i)));
    write(root, 'Downloads/$doc', bytes, day.add(Duration(days: 101 + i)));
    if (i == 0) write(root, 'Desktop/To sort/tax return final.pdf', bytes, day.add(const Duration(days: 140)));
  }
  write(root, 'Music/Live sessions/01 Opening.flac', noise(30, 5 << 20), day);
  write(root, 'Downloads/01 Opening.flac', noise(30, 5 << 20), day.add(const Duration(days: 5)));
  Directory(p.join(root, 'Downloads', 'New folder')).createSync(recursive: true);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  testWidgets(
    'landing page screenshots',
    skip: shots.isEmpty || demo.isEmpty,
    timeout: const Timeout(Duration(minutes: 5)),
    (tester) async {
      final root = p.join(Directory(demo).absolute.path, 'Home');
      if (Directory(root).existsSync()) Directory(root).deleteSync(recursive: true);
      debugPrint('building demo library in $root');
      await tester.runAsync(() => buildLibrary(root));
      debugPrint('demo library ready');
      Future<void> waitFor(bool Function() c) async {
        final end = DateTime.now().add(const Duration(seconds: 60));
        while (!c()) {
          if (DateTime.now().isAfter(end)) fail('timeout');
          await tester.pump(const Duration(milliseconds: 50));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
      }

      for (final (name, size, dark) in [
        ('screenshot-desktop', const Size(1280, 800), false),
        ('screenshot-desktop-dark', const Size(1280, 800), true),
      ]) {
        // Fresh app data per pass: otherwise the second pass restores the
        // first pass's saved results and never settles.
        final appData = Directory.systemTemp.createTempSync('dc_marketing_');
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        SharedPreferences.setMockInitialValues({
          'settings.v1': '{"onboardingDone": true, "themeMode": "${dark ? 'dark' : 'light'}"}',
        });
        final container = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
            appPathsProvider.overrideWithValue(AppPaths.forTesting(appData.path)),
          ],
        );
        container.read(locationsProvider.notifier).add(root, label: 'Home');
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
        await tester.tap(find.text('Smart select'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Apply'));
        await waitFor(() => find.textContaining(' selected').evaluate().isNotEmpty);

        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(p.join(shots, '$name.png'))
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(bytes!.buffer.asUint8List());

        await tester.pumpWidget(const SizedBox());
        container.dispose();
        appData.deleteSync(recursive: true);
      }
      tester.view.reset();
      Directory(root).deleteSync(recursive: true);
    },
  );
}
