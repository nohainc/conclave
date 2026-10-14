# AX Phase 6 performance gate V1

Phase 6 uses deterministic Flutter fixtures so rendering and activity behavior
can be tested without provider accounts or a live Worker.

## Automated gate

Run from `apps/app`:

```sh
flutter test test/phase6_performance_test.dart
flutter test test/ax_timeline_container_test.dart
flutter test test/spaces_pages_test.dart
```

The fixture suite covers:

- 1,000 variable-height Chat entries and 500 Work entries, asserting that the
  sliver surface does not build the complete history.
- Five independent Worker activity projections, with a 100-event burst routed
  to one assignment and only that assignment's listener rebuilding.
- A large Markdown response followed by updates while the user is away from
  the bottom, asserting that the reading offset is retained and no framework
  exception is raised.
- Existing Thread navigation, reconnect, pagination, composer, clear/archive,
  and stale-generation widget coverage in the Spaces suite.

## Profile-mode measurement

Automated widget tests prove behavior and bounded construction; they are not a
substitute for release-mode frame timings. For a release candidate, run the
same fixture scenarios from a profile build on the target device/browser:

```sh
cd apps/app
flutter run --profile -d <device>
```

On Chrome, record the fixture interaction in Chrome DevTools Performance with
the Performance and Memory panels enabled. Capture separate traces for:

1. initial history load;
2. a 100-event activity burst;
3. a large Markdown response;
4. rapid Thread switching and reconnect;
5. loading an older page while reading away from the bottom.

Review frame raster/build time, long tasks, scripting time, layout/recalculate
style work, heap growth, detached nodes, and the number of visible timeline
children. A trace is acceptable only when scrolling remains responsive, no
single interaction produces a sustained long task, heap growth settles after
the fixture is released, and the visible-child count remains bounded rather
than tracking total history size.

The trace date, browser/device, Flutter revision, renderer, fixture sizes and
any observed long task should be recorded with the release validation results.
Do not infer profile performance from debug-mode wall-clock test durations.
