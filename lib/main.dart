import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/app.dart';
import 'src/core/app_paths.dart';
import 'src/rust/frb_generated.dart';
import 'src/state/locations.dart';
import 'src/state/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();

  // Thumbnails in long lists: keep the decoded-image cache bounded,
  // especially on phones.
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSizeBytes = (Platform.isAndroid || Platform.isIOS ? 48 : 128) << 20;

  final results = await Future.wait([SharedPreferences.getInstance(), AppPaths.resolve()]);

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(results[0] as SharedPreferences),
        appPathsProvider.overrideWithValue(results[1] as AppPaths),
      ],
      child: const DigiCleanApp(),
    ),
  );
}
