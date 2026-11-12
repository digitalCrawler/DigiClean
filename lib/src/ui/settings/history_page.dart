import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../rust/api/types.dart';
import '../../state/history.dart';
import '../widgets/common.dart';

Future<void> openHistory(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HistoryPage()));

/// What DigiClean removed, moved and freed, newest first.
class HistoryPage extends ConsumerWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = ref.watch(historyProvider);
    final freed = ref.watch(totalFreedProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cleanup history'),
        actions: [if (events.isNotEmpty) TextButton(onPressed: () => _clear(context, ref), child: const Text('Clear'))],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: events.isEmpty
              ? const EmptyState(
                  icon: Icons.history,
                  title: 'Nothing cleaned yet',
                  message: 'Every cleanup is listed here, with how much space it really freed.',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Freed with DigiClean', style: theme.textTheme.labelLarge),
                            const SizedBox(height: 4),
                            Text(
                              formatBytes(freed),
                              style: theme.textTheme.headlineMedium?.copyWith(
                                color: scheme.primary,
                                fontWeight: FontWeight.w700,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Counts space released for good: permanent deletes, hard links and emptied bins. '
                              'Items moved to a bin count once the bin is emptied.',
                              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Card(
                      child: Column(
                        children: [
                          for (var i = 0; i < events.length; i++) ...[
                            if (i > 0) const Divider(height: 1),
                            _EventTile(event: events[i]),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Future<void> _clear(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear cleanup history?'),
        content: const Text('The list and the “freed” total are reset. Nothing on disk changes.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) ref.read(historyProvider.notifier).clear();
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});

  final CleanupEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final e = event;
    final trash = Platform.isWindows ? 'Recycle Bin' : 'Trash';
    final items = plural(e.items, 'item');
    final (IconData icon, String title) = switch (e.kind) {
      CleanupKind.recoveryBin => (
        Icons.delete_forever_outlined,
        e.items > 0 ? 'Deleted $items from the Recovery Bin' : 'Expired items left the Recovery Bin',
      ),
      CleanupKind.systemTrash => (
        Icons.delete_sweep_outlined,
        e.items > 0 ? 'Emptied the $trash ($items)' : 'Emptied the $trash',
      ),
      CleanupKind.cleanup => switch (e.action) {
        ActionType.deletePermanently => (Icons.delete_forever_outlined, 'Deleted $items'),
        ActionType.replaceWithHardlink => (Icons.link, 'Linked $items'),
        ActionType.replaceWithClone => (Icons.copy_all, 'Replaced $items with clones'),
        ActionType.moveTo => (Icons.drive_file_move_outlined, 'Moved $items to another folder'),
        _ => (Icons.delete_outline, 'Moved $items to the ${e.systemTrash ? trash : 'Recovery Bin'}'),
      },
    };
    final details = [
      if (e.bytesInBin > 0) '${formatBytes(e.bytesInBin)} in the bin',
      if (e.bytesMoved > 0) '${formatBytes(e.bytesMoved)} moved',
      formatDateTime(e.atMs),
    ].join(' · ');
    return ListTile(
      leading: Icon(icon, color: scheme.onSurfaceVariant),
      title: Text(title),
      subtitle: Text(details, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
      trailing: e.bytesFreed > 0
          ? Text(
              formatBytes(e.bytesFreed),
              style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700),
            )
          : null,
    );
  }
}
