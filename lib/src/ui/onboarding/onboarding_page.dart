import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage_access.dart';
import '../../state/settings.dart';

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

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.asset('assets/branding/app_icon.png', width: 72, height: 72),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Welcome to DigiClean',
                    style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'DUPLICATE FILE & FOLDER FINDER',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.secondary,
                      letterSpacing: 1.6,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Reclaim storage by finding exact duplicate files and folders.',
                    style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 28),
                  for (final (icon, title, text) in points)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(icon, color: scheme.onPrimaryContainer, size: 22),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(title, style: theme.textTheme.titleMedium),
                                const SizedBox(height: 2),
                                Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (permissionNote != null) ...[
                    const SizedBox(height: 8),
                    Text(permissionNote, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _requesting ? null : _continue,
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
