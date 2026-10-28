import 'dart:math' as math;

import 'package:syntila_design/syntila_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  inputFocusTests();
  Future<double> dialogWidth(WidgetTester tester, Widget dialog,
      {bool dark = false}) async {
    tester.view.physicalSize = const Size(2400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: dark ? SyntilaBrand.darkTheme() : SyntilaBrand.lightTheme(),
      home: Scaffold(body: Center(child: dialog)),
    ));
    return tester.getSize(find.byType(Material).last).width;
  }

  final longMessage = List.filled(80, 'unbroken-error-detail').join(' ');

  testWidgets('theme caps dialogs at the medium width', (tester) async {
    final width = await dialogWidth(tester,
        AlertDialog(title: const Text('Error'), content: Text(longMessage)));
    expect(width, lessThanOrEqualTo(SyntilaDialogStyle.medium.maxWidth));
  });

  testWidgets('small confirmations stay within 400', (tester) async {
    final width = await dialogWidth(
        tester,
        AlertDialog(
            constraints: SyntilaDialogStyle.small,
            title: const Text('Delete?'),
            content: Text(longMessage)),
        dark: true);
    expect(width, lessThanOrEqualTo(400));
  });

  test('dialog theme uses shared surface and typography', () {
    final theme = SyntilaBrand.darkTheme().dialogTheme;
    expect(theme.backgroundColor, SyntilaColors.surfaceDark);
    expect(theme.titleTextStyle?.fontSize, 16);
    expect(theme.contentTextStyle?.color, SyntilaColors.textSecondaryDark);
    expect(theme.constraints, SyntilaDialogStyle.medium);
  });
}

double _contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

void inputFocusTests() {
  for (final dark in [false, true]) {
    test('focused field label is readable (${dark ? 'dark' : 'light'})', () {
      final theme = dark ? SyntilaBrand.darkTheme() : SyntilaBrand.lightTheme();
      final input = theme.inputDecorationTheme;
      final label = WidgetStateProperty.resolveAs(
          input.floatingLabelStyle, {WidgetState.focused})!;
      expect(
          _contrast(label.color!, input.fillColor!), greaterThanOrEqualTo(4.5));
      final border = input.focusedBorder!.borderSide.color;
      expect(_contrast(border, input.fillColor!), greaterThanOrEqualTo(3));
    });
  }
}
