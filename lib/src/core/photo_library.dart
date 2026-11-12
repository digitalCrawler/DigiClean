import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A photo in the iOS Photos library, with a small preview file.
class LibraryPhoto {
  const LibraryPhoto({
    required this.id,
    required this.preview,
    required this.width,
    required this.height,
    required this.createdMs,
    this.screenshot = false,
    this.favorite = false,
  });

  factory LibraryPhoto.fromMap(Map<dynamic, dynamic> m) => LibraryPhoto(
    id: m['id'] as String,
    preview: m['file'] as String,
    width: (m['width'] as num?)?.toInt() ?? 0,
    height: (m['height'] as num?)?.toInt() ?? 0,
    createdMs: (m['created'] as num?)?.toInt() ?? 0,
    screenshot: m['screenshot'] as bool? ?? false,
    favorite: m['favorite'] as bool? ?? false,
  );

  /// PhotoKit local identifier.
  final String id;
  final String preview;
  final int width;
  final int height;
  final int createdMs;
  final bool screenshot;
  final bool favorite;
}

enum LibraryAccess { granted, limited, denied }

/// Access to the device photo library. On iOS this is PhotoKit; tests
/// provide their own.
abstract class PhotoLibrarySource {
  Future<LibraryAccess> requestAccess();

  /// Writes previews into [dir] and lists the photos, newest first.
  Future<List<LibraryPhoto>> exportPreviews(String dir);

  /// Deletes photos; returns how many were deleted (0 if the user declined).
  Future<int> delete(List<String> ids);
}

class IosPhotoLibrary implements PhotoLibrarySource {
  static const _channel = MethodChannel('digiclean/platform');

  @override
  Future<LibraryAccess> requestAccess() async => switch (await _channel.invokeMethod<String>('photoLibraryAccess')) {
    'granted' => LibraryAccess.granted,
    'limited' => LibraryAccess.limited,
    _ => LibraryAccess.denied,
  };

  @override
  Future<List<LibraryPhoto>> exportPreviews(String dir) async {
    final list = await _channel.invokeMethod<List<dynamic>>('exportPhotoPreviews', {'dir': dir}) ?? const [];
    return list.whereType<Map<dynamic, dynamic>>().map(LibraryPhoto.fromMap).toList();
  }

  @override
  Future<int> delete(List<String> ids) async => (await _channel.invokeMethod<int>('deletePhotos', {'ids': ids})) ?? 0;
}

/// Overridden in tests; only iOS has a photo library to read.
final photoLibrarySourceProvider = Provider<PhotoLibrarySource?>((ref) => Platform.isIOS ? IosPhotoLibrary() : null);
