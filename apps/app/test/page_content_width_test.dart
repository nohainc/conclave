import 'package:conclave_app/src/app_shell.dart';
import 'package:conclave_app/src/features/home/home_page.dart';
import 'package:conclave_app/src/features/people/people_page.dart';
import 'package:conclave_app/src/features/spaces/archived_spaces_page.dart';
import 'package:conclave_app/src/platform/platform_services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ax_fixture_data.dart';

void main() {
  for (final width in [650.0, 1200.0, 1800.0]) {
    testWidgets('People and Archived Spaces match Home width at $width',
        (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Rect? homeBounds;
      for (final entry in <String, Type>{
        '/': HomePage,
        '/people': PeoplePage,
        '/archived-spaces': ArchivedSpacesPage,
      }.entries) {
        await tester.pumpWidget(MaterialApp(
          home: ConclaveAppShell(
            key: ValueKey(entry.key),
            services: const DefaultPlatformServices(),
            dataSource: const AxFixtureDataSource(),
            initialUri: Uri.parse(entry.key),
          ),
        ));
        await tester.pumpAndSettle();
        final bounds = tester.getRect(find.byType(entry.value));
        if (homeBounds == null) {
          homeBounds = bounds;
          if (width == 1800) expect(bounds.width, 840);
        } else {
          expect(bounds.left, closeTo(homeBounds.left, 0.1));
          expect(bounds.width, closeTo(homeBounds.width, 0.1));
        }
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
