import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:conclave_app/src/features/spaces/spaces_pages.dart';
import 'package:flutter/material.dart';
import 'package:conclave_design/conclave_design.dart';
import 'package:flutter_test/flutter_test.dart';

const _claude = '''
You are currently using your subscription to power your Claude Code usage

Current session: 0% used
Current week (all models): 21% used · resets Oct 22 at 8:59pm (Europe/Bratislava)

What's contributing to your limits usage?

Last 24h · 427 requests · 38 sessions
  51% of your usage was at >150k context

Last 7d · 2072 requests · 139 sessions
  38% of your usage was at >150k context
  Top subagents: Explore 1%
''';

const _codex = '''
{
  "ordinaryUsageAllowed": true,
  "rateLimits": {
    "limitId": "codex",
    "primary": {"usedPercent": 0, "windowDurationMins": 300, "resetsAt": 1792244044},
    "secondary": {"usedPercent": 36, "windowDurationMins": 10080, "resetsAt": 1792662209},
    "planType": "plus"
  },
  "rateLimitResetCredits": {"availableCount": 1}
}
''';

const _gemini =
    'Gemini Models\tWeekly Limit Remaining\t100%\t2026-10-24T08:34:56Z\n'
    'Gemini Models\tFive Hour Limit Remaining\t100%\t2026-10-17T13:34:56Z\n'
    'Gemini 4 Argon\tGemini 4 Argon Weekly Limit\t75%\t2026-10-24T08:34:56Z\n';

void main() {
  test('Claude report', () {
    final usage = parseWorkerUsage(_claude, now: DateTime.utc(2026, 10, 17))!;
    expect(usage.windows.map((w) => w.label), ['Session', 'Week']);
    expect(usage.windows[1].usedPercent, 21);
    expect(usage.windows[1].resetsText, 'Oct 22 at 8:59pm (Europe/Bratislava)');
    expect(usage.notes, isEmpty);
    expect(usage.windows[1].resetsAt, DateTime.utc(2026, 10, 22, 18, 59));
  });

  test('Codex report', () {
    final usage = parseWorkerUsage(_codex)!;
    expect(usage.windows.map((w) => w.label), ['5 hours', 'Week']);
    expect(usage.windows[1].usedPercent, 36);
    expect(usage.windows[0].resetsAt, DateTime.utc(2026, 10, 17, 13, 34, 4));
    expect(usage.windows[1].resetsAt, DateTime.utc(2026, 10, 22, 9, 43, 29));
    expect(usage.notes.any((n) => n.startsWith('Plan:')), isFalse);
    expect(usage.notes, contains('1 free rate limit reset available'));
  });

  test('Gemini report converts remaining to used', () {
    final usage = parseWorkerUsage(_gemini)!;
    expect(usage.windows.map((w) => w.label), ['Week', '5 hours', 'Week']);
    expect(usage.windows.map((w) => w.usedPercent), [0, 0, 25]);
    expect(usage.windows[2].group, 'Gemini 4 Argon');
    expect(usage.windows[1].resetsAt, DateTime.utc(2026, 10, 17, 13, 34, 56));
  });

  test('countdowns use hours for sessions and days for weeks', () {
    final now = DateTime.utc(2026, 10, 17);
    expect(
        usageResetLabel(
            AxUsageWindow(
                label: '5 hours',
                usedPercent: 0,
                resetsAt: now.add(const Duration(hours: 1, minutes: 29))),
            now),
        'Resets in 1 hr 29 min');
    expect(
        usageResetLabel(
            AxUsageWindow(
                label: 'Week',
                usedPercent: 0,
                resetsAt:
                    now.add(const Duration(days: 2, hours: 2, minutes: 30))),
            now),
        'Resets in 2 d 2 hr 30 min');
    expect(
        usageResetLabel(
            AxUsageWindow(
                label: 'Session',
                usedPercent: 0,
                resetsAt: now.add(const Duration(seconds: 1))),
            now),
        'Resets in 0 hr 1 min');
    expect(
        usageResetLabel(
            AxUsageWindow(label: 'Week', usedPercent: 0, resetsAt: now), now),
        'Reset time reached — refresh usage');
    expect(
        usageResetLabel(
            const AxUsageWindow(label: 'Session', usedPercent: 0), now),
        '');
  });

  test('Claude reset dates handle DST, year rollover and unknown zones', () {
    AxUsageWindow window(String text, DateTime now) =>
        parseWorkerUsage('Current week (all models): 21% used · resets $text',
                now: now)!
            .windows
            .single;
    expect(
        window('Oct 26 at 8:59pm (Europe/Bratislava)',
                DateTime.utc(2026, 10, 17))
            .resetsAt,
        DateTime.utc(2026, 10, 26, 19, 59));
    expect(
        window('Jan 2 at 12:30am (Europe/Bratislava)',
                DateTime.utc(2026, 12, 31))
            .resetsAt,
        DateTime.utc(2027, 1, 1, 23, 30));
    expect(
        window('8:59pm (Europe/Bratislava)', DateTime.utc(2026, 10, 17, 20))
            .resetsAt,
        DateTime.utc(2026, 10, 18, 18, 59));
    final unknown =
        window('Oct 22 at 8:59pm (Unknown/Zone)', DateTime.utc(2026, 10, 17));
    expect(unknown.resetsAt, isNull);
    expect(
        usageResetLabel(unknown, DateTime.utc(2026)), contains('Unknown/Zone'));
  });

  test('unknown or malformed reports are not parsed', () {
    for (final text in [
      '',
      'Usage: unavailable',
      '{not json',
      '{"rateLimits": {"primary": {"usedPercent": 140, "windowDurationMins": 300}}}',
      '{"other": 1}',
      'Current session: lots used',
      'Gemini Models\tWeekly Limit Remaining\t100%',
      'Gemini Models\tWeekly Limit Remaining\t101%\t2026-10-24T08:34:56Z',
      'Gemini Models\tWeekly Limit Remaining\t50%\tnot-a-date',
      '$_gemini\nextra unexpected line',
    ]) {
      expect(parseWorkerUsage(text), isNull, reason: text);
    }
  });

  testWidgets('panel shows summary, original on request, raw on failure',
      (tester) async {
    Future<AxWorkerUsageController> pump(String output) async {
      final controller = AxWorkerUsageController(_Source(output));
      await controller.load(
          workspaceId: 'w', workerId: 'k', workerName: 'Worker');
      return controller;
    }

    final ok = await pump(_codex
        .replaceAll('1792244044', '4102444800')
        .replaceAll('1792662209', '4103049600'));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AxWorkerUsagePanel(controller: ok, onRefresh: () {}))));
    expect(find.byKey(const ValueKey('worker-usage-table')), findsOneWidget);
    expect(find.textContaining('Plan:'), findsNothing);
    final original = find.text('Original');
    expect(find.ancestor(of: original, matching: find.byType(TextButton)),
        findsNothing);
    final timestamp = find.textContaining('as of ');
    expect(timestamp, findsOneWidget);
    expect(tester.widget<Text>(original).style,
        tester.widget<Text>(timestamp).style);
    expect(tester.widget<Text>(original).style,
        Theme.of(tester.element(original)).textTheme.bodySmall);

    final bar = tester
        .widgetList<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator))
        .first;
    expect(bar.color, ConclaveColors.primaryForeground(false));
    expect(bar.backgroundColor, ConclaveColors.surfaceHoverLight);
    expect(find.textContaining('Resets in'), findsWidgets);
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
            body: AxWorkerUsagePanel(
                controller: ok, onRefresh: () {}, attached: true))));
    await tester.pump(const Duration(milliseconds: 300));
    final darkBar = tester
        .widgetList<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator))
        .first;
    expect(darkBar.color, ConclaveColors.primaryForeground(true));
    expect(darkBar.backgroundColor, ConclaveColors.surfaceHoverDark);

    await tester
        .tap(find.byKey(const ValueKey('worker-usage-toggle-original')));
    await tester.pump();
    expect(find.byKey(const ValueKey('worker-usage-table')), findsNothing);
    expect(find.byKey(const ValueKey('worker-usage-text')), findsOneWidget);
    expect(ok.visible, isTrue);
    await tester.tap(find.byKey(const ValueKey('worker-usage-text')));
    await tester.pump();
    expect(ok.visible, isTrue);

    final bad = await pump('something new');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AxWorkerUsagePanel(controller: bad, onRefresh: () {}))));
    expect(find.byKey(const ValueKey('worker-usage-unparsed')), findsOneWidget);
    expect(find.text('something new'), findsOneWidget);
  });
}

class _Source implements AxWorkerUsageDataSource {
  _Source(this.output);
  final String output;
  @override
  Future<AxWorkerUsageReport> readWorkerUsage(
          {required String workspaceId, required String workerId}) async =>
      AxWorkerUsageReport(
          status: 'ok', output: output, fetchedAt: DateTime.utc(2026, 10, 17));
}
