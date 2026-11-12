import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/path_display.dart';
import '../../rust/api/types.dart';
import '../../state/ignore_list.dart';
import '../../state/settings.dart';
import '../scan/scan_options_page.dart';
import '../widgets/common.dart';
import '../widgets/path_text.dart';

/// Groups marked "Not duplicates", with a way to show them again.
class IgnoredPage extends ConsumerWidget {
  const IgnoredPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(ignoreListProvider);
    final algorithm = ref.watch(settingsProvider.select((s) => s.hashAlgorithm));
    final excluded = ref.watch(settingsProvider.select((s) => s.excludePaths.length));
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Not duplicates'),
        actions: [
          if (list.isNotEmpty)
            TextButton(onPressed: () => _clearAll(context, ref, list.length), child: const Text('Show all again')),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: [
              Card(
                child: ListTile(
                  leading: const Icon(Icons.folder_off_outlined),
                  title: const Text('Excluded folders'),
                  subtitle: Text(excluded == 0 ? 'None' : '${plural(excluded, 'folder')} never scanned'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => openScanOptions(context),
                ),
              ),
              const SizedBox(height: 8),
              if (list.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 48),
                  child: EmptyState(
                    icon: Icons.visibility_off_outlined,
                    title: 'Nothing hidden',
                    message: 'Use “Not duplicates” in a copy’s menu to hide groups you want to keep, such as backups.',
                  ),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                  child: Text(
                    '${plural(list.length, 'group')} hidden from results. They are matched by content, '
                    'so they stay hidden even after files are moved or renamed.',
                    style: small,
                  ),
                ),
                Card(
                  child: Column(
                    children: [
                      for (var i = 0; i < list.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _IgnoredTile(group: list[i], otherAlgorithm: list[i].algorithm != algorithm),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _clearAll(BuildContext context, WidgetRef ref, int count) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Show all groups again?'),
        content: Text('${plural(count, 'hidden group')} will appear in results again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Show all')),
        ],
      ),
    );
    if (ok == true) ref.read(ignoreListProvider.notifier).clear();
  }
}

class _IgnoredTile extends ConsumerWidget {
  const _IgnoredTile({required this.group, required this.otherAlgorithm});

  final IgnoredGroup group;

  /// Made with another hash algorithm, so it does not match current scans.
  final bool otherAlgorithm;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final folder = group.kind == ResultKind.folders;
    return ListTile(
      leading: Icon(folder ? Icons.folder_copy_outlined : Icons.insert_drive_file_outlined),
      title: Text(group.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              plural(group.copies, 'copy', 'copies'),
              '${formatBytes(group.size)} each',
              'hidden ${formatDate(group.addedMs)}',
            ].join(' · '),
            style: small,
          ),
          PathSegmentsText(_location(group), tooltip: group.path, style: small),
          if (otherAlgorithm)
            Text(
              'Applies only to ${group.algorithm == HashAlgo.sha256 ? 'SHA-256' : 'BLAKE3'} scans',
              style: small?.copyWith(color: theme.colorScheme.error),
            ),
        ],
      ),
      trailing: IconButton(
        tooltip: 'Show again',
        icon: const Icon(Icons.visibility_outlined),
        onPressed: () {
          ref.read(ignoreListProvider.notifier).remove(group);
          showMessage(
            context,
            '“${group.name}” will be shown again',
            action: SnackBarAction(label: 'Undo', onPressed: () => ref.read(ignoreListProvider.notifier).add(group)),
          );
        },
      ),
    );
  }
}

/// The last few folders of where one copy was, for recognition.
List<String> _location(IgnoredGroup g) {
  final parts = splitPath(g.path);
  final folders = g.kind == ResultKind.folders || parts.isEmpty ? parts : parts.sublist(0, parts.length - 1);
  return folders.length > 3 ? folders.sublist(folders.length - 3) : folders;
}
