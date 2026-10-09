import {
  spaceMemberPermissions,
  type SpaceMemberPermissions,
} from "@conclave/security";
import {
  securityContext,
  HttpError,
  json,
  type SecurityEnv,
} from "./http-security.js";
import { avatarUrlFor } from "./profile.js";

export interface PeopleSpace {
  readonly id: string;
  readonly name: string;
}
export interface InvitablePeopleSpace extends PeopleSpace {
  readonly permissions: SpaceMemberPermissions;
  readonly canInvite: boolean;
}
export interface Person {
  readonly userId: string;
  readonly displayName: string;
  readonly email: string;
  readonly avatarUrl: string | null;
  readonly establishedAt: string;
  readonly sharedSpaceCount: number;
  readonly sharedSpaces: readonly PeopleSpace[];
  readonly pendingInvitationSpaceIds: readonly string[];
  readonly invitableSpaces: readonly InvitablePeopleSpace[];
}
export async function handleListPeople(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (request.method !== "GET")
    throw new HttpError(405, "People is maintained automatically");
  if ([...new URL(request.url).searchParams.keys()].length)
    throw new HttpError(
      400,
      "People does not support global search or ownership parameters",
    );
  const rows = await env.CONCLAVE_DB.prepare(
    `WITH peers AS (
    SELECT user_high_id AS user_id,established_at FROM people_relationships WHERE user_low_id=?1
    UNION ALL SELECT user_low_id AS user_id,established_at FROM people_relationships WHERE user_high_id=?1)
    SELECT u.id AS userId,u.display_name AS displayName,u.email,u.avatar_url AS avatarUrl,p.established_at AS establishedAt,
      (SELECT COUNT(*) FROM space_memberships mine JOIN space_memberships theirs ON theirs.space_id=mine.space_id WHERE mine.user_id=?1 AND theirs.user_id=u.id) AS sharedSpaceCount
    FROM peers p JOIN users u ON u.id=p.user_id WHERE u.status='active'
    ORDER BY LOWER(u.display_name),u.id`,
  )
    .bind(context.userId)
    .all<
      Omit<
        Person,
        "sharedSpaces" | "invitableSpaces" | "pendingInvitationSpaceIds"
      >
    >();
  if (!rows.results.length) return json({ schemaVersion: 1, people: [] });
  // Only the caller's memberships and invitation rights contribute Space metadata.
  const [spaces, shared, pending] = await Promise.all([
    env.CONCLAVE_DB.prepare(
      `SELECT s.id,s.name,COALESCE(json_extract(s.settings_json, '$.archived'), 0) AS archived,s.settings_json AS settingsJson,m.role
      FROM spaces s JOIN space_memberships m ON m.space_id=s.id WHERE m.user_id=?1 ORDER BY LOWER(s.name),s.id`,
    )
      .bind(context.userId)
      .all<
        PeopleSpace & { archived: number; settingsJson: string; role: string }
      >(),
    env.CONCLAVE_DB.prepare(
      `SELECT theirs.user_id AS userId,mine.space_id AS spaceId
      FROM space_memberships mine JOIN space_memberships theirs ON theirs.space_id=mine.space_id
      JOIN people_relationships p ON p.user_low_id=MIN(?1,theirs.user_id) AND p.user_high_id=MAX(?1,theirs.user_id)
      WHERE mine.user_id=?1`,
    )
      .bind(context.userId)
      .all<{ userId: string; spaceId: string }>(),
    env.CONCLAVE_DB.prepare(
      `SELECT i.space_id AS spaceId,LOWER(i.email) AS email,i.invitee_user_id AS inviteeUserId FROM space_invitations i
      JOIN space_memberships m ON m.space_id=i.space_id AND m.user_id=?1
      WHERE i.status='pending' AND i.expires_at>?2`,
    )
      .bind(context.userId, new Date().toISOString())
      .all<{ spaceId: string; email: string; inviteeUserId: string | null }>(),
  ]);
  const permissions = new Map(
    spaces.results.map((space) => [
      space.id,
      spaceMemberPermissions(space.role, space.settingsJson, context.userId),
    ]),
  );
  const sharedByUser = new Map<string, Set<string>>();
  for (const row of shared.results) {
    const ids = sharedByUser.get(row.userId) ?? new Set<string>();
    ids.add(row.spaceId);
    sharedByUser.set(row.userId, ids);
  }
  const pendingByUser = new Map<string, Set<string>>();
  const pendingByEmail = new Map<string, Set<string>>();
  for (const row of pending.results) {
    if (row.inviteeUserId !== null) {
      const ids = pendingByUser.get(row.inviteeUserId) ?? new Set<string>();
      ids.add(row.spaceId);
      pendingByUser.set(row.inviteeUserId, ids);
      continue;
    }
    const ids = pendingByEmail.get(row.email) ?? new Set<string>();
    ids.add(row.spaceId);
    pendingByEmail.set(row.email, ids);
  }
  return json({
    schemaVersion: 1,
    people: rows.results.map((person) => {
      const membership = sharedByUser.get(person.userId) ?? new Set<string>();
      const invitations = new Set([
        ...(pendingByUser.get(person.userId) ?? []),
        ...(pendingByEmail.get(person.email.trim().toLowerCase()) ?? []),
      ]);
      return {
        ...person,
        avatarUrl: avatarUrlFor(request, person.userId, person.avatarUrl),
        pendingInvitationSpaceIds: [...invitations].filter((id) =>
          spaces.results.some(
            (space) => space.id === id && space.role === "owner",
          ),
        ),
        sharedSpaces: spaces.results
          .filter((space) => membership.has(space.id))
          .map(({ id, name }): PeopleSpace => ({ id, name })),
        invitableSpaces: spaces.results
          .filter(
            (space) =>
              space.role === "owner" &&
              space.archived === 0 &&
              !membership.has(space.id) &&
              !invitations.has(space.id),
          )
          .map(({ id, name, role }): InvitablePeopleSpace => ({
            id,
            name,
            permissions: permissions.get(id)!,
            canInvite: role === "owner",
          })),
      };
    }),
  });
}
