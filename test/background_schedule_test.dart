import 'package:digiclean/src/core/background_schedule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const checker = r'C:\Program Files\DigiClean & Co\digiclean-check.exe';
  const job = r'C:\Users\Ann "Bee"\AppData\Roaming\DigiClean\background-job.json';

  test('the Windows task runs the checker daily with the job, escaped', () {
    final xml = windowsTaskXml(checker: checker, job: job);
    expect(xml, contains('<Command>C:\\Program Files\\DigiClean &amp; Co\\digiclean-check.exe</Command>'));
    expect(xml, contains('<Arguments>--job &quot;C:\\Users\\Ann &quot;Bee&quot;\\AppData'));
    expect(xml, contains('<DaysInterval>1</DaysInterval>'));
    expect(xml, contains('<DisallowStartIfOnBatteries>true</DisallowStartIfOnBatteries>'));
    expect(xml, contains('<LogonType>InteractiveToken</LogonType>'));
    expect(xml, isNot(contains('& ')), reason: 'no raw ampersands');
  });

  test('systemd units quote paths and run daily, catching up after downtime', () {
    final units = systemdUnits(checker: '/opt/digi clean/digiclean-check', job: r'/home/a"b/job.json');
    expect(units.service, contains(r'ExecStart="/opt/digi clean/digiclean-check" --job "/home/a\"b/job.json"'));
    expect(units.service, contains('Type=oneshot'));
    expect(units.timer, contains('OnCalendar=*-*-* 13:00:00'));
    expect(units.timer, contains('Persistent=true'));
  });

  test('the LaunchAgent passes the job as separate arguments', () {
    final plist = launchAgentPlist(
      checker: '/Applications/DigiClean.app/Contents/MacOS/digiclean-check',
      job: '/x/<j>.json',
    );
    expect(plist, contains('<string>com.digiclean.check</string>'));
    expect(plist, contains('<string>--job</string>'));
    expect(plist, contains('<string>/x/&lt;j&gt;.json</string>'));
    expect(plist, contains('<key>Hour</key>'));
  });
}
