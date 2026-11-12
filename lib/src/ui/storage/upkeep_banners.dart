import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/format.dart';
import '../../rust/api/maintenance.dart';
import '../../rust/api/types.dart';
import '../../state/history.dart';
import '../../state/locations.dart';
import '../../state/recovery_controller.dart';
import '../../state/results_controller.dart';
import '../../state/settings.dart';
import '../../state/upkeep.dart';
import '../widgets/common.dart';
import '../widgets/system_trash.dart';
import 'recommendations_page.dart';
import 'storage_overview.dart';

/// Warnings that need attention: a nearly full drive, new duplicate
/// downloads. Renders nothing when all is well.
class UpkeepBanners extends ConsumerWidget {
  const UpkeepBanners({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drives = ref.watch(drivesProvider).value ?? const [];
    final low = drives.where((d) => d.total > 0 && d.free < d.total * 0.1).toList();
    final copies = ref.watch(upkeepProvider).newCopies;
    // Recommendations need scan results; without them the banner only informs.
    final hasResults = ref.watch(resultsProvider.select((r) => r.hasResults));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final d in low)
          _Banner(
            icon: Icons.warning_amber_rounded,
            error: true,
            title: '${d.label} is almost full',
            message: '${formatBytes(d.free)} free of ${formatBytes(d.total)}.',
            actions: [
              if (hasResults)
                FilledButton(
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RecommendationsPage())),
                  child: const Text('Recommended cleanup'),
                ),
            ],
          ),
        if (copies.isNotEmpty)
          _Banner(
            icon: Icons.download_done,
            title: '${plural(copies.length, 'new download')} you already have',
            message:
                '${formatBytes(copies.fold(0, (s, c) => s + c.size))} in Downloads are copies of files in your scanned folders.',
            actions: [
              TextButton(onPressed: () => ref.read(upkeepProvider.notifier).clear(), child: const Text('Dismiss')),
              FilledButton(onPressed: () => _review(context, ref, copies), child: const Text('Review')),
            ],
          ),
      ],
    );
  }

  Future<void> _review(BuildContext context, WidgetRef ref, List<CopyMatchDto> copies) async {
    final chosen = {for (final c in copies) c.path};
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('New downloads you already have'),
          content: SizedBox(
            width: 480,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final c in copies)
                  CheckboxListTile(
                    value: chosen.contains(c.path),
                    onChanged: (v) => setState(() => v == true ? chosen.add(c.path) : chosen.remove(c.path)),
                    title: Text(p.basename(c.path)),
                    subtitle: Text('Same as ${c.existing} · ${formatBytes(c.size)}'),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: chosen.isEmpty ? null : () => Navigator.pop(context, true),
              child: const Text('Remove downloads'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    final settings = ref.read(settingsProvider);
    final action = switch (settings.deleteAction) {
      ActionType.deletePermanently => ActionType.deletePermanently,
      ActionType.recoveryBin => ActionType.recoveryBin,
      _ => ActionType.trash,
    };
    try {
      final report = await removePaths(
        paths: chosen.toList(),
        action: action,
        recoveryRoots: ref.read(appPathsProvider).recoveryRoots,
      );
      ref.read(upkeepProvider.notifier).clear(report.done);
      final permanent = action == ActionType.deletePermanently;
      if (report.done.isNotEmpty) {
        ref
            .read(historyProvider.notifier)
            .record(
              CleanupEvent(
                kind: CleanupKind.cleanup,
                atMs: DateTime.now().millisecondsSinceEpoch,
                items: report.done.length,
                action: action,
                bytesFreed: permanent ? report.bytes : 0,
                bytesInBin: permanent ? 0 : report.bytes,
                systemTrash: report.usedSystemTrash,
              ),
            );
      }
      if (report.batchId != null) ref.read(recoveryProvider.notifier).refresh();
      if (report.usedSystemTrash) ref.invalidate(systemTrashProvider);
      if (context.mounted) {
        showMessage(
          context,
          report.issues.isEmpty
              ? 'Removed ${plural(report.done.length, 'download')}'
              : 'Removed ${report.done.length}; ${report.issues.length} could not be removed',
        );
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.title,
    required this.message,
    required this.actions,
    this.error = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final List<Widget> actions;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bg = error ? scheme.errorContainer : scheme.secondaryContainer;
    final fg = error ? scheme.onErrorContainer : scheme.onSecondaryContainer;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        color: bg,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, color: fg),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: theme.textTheme.titleSmall?.copyWith(color: fg)),
                        const SizedBox(height: 2),
                        Text(message, style: theme.textTheme.bodySmall?.copyWith(color: fg)),
                      ],
                    ),
                  ),
                ],
              ),
              if (actions.isNotEmpty)
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(spacing: 8, children: actions),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
