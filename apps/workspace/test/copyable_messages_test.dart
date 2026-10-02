import 'package:conclave_workspace/copyable_messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('error snackbar preserves its timeout and copies full text',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copiedText = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    const message = 'Authentication failed: access denied';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showCopyableErrorSnackBar(context, message),
            child: const Text('Show'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('Show'));
    await tester.pump();
    expect(tester.widget<SnackBar>(find.byType(SnackBar)).duration,
        const Duration(seconds: 3));

    final copyButton = tester.widget<IconButton>(find.ancestor(
      of: find.byTooltip('Copy error message'),
      matching: find.byType(IconButton),
    ));
    copyButton.onPressed!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(copiedText, message);
    expect(find.text('Error message copied'), findsOneWidget);
  });

  testWidgets('inline warning text can be copied', (tester) async {
    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copiedText = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    const warning = 'The local Worker needs attention.';
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: CopyableMessageText(warning)),
    ));
    final copyButton = tester.widget<IconButton>(find.ancestor(
      of: find.byTooltip('Copy message'),
      matching: find.byType(IconButton),
    ));
    copyButton.onPressed!();
    await tester.pump();

    expect(copiedText, warning);
    expect(find.text('Message copied to clipboard'), findsOneWidget);
  });
}
