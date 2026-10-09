/** Version 1 product rights, independent of provider and Workspace permissions. */
export const SPACE_MEMBER_PERMISSION_KEYS = [
  "chat",
  "work",
  "manageOwnThreads",
  "attachWorkspace",
  "inviteMembers",
] as const;
export type SpaceMemberPermission =
  (typeof SPACE_MEMBER_PERMISSION_KEYS)[number];
export type SpaceMemberPermissions = Readonly<
  Record<SpaceMemberPermission, boolean>
>;

export function defaultSpaceMemberPermissions(
  role: string,
): SpaceMemberPermissions {
  const owner = role === "owner";
  const collaborator = role === "collaborator";
  return {
    chat: owner || collaborator,
    work: owner || collaborator,
    manageOwnThreads: owner || collaborator,
    attachWorkspace: owner,
    inviteMembers: owner,
  };
}

export function parseSpaceSettings(value: unknown): Record<string, unknown> {
  if (typeof value === "string") {
    try {
      value = JSON.parse(value);
    } catch {
      return {};
    }
  }
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

export function spaceMemberPermissions(
  role: string,
  settings: unknown,
  userId: string,
): SpaceMemberPermissions {
  const defaults = defaultSpaceMemberPermissions(role);
  if (role === "owner") return defaults;
  const map = parseSpaceSettings(
    parseSpaceSettings(settings).memberPermissions,
  );
  const override = map[userId];
  if (!Object.hasOwn(map, userId)) return defaults;
  // Stored overrides fail closed: missing or malformed values grant no rights.
  const value = parseSpaceSettings(override);
  return {
    chat: value.chat === true,
    work: value.work === true,
    manageOwnThreads: value.manageOwnThreads === true,
    attachWorkspace: value.attachWorkspace === true,
    inviteMembers: value.inviteMembers === true,
  };
}
