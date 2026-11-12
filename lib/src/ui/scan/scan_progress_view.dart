import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../rust/api/types.dart';
import '../../state/scan_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Live view of a running scan: pipeline stage, throughput and controls.
class ScanProgressView extends ConsumerWidget {
  const ScanProgressView({super.key});

  static const _stages = [
    (Phase.discovering, 'Discover', Icons.travel_explore),
    (Phase.partialHashing, 'Fingerprint', Icons.fingerprint),
    (Phase.fullHashing, 'Hash', Icons.tag),
    (Phase.analyzingFolders, 'Folders', Icons.account_tree_outlined),
  ];

  static int _stageIndex(Phase p) => switch (p) {
    Phase.discovering || Phase.groupingBySize => 0,
    Phase.partialHashing => 1,
    Phase.fullHashing || Phase.verifying => 2,
    Phase.analyzingFolders || Phase.finalizing || Phase.done => 3,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scan = ref.watch(scanProvider);
    final notifier = ref.read(scanProvider.notifier);
    final p = scan.progress;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final phase = p?.phase ?? Phase.discovering;
    final stage = _stageIndex(phase);
    final determinate = p != null && p.phaseBytesTotal > 0 && phase != Phase.discovering;
    final fraction = determinate ? (p.phaseBytesDone / p.phaseBytesTotal).clamp(0.0, 1.0) : null;

    return Scaffold(
      appBar: AppBar(title: Text(scan.paused ? 'Scan paused' : 'Scanning…')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                _StageStepper(current: stage, stages: _stages),
                const SizedBox(height: 32),
                Center(
                  child: SizedBox(
                    width: 180,
                    height: 180,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CircularProgressIndicator(
                          value: fraction,
                          strokeWidth: 10,
                          strokeCap: StrokeCap.round,
                          backgroundColor: scheme.surfaceContainerHighest,
                        ),
                        Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                fraction == null
                                    ? formatCount(p?.filesDiscovered ?? 0)
                                    : '${(fraction * 100).floor()}%',
                                style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              Text(
                                fraction == null ? 'files found' : phaseLabel(phase),
                                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Text(phaseLabel(phase), style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
                const SizedBox(height: 6),
                Text(
                  middleEllipsis(p?.currentPath ?? 'Preparing…', 64),
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                ),
                const SizedBox(height: 28),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Wrap(
                      spacing: 32,
                      runSpacing: 20,
                      children: [
                        StatTile(
                          label: 'Files',
                          value: formatCount(p?.filesDiscovered ?? 0),
                          icon: Icons.description_outlined,
                        ),
                        StatTile(
                          label: 'Folders',
                          value: formatCount(p?.dirsDiscovered ?? 0),
                          icon: Icons.folder_outlined,
                        ),
                        StatTile(
                          label: 'Data',
                          value: formatBytes(p?.bytesDiscovered ?? 0),
                          icon: Icons.storage_outlined,
                        ),
                        if ((p?.candidates ?? 0) > 0)
                          StatTile(
                            label: 'Possible duplicates',
                            value: formatCount(p!.candidates),
                            icon: Icons.filter_alt_outlined,
                          ),
                        if ((p?.bytesPerSecond ?? 0) > 0)
                          StatTile(label: 'Speed', value: '${formatBytes(p!.bytesPerSecond)}/s', icon: Icons.speed),
                        if (p?.etaMs != null && !scan.paused)
                          StatTile(
                            label: 'Remaining',
                            value: formatDuration(Duration(milliseconds: p!.etaMs!)),
                            icon: Icons.timer_outlined,
                          ),
                        StatTile(
                          label: 'Elapsed',
                          value: formatDuration(Duration(milliseconds: p?.elapsedMs ?? 0)),
                          icon: Icons.schedule,
                        ),
                        if ((p?.cacheHits ?? 0) > 0)
                          StatTile(label: 'From cache', value: formatCount(p!.cacheHits), icon: Icons.bolt_outlined),
                        if ((p?.errors ?? 0) > 0)
                          StatTile(
                            label: 'Unreadable',
                            value: formatCount(p!.errors),
                            icon: Icons.warning_amber_outlined,
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: scan.paused ? notifier.resume : notifier.pause,
                        icon: Icon(scan.paused ? Icons.play_arrow : Icons.pause),
                        label: Text(scan.paused ? 'Resume' : 'Pause'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: notifier.cancel,
                        icon: const Icon(Icons.stop),
                        label: const Text('Cancel'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'You can keep using your device. Scanning continues in the background.',
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StageStepper extends StatelessWidget {
  const _StageStepper({required this.current, required this.stages});

  final int current;
  final List<(Phase, String, IconData)> stages;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final children = <Widget>[];
    for (var i = 0; i < stages.length; i++) {
      final done = i < current;
      final active = i == current;
      final color = done || active ? scheme.primary : scheme.outline;
      children.add(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: active ? context.ds.accent : (done ? scheme.primary : scheme.surfaceContainerLowest),
                border: Border.all(color: active ? context.ds.accent : scheme.primary, width: Tokens.control),
              ),
              child: Icon(
                done ? Icons.check : stages[i].$3,
                size: 20,
                color: active ? context.ds.onAccent : (done ? scheme.onPrimary : scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 6),
            Text(stages[i].$2, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color)),
          ],
        ),
      );
      if (i < stages.length - 1) {
        children.add(
          Expanded(
            child: Container(
              height: 2,
              margin: const EdgeInsets.only(bottom: 20, left: 4, right: 4),
              color: i < current ? scheme.primary : scheme.outlineVariant,
            ),
          ),
        );
      }
    }
    return Row(children: children);
  }
}
