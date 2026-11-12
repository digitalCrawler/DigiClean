import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/storage_access.dart';
import '../../rust/api/maintenance.dart';
import '../../rust/api/types.dart';
import '../../state/background_check.dart';
import '../../state/history.dart';
import '../../state/ignore_list.dart';
import '../../state/locations.dart';
import '../../state/scan_controller.dart';
import '../../state/settings.dart';
import '../scan/scan_options_page.dart';
import '../widgets/common.dart';
import 'history_page.dart';
import 'ignored_page.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  Future<CacheInfo?>? _cache;
  AccessState? _access;

  @override
  void initState() {
    super.initState();
    _loadCache();
    StorageAccess.status().then((s) {
      if (mounted) setState(() => _access = s);
    });
  }

  void _loadCache() {
    final dir = ref.read(appPathsProvider).cacheDir;
    setState(() {
      _cache = cacheInfo(dir: dir).then<CacheInfo?>((c) => c).catchError((_) => null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final ignored = ref.watch(ignoreListProvider.select((l) => l.length));
    final freedTotal = ref.watch(totalFreedProvider);
    final controller = ref.read(settingsProvider.notifier);
    final caps = platformCapabilities();
    final scanning = ref.watch(scanProvider.select((s) => s.isRunning));
    final trashName = Platform.isWindows ? 'Recycle Bin' : 'Trash';

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              const SectionHeader('Appearance'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto), label: Text('System')),
                      ButtonSegment(
                        value: ThemeMode.light,
                        icon: Icon(Icons.light_mode_outlined),
                        label: Text('Light'),
                      ),
                      ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_outlined), label: Text('Dark')),
                    ],
                    selected: {s.themeMode},
                    onSelectionChanged: (v) => controller.update((s) => s.copyWith(themeMode: v.first)),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const SectionHeader('Scanning'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.tune),
                      title: const Text('Filters & detection options'),
                      subtitle: Text(
                        '${s.hashAlgorithm == HashAlgo.blake3 ? 'BLAKE3' : 'SHA-256'} · '
                        '${s.activeFilterCount == 0 ? 'no filters' : plural(s.activeFilterCount, 'filter')}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => openScanOptions(context),
                    ),
                    ListTile(
                      leading: const Icon(Icons.visibility_off_outlined),
                      title: const Text('Not duplicates'),
                      subtitle: Text(
                        ignored == 0
                            ? 'Groups you hide appear here'
                            : '${plural(ignored, 'group')} hidden from results',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () =>
                          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const IgnoredPage())),
                    ),
                    const Divider(),
                    const PerformancePicker(),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const SectionHeader('Keep it clean'),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      secondary: const Icon(Icons.download_done),
                      title: const Text('Watch download folders'),
                      subtitle: const Text('Point out new downloads you already have, while DigiClean is open'),
                      value: s.watchDownloads,
                      onChanged: (v) => controller.update((s) => s.copyWith(watchDownloads: v)),
                    ),
                    if (BackgroundCheckController.supported)
                      SwitchListTile(
                        secondary: const Icon(Icons.notifications_active_outlined),
                        title: const Text('Check in the background'),
                        subtitle: Text(
                          Platform.isAndroid || Platform.isIOS
                              ? 'Daily, even when DigiClean is closed. Notifies you when storage is almost full '
                                    'or a rescan is due. Never removes anything.'
                              : 'Daily, even when DigiClean is closed. Notifies you when a drive is almost full '
                                    'or there is space to free. Never removes anything.',
                        ),
                        value: s.backgroundCheck,
                        onChanged: (v) async {
                          final error = await ref.read(backgroundCheckProvider).setEnabled(v);
                          if (error != null && context.mounted) showMessage(context, error);
                        },
                      ),
                    ListTile(
                      leading: const Icon(Icons.event_repeat),
                      title: const Text('Scan again automatically'),
                      subtitle: const Text('Rescans your locations when DigiClean is open and the last scan is older'),
                      trailing: DropdownButton<int>(
                        value: s.autoRescanDays,
                        underline: const SizedBox.shrink(),
                        onChanged: (v) => controller.update((s) => s.copyWith(autoRescanDays: v ?? 0)),
                        items: const [
                          DropdownMenuItem(value: 0, child: Text('Off')),
                          DropdownMenuItem(value: 1, child: Text('Daily')),
                          DropdownMenuItem(value: 7, child: Text('Weekly')),
                          DropdownMenuItem(value: 30, child: Text('Monthly')),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const SectionHeader('Safety'),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.history),
                  title: const Text('Cleanup history'),
                  subtitle: Text(freedTotal > 0 ? '${formatBytes(freedTotal)} freed so far' : 'Nothing cleaned yet'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => openHistory(context),
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    RadioGroup<ActionType>(
                      groupValue: s.deleteAction,
                      onChanged: (v) => controller.update((s) => s.copyWith(deleteAction: v)),
                      child: Column(
                        children: [
                          RadioListTile<ActionType>(
                            value: ActionType.trash,
                            title: Text(
                              caps.systemTrash ? 'Remove moves to the $trashName' : 'Remove moves to the Recovery Bin',
                            ),
                            subtitle: Text(
                              caps.systemTrash ? 'Restore from the system $trashName' : 'Restore from the Recovery tab',
                            ),
                          ),
                          if (caps.systemTrash)
                            const RadioListTile<ActionType>(
                              value: ActionType.recoveryBin,
                              title: Text('Remove moves to DigiClean’s Recovery Bin'),
                              subtitle: Text('Restore with one tap from the Recovery tab'),
                            ),
                        ],
                      ),
                    ),
                    const Divider(),
                    SwitchListTile(
                      title: const Text('Re-check contents before removing'),
                      subtitle: const Text('Hashes files again right before they are removed'),
                      value: s.verifyBeforeDelete,
                      onChanged: (v) => controller.update((s) => s.copyWith(verifyBeforeDelete: v)),
                    ),
                    ListTile(
                      title: const Text('Keep Recovery Bin items for'),
                      subtitle: Text(
                        s.recoveryRetentionDays == 0 ? 'Until emptied manually' : '${s.recoveryRetentionDays} days',
                      ),
                      trailing: DropdownButton<int>(
                        value: s.recoveryRetentionDays,
                        underline: const SizedBox.shrink(),
                        items: const [
                          DropdownMenuItem(value: 7, child: Text('7 days')),
                          DropdownMenuItem(value: 14, child: Text('14 days')),
                          DropdownMenuItem(value: 30, child: Text('30 days')),
                          DropdownMenuItem(value: 90, child: Text('90 days')),
                          DropdownMenuItem(value: 0, child: Text('Forever')),
                        ],
                        onChanged: (v) => controller.update((s) => s.copyWith(recoveryRetentionDays: v)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const SectionHeader('Storage'),
              Card(
                child: Column(
                  children: [
                    if (StorageAccess.needsPermission)
                      ListTile(
                        leading: Icon(
                          _access == AccessState.granted ? Icons.verified_user_outlined : Icons.gpp_maybe_outlined,
                        ),
                        title: const Text('All files access'),
                        subtitle: Text(
                          _access == AccessState.granted ? 'Granted' : 'Required to scan and clean shared storage',
                        ),
                        trailing: _access == AccessState.granted
                            ? null
                            : FilledButton.tonal(
                                onPressed: () async {
                                  final r = await StorageAccess.request();
                                  if (mounted) setState(() => _access = r);
                                },
                                child: const Text('Grant'),
                              ),
                      ),
                    FutureBuilder<CacheInfo?>(
                      future: _cache,
                      builder: (context, snap) {
                        final info = snap.data;
                        return ListTile(
                          leading: const Icon(Icons.bolt_outlined),
                          title: const Text('Fingerprint cache'),
                          subtitle: Text(
                            info == null
                                ? (snap.connectionState == ConnectionState.waiting
                                      ? 'Loading…'
                                      : 'Unavailable while scanning')
                                : '${formatCount(info.entries)} files · ${formatBytes(info.sizeBytes)}',
                          ),
                          trailing: TextButton(
                            onPressed: scanning || info == null
                                ? null
                                : () async {
                                    try {
                                      await cacheClear(dir: ref.read(appPathsProvider).cacheDir);
                                      _loadCache();
                                    } catch (e) {
                                      if (context.mounted) showError(context, e);
                                    }
                                  },
                            child: const Text('Clear'),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const SectionHeader('About'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: const Text('DigiClean'),
                      subtitle: Text('Engine ${caps.engineVersion} · ${caps.os} · ${caps.cores} cores'),
                    ),
                    const ListTile(
                      leading: Icon(Icons.lock_outline),
                      title: Text('Private by design'),
                      subtitle: Text('Everything runs on this device. No files, names or hashes ever leave it.'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.restart_alt),
                      title: const Text('Reset scan options to defaults'),
                      onTap: controller.reset,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
