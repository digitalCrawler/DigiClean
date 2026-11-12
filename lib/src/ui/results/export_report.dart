import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../rust/api/results.dart';
import '../../rust/api/types.dart';
import '../widgets/common.dart';
import '../widgets/file_preview.dart';

const _formats = [
  (format: ReportFormat.csv, ext: 'csv', mime: 'text/csv', title: 'Spreadsheet (CSV)', hint: 'One row per item'),
  (format: ReportFormat.html, ext: 'html', mime: 'text/html', title: 'Web page (HTML)', hint: 'To read or print'),
  (format: ReportFormat.json, ext: 'json', mime: 'application/json', title: 'JSON', hint: 'For scripts and tools'),
];

/// Asks for a format, renders a report of the results and saves it where
/// the user chooses.
Future<void> exportReportFlow(BuildContext context, ScanResults results) async {
  final choice = await showDialog<int>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Export report'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(
            'Lists the duplicates, large files and empty folders shown in the results, '
            'and what is selected for removal. Nothing is changed.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        for (var i = 0; i < _formats.length; i++)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, i),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_formats[i].title),
              subtitle: Text(_formats[i].hint),
            ),
          ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return;
  final f = _formats[choice];
  try {
    final bytes = await results.exportReport(format: f.format, utcOffsetMin: DateTime.now().timeZoneOffset.inMinutes);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final uri = await FilePicker.saveFile(
      dialogTitle: 'Save report',
      fileName: 'digiclean-report-${now.year}-${two(now.month)}-${two(now.day)}.${f.ext}',
      bytes: bytes,
      mimeType: f.mime,
    );
    if (uri == null || !context.mounted) return;
    final path = uri.isScheme('file') ? uri.toFilePath() : null;
    showMessage(
      context,
      'Report saved',
      action: path != null && !Platform.isAndroid && !Platform.isIOS
          ? SnackBarAction(label: 'Open', onPressed: () => openFile(context, path))
          : null,
    );
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}
