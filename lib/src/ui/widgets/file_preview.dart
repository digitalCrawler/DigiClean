import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../../core/file_kind.dart';
import '../../core/native.dart';
import 'common.dart';

/// Square thumbnail: a downscaled image for pictures, an icon otherwise.
/// Images are decoded at display size to keep memory low in long lists.
class FileThumbnail extends StatelessWidget {
  const FileThumbnail({super.key, required this.path, this.size = 44, this.color});

  final String path;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = color ?? scheme.primary;
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: tint.withValues(alpha: 0.12), borderRadius: BorderRadius.zero),
      child: Icon(iconForPath(path), color: tint, size: size * 0.5),
    );
    if (previewKindFor(path) != PreviewKind.image) return fallback;
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.zero,
      child: Image.file(
        File(path),
        width: size,
        height: size,
        cacheWidth: px,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}

/// Large preview used by the compare view.
class FilePreview extends StatelessWidget {
  const FilePreview({super.key, required this.path, this.height = 260});

  final String path;
  final double height;

  @override
  Widget build(BuildContext context) {
    final kind = previewKindFor(path);
    final scheme = Theme.of(context).colorScheme;
    Widget child;
    switch (kind) {
      case PreviewKind.image:
        final px = (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context)).clamp(256, 2048).round();
        child = InteractiveViewer(
          maxScale: 6,
          child: Image.file(
            File(path),
            cacheWidth: px,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => _NoPreview(path: path),
          ),
        );
      case PreviewKind.text:
        child = _TextPreview(path: path);
      default:
        child = _NoPreview(path: path);
    }
    return Container(
      height: height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.zero,
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _NoPreview extends StatelessWidget {
  const _NoPreview({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(iconForPath(path), size: 56, color: scheme.onSurfaceVariant),
          const SizedBox(height: 8),
          Text('No preview', style: TextStyle(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _TextPreview extends StatelessWidget {
  const _TextPreview({required this.path});

  final String path;
  static const _maxBytes = 32 * 1024;

  Future<String> _read() async {
    final file = File(path);
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
      future: _read(),
      builder: (context, snap) {
        if (snap.hasError) return _NoPreview(path: path);
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        return Scrollbar(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              snap.data!,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4),
            ),
          ),
        );
      },
    );
  }
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
