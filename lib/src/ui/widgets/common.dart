import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import '../theme.dart';

/// Large number with a caption, used in summaries: a caps label over the
/// figure in display type.
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.icon, this.emphasis = false});

  final String label;
  final String value;
  final IconData? icon;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Icon(icon, size: 14, color: ds.muted), const SizedBox(width: 6)],
            Flexible(
              child: Text(label.toUpperCase(), style: capsStyle(ds.muted), overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          value,
          style: displayStyle(
            emphasis ? 34 : 24,
            color: emphasis ? ds.accent : ds.ink,
          ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ],
    );
  }
}

/// Caps label that opens a group of content.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing, this.padding});

  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(title.toUpperCase(), style: capsStyle(ds.ink, size: 12).copyWith(fontWeight: FontWeight.w700)),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ds = context.ds;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  border: Border.all(color: ds.ink, width: Tokens.rule),
                ),
                child: Icon(icon, size: 32, color: ds.ink),
              ),
              const SizedBox(height: 24),
              Text(
                title,
                style: displayStyle(30, color: ds.ink),
                textAlign: TextAlign.center,
              ),
              if (message != null) ...[
                const SizedBox(height: 12),
                Text(
                  message!,
                  style: theme.textTheme.bodyMedium?.copyWith(color: ds.muted),
                  textAlign: TextAlign.center,
                ),
              ],
              if (action != null) ...[const SizedBox(height: 28), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Small square badge (e.g. "Keep", "Best"): solid [color] with a readable
/// label, or [outlined] for quieter information.
class TagChip extends StatelessWidget {
  const TagChip(this.text, {super.key, this.color, this.icon, this.outlined = false, this.caps = true});

  final String text;
  final Color? color;
  final IconData? icon;
  final bool outlined;

  /// Uppercase, tracked label (the design system's badge). Off for values
  /// such as file extensions whose case matters.
  final bool caps;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = color ?? ds.ink;
    final fg = outlined ? c : (ThemeData.estimateBrightnessForColor(c) == Brightness.dark ? Colors.white : Tokens.text);
    final style = caps
        ? capsStyle(fg, size: 10.5).copyWith(fontWeight: FontWeight.w800)
        : Theme.of(context).textTheme.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w600);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 7, vertical: caps ? 3.5 : 2.5),
      decoration: BoxDecoration(
        color: outlined ? null : c,
        border: outlined ? Border.all(color: c, width: 1.5) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 12, color: fg), const SizedBox(width: 4)],
          Text(caps ? text.toUpperCase() : text, style: style),
        ],
      ),
    );
  }
}

/// Extracts a user-facing message from engine and platform errors.
String errorMessage(Object error) {
  if (error is AnyhowException) {
    final m = error.message;
    // anyhow appends a backtrace after a blank line in debug builds.
    final firstBlock = m.split('\n\n').first.trim();
    return firstBlock.isEmpty ? m : firstBlock;
  }
  if (error is StateError) return error.message;
  return error.toString();
}

void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(errorMessage(error))));
}

void showMessage(BuildContext context, String message, {SnackBarAction? action}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), action: action, duration: const Duration(seconds: 6)));
}
