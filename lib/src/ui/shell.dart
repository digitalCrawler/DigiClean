import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/background_check.dart';
import '../state/locations.dart';
import '../state/navigation.dart';
import '../state/recovery_controller.dart';
import '../state/results_controller.dart';
import '../state/scan_controller.dart';
import '../state/settings.dart';
import '../state/upkeep.dart';
import 'home/home_page.dart';
import 'recovery/recovery_page.dart';
import 'results/results_page.dart';
import 'settings/settings_page.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// Top-level navigation: bottom bar on phones, rail on tablets/desktop.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  late final AppLifecycleListener _lifecycle;

  static const _destinations = [
    (icon: Icons.pie_chart_outline, selected: Icons.pie_chart, label: 'Storage'),
    (icon: Icons.copy_all_outlined, selected: Icons.copy_all, label: 'Results'),
    (icon: Icons.restore_from_trash_outlined, selected: Icons.restore_from_trash, label: 'Recovery'),
    (icon: Icons.settings_outlined, selected: Icons.settings, label: 'Settings'),
  ];

  @override
  void initState() {
    super.initState();
    // Keep the results across restarts: save whenever the app may be
    // stopped, and wait for the save before a desktop window closes.
    _lifecycle = AppLifecycleListener(
      onHide: _saveResults,
      onPause: _saveResults,
      onExitRequested: () async {
        await _saveResults();
        return AppExitResponse.exit;
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(resultsProvider.notifier).restoreSaved().whenComplete(() {
        if (mounted) ref.read(upkeepProvider.notifier).start();
      });
      ref.read(locationsProvider.notifier).restoreAccess();
      // Apply the Recovery Bin retention policy.
      final days = ref.read(settingsProvider).recoveryRetentionDays;
      ref.read(recoveryProvider.notifier).purgeExpired(days).catchError((_) {});
    });
  }

  Future<void> _saveResults() async {
    await ref.read(resultsProvider.notifier).save();
    // The background check scans what the app would scan.
    await ref.read(backgroundCheckProvider).refresh();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _select(int i) => ref.read(appTabProvider.notifier).state = AppTab.values[i];

  @override
  Widget build(BuildContext context) {
    ref.listen(scanProvider.select((s) => s.status), (previous, status) {
      if (previous != ScanStatus.running) return;
      switch (status) {
        case ScanStatus.completed:
          ref.read(appTabProvider.notifier).state = AppTab.results;
          ref.read(scanProvider.notifier).acknowledge();
        case ScanStatus.cancelled:
          showMessage(context, 'Scan cancelled');
          ref.read(scanProvider.notifier).acknowledge();
        case ScanStatus.failed:
          final error = ref.read(scanProvider).error ?? 'Scan failed';
          showMessage(context, error);
          ref.read(scanProvider.notifier).acknowledge();
        default:
      }
    });

    final index = ref.watch(appTabProvider).index;
    final hasResults = ref.watch(resultsProvider.select((r) => r.hasResults));
    final scanning = ref.watch(scanProvider.select((s) => s.isRunning));

    final pages = [
      const HomePage(),
      ResultsPage(onStartScan: () => _select(0)),
      const RecoveryPage(),
      const SettingsPage(),
    ];
    final body = IndexedStack(index: index, children: pages);

    Widget iconFor(int i, {required bool selected}) {
      final d = _destinations[i];
      final icon = Icon(selected ? d.selected : d.icon);
      if (i == 0 && scanning) {
        return Badge(smallSize: 8, child: icon);
      }
      if (i == 1 && hasResults) {
        final count = ref.watch(resultsProvider.select((r) => r.summary?.activeFileGroups ?? 0));
        return count > 0 ? Badge(label: Text(count > 999 ? '999+' : '$count'), child: icon) : icon;
      }
      return icon;
    }

    if (context.isCompact) {
      return Scaffold(
        body: body,
        bottomNavigationBar: DecoratedBox(
          // Drawn over the bar, whose own background would hide it.
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(border: Border(top: context.ds.rule)),
          child: NavigationBar(
            selectedIndex: index,
            onDestinationSelected: _select,
            destinations: [
              for (var i = 0; i < _destinations.length; i++)
                NavigationDestination(
                  icon: iconFor(i, selected: false),
                  selectedIcon: iconFor(i, selected: true),
                  label: _destinations[i].label,
                ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: index,
            onDestinationSelected: _select,
            extended: context.isExpanded,
            minExtendedWidth: 200,
            labelType: context.isExpanded ? NavigationRailLabelType.none : NavigationRailLabelType.all,
            leading: Padding(
              padding: const EdgeInsets.fromLTRB(4, 18, 4, 20),
              child: _Logo(extended: context.isExpanded),
            ),
            destinations: [
              for (var i = 0; i < _destinations.length; i++)
                NavigationRailDestination(
                  icon: iconFor(i, selected: false),
                  selectedIcon: iconFor(i, selected: true),
                  label: Text(_destinations[i].label),
                ),
            ],
          ),
          VerticalDivider(width: Tokens.rule, thickness: Tokens.rule, color: context.ds.ink),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// The wordmark: an accent square and "DigiClean" in display type.
class _Logo extends StatelessWidget {
  const _Logo({required this.extended});

  final bool extended;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final mark = Container(width: extended ? 14 : 22, height: extended ? 14 : 22, color: ds.accent);
    if (!extended) {
      return Semantics(label: 'DigiClean', child: Padding(padding: const EdgeInsets.all(9), child: mark));
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        const SizedBox(width: 10),
        Text('DigiClean', style: displayStyle(24, color: ds.ink).copyWith(letterSpacing: -1.1)),
      ],
    );
  }
}
