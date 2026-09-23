# APP-2: Application shell extraction

The Conclave AX application has an app-level shell boundary at
`apps/app/lib/src/app_shell.dart` and an app routing boundary at
`apps/app/lib/src/router.dart`.

`ConclaveAppShell` owns application lifecycle, authentication, shared stores,
browser history, and cross-feature coordination. Feature pages receive domain
models and callbacks instead of reaching into shell state directly.

The first extracted pages are:

- `features/projects/projects_pages.dart` for Projects and Project overview;
- `features/workspace/workspace_settings_page.dart` for Workspace settings.

The compatibility `StudioApp` name and existing `Studio*` domain models remain
temporarily so this architectural split can proceed without a broad, risky
rename. Additional feature pages should move behind the same boundary before
new feature-specific behavior is added to the shell.
