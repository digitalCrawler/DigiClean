import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/path_display.dart';
import '../../rust/api/results.dart';
import '../../rust/api/types.dart';
import '../../state/locations.dart';
import '../../state/results_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/file_preview.dart';
import '../widgets/path_text.dart';

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

/// A set of similar photos as a grid of thumbnails, best shot first.
class SimilarGroupCard extends StatelessWidget {
  const SimilarGroupCard({super.key, required this.group, required this.onSelect});

  final SimilarGroupDto group;
  final void Function(int id, bool selected) onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final locations = GroupLocations.of([for (final p in group.photos) p.parent]);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${group.photos.length} similar photos'
                    '${locations.prefixLabel.isEmpty ? '' : ' · in ${locations.prefixLabel}'}',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  '${formatBytes(group.reclaimable)} to free',
                  style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (var i = 0; i < group.photos.length; i++)
                  _PhotoTile(photo: group.photos[i], location: locations.segmentsOf(i), onSelect: onSelect),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({required this.photo, required this.location, required this.onSelect});

  final PhotoDto photo;
  final List<String> location;
  final void Function(int id, bool selected) onSelect;

  static const double _size = 148;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return SizedBox(
      width: _size,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              InkWell(
                borderRadius: BorderRadius.zero,
                onTap: () => openFile(context, photo.path),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.zero,
                    border: Border.all(
                      width: 3,
                      color: photo.selected
                          ? scheme.error
                          : photo.best
                          ? scheme.primary
                          : Colors.transparent,
                    ),
                  ),
                  child: FileThumbnail(path: photo.path, size: _size - 6),
                ),
              ),
              Positioned(
                top: 4,
                left: 4,
                child: Material(
                  color: scheme.surface.withValues(alpha: 0.85),
                  shape: const RoundedRectangleBorder(),
                  child: Checkbox(value: photo.selected, onChanged: (v) => onSelect(photo.id, v ?? false)),
                ),
              ),
              if (photo.best) Positioned(bottom: 8, left: 8, child: TagChip('Best', color: context.ds.accent)),
            ],
          ),
          const SizedBox(height: 4),
          Text(photo.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
          PathSegmentsText(location, tooltip: photo.path, style: small),
          Text(
            [if (photo.width > 0) '${photo.width}×${photo.height}', formatBytes(photo.size)].join(' · '),
            style: small,
          ),
        ],
      ),
    );
  }
}

/// One blurry, dark or screenshot image.
class PhotoIssueTile extends StatelessWidget {
  const PhotoIssueTile({super.key, required this.photo, required this.roots, required this.onSelect});

  final PhotoDto photo;
  final List<String> roots;
  final void Function(int id, bool selected) onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Card(
      child: Material(
        color: photo.selected ? scheme.errorContainer.withValues(alpha: dark ? 0.28 : 0.4) : Colors.transparent,
        child: InkWell(
          onTap: () => onSelect(photo.id, !photo.selected),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
            child: Row(
              children: [
                Checkbox(value: photo.selected, onChanged: (v) => onSelect(photo.id, v ?? false)),
                InkWell(
                  onTap: () => openFile(context, photo.path),
                  child: FileThumbnail(path: photo.path, size: 64),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        photo.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      PathSegmentsText(segmentsUnderRoot(photo.parent, roots), tooltip: photo.path, style: small),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final k in photo.issues) TagChip(photoIssueLabel(k), color: scheme.tertiary),
                          if (photo.width > 0) Text('${photo.width}×${photo.height}', style: small),
                        ],
                      ),
                    ],
                  ),
                ),
                Text(
                  formatBytes(photo.size),
                  style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _duration(int ms) {
  final s = ms ~/ 1000;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
}

/// A set of songs or videos with the same soundtrack, best copy first.
class MediaGroupCard extends StatelessWidget {
  const MediaGroupCard({super.key, required this.group, required this.onSelect});

  final MediaGroupDto group;
  final void Function(int id, bool selected) onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final locations = GroupLocations.of([for (final m in group.items) m.parent]);
    final video = group.items.any((m) => m.video);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(video ? Icons.movie_outlined : Icons.music_note_outlined, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${group.items.length} copies of the same ${video ? 'video' : 'song'}',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  '${formatBytes(group.reclaimable)} to free',
                  style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (var i = 0; i < group.items.length; i++)
              Builder(
                builder: (context) {
                  final m = group.items[i];
                  return InkWell(
                    onTap: () => onSelect(m.id, !m.selected),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Checkbox(value: m.selected, onChanged: (v) => onSelect(m.id, v ?? false)),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    if (m.best) ...[TagChip('Best', color: context.ds.accent), const SizedBox(width: 6)],
                                    Expanded(
                                      child: Text(
                                        m.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodyMedium,
                                      ),
                                    ),
                                  ],
                                ),
                                PathSegmentsText(locations.segmentsOf(i), tooltip: m.path, style: small),
                                Text(
                                  [if (m.durationMs != null) _duration(m.durationMs!), formatBytes(m.size)].join(' · '),
                                  style: small,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Play',
                            icon: const Icon(Icons.play_circle_outline),
                            onPressed: () => openFile(context, m.path),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
