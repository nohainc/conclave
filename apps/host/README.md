# Conclave Workspace

Conclave Workspace is the machine-side execution and security runtime.

It maintains the Cloud connection, owns the local Work Root, creates/resolves
Workstream working directories, manages locally configured Workers and their
credentials, installs/verifies Worker Type adapter packages, launches adapter
child processes, enforces local permissions, supervises execution, and reports
safe readiness/status back to Conclave Cloud.

Its GUI is intentionally minimal and local-first:
- pairing/connection;
- Workers;
- provider authentication;
- local permissions;
- current local work;
- diagnostics/logs;
- updates;
- pause/quit.

Projects, Workstreams, Discuss, Work orchestration, Project membership and
remote scheduling policy belong in Conclave AX.

Users install only Conclave Workspace. Worker adapters are managed internally;
they are not separately installed desktop applications.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
