import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/features/profile/read_receipt_privacy.dart';

class _Privacy implements AxReadReceiptPrivacyDataSource {
  bool share = true;
  bool fail = false;
  final saved = <bool>[];

  @override
  Future<bool> loadShareReadReceipts() async => share;

  @override
  Future<void> setShareReadReceipts(bool value) async {
    if (fail) throw Exception('offline');
    saved.add(value);
    share = value;
  }
}

Future<void> _pump(WidgetTester tester, _Privacy source) async {
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ReadReceiptPrivacyToggle(source: source))));
  await tester.pumpAndSettle();
}

bool _value(WidgetTester tester) => tester
    .widget<SwitchListTile>(find.byKey(const ValueKey('profile-read-receipts')))
    .value;

void main() {
  testWidgets('turning read receipts off saves the choice', (tester) async {
    final source = _Privacy();
    await _pump(tester, source);
    expect(_value(tester), isTrue);
    await tester.tap(find.byKey(const ValueKey('profile-read-receipts')));
    await tester.pumpAndSettle();
    expect(source.saved, [false]);
    expect(_value(tester), isFalse);
  });

  testWidgets('a failed save restores the previous value', (tester) async {
    final source = _Privacy()..fail = true;
    await _pump(tester, source);
    await tester.tap(find.byKey(const ValueKey('profile-read-receipts')));
    await tester.pumpAndSettle();
    expect(_value(tester), isTrue);
  });
}
