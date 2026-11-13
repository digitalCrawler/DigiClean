import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../rust/api/results.dart';
import '../../rust/api/types.dart';
import '../../state/locations.dart';
import '../../state/results_controller.dart';
import '../widgets/common.dart';

String photoIssueLabel(PhotoIssueKind k) => switch (k) {
  PhotoIssueKind.blurry => 'Blurry',
  PhotoIssueKind.dark => 'Dark',
  PhotoIssueKind.screenshot => 'Screenshot',
};

IconData photoIssueIcon(PhotoIssueKind k) => switch (k) {
  PhotoIssueKind.blurry => Icons.blur_on,
  PhotoIssueKind.dark => Icons.brightness_2_outlined,
  PhotoIssueKind.screenshot => Icons.screenshot_outlined,
};

/// Fingerprints the scan's photos, then the soundtracks of its songs and
/// videos, with a progress dialog; then reloads the results. Returns false
/// when cancelled or failed.
Future<bool> analyzePhotosFlow(BuildContext context, WidgetRef ref) async {
  final results = ref.read(resultsProvider).results;
  if (results == null) return false;
  final cacheDir = ref.read(appPathsProvider).cacheDir;
  final outcome = await showDialog<Object?>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AnalyzeDialog(results: results, cacheDir: cacheDir, threads: 0),
  );
  if (!context.mounted) return false;
  if (outcome case (final PhotoAnalysisDto photos, final MediaAnalysisDto media)) {
    ref.read(resultsProvider.notifier).refresh();
    showMessage(
      context,
      [
        'Analysed ${plural(photos.analyzed, 'photo')} and ${plural(media.analyzed, 'song or video', 'songs and videos')}',
        '${formatCount(photos.similarGroups + media.similarGroups)} similar sets',
        '${formatCount(photos.withIssues)} photos to review',
      ].join(' · '),
    );
    return true;
  }
  if (outcome != null) showError(context, outcome);
  return false;
}

class _AnalyzeDialog extends StatefulWidget {
  const _AnalyzeDialog({required this.results, required this.cacheDir, required this.threads});

  final ScanResults results;
  final String cacheDir;
  final int threads;

  @override
  State<_AnalyzeDialog> createState() => _AnalyzeDialogState();
}

class _AnalyzeDialogState extends State<_AnalyzeDialog> {
  Timer? _poll;
  int _done = 0;
  int _total = 0;
  bool _cancelling = false;
  bool _media = false;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final p = widget.results.actionProgress();
      if (!mounted) return;
      setState(() {
        _done = p.done;
        _total = p.total;
      });
    });
    _run().then<Object?>((r) => r, onError: (Object e) => _cancelling ? null : e).then((outcome) {
      if (mounted) Navigator.of(context).pop(outcome);
    });
  }

  Future<(PhotoAnalysisDto, MediaAnalysisDto)> _run() async {
    final photos = await widget.results.analyzePhotos(cacheDir: widget.cacheDir, threads: widget.threads);
    if (mounted) setState(() => _media = true);
    final media = await widget.results.analyzeMedia(cacheDir: widget.cacheDir, threads: widget.threads);
    return (photos, media);
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(_media ? 'Analysing music and videos' : 'Analysing photos'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
            const SizedBox(height: 12),
            Text(
              _total == 0
                  ? 'Looking for files…'
                  : '${formatCount(_done)} of ${formatCount(_total)} ${_media ? 'songs and videos' : 'photos'}',
            ),
            const SizedBox(height: 4),
            Text(
              _media
                  ? 'Songs and videos are compared by how they sound. Unchanged files are read only once.'
                  : 'Photos are compared by what they look like. Unchanged photos are read only once.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _cancelling
                ? null
                : () {
                    setState(() => _cancelling = true);
                    widget.results.cancelAction();
                  },
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

/// Shown on the photos tab until the photos are analysed.
class PhotoAnalyzeCard extends ConsumerWidget {
  const PhotoAnalyzeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return EmptyState(
      icon: Icons.photo_library_outlined,
      title: 'Find similar photos, music and videos',
      message:
          'Photos are compared by what they look like, so resized, re-saved and burst shots are found; '
          'songs and videos by how they sound, so copies in another format or quality are found. '
          'The best copy is suggested. Also finds blurry and dark photos and screenshots.',
      action: FilledButton.icon(
        onPressed: () => analyzePhotosFlow(context, ref),
        icon: const Icon(Icons.auto_awesome_outlined),
        label: const Text('Analyse media'),
      ),
    );
  }
}
