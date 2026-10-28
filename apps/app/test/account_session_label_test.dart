import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/account_session_label.dart';

void main() {
  test('summarizes browsers despite shared compatibility tokens', () {
    const base = 'Mozilla/5.0 (Windows NT 10.0) AppleWebKit/537.36 '
        'Chrome/140.0.0.0 Safari/537.36';
    expect(accountSessionLabel(base), 'Chrome on Windows');
    expect(accountSessionLabel('$base Edg/140.0'), 'Edge on Windows');
    expect(accountSessionLabel('$base OPR/120.0'), 'Opera on Windows');
    expect(accountSessionLabel('Mozilla/5.0 (iPhone) CriOS/140 Safari/604'),
        'Chrome on iPhone');
    expect(accountSessionLabel('Mozilla/5.0 (Macintosh) Version/18 Safari/605'),
        'Safari on macOS');
    expect(accountSessionLabel('Mozilla/5.0 (Linux) Firefox/140'),
        'Firefox on Linux');
  });
  test('handles missing and unknown clients without raw UA paragraphs', () {
    expect(accountSessionLabel(null), 'Browser session');
    expect(accountSessionLabel('  '), 'Browser session');
    expect(accountSessionLabel('\u200B\uFEFF'), 'Browser session');
    expect(accountSessionLabel('Custom client'), 'Custom client');
    expect(accountSessionLabel('unknown ' * 30), 'Browser session');
  });
}
