import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../../core/file_kind.dart';
import '../../core/format.dart';
import '../../core/native.dart';
import '../../rust/api/preview.dart';
import '../theme.dart';
import 'common.dart';
import 'thumbnails.dart';

/// Square thumbnail for lists: a downscaled picture for images, the system's
/// thumbnail for videos, documents and RAW photos where available, an icon
/// otherwise. Everything is decoded at display size to keep memory low.
class FileThumbnail extends StatelessWidget {
  const FileThumbnail({super.key, required this.path, this.size = 44, this.color});

  final String path;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Theme.of(context).colorScheme.primary;
    final fallback = Container(
      width: size,
      height: size,
      color: tint.withValues(alpha: 0.12),
      child: Icon(iconForPath(path), color: tint, size: size * 0.5),
    );
    Widget child;
    if (previewKindFor(path) == PreviewKind.image) {
      final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
      child = Image.file(
        File(path),
        width: size,
        height: size,
        cacheWidth: px,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => fallback,
      );
    } else if (wantsSystemThumbnail(path)) {
      child = SystemThumbnailImage(path: path, size: size, fallback: fallback);
    } else {
      return fallback;
    }
    return SizedBox(width: size, height: size, child: child);
  }
}

/// Whether [FilePreview] can show more than an icon for [path].
bool hasRichPreview(String path) => switch (previewKindFor(path)) {
  PreviewKind.image || PreviewKind.text || PreviewKind.video || PreviewKind.audio => true,
  PreviewKind.archive => extensionOf(path) == 'zip',
  _ => wantsSystemThumbnail(path),
};

/// Large preview of any file: zoomable images, video frames, album art and
/// waveforms, text, archive contents and document thumbnails.
class FilePreview extends StatelessWidget {
  const FilePreview({super.key, required this.path, this.height = 260});

  final String path;
  final double height;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final kind = previewKindFor(path);
    final Widget child = switch (kind) {
      PreviewKind.image => _ImagePreview(path: path),
      PreviewKind.text => _TextPreview(path: path),
      PreviewKind.video => _VideoPreview(path: path),
      PreviewKind.audio => _AudioPreview(path: path),
      PreviewKind.archive when extensionOf(path) == 'zip' => _ZipPreview(path: path),
      _ when wantsSystemThumbnail(path) => _SystemPreview(path: path),
      _ => _NoPreview(path: path),
    };
    return Container(
      height: height,
      width: double.infinity,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(color: ds.surfaceStrong),
      child: kind == PreviewKind.text ? child : _Deferred(key: ValueKey(path), child: child),
    );
  }
}

/// Builds [child] only once the preview has been on screen briefly, so
/// moving quickly through a list (holding the arrow key) decodes one
/// preview instead of every one passed on the way.
class _Deferred extends StatefulWidget {
  const _Deferred({super.key, required this.child});

  final Widget child;

  @override
  State<_Deferred> createState() => _DeferredState();
}

class _DeferredState extends State<_Deferred> {
  bool _ready = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 90), () {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ready ? widget.child : const SizedBox.expand();
}

class _ImagePreview extends StatelessWidget {
  const _ImagePreview({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final px = (box.maxWidth * MediaQuery.devicePixelRatioOf(context)).clamp(256, 2048).round();
        return InteractiveViewer(
          maxScale: 8,
          child: Center(
            child: Image.file(
              File(path),
              cacheWidth: px,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => _SystemPreview(path: path),
            ),
          ),
        );
      },
    );
  }
}

/// The system thumbnail at preview size (documents, RAW photos…).
class _SystemPreview extends StatelessWidget {
  const _SystemPreview({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => Center(
        child: SystemThumbnailImage(
          path: path,
          size: box.biggest.shortestSide.clamp(128, 1024),
          fit: BoxFit.contain,
          fallback: _NoPreview(path: path),
        ),
      ),
    );
  }
}

class _VideoPreview extends StatelessWidget {
  const _VideoPreview({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Stack(
      fit: StackFit.expand,
      children: [
        LayoutBuilder(
          builder: (context, box) => SystemThumbnailImage(
            path: path,
            size: box.biggest.shortestSide.clamp(128, 1024),
            fit: BoxFit.contain,
            fallback: Center(child: Icon(Icons.movie_outlined, size: 56, color: ds.muted)),
          ),
        ),
        Center(
          child: Material(
            color: ds.ink.withValues(alpha: 0.82),
            shape: const CircleBorder(),
            child: IconButton(
              tooltip: 'Play',
              iconSize: 40,
              color: Theme.of(context).colorScheme.surface,
              icon: const Icon(Icons.play_arrow_rounded),
              onPressed: () => openFile(context, path),
            ),
          ),
        ),
        Positioned(
          left: 12,
          bottom: 12,
          child: FutureBuilder<AudioPreviewDto>(
            future: AudioPreviews.load(path, waveform: false),
            builder: (context, snap) {
              final ms = snap.data?.durationMs;
              if (ms == null) return const SizedBox.shrink();
              return TagChip(formatClock(ms), color: ds.ink, caps: false);
            },
          ),
        ),
      ],
    );
  }
}

/// Album art, tags and a waveform.
class _AudioPreview extends StatelessWidget {
  const _AudioPreview({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ds = context.ds;
    return FutureBuilder<AudioPreviewDto>(
      future: AudioPreviews.load(path, waveform: true),
      builder: (context, snap) {
        final a = snap.data;
        final facts = [
          if (a?.durationMs != null) formatClock(a!.durationMs!),
          if (a?.codec != null) a!.codec!.toUpperCase(),
          if (a?.sampleRate != null) '${(a!.sampleRate! / 1000).toStringAsFixed(1)} kHz',
          if (a?.channels != null) a!.channels == 1 ? 'mono' : (a.channels == 2 ? 'stereo' : '${a.channels} ch'),
        ];
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 88,
                    height: 88,
                    child: FileThumbnail(path: path, size: 88, color: ds.ink),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          a?.title ?? fileNameOf(path),
                          style: displayStyle(22, color: ds.ink),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (a?.artist != null || a?.album != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              [?a?.artist, ?a?.album].join(' · '),
                              style: theme.textTheme.bodyMedium,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        if (facts.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(facts.join(' · '), style: theme.textTheme.bodySmall),
                          ),
                      ],
                    ),
                  ),
                  IconButton.filled(
                    tooltip: 'Play',
                    style: IconButton.styleFrom(backgroundColor: ds.accent, foregroundColor: ds.onAccent),
                    icon: const Icon(Icons.play_arrow_rounded),
                    onPressed: () => openFile(context, path),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: snap.hasError
                    ? Center(child: Text('Cannot read this recording', style: theme.textTheme.bodySmall))
                    : a == null
                    ? const SizedBox.shrink()
                    : a.peaks.isEmpty
                    ? const SizedBox.shrink()
                    : Waveform(peaks: a.peaks, color: ds.ink),
              ),
              if (a != null && a.durationMs != null && a.decodedMs + 1000 < a.durationMs!)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('Waveform of the first ${formatClock(a.decodedMs)}', style: theme.textTheme.bodySmall),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Loudness bars, one per peak.
class Waveform extends StatelessWidget {
  const Waveform({super.key, required this.peaks, required this.color});

  final List<int> peaks;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _WaveformPainter(peaks, color), size: Size.infinite);
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter(this.peaks, this.color);

  final List<int> peaks;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty || size.isEmpty) return;
    final paint = Paint()..color = color;
    final step = size.width / peaks.length;
    final bar = (step * 0.62).clamp(1.0, 6.0);
    final mid = size.height / 2;
    for (var i = 0; i < peaks.length; i++) {
      final h = (peaks[i] / 255 * size.height).clamp(2.0, size.height);
      canvas.drawRect(Rect.fromLTWH(i * step + (step - bar) / 2, mid - h / 2, bar, h), paint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) => !identical(old.peaks, peaks) || old.color != color;
}

/// Previews of songs and video soundtracks, cached by path.
abstract final class AudioPreviews {
  static final _cache = <String, Future<AudioPreviewDto>>{};
  static const _capacity = 40;

  static Future<AudioPreviewDto> load(String path, {required bool waveform}) {
    final key = '${waveform ? 'w' : 'i'}|$path';
    final hit = _cache.remove(key);
    if (hit != null) return _cache[key] = hit;
    final f = audioPreview(path: path, bars: 160, waveform: waveform);
    _cache[key] = f;
    // Forget failures so a later visit can try again.
    f.then<void>(
      (_) {},
      onError: (Object _) {
        _cache.remove(key);
      },
    );
    while (_cache.length > _capacity) {
      _cache.remove(_cache.keys.first);
    }
    return f;
  }
}

class _ZipPreview extends StatefulWidget {
  const _ZipPreview({required this.path});

  final String path;

  @override
  State<_ZipPreview> createState() => _ZipPreviewState();
}

class _ZipPreviewState extends State<_ZipPreview> {
  late final Future<ArchiveListingDto> _listing = archiveListing(path: widget.path, limit: 300);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<ArchiveListingDto>(
      future: _listing,
      builder: (context, snap) {
        if (snap.hasError) return _NoPreview(path: widget.path);
        final l = snap.data;
        if (l == null) return const SizedBox.shrink();
        final more = l.totalEntries - l.entries.length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                '${plural(l.totalEntries, 'item')} inside · ${formatBytes(l.totalBytes)} unpacked',
                style: capsStyle(context.ds.muted),
              ),
            ),
            Expanded(
              child: Scrollbar(
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 8),
                  itemExtent: 30,
                  itemCount: l.entries.length + (more > 0 ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i == l.entries.length) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text('… and ${formatCount(more)} more', style: theme.textTheme.bodySmall),
                      );
                    }
                    final e = l.entries[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Icon(e.isDir ? Icons.folder_outlined : iconForPath(e.name), size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              e.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(color: context.ds.ink),
                            ),
                          ),
                          if (!e.isDir) Text(formatBytes(e.size), style: theme.textTheme.bodySmall),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _NoPreview extends StatelessWidget {
  const _NoPreview({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final ext = extensionOf(path);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(iconForPath(path), size: 56, color: ds.ink),
          const SizedBox(height: 10),
          Text(ext.isEmpty ? 'No preview' : '.${ext.toUpperCase()} — no preview', style: capsStyle(ds.muted)),
        ],
      ),
    );
  }
}

class _TextPreview extends StatefulWidget {
  const _TextPreview({required this.path});

  final String path;

  @override
  State<_TextPreview> createState() => _TextPreviewState();
}

class _TextPreviewState extends State<_TextPreview> {
  static const _maxBytes = 32 * 1024;
  late final Future<String> _text = _read();

  Future<String> _read() async {
    final file = File(widget.path);
    final raf = await file.open();
    try {
      final bytes = await raf.read(_maxBytes);
      final text = utf8.decode(bytes, allowMalformed: true);
      final truncated = await file.length() > _maxBytes;
      return truncated ? '$text\n…' : text;
    } finally {
      await raf.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _text,
      builder: (context, snap) {
        if (snap.hasError) return _NoPreview(path: widget.path);
        if (!snap.hasData) return const SizedBox.shrink();
        return Scrollbar(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(14),
            child: SelectableText(
              snap.data!,
              style: TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.45, color: context.ds.ink),
            ),
          ),
        );
      },
    );
  }
}

/// "3:07" or "1:02:45".
String formatClock(int ms) {
  final s = ms ~/ 1000;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
}

String fileNameOf(String path) {
  final parts = path.split(RegExp(r'[\\/]'));
  return parts.isEmpty ? path : parts.last;
}

/// Opens a file with the default application.
Future<void> openFile(BuildContext context, String path) async {
  if (Platform.isAndroid) {
    // Own FileProvider: no extra media permissions needed.
    final opened = await NativePlatform.openFileAndroid(path);
    if (!opened && context.mounted) showMessage(context, 'No app can open this file');
    return;
  }
  final result = await OpenFilex.open(path);
  if (result.type != ResultType.done && context.mounted) {
    showMessage(context, result.message.isEmpty ? 'No app can open this file' : result.message);
  }
}

Future<void> revealFile(String path) => NativePlatform.revealInFileManager(path);
