import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage_access.dart';
import '../../state/settings.dart';
import '../theme.dart';

/// First-run explanation and, on Android, the storage permission request.
class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key});

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  bool _requesting = false;

  void _finish() => ref.read(settingsProvider.notifier).update((s) => s.copyWith(onboardingDone: true));

  Future<void> _continue() async {
    if (StorageAccess.needsPermission) {
      setState(() => _requesting = true);
      await StorageAccess.request();
      if (mounted) setState(() => _requesting = false);
    }
    _finish();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final points = [
      (
        Icons.fingerprint,
        'Compares contents, not names',
        'Renamed and moved copies are found using BLAKE3 or SHA-256 fingerprints.',
      ),
      (
        Icons.folder_copy_outlined,
        'Finds duplicate folders',
        'Whole folder trees with identical structure and files, plus empty folders.',
      ),
      (
        Icons.shield_outlined,
        'Safe by default',
        'One copy is always kept, changed files are skipped, and removals can be undone.',
      ),
      (Icons.lock_outline, 'Stays on your device', 'No account, no upload. Everything runs locally.'),
    ];
    final permissionNote = Platform.isAndroid
        ? 'Next, Android will ask you to allow “All files access”. DigiClean needs it to read and clean up files outside its own folder.'
        : Platform.isIOS
        ? 'You choose which folders DigiClean can see, from Files, iCloud Drive or On My iPhone.'
        : null;

    final ds = context.ds;
    final wide = MediaQuery.sizeOf(context).width >= 520;
    final headline = displayStyle(wide ? 64 : 48, color: ds.ink);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(width: 14, height: 14, color: ds.accent),
                      const SizedBox(width: 10),
                      Text('DigiClean', style: displayStyle(22, color: ds.ink).copyWith(letterSpacing: -1)),
                    ],
                  ),
                  const SizedBox(height: 40),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                    color: ds.ink,
                    child: Text(
                      'DUPLICATE FILE & FOLDER FINDER',
                      style: capsStyle(scheme.surface, size: 11).copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text.rich(
                    TextSpan(
                      style: headline,
                      children: [
                        const TextSpan(text: 'Keep '),
                        TextSpan(
                          text: 'one',
                          style: TextStyle(
                            decoration: TextDecoration.underline,
                            decorationColor: ds.accent,
                            decorationThickness: 3,
                          ),
                        ),
                        const TextSpan(text: '.\nClear the rest.'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'DigiClean finds exact duplicate files and folders by their contents, and removes the extras without ever touching the last copy.',
                    style: theme.textTheme.bodyLarge?.copyWith(color: ds.muted),
                  ),
                  const SizedBox(height: 32),
                  for (final (i, (icon, title, text)) in points.indexed)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      decoration: BoxDecoration(
                        border: Border(top: i == 0 ? ds.rule : BorderSide(color: ds.hairline)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 44,
                            child: Text((i + 1).toString().padLeft(2, '0'), style: displayStyle(20, color: ds.accent)),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(title, style: theme.textTheme.titleMedium),
                                const SizedBox(height: 2),
                                Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: ds.muted)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Icon(icon, size: 22, color: ds.ink),
                        ],
                      ),
                    ),
                  if (permissionNote != null) ...[
                    const SizedBox(height: 8),
                    Text(permissionNote, style: theme.textTheme.bodySmall),
                  ],
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _requesting ? null : _continue,
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                      child: Text(StorageAccess.needsPermission ? 'Allow access and continue' : 'Get started'),
                    ),
                  ),
                  if (StorageAccess.needsPermission)
                    Center(
                      child: TextButton(onPressed: _finish, child: const Text('Not now')),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
