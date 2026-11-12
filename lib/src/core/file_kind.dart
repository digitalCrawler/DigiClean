import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../rust/api/types.dart';

enum PreviewKind { image, text, video, audio, pdf, archive, other }

const _imageExtensions = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'wbmp'};
// Decoded by the platform codecs on Apple devices and Android 9+.
const _platformImageExtensions = {'heic', 'heif', 'avif'};
const _textExtensions = {
  'txt',
  'md',
  'csv',
  'tsv',
  'json',
  'xml',
  'yaml',
  'yml',
  'log',
  'ini',
  'cfg',
  'conf',
  'toml',
  'html',
  'htm',
  'css',
  'js',
  'ts',
  'dart',
  'rs',
  'py',
  'java',
  'kt',
  'swift',
  'c',
  'h',
  'cpp',
  'hpp',
  'cs',
  'go',
  'rb',
  'php',
  'sh',
  'bat',
  'ps1',
  'sql',
  'srt',
  'vtt',
  'gradle',
  'properties',
};
const _videoExtensions = {'mp4', 'mkv', 'mov', 'avi', 'wmv', 'webm', 'm4v', '3gp', 'mpg', 'mpeg', 'flv'};
const _audioExtensions = {'mp3', 'wav', 'flac', 'aac', 'ogg', 'opus', 'm4a', 'wma', 'aiff', 'amr'};
const _archiveExtensions = {'zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'xz', 'zst', 'iso'};

String extensionOf(String path) {
  final ext = p.extension(path);
  return ext.isEmpty ? '' : ext.substring(1).toLowerCase();
}

PreviewKind previewKindFor(String path) {
  final ext = extensionOf(path);
  if (_imageExtensions.contains(ext)) return PreviewKind.image;
  if (_platformImageExtensions.contains(ext) && (Platform.isIOS || Platform.isMacOS || Platform.isAndroid)) {
    return PreviewKind.image;
  }
  if (_textExtensions.contains(ext)) return PreviewKind.text;
  if (_videoExtensions.contains(ext)) return PreviewKind.video;
  if (_audioExtensions.contains(ext)) return PreviewKind.audio;
  if (ext == 'pdf') return PreviewKind.pdf;
  if (_archiveExtensions.contains(ext)) return PreviewKind.archive;
  return PreviewKind.other;
}

IconData categoryIcon(Category c) => switch (c) {
  Category.image => Icons.image_outlined,
  Category.video => Icons.movie_outlined,
  Category.audio => Icons.music_note_outlined,
  Category.document => Icons.description_outlined,
  Category.archive => Icons.folder_zip_outlined,
  Category.application => Icons.apps_outlined,
  Category.other => Icons.insert_drive_file_outlined,
};

String categoryLabel(Category c) => switch (c) {
  Category.image => 'Images',
  Category.video => 'Videos',
  Category.audio => 'Audio',
  Category.document => 'Documents',
  Category.archive => 'Archives',
  Category.application => 'Apps',
  Category.other => 'Other',
};

/// Distinct hues per category that read well on both light and dark themes.
Color categoryColor(Category c, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return switch (c) {
    Category.image => dark ? const Color(0xFF7FB3FF) : const Color(0xFF2563EB),
    Category.video => dark ? const Color(0xFFFF9EB1) : const Color(0xFFDB2777),
    Category.audio => dark ? const Color(0xFFC4A5FF) : const Color(0xFF7C3AED),
    Category.document => dark ? const Color(0xFF6EE7C8) : const Color(0xFF0F9F7A),
    Category.archive => dark ? const Color(0xFFFFC27A) : const Color(0xFFD97706),
    Category.application => dark ? const Color(0xFF9DD3FF) : const Color(0xFF0284C7),
    Category.other => dark ? const Color(0xFFB8C0CC) : const Color(0xFF64748B),
  };
}

IconData iconForPath(String path) => switch (previewKindFor(path)) {
  PreviewKind.image => Icons.image_outlined,
  PreviewKind.text => Icons.article_outlined,
  PreviewKind.video => Icons.movie_outlined,
  PreviewKind.audio => Icons.music_note_outlined,
  PreviewKind.pdf => Icons.picture_as_pdf_outlined,
  PreviewKind.archive => Icons.folder_zip_outlined,
  PreviewKind.other => Icons.insert_drive_file_outlined,
};
