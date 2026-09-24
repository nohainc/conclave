# Workspace UX implementation phases

This roadmap keeps Workspace as the security and ownership boundary while
making the one-Workspace case feel lightweight.

## Phase 1 — Complete Workspace UX

Status: implemented.

- Always show the current Workspace at the top of the sidebar.
- Provide a Workspace menu with switching, New workspace, invitations, and
  Workspace settings.
- Create Workspaces through the authenticated Cloud API and immediately select
  the returned Workspace.
- Keep Workspace settings out of primary sidebar navigation.

## Phase 2 — Workspace-aware navigation

- Scope app routes by Workspace slug or stable ID.
- Preserve the last Project/Chat location independently for each Workspace.
- Make refresh, copied links, notifications, and browser history retain the
  intended Workspace.

## Phase 3 — Resource availability UX

- Show Host Workspace bindings and add “Make available to another Workspace”.
- Show Worker readiness by Host without adding Worker sharing controls.
- Keep Account sharing explicit and separate from Worker installation.

## Phase 4 — Team refinement

- Improve invitation onboarding, membership management, usage attribution, and
  audit visibility.
- Keep the initial Owner/Admin/Member/Viewer roles and existing granular
  permissions until concrete enterprise requirements justify more roles.

The phases deliberately do not introduce direct User → Host or User → Worker
sharing. Hosts are made available through Workspace bindings; Workers are
software capabilities installed on Hosts; Accounts are the resource that can
be private or explicitly shared.
