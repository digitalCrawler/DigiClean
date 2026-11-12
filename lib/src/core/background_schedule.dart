import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Registers the daily background check (`digiclean-check --job <file>`)
/// with the operating system's own scheduler, so it runs while DigiClean is
/// closed: Task Scheduler on Windows, a systemd user timer on Linux and a
/// LaunchAgent on macOS. Mobile platforms use their own mechanisms.
class BackgroundSchedule {
  BackgroundSchedule({this.windowsTaskName = r'DigiClean\Background check', String? home})
    : _home = home ?? Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '';

  final String windowsTaskName;
  final String _home;

  static const linuxUnit = 'digiclean-check';
  static const macLabel = 'com.digiclean.check';

  static bool get supported => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  static String get checkerName => Platform.isWindows ? 'digiclean-check.exe' : 'digiclean-check';

  /// The checker shipped next to the app, or `DIGICLEAN_CHECK` if set.
  static String? findChecker() {
    final override = Platform.environment['DIGICLEAN_CHECK'];
    if (override != null && File(override).existsSync()) return override;
    final bundled = p.join(p.dirname(Platform.resolvedExecutable), checkerName);
    return File(bundled).existsSync() ? bundled : null;
  }

  Future<void> enable({required String checker, required String job}) async {
    if (Platform.isWindows) {
      final xml = File(p.join(Directory.systemTemp.path, 'digiclean-task-$pid.xml'));
      // Task Scheduler expects UTF-16 with a byte-order mark.
      final text = windowsTaskXml(checker: checker, job: job);
      final bytes = <int>[0xFF, 0xFE];
      for (final unit in text.codeUnits) {
        bytes
          ..add(unit & 0xFF)
          ..add(unit >> 8);
      }
      xml.writeAsBytesSync(bytes);
      try {
        await _run('schtasks', ['/Create', '/F', '/TN', windowsTaskName, '/XML', xml.path]);
      } finally {
        if (xml.existsSync()) xml.deleteSync();
      }
    } else if (Platform.isLinux) {
      final dir = Directory(p.join(_home, '.config', 'systemd', 'user'))..createSync(recursive: true);
      final units = systemdUnits(checker: checker, job: job);
      File(p.join(dir.path, '$linuxUnit.service')).writeAsStringSync(units.service);
      File(p.join(dir.path, '$linuxUnit.timer')).writeAsStringSync(units.timer);
      await _run('systemctl', ['--user', 'daemon-reload']);
      await _run('systemctl', ['--user', 'enable', '--now', '$linuxUnit.timer']);
    } else if (Platform.isMacOS) {
      final plist = File(p.join(_home, 'Library', 'LaunchAgents', '$macLabel.plist'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(launchAgentPlist(checker: checker, job: job));
      final uid = (await _run('id', ['-u'])).trim();
      await _run('launchctl', ['bootout', 'gui/$uid/$macLabel'], allowFailure: true);
      await _run('launchctl', ['bootstrap', 'gui/$uid', plist.path]);
    } else {
      throw UnsupportedError('Background checks are not available on this device.');
    }
  }

  Future<void> disable() async {
    if (Platform.isWindows) {
      await _run('schtasks', ['/Delete', '/F', '/TN', windowsTaskName], allowFailure: true);
    } else if (Platform.isLinux) {
      await _run('systemctl', ['--user', 'disable', '--now', '$linuxUnit.timer'], allowFailure: true);
      for (final ext in ['service', 'timer']) {
        final f = File(p.join(_home, '.config', 'systemd', 'user', '$linuxUnit.$ext'));
        if (f.existsSync()) f.deleteSync();
      }
      await _run('systemctl', ['--user', 'daemon-reload'], allowFailure: true);
    } else if (Platform.isMacOS) {
      final uid = (await _run('id', ['-u'])).trim();
      await _run('launchctl', ['bootout', 'gui/$uid/$macLabel'], allowFailure: true);
      final f = File(p.join(_home, 'Library', 'LaunchAgents', '$macLabel.plist'));
      if (f.existsSync()) f.deleteSync();
    }
  }

  /// Whether the schedule is registered (Windows: asks Task Scheduler).
  Future<bool> isEnabled() async {
    if (Platform.isWindows) {
      final r = await Process.run('schtasks', ['/Query', '/TN', windowsTaskName]);
      return r.exitCode == 0;
    }
    if (Platform.isLinux) return File(p.join(_home, '.config', 'systemd', 'user', '$linuxUnit.timer')).existsSync();
    if (Platform.isMacOS) return File(p.join(_home, 'Library', 'LaunchAgents', '$macLabel.plist')).existsSync();
    return false;
  }

  Future<String> _run(String exe, List<String> args, {bool allowFailure = false}) async {
    final r = await Process.run(exe, args);
    if (r.exitCode != 0 && !allowFailure) {
      final message = '${r.stderr}'.trim().isNotEmpty ? '${r.stderr}'.trim() : '${r.stdout}'.trim();
      throw ProcessException(exe, args, message, r.exitCode);
    }
    return '${r.stdout}';
  }
}

String _xml(String s) => const HtmlEscape(HtmlEscapeMode.attribute).convert(s);

/// A daily Task Scheduler task at 13:00 (or later when the PC was off) that
/// runs only while the user is logged on and on AC power, at low priority.
String windowsTaskXml({required String checker, required String job}) =>
    '''<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>DigiClean: daily check for duplicates, junk and low disk space. Never removes anything.</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>2024-01-01T13:00:00</StartBoundary>
      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>true</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>true</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>${_xml(checker)}</Command>
      <Arguments>--job &quot;${_xml(job)}&quot;</Arguments>
    </Exec>
  </Actions>
</Task>
''';

/// systemd quotes arguments with double quotes and backslash escapes.
String _systemdQuote(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

({String service, String timer}) systemdUnits({required String checker, required String job}) => (
  service:
      '''[Unit]
Description=DigiClean background check (duplicates, junk, low disk space)

[Service]
Type=oneshot
Nice=15
IOSchedulingClass=idle
ExecStart=${_systemdQuote(checker)} --job ${_systemdQuote(job)}
''',
  timer: '''[Unit]
Description=Daily DigiClean background check

[Timer]
OnCalendar=*-*-* 13:00:00
Persistent=true
RandomizedDelaySec=15min

[Install]
WantedBy=timers.target
''',
);

String launchAgentPlist({required String checker, required String job}) =>
    '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${BackgroundSchedule.macLabel}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${_xml(checker)}</string>
    <string>--job</string>
    <string>${_xml(job)}</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>13</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>LowPriorityIO</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
</dict>
</plist>
''';
