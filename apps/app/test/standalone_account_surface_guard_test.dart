import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('does not reintroduce a standalone AI Account product surface', () {
    final sourceRoot = Directory('lib/src');
    final forbidden = <String>[
      'StudioRouteKind.accounts',
      'StudioNavigation.accounts',
      'AccountsTab',
      'onCreateAccount:',
      "title: 'AI Account'",
      "action: 'Open Accounts'",
      "label: const Text('Add AI Account')",
    ];
    final violations = <String>[];
    for (final entity in sourceRoot.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final contents = entity.readAsStringSync();
      for (final term in forbidden) {
        if (contents.contains(term)) violations.add('${entity.path}: $term');
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
