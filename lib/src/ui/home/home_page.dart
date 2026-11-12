import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/file_kind.dart';
import '../../core/format.dart';
import '../../core/storage_access.dart';
import '../../rust/api/types.dart';
import '../../state/locations.dart';
import '../../state/results_controller.dart';
import '../../state/scan_controller.dart';
import '../../state/settings.dart';
import '../scan/scan_options_page.dart';
import '../scan/scan_progress_view.dart';
import '../storage/storage_overview.dart';
import '../storage/upkeep_banners.dart';
import '../theme.dart';
import '../widgets/common.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scanning = ref.watch(scanProvider.select((s) => s.isRunning));
    if (scanning) return const ScanProgressView();

    final wide = !context.isCompact;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Storage'),
        actions: [
          IconButton(
            tooltip: 'Filters & options',
            icon: const Icon(Icons.tune),
            onPressed: () => openScanOptions(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: ListView(
              padding: EdgeInsets.symmetric(horizontal: wide ? 24 : 16, vertical: 8),
              children: [
                const _PermissionBanner(),
                const UpkeepBanners(),
                if (wide)
                  const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [DrivesCard(), SizedBox(height: 8), _LocationsCard()],
                        ),
                      ),
                      SizedBox(width: 20),
                      Expanded(flex: 2, child: _StartColumn()),
                    ],
                  )
                else ...const [
                  DrivesCard(),
                  SizedBox(height: 8),
                  _LocationsCard(),
                  SizedBox(height: 16),
                  _StartColumn(),
                ],
                const SizedBox(height: 8),
                const PhotoLibraryCard(),
                const SpaceUsageCard(),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PermissionBanner extends ConsumerStatefulWidget {
  const _PermissionBanner();

  @override
  ConsumerState<_PermissionBanner> createState() => _PermissionBannerState();
}

class _PermissionBannerState extends ConsumerState<_PermissionBanner> with WidgetsBindingObserver {
  AccessState _state = AccessState.granted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user may have toggled "All files access" in system settings.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final s = await StorageAccess.status();
    if (mounted) setState(() => _state = s);
  }

  @override
  Widget build(BuildContext context) {
    if (_state == AccessState.granted) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.folder_off_outlined, color: scheme.onErrorContainer),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  'DigiClean needs “All files access” to read and clean up files in your storage.',
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.tonal(
                onPressed: () async {
                  if (_state == AccessState.permanentlyDenied) {
                    await StorageAccess.openSettings();
                  } else {
                    await StorageAccess.request();
                  }
                  _refresh();
                },
                child: const Text('Allow'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LocationsCard extends ConsumerWidget {
  const _LocationsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locations = ref.watch(locationsProvider);
    final suggestions = ref.watch(appPathsProvider).suggestions;
    final notifier = ref.read(locationsProvider.notifier);
    final theme = Theme.of(context);
    final unused = suggestions.where((s) => !locations.any((l) => l.path == s.path)).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Where to look',
              padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
              trailing: TextButton.icon(
                onPressed: () async {
                  try {
                    await notifier.pickAndAdd();
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Add folder'),
              ),
            ),
            if (locations.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
                decoration: BoxDecoration(
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                  borderRadius: BorderRadius.zero,
                ),
                child: Column(
                  children: [
                    Icon(Icons.folder_open_outlined, size: 36, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(height: 8),
                    Text('No folders selected', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(
                      Platform.isIOS
                          ? 'Add folders from Files, iCloud Drive or On My iPhone.'
                          : 'Add a folder or pick a suggestion below.',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            else
              for (final l in locations)
                _LocationTile(location: l, onToggle: () => notifier.toggle(l), onRemove: () => notifier.remove(l)),
            if (unused.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'Suggestions',
                style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in unused)
                    ActionChip(
                      avatar: Icon(s.isVolume ? Icons.storage_outlined : Icons.add, size: 18),
                      label: Text(s.label),
                      tooltip: s.path,
                      onPressed: () => notifier.add(s.path, label: s.label),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LocationTile extends StatelessWidget {
  const _LocationTile({required this.location, required this.onToggle, required this.onRemove});

  final ScanLocation location;
  final VoidCallback onToggle;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final missing = !location.exists;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Checkbox(value: location.enabled && !missing, onChanged: missing ? null : (_) => onToggle()),
      title: Text(location.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        missing ? 'Not available — ${location.path}' : location.path,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: missing ? TextStyle(color: theme.colorScheme.error) : null,
      ),
      trailing: IconButton(tooltip: 'Remove', icon: const Icon(Icons.close), onPressed: onRemove),
      onTap: missing ? null : onToggle,
    );
  }
}

class _StartColumn extends ConsumerWidget {
  const _StartColumn();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final locations = ref.watch(locationsProvider);
    final results = ref.watch(resultsProvider);
    final enabled = locations.where((l) => l.enabled && l.exists).length;
    final theme = Theme.of(context);

    final chips = <String>[
      settings.categories.isEmpty ? 'All file types' : settings.categories.map(categoryLabel).join(', '),
      if (settings.minSize > 1) '≥ ${formatBytes(settings.minSize)}',
      if (settings.maxSize != null) '≤ ${formatBytes(settings.maxSize!)}',
      if (settings.includeExtensions.isNotEmpty) '.${settings.includeExtensions.join(' .')}',
      settings.recursive
          ? (settings.maxDepth == null ? 'All sub-folders' : 'Depth ${settings.maxDepth}')
          : 'Top level only',
      settings.hashAlgorithm == HashAlgo.blake3 ? 'BLAKE3' : 'SHA-256',
      if (settings.verifyByteByByte) 'Byte-by-byte check',
      if (settings.detectFolders) 'Duplicate folders',
      if (settings.includeHidden) 'Hidden files',
      switch (settings.effectivePerformance) {
        PerformanceMode.maximum => 'Max speed',
        PerformanceMode.balanced => 'Balanced',
        PerformanceMode.batterySaver => 'Battery saver',
        PerformanceMode.spinningDisk => 'HDD mode',
      },
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionHeader(
                  'Scan settings',
                  padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
                  trailing: TextButton(
                    onPressed: () => openScanOptions(context),
                    child: Text(settings.activeFilterCount > 0 ? 'Edit (${settings.activeFilterCount})' : 'Edit'),
                  ),
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [for (final c in chips) TagChip(c, outlined: true, caps: false)],
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: enabled == 0
                      ? null
                      : () async {
                          try {
                            await StorageAccess.requestNotifications();
                            await ref.read(scanProvider.notifier).start();
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        },
                  icon: const Icon(Icons.search),
                  label: Text(enabled == 0 ? 'Select a folder to scan' : 'Scan ${plural(enabled, 'location')}'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                ),
                const SizedBox(height: 10),
                Text(
                  'Files are compared by their contents, so renamed copies are found too. Nothing is changed until you choose what to remove.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        if (results.stats != null) ...[const SizedBox(height: 16), const FindingsCard()],
      ],
    );
  }
}
