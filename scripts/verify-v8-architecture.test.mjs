import { describe, expect, it } from "vitest";
import { forbiddenArchitecture } from "./v8-architecture-rules.mjs";

function violationsFor(source) {
  return forbiddenArchitecture
    .filter(([, pattern]) => pattern.test(source))
    .map(([label]) => label);
}

describe("v8 architecture guard rejects retired source patterns", () => {
  it.each([
    ["WorkstreamCheckoutManager", "WorkstreamCheckoutManager"],
    ["checkout_id schema columns", "checkout_id"],
    ["Workstream checkpoint tables", "workstream_checkpoints"],
    ["Checkout mutation commands", "checkout.provision"],
    ["Git rollback commands", "resetHard"],
  ])("rejects %s", (_description, source) => {
    expect(violationsFor(source)).toContain(
      "retired Workstream Checkout architecture",
    );
  });

  it.each([
    ["registry class", "LocalRepositoryRegistry"],
    ["repository configuration file", "repositoriesFile"],
    ["repository mapping columns", "repository_mappings_json"],
    ["path mapping properties", "pathMappings"],
    ["repository CLI option", "--repositories"],
  ])("rejects %s", (_description, source) => {
    expect(violationsFor(source)).toContain(
      "repository registration architecture",
    );
  });

  it.each([
    ["Host domain class", "ExecutionHost"],
    ["Host registration class", "HostRegistration"],
    ["Host identifier field", "hostId"],
    ["Host database column", "host_id"],
    ["Host API route", "/api/hosts/123"],
    ["Host environment variable", "CONCLAVE_HOST_RUNTIME_ID"],
  ])("rejects %s", (_description, source) => {
    expect(violationsFor(source)).toContain("retired Host product naming");
  });

  it.each([
    ["auth intent version 1.0", 'DESKTOP_AUTH_INTENT_VERSION = "1.0"'],
    ["camel-case comparison code", "userCode"],
    ["snake-case comparison code", "user_code"],
    [
      "optional installation ID in persisted registration",
      "installationId: json['installationId'] is String",
    ],
    [
      "null installation ID recovery from registration",
      "registration.installationId ?? identityStore.getOrCreate()",
    ],
    ["optional installation ID in pairing method", "String? installationId,"],
    [
      "legacy registration identity creation branch",
      "existingRegistration == null ? null : await identityStore.getOrCreate()",
    ],
  ])("rejects %s", (_description, source) => {
    expect(violationsFor(source)).toContain(
      "retired desktop auth compatibility",
    );
  });

  it("retains the independently versioned current transport contract", () => {
    expect(
      violationsFor('DESKTOP_AUTH_TRANSPORT_VERSION = "1.0"'),
    ).not.toContain("retired desktop auth compatibility");
  });

  it.each([
    ["pairing-intent table", "workspace_pairing_intents"],
    ["pairing-intent API", "/api/workspace-pairing-intents"],
    ["pairing-intent handler", "handleCreateWorkspacePairingIntent"],
    ["pairing token prefix", "conclave_pair_"],
    ["Workspace pairing service", "WorkspacePairingService"],
  ])("rejects retired Workspace pairing flow: %s", (_description, source) => {
    expect(violationsFor(source)).toContain(
      "retired Workspace token pairing flow",
    );
  });

  it.each([
    ["retired pairing-intent table", "workspace_pairing_intents"],
    ["enrollment table", "workspace_enrollments"],
    ["retired runtime enrollment route", "workspace-runtime/enroll"],
    ["retired pairing-intent route", "workspace-pairing-intents"],
    ["enrollment route", "/api/workspaces/id/enrollments"],
    ["enrollment handler", "handleCreateWorkspaceEnrollment"],
    ["Workspace enrollment factory", "createWorkspaceEnrollment"],
    ["enrollment token prefix", "conclave_enroll_"],
    ["legacy smoke environment variable", "CONCLAVE_ENROLLMENT_TOKEN"],
    ["AX enrollment model", "AxWorkspaceEnrollment"],
  ])(
    "rejects retired Workspace token enrollment: %s",
    (_description, source) => {
      expect(violationsFor(source)).toContain(
        "retired Workspace token pairing flow",
      );
    },
  );
});
