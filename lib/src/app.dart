import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state/settings.dart';
import 'ui/onboarding/onboarding_page.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

class DigiCleanApp extends ConsumerWidget {
  const DigiCleanApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(settingsProvider.select((s) => s.themeMode));
    final onboarded = ref.watch(settingsProvider.select((s) => s.onboardingDone));
    return MaterialApp(
      title: 'DigiClean',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: themeMode,
      home: onboarded ? const AppShell() : const OnboardingPage(),
    );
  }
}
