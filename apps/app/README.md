# Conclave AX

Conclave AX is the Flutter application for human authentication, Projects,
Workstreams, Chat, Work, Workspace access, Worker catalog visibility, and
account security. The Workstream Chat tab is the human discussion surface;
Work remains the execution surface.

Run failures include a **Copy Run error** icon that copies the full message.
Worker replies appear directly beneath their Step in Work history. Failed
Steps show a selectable diagnostic with a **Copy step error** icon.
AX sends commands and reads history over HTTP, with WebSocket notifications
triggering immediate history refresh. It subscribes to the active Workstream
and resynchronizes after reconnecting. While Work is queued, running, or waiting,
a five-second HTTP refresh also reconciles progress and completion if a live
notification is missed. The fallback stops after completion or leaving the page.
To enable Direct, open **Project → Workspaces → Edit Workspace access** (shield
icon), select **Read repository files** and **Change repository files**, then
confirm. Test steps also require **Execute commands and tests**. Both Workspace
connection flows present these choices explicitly; permissions are never
automatically widened. Existing connections retain their permissions.

The package intentionally has no native desktop targets. Desktop execution is
provided by Conclave Workspace; Conclave AX communicates with Cloud through
the Human Product Protocol and realtime event stream.

If live data cannot load, the recovery screen shows the failing resource,
HTTP status, and Cloud's JSON error detail when available. **Copy error**
copies that message with recovery context; **Try again** reloads the data.
Error text is also selectable. Non-JSON proxy responses use the resource
and status without copying the response page.

Worker availability is derived from Cloud's readiness and activation fields.
Enabled, Ready Workers count as available; disabled Workers do not. Worker
cards distinguish unchecked, sign-in, Profile/runtime, setup, and test failures
instead of treating a missing legacy status field as “Needs attention”.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
