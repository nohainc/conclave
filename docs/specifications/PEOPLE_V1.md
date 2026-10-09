# People v1

People is an automatically maintained, private directory of established collaborators. Email invitations remain pending until accepted. Creating an invitation does not create a Person. Successful membership creation establishes relationships between the new member and every existing member of that Space, including collaborators other than the inviter.

## Persistence and identity

Membership derivation alone cannot retain People after the last shared Space disappears. `people_relationships` therefore stores one canonical undirected pair of user IDs and its establishment timestamp. The ordered composite primary key prevents duplicates and self relationships. Both identities reference users. A membership insertion trigger establishes pairs atomically with membership creation; membership and Space deletion leave those pairs intact.

Migration `0023_people_relationships.sql` backfills accepted co-members across all Spaces, using their earliest shared membership timestamp. It consolidates duplicate pending invitations by retaining the oldest and revoking the rest, then enforces one pending invitation per Space and case-insensitive email. Expired pending invitations may be replaced. The migration does not send invitations or modify historical accepted memberships.

## Authenticated APIs

`GET /api/people` returns `{schemaVersion: 1, people: [...]}` for the authenticated user only. Each Person has `userId`, current `displayName`, `email`, nullable `avatarUrl`, `establishedAt`, and current `sharedSpaceCount`. Profiles are joined live rather than copied into relationships. There are no creation, deletion, ownership, global search, or enumeration endpoints.

`POST /api/spaces/:spaceId/invitations` accepts exactly one of `email` or `userId`, plus role/permissions. A known `userId` must be an established Person of the caller; Cloud resolves the current email and applies existing Space invitation authorization. Self invitations and duplicate pending invitations are rejected. Acceptance claims the invitation and creates membership in one batch; failed, expired, or competing acceptance cannot establish a relationship.

## AX synchronization

The session-wide `['people']` query contains immutable domain models, shared by the People page and Space invitation picker. Bootstrap loads it once; page and dialog navigation reuse cached state. Session clearing fences outstanding reads. There is no People polling.

Existing authorized Space events refresh People after acceptance, membership changes, and Space deletion. Better Auth profile updates publish durable, ID-only `people.updated` events to established peers' user streams. This event cannot contain profile fields or execution/Space identity. User and Space reconnect recovery refresh registered People even when its page is closed. The invitation picker submits stable user IDs; email remains available for someone new.

Apply migrations 0023 and 0025 before deploying Cloud and AX changes. Migration 0025 removes obsolete member-level invitation rights from persisted Space snapshots; invitation management is owner-only. Relationship retention currently has no manual removal control; account deletion cascades relationship rows. Direct administrative profile SQL changes require an explicit synchronization signal or reconnect; application profile changes use the authentication hook.

## People page and details

The existing application/account popup opens the global `/people` route; People has no main sidebar entry and does not depend on selected Space. Name/email search filters only the already-authorized in-memory People list. Search does not issue Cloud discovery requests.

The version 1 People response additionally includes `sharedSpaces: [{id, name}]` and `invitableSpaces: [{id, name, permissions, canInvite}]`. Shared names are restricted to Spaces where both users are members; a Person's other Spaces remain private. Invitation destinations are limited to Spaces owned by the current user and exclude archived Spaces, existing membership, and unexpired pending invitations. The permissions snapshot bounds requested collaborator/viewer rights; the invitation endpoint rechecks live ownership, membership, and invitation state on submission.

Person details and the Add to Space picker subscribe to the same session query without opening-time reads. Membership, invitation, permission, and Space rename signals update open details and eligibility. Successful invitations refresh People and registered Space invitation/audit queries; rejected writes reconcile eligibility without retrying the invitation. Session fences prevent a late successful write from reloading a signed-out user's directory.

Cold loading displays progress. Empty accounts explain acceptance; search misses have their own empty state. Connection errors preserve cached People and expose Retry, while invitation submission is disabled when eligibility reads fail or are refreshing. The existing shell live-update/reconnecting banner remains the authoritative transport indicator.

## Shared invitation flow

~~~text
USER
 ├── PEOPLE: known collaborators
 └── SPACES
      ├── Members
      ├── Invitations
      └── Permissions

First collaboration:  Email invitation → Accept → Known Person
Future collaboration: People selection → Space invitation → Accept
~~~

Space → Invite people and People → Person → Add to Space use the same `SpaceInvitationDialog` and `AxSpaceInvitations` writer. The Space dialog searches only cached People, displays recent relationships, supports multiple selections, and labels each Person as Already a member, Pending invitation, Available to invite, or unavailable. Known members and pending recipients cannot be selected. Email remains available for someone new; People selection and email entry are mutually exclusive.

Both paths expose the same per-Space permission editor. Read access is inherent in membership; Chat, Work, own Thread management, and Workspace attachment are bounded by the owner's selected rights. Invitation management is owner-only and is not a member permission. Cloud validates those rules again. Each selected Person creates a normal invitation, never a direct membership. Partial multi-person failures retain only unsent selections; successful recipients are not retried. Resend preserves recipient identity and selected permissions, bounded by current rights.

Migration `0024_space_invitation_identity.sql` adds nullable `invitee_user_id` to Space invitations. Known-Person requests persist this identity; email is a delivery-address snapshot. Inbox, Accept, Reject, pending detection, and notifications use the user ID whenever present, so email changes or reuse cannot transfer consent. Unknown/legacy pending email invitations remain email-addressed until accepted; acceptance binds them to the authenticated user ID. Existing accepted invitations are backfilled from `accepted_by_user_id`. A unique pending Space/user index supplements the pending email index. Account deletion cascades invitations addressed to that deleted identity rather than falling back to a reusable email.

Apply migration 0024 after 0023, then 0025, before deploying these Cloud/AX changes. These migrations preserve accepted memberships and People relationships while cleaning persisted invitation identity and obsolete member-level invitation rights. The obsolete email-only AX writer and unused email-only authentication invitation reader are removed. There is no separate membership or global discovery API.
