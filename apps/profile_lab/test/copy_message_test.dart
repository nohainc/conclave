import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_profile_lab/widgets/lab_components.dart';

void main() {
  for (final message in [
    'ERROR: no such table: tool_profile_local_qualification_evidence\nPublication failed',
    'WARNING: Version outside range',
    'INFO: All tests passed'
  ]) {
    testWidgets('copies complete operational message: $message',
        (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: CopyableMessage(message))));
      await tester.tap(find.byTooltip('Copy message'));
      await tester.pump();
      expect(copied, message);
      expect(find.text('Message copied'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
