import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/file_kind.dart';
import '../../rust/api/preview.dart';

/// Formats Flutter cannot decode itself but the system usually can show:
/// videos, documents, design files and camera RAW photos.
const _systemThumbnailExtensions = {
  // video
  'mp4', 'mkv', 'mov', 'avi', 'wmv', 'webm', 'm4v', '3gp', 'mpg', 'mpeg', 'flv',
  // audio (album art)
  'mp3', 'flac', 'm4a', 'wma', 'ogg', 'opus', 'aac',
  // documents
  'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'odt', 'ods', 'odp', 'rtf', 'epub', 'xps',
  // images Flutter does not decode
  'heic', 'heif', 'avif', 'tif', 'tiff', 'svg', 'psd', 'ico', 'jxl',
  // camera RAW
  'cr2', 'cr3', 'nef', 'arw', 'dng', 'orf', 'rw2', 'raf', 'srw', 'pef',
};

/// Whether the system may have a thumbnail worth asking for.
bool wantsSystemThumbnail(String path) =>
    SystemThumbnails.instance.supported && _systemThumbnailExtensions.contains(extensionOf(path));

/// System thumbnails (what the file manager shows), decoded off the UI
/// thread and cached.
///
/// Requests run two at a time, newest first, so the rows on screen load
/// before rows that were scrolled past. A request whose widget left the
/// screen before it started is dropped.
class SystemThumbnails {
  SystemThumbnails._();
  static final instance = SystemThumbnails._();

  late final bool supported = () {
    try {
      return systemThumbnailsSupported();
    } catch (_) {
      return false;
    }
  }();

  static const _maxConcurrent = 2;

  /// Small thumbnails for lists, and a few large ones for the preview pane.
  final _small = _Lru(300);
  final _large = _Lru(12);
  final _queue = <_Request>[];
  int _running = 0;

  /// Sizes are bucketed so neighbouring requests share cache entries.
  static int bucket(double logicalSize, double devicePixelRatio) {
    final px = logicalSize * devicePixelRatio;
    for (final b in const [64, 128, 256, 512, 1024]) {
      if (px <= b) return b;
    }
    return 1024;
  }

  /// The cached image if it is ready (no flicker when rows are rebuilt).
  ui.Image? peek(String path, int size) => _cacheFor(size).ready('$size|$path');

  /// Requests a thumbnail. Call [cancel] when the result is no longer needed.
  ThumbnailRequest load(String path, int size) {
    final key = '$size|$path';
    final cache = _cacheFor(size);
    final existing = cache.get(key);
    if (existing != null) return ThumbnailRequest._(existing, () {});
    final request = _Request(path, size, key, cache);
    cache.put(key, request.completer.future);
    _queue.add(request);
    _pump();
    return ThumbnailRequest._(request.completer.future, () {
      if (!request.started && !request.completer.isCompleted) {
        _queue.remove(request);
        cache.remove(key);
        request.completer.complete(null);
      }
    });
  }

  _Lru _cacheFor(int size) => size > 256 ? _large : _small;

  void _pump() {
    while (_running < _maxConcurrent && _queue.isNotEmpty) {
      final request = _queue.removeLast();
      request.started = true;
      _running++;
      _run(request).whenComplete(() {
        _running--;
        _pump();
      });
    }
  }

  Future<void> _run(_Request r) async {
    try {
      final dto = await systemThumbnail(path: r.path, size: r.size);
      if (dto == null) {
        r.completer.complete(null);
        return;
      }
      final done = Completer<ui.Image>();
      ui.decodeImageFromPixels(dto.bgra, dto.width, dto.height, ui.PixelFormat.bgra8888, done.complete);
      final image = await done.future;
      r.cache.markReady(r.key, image);
      r.completer.complete(image);
    } catch (_) {
      if (!r.completer.isCompleted) r.completer.complete(null);
    }
  }
}

class ThumbnailRequest {
  ThumbnailRequest._(this.image, this.cancel);
  final Future<ui.Image?> image;
  final VoidCallback cancel;
}

class _Request {
  _Request(this.path, this.size, this.key, this.cache);
  final String path;
  final int size;
  final String key;
  final _Lru cache;
  final completer = Completer<ui.Image?>();
  bool started = false;
}

/// Least-recently-used futures, with the finished images kept for [ready].
class _Lru {
  _Lru(this.capacity);
  final int capacity;
  final _map = <String, Future<ui.Image?>>{};
  final _ready = <String, ui.Image>{};

  Future<ui.Image?>? get(String key) {
    final f = _map.remove(key);
    if (f != null) _map[key] = f;
    return f;
  }

  ui.Image? ready(String key) => _ready[key];

  void put(String key, Future<ui.Image?> f) {
    _map[key] = f;
    while (_map.length > capacity) {
      final oldest = _map.keys.first;
      _map.remove(oldest);
      _ready.remove(oldest);
    }
  }

  void markReady(String key, ui.Image image) {
    if (_map.containsKey(key)) _ready[key] = image;
  }

  void remove(String key) {
    _map.remove(key);
    _ready.remove(key);
  }
}

/// Shows the system thumbnail of [path], or [fallback] while it loads or
/// when there is none.
class SystemThumbnailImage extends StatefulWidget {
  const SystemThumbnailImage({
    super.key,
    required this.path,
    required this.size,
    required this.fallback,
    this.fit = BoxFit.cover,
  });

  final String path;

  /// Logical size of the longer side to request.
  final double size;
  final Widget fallback;
  final BoxFit fit;

  @override
  State<SystemThumbnailImage> createState() => _SystemThumbnailImageState();
}

class _SystemThumbnailImageState extends State<SystemThumbnailImage> {
  ThumbnailRequest? _request;
  ui.Image? _image;
  bool _missing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_request == null) _start();
  }

  @override
  void didUpdateWidget(SystemThumbnailImage old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path || old.size != widget.size) {
      _request?.cancel();
      _image = null;
      _missing = false;
      _start();
    }
  }

  void _start() {
    final size = SystemThumbnails.bucket(widget.size, MediaQuery.devicePixelRatioOf(context));
    final cached = SystemThumbnails.instance.peek(widget.path, size);
    if (cached != null) {
      _image = cached;
      _request = null;
      return;
    }
    final request = SystemThumbnails.instance.load(widget.path, size);
    _request = request;
    request.image.then((image) {
      if (!mounted || !identical(_request, request)) return;
      setState(() {
        _image = image;
        _missing = image == null;
      });
    });
  }

  @override
  void dispose() {
    _request?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null || _missing) return widget.fallback;
    return RawImage(image: image, fit: widget.fit, filterQuality: FilterQuality.medium);
  }
}
