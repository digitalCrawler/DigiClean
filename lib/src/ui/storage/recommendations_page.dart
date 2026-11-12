import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../rust/api/maintenance.dart';
import '../../rust/api/types.dart';
import '../../state/history.dart';
import '../../state/locations.dart';
import '../../state/navigation.dart';
import '../../state/results_controller.dart';
import '../../state/settings.dart';
import '../results/action_flow.dart';
import '../widgets/common.dart';
import '../widgets/system_trash.dart';

final _recommendationsProvider = FutureProvider.autoDispose<List<RecommendationDto>>((ref) async {
  final results = ref.watch(resultsProvider.select((r) => r.results));
  ref.watch(resultsProvider.select((r) => r.generation));
  if (results == null) return const [];
  return results.recommendations(downloads: ref.read(appPathsProvider).downloadDirs);
});

({IconData icon, String title, String why, ResultKind list}) _describe(RecommendationKind k) => switch (k) {
  RecommendationKind.systemCaches => (
    icon: Icons.cached,
    title: 'Thumbnail caches',
    why: 'Windows and macOS rebuild these automatically when needed.',
    list: ResultKind.junk,
  ),
  RecommendationKind.leftoverFiles => (
    icon: Icons.downloading,
    title: 'Unfinished downloads and temporary files',
    why: 'Older than a day, so nothing is still writing them.',
    list: ResultKind.junk,
  ),
  RecommendationKind.downloadDuplicates => (
    icon: Icons.download_done,
    title: 'Duplicate downloads',
    why: 'Copies in Downloads of files you keep elsewhere, or the same file downloaded twice. One copy always stays.',
    list: ResultKind.files,
  ),
  RecommendationKind.emptyFolders => (
    icon: Icons.folder_off_outlined,
    title: 'Empty folders',
    why: 'Folders with nothing inside.',
    list: ResultKind.emptyFolders,
  ),
};

/// Low-risk cleanups in one reviewed checklist.
class RecommendationsPage extends ConsumerStatefulWidget {
  const RecommendationsPage({super.key});

  @override
  ConsumerState<RecommendationsPage> createState() => _RecommendationsPageState();
}

class _RecommendationsPageState extends ConsumerState<RecommendationsPage> {
  final Set<RecommendationKind> _off = {};
  bool _emptyTrash = false;
  bool _running = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recs = ref.watch(_recommendationsProvider);
    final trash = ref.watch(systemTrashProvider).value;
    final list = recs.value ?? const [];
    final chosen = [
      for (final r in list)
        if (!_off.contains(r.kind)) r,
    ];
    final trashBytes = trash?.bytes ?? 0;
    final total = chosen.fold<int>(0, (s, r) => s + r.bytes) + (_emptyTrash ? trashBytes : 0);
    final removal = ref.watch(settingsProvider.select((s) => s.deleteAction));
    final intoBin = removal != ActionType.deletePermanently;

    return Scaffold(
      appBar: AppBar(title: const Text('Recommended cleanup')),
      body: recs.isLoading
          ? const Center(child: CircularProgressIndicator())
          : list.isEmpty && trashBytes == 0
          ? const EmptyState(
              icon: Icons.check_circle_outline,
              title: 'Nothing to recommend',
              message: 'No caches, leftovers, duplicate downloads or empty folders were found in the scanned folders.',
            )
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
                      child: Text(
                        'Only items that are safe to remove are listed. Review any of them before cleaning up.',
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                    Card(
                      child: Column(
                        children: [
                          for (var i = 0; i < list.length; i++) ...[
                            if (i > 0) const Divider(height: 1),
                            _RecTile(
                              rec: list[i],
                              checked: !_off.contains(list[i].kind),
                              onChanged: (v) => setState(() => v ? _off.remove(list[i].kind) : _off.add(list[i].kind)),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (trashBytes > 0) ...[
                      const SizedBox(height: 8),
                      Card(
                        child: CheckboxListTile(
                          value: _emptyTrash,
                          onChanged: (v) => setState(() => _emptyTrash = v ?? false),
                          secondary: const Icon(Icons.delete_sweep_outlined),
                          title: Text('Empty the $systemTrashName'),
                          subtitle: Text(
                            '${plural(trash!.items, 'item')} already deleted${intoBin ? ', plus what this cleanup moves there' : ''}. '
                            'This cannot be undone.',
                          ),
                          isThreeLine: true,
                        ),
                      ),
                    ],
                    if (intoBin && !_emptyTrash)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                        child: Text(
                          'Removed items go to the ${removal == ActionType.recoveryBin ? 'Recovery Bin' : systemTrashName}; '
                          'the space is freed when it is emptied.',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                  ],
                ),
              ),
            ),
      bottomNavigationBar: list.isEmpty && trashBytes == 0
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  onPressed: _running || (chosen.isEmpty && !_emptyTrash) ? null : () => _run(chosen),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  icon: const Icon(Icons.auto_awesome),
                  label: Text(total > 0 ? 'Clean up ${formatBytes(total)}' : 'Clean up'),
                ),
              ),
            ),
    );
  }

  Future<void> _run(List<RecommendationDto> chosen) async {
    final results = ref.read(resultsProvider).results;
    if (results == null && chosen.isNotEmpty) return;
    final settings = ref.read(settingsProvider);
    final removal = settings.deleteAction == ActionType.moveTo ? ActionType.trash : settings.deleteAction;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.auto_awesome_outlined),
        title: const Text('Clean up now?'),
        content: Text(
          [
            for (final r in chosen) '• ${_describe(r.kind).title}: ${plural(r.items, 'item')}',
            if (_emptyTrash) '• Empty the $systemTrashName (permanent)',
          ].join('\n'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clean up')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _running = true);
    var done = 0;
    var freed = 0;
    var inBin = 0;
    var problems = 0;
    try {
      if (chosen.isNotEmpty) {
        final targets = await results!.selectRecommendations(
          kinds: [for (final r in chosen) r.kind],
          downloads: ref.read(appPathsProvider).downloadDirs,
        );
        for (final target in targets) {
          if (!mounted) return;
          final report = await performAction(
            context,
            ref,
            ActionRequestDto(
              action: removal,
              target: target,
              keepStructure: false,
              verifyContent: settings.verifyBeforeDelete,
            ),
          );
          if (report == null) continue;
          done += report.succeeded.toInt();
          freed += report.bytesFreed.toInt();
          inBin += report.bytesInBin.toInt();
          problems += report.failed.toInt() + report.skipped.toInt();
        }
      }
      if (_emptyTrash) {
        final info = await systemTrashInfo();
        await emptySystemTrash();
        ref.invalidate(systemTrashProvider);
        final bytes = info?.bytes ?? 0;
        ref
            .read(historyProvider.notifier)
            .record(
              CleanupEvent(
                kind: CleanupKind.systemTrash,
                atMs: DateTime.now().millisecondsSinceEpoch,
                items: info?.items ?? 0,
                bytesFreed: bytes,
              ),
            );
        // What this cleanup moved there is now really freed.
        freed += bytes;
        inBin = 0;
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _running = false);
    }
    if (!mounted) return;
    final message = [
      if (done > 0) 'Cleaned up ${plural(done, 'item')}',
      if (freed > 0) '${formatBytes(freed)} freed',
      if (inBin > 0) '${formatBytes(inBin)} in the bin until it is emptied',
      if (problems > 0) '${plural(problems, 'item')} skipped',
    ].join(' · ');
    if (message.isNotEmpty) showMessage(context, message);
    Navigator.of(context).pop();
  }
}

class _RecTile extends ConsumerWidget {
  const _RecTile({required this.rec, required this.checked, required this.onChanged});

  final RecommendationDto rec;
  final bool checked;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final d = _describe(rec.kind);
    return InkWell(
      onTap: () => onChanged(!checked),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(value: checked, onChanged: (v) => onChanged(v ?? false)),
            Padding(
              padding: const EdgeInsets.only(top: 10, right: 12),
              child: Icon(d.icon, color: theme.colorScheme.onSurfaceVariant),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.title, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(d.why, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    TextButton(
                      style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                      onPressed: () {
                        Navigator.of(context).pop();
                        openResults(ref, d.list);
                      },
                      child: Text('Review ${plural(rec.items, 'item')}'),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                rec.bytes > 0 ? formatBytes(rec.bytes) : '',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
