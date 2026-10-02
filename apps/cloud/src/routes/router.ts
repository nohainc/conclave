import { BUILTIN_WORKFLOW_CATALOG } from "@conclave/core";

export type RouteHandler = (...args: unknown[]) => Promise<Response>;
export type WorkerRouteHandlers = Record<string, RouteHandler>;

export interface WorkerRouteDependencies {
  readonly json: (data: unknown, init?: ResponseInit) => Response;
  readonly requireSameOriginForCookieMutation: (request: Request) => void;
  readonly testAuthenticationEnabled: (env: Env) => boolean;
  readonly runProjectId: (
    env: Env,
    runId: string,
  ) => Promise<string | undefined>;
  readonly authorizeRequest: (...args: unknown[]) => Promise<void>;
  readonly resolveWorkflowInstanceId: (
    env: Env,
    runId: string,
  ) => Promise<string>;
  readonly errorMessage: (error: unknown) => string;
  readonly HttpError: new (...args: unknown[]) => Error;
}

export async function routeWorkerRequest(
  request: Request,
  env: Env,
  ctx: ExecutionContext | undefined,
  handlers: WorkerRouteHandlers,
  deps: WorkerRouteDependencies,
): Promise<Response> {
  const url = new URL(request.url);
  try {
    const workspaceEnrollmentRedeem =
      request.method === "POST" &&
      url.pathname === "/api/workspace-runtime/enroll";
    const desktopWorkspaceRegistration =
      request.method === "POST" &&
      url.pathname === "/api/workspace-runtime/register";
    const desktopWorkspaceOwnershipCheck =
      request.method === "POST" &&
      url.pathname === "/api/workspace-runtime/ownership";
    const desktopWorkspaceRelease =
      request.method === "POST" &&
      url.pathname === "/api/workspace-runtime/release";
    const desktopWorkspaceDisconnect =
      request.method === "POST" &&
      url.pathname === "/api/workspace-runtime/disconnect";
    const workspaceRuntimeUnpair =
      request.method === "POST" &&
      url.pathname === "/api/workspace-runtime/unpair";
    const workspaceRuntimeTransport =
      request.method === "POST" &&
      (url.pathname === "/api/workspace-runtime/sessions" ||
        url.pathname === "/api/workspace-runtime/events" ||
        url.pathname === "/api/workspace-runtime/poll" ||
        /^\/api\/workspace-runtime\/sessions\/[^/]+\/close$/.test(
          url.pathname,
        ));
    const desktopAuthPath = url.pathname.startsWith("/api/desktop-auth/");
    const desktopAuthRequiresSameOrigin =
      desktopAuthPath &&
      (url.pathname.endsWith("/approve") || url.pathname.endsWith("/deny"));
    if (
      !workspaceEnrollmentRedeem &&
      !desktopWorkspaceRegistration &&
      !desktopWorkspaceOwnershipCheck &&
      !desktopWorkspaceRelease &&
      !desktopWorkspaceDisconnect &&
      !workspaceRuntimeUnpair &&
      !workspaceRuntimeTransport &&
      (!desktopAuthPath || desktopAuthRequiresSameOrigin) &&
      (request.method === "POST" ||
        request.method === "PUT" ||
        request.method === "PATCH" ||
        request.method === "DELETE")
    ) {
      deps.requireSameOriginForCookieMutation(request);
    }
    if (workspaceEnrollmentRedeem) {
      return await handlers.handleRedeemWorkspaceEnrollment!(request, env, ctx);
    }
    if (desktopWorkspaceRegistration) {
      return await handlers.handleRegisterWorkspaceFromDesktop!(
        request,
        env,
        ctx,
      );
    }
    if (desktopWorkspaceOwnershipCheck) {
      return await handlers.handleCheckWorkspaceOwnership!(request, env);
    }
    if (desktopWorkspaceRelease) {
      return await handlers.handleReleaseDesktopWorkspace!(request, env);
    }
    if (desktopWorkspaceDisconnect) {
      return await handlers.handleDisconnectDesktopWorkspace!(request, env);
    }
    if (workspaceRuntimeUnpair) {
      return await handlers.handleUnpairWorkspaceRuntime!(request, env);
    }
    if (workspaceRuntimeTransport) {
      return await handlers.handleWorkspaceRuntimeTransport!(request, env);
    }
    if (
      request.method === "POST" &&
      url.pathname === "/api/desktop-auth/intents"
    ) {
      return await handlers.handleCreateDesktopAuthIntent!(request, env);
    }
    if (
      request.method === "GET" &&
      url.pathname === "/api/desktop-auth/session"
    ) {
      return await handlers.handleGetDesktopHumanSession!(request, env);
    }
    const desktopIntentMatch = url.pathname.match(
      /^\/api\/desktop-auth\/intents\/([^/]+)(?:\/(approve|claim|cancel|deny|browser-status))?$/,
    );
    if (desktopIntentMatch?.[1]) {
      const intentId = decodeURIComponent(desktopIntentMatch[1]);
      if (request.method === "GET" && !desktopIntentMatch[2]) {
        return await handlers.handleDesktopAuthIntentStatus!(
          request,
          env,
          intentId,
        );
      }
      if (
        request.method === "GET" &&
        desktopIntentMatch[2] === "browser-status"
      ) {
        return await handlers.handleDesktopAuthIntentBrowserStatus!(
          request,
          env,
          intentId,
        );
      }
      if (request.method === "POST" && desktopIntentMatch[2] === "cancel") {
        return await handlers.handleCancelDesktopAuthIntent!(
          request,
          env,
          intentId,
        );
      }
      if (request.method === "POST" && desktopIntentMatch[2] === "deny") {
        return await handlers.handleDenyDesktopAuthIntent!(
          request,
          env,
          intentId,
        );
      }
      if (request.method === "POST" && desktopIntentMatch[2] === "approve") {
        return await handlers.handleApproveDesktopAuthIntent!(
          request,
          env,
          intentId,
        );
      }
      if (request.method === "POST" && desktopIntentMatch[2] === "claim") {
        return await handlers.handleClaimDesktopAuthIntent!(
          request,
          env,
          intentId,
        );
      }
    }
    const desktopSessionRevokeMatch = url.pathname.match(
      /^\/api\/desktop-auth\/sessions\/([^/]+)\/revoke$/,
    );
    if (request.method === "POST" && desktopSessionRevokeMatch?.[1]) {
      return await handlers.handleRevokeDesktopHumanSession!(
        request,
        env,
        decodeURIComponent(desktopSessionRevokeMatch[1]),
      );
    }
    const desktopSessionRotateMatch = url.pathname.match(
      /^\/api\/desktop-auth\/sessions\/([^/]+)\/rotate$/,
    );
    if (request.method === "POST" && desktopSessionRotateMatch?.[1]) {
      return await handlers.handleRotateDesktopHumanSession!(
        request,
        env,
        decodeURIComponent(desktopSessionRotateMatch[1]),
      );
    }
    if (request.method === "GET" && url.pathname === "/api/session") {
      return await handlers.handleSession!(request, env, ctx);
    }
    if (request.method === "POST" && url.pathname === "/api/session/logout") {
      return await handlers.handleSessionLogout!(request, env, ctx);
    }
    const connectorMatch = url.pathname.match(
      /^\/api\/connector\/(register_session|claim_task|get_task|get_context|get_next_message|submit_candidate|submit_result|submit_finding|report_status|release_task)$/,
    );
    if (request.method === "POST" && connectorMatch?.[1]) {
      return await handlers.handleConnectorRequest!(
        request,
        env,
        connectorMatch[1],
      );
    }
    if (
      request.method === "POST" &&
      url.pathname === "/api/connector/tasks/register"
    ) {
      return await handlers.handleConnectorTaskRequest!(
        request,
        env,
        undefined,
      );
    }
    const connectorTaskStatusMatch = url.pathname.match(
      /^\/api\/connector\/tasks\/([^/]+)\/status$/,
    );
    if (request.method === "GET" && connectorTaskStatusMatch?.[1]) {
      return await handlers.handleConnectorTaskRequest!(
        request,
        env,
        connectorTaskStatusMatch[1],
      );
    }
    if (request.method === "GET" && url.pathname === "/api/workspaces") {
      return await handlers.handleListWorkspaces!(request, env, ctx);
    }
    if (
      request.method === "POST" &&
      url.pathname === "/api/workspace-pairing-intents"
    ) {
      return await handlers.handleCreateWorkspacePairingIntent!(
        request,
        env,
        ctx,
      );
    }
    const pairingIntentMatch = url.pathname.match(
      /^\/api\/workspace-pairing-intents\/([^/]+)(?:\/(regenerate|cancel))?$/,
    );
    if (pairingIntentMatch?.[1]) {
      if (request.method === "GET" && !pairingIntentMatch[2]) {
        return await handlers.handleGetWorkspacePairingIntent!(
          request,
          env,
          pairingIntentMatch[1],
          ctx,
        );
      }
      if (request.method === "POST" && pairingIntentMatch[2] === "regenerate") {
        return await handlers.handleRegenerateWorkspacePairingIntent!(
          request,
          env,
          pairingIntentMatch[1],
          ctx,
        );
      }
      if (
        (request.method === "POST" || request.method === "DELETE") &&
        pairingIntentMatch[2] === "cancel"
      ) {
        return await handlers.handleCancelWorkspacePairingIntent!(
          request,
          env,
          pairingIntentMatch[1],
          ctx,
        );
      }
    }
    if (request.method === "POST" && url.pathname === "/api/workspaces") {
      return await handlers.handleCreateWorkspace!(request, env, ctx);
    }
    if (request.method === "GET" && url.pathname === "/api/workflows/catalog") {
      return deps.json({ workflows: Object.values(BUILTIN_WORKFLOW_CATALOG) });
    }
    if (request.method === "GET" && url.pathname === "/api/release-trust") {
      return await handlers.handleGetReleaseTrustState!(request, env, ctx);
    }
    const releaseKeyRevocation = url.pathname.match(
      /^\/api\/admin\/release-trust\/keys\/([^/]+)\/revoke$/,
    );
    if (request.method === "POST" && releaseKeyRevocation?.[1]) {
      return await handlers.handleRevokeReleaseSigningKey!(
        request,
        env,
        decodeURIComponent(releaseKeyRevocation[1]),
        ctx,
      );
    }
    if (request.method === "GET" && url.pathname === "/api/tool-profiles") {
      return await handlers.handleResolveToolProfileChannels!(
        request,
        env,
        ctx,
      );
    }
    if (request.method === "GET" && url.pathname === "/api/workers") {
      return await handlers.handleListWorkspaceWorkerInventory!(
        request,
        env,
        ctx,
      );
    }
    if (
      request.method === "POST" &&
      url.pathname === "/api/admin/tool-profiles/definitions"
    ) {
      return await handlers.handleCreateToolProfileDefinition!(
        request,
        env,
        ctx,
      );
    }
    if (
      request.method === "POST" &&
      url.pathname === "/api/admin/workers/catalog"
    ) {
      return await handlers.handleCreateApprovedLogicalWorker!(
        request,
        env,
        ctx,
      );
    }
    const toolProfileReleaseMatch = url.pathname.match(
      /^\/api\/admin\/tool-profiles\/([^/]+)\/releases(?:\/(\d+)(?:\/(draft|publish|promote|retire|revoke|audit))?)?$/,
    );
    if (toolProfileReleaseMatch?.[1]) {
      const profileDefinitionId = decodeURIComponent(
        toolProfileReleaseMatch[1],
      );
      const version = toolProfileReleaseMatch[2];
      const action = toolProfileReleaseMatch[3];
      if (request.method === "GET" && !version) {
        return await handlers.handleListToolProfileReleases!(
          request,
          env,
          profileDefinitionId,
          ctx,
        );
      }
      if (request.method === "POST" && !version) {
        return await handlers.handleCreateDraftToolProfileRelease!(
          request,
          env,
          profileDefinitionId,
          ctx,
        );
      }
      if (version && action === "audit" && request.method === "GET") {
        return await handlers.handleListToolProfileReleaseAudit!(
          request,
          env,
          profileDefinitionId,
          version,
          ctx,
        );
      }
      if (version && action === "draft" && request.method === "PUT") {
        return await handlers.handleUpdateDraftToolProfileRelease!(
          request,
          env,
          profileDefinitionId,
          version,
          ctx,
        );
      }
      if (version && action === "publish" && request.method === "POST") {
        return await handlers.handlePublishDraftToolProfileRelease!(
          request,
          env,
          profileDefinitionId,
          version,
          ctx,
        );
      }
      if (version && action === "promote" && request.method === "POST") {
        return await handlers.handlePromoteToolProfileRelease!(
          request,
          env,
          profileDefinitionId,
          version,
          ctx,
        );
      }
      if (
        version &&
        (action === "retire" || action === "revoke") &&
        request.method === "POST"
      ) {
        return await handlers.handleChangeToolProfileReleaseLifecycle!(
          request,
          env,
          profileDefinitionId,
          version,
          action,
          ctx,
        );
      }
    }
    const workspaceProjectsMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/projects$/,
    );
    if (request.method === "GET" && workspaceProjectsMatch?.[1]) {
      return await handlers.handleListWorkspaceProjectGrants!(
        request,
        env,
        workspaceProjectsMatch[1],
        ctx,
      );
    }
    const workspaceProjectGrantMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/projects\/([^/]+)\/grant$/,
    );
    if (
      request.method === "POST" &&
      workspaceProjectGrantMatch?.[1] &&
      workspaceProjectGrantMatch?.[2]
    ) {
      return await handlers.handleCreateWorkspaceProjectGrant!(
        request,
        env,
        workspaceProjectGrantMatch[1],
        workspaceProjectGrantMatch[2],
        ctx,
      );
    }
    const projectWorkspacesMatch = url.pathname.match(
      /^\/api\/projects\/([^/]+)\/workspaces$/,
    );
    if (request.method === "GET" && projectWorkspacesMatch?.[1]) {
      return await handlers.handleListProjectWorkspaces!(
        request,
        env,
        projectWorkspacesMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && projectWorkspacesMatch?.[1]) {
      return await handlers.handleRequestProjectWorkspace!(
        request,
        env,
        projectWorkspacesMatch[1],
        ctx,
      );
    }
    const grantItemMatch = url.pathname.match(
      /^\/api\/workspace-project-grants\/([^/]+)$/,
    );
    if (request.method === "PATCH" && grantItemMatch?.[1]) {
      return await handlers.handleUpdateWorkspaceProjectGrant!(
        request,
        env,
        grantItemMatch[1],
        ctx,
      );
    }
    if (request.method === "DELETE" && grantItemMatch?.[1]) {
      return await handlers.handleRevokeWorkspaceProjectGrant!(
        request,
        env,
        grantItemMatch[1],
        ctx,
      );
    }
    const artifactUploadMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/artifacts$/,
    );
    if (request.method === "POST" && artifactUploadMatch?.[1]) {
      return await handlers.handleUploadArtifact!(
        request,
        env,
        artifactUploadMatch[1],
        ctx,
      );
    }
    const artifactMatch = url.pathname.match(/^\/api\/artifacts\/([^/]+)$/);
    if (
      (request.method === "GET" || request.method === "HEAD") &&
      artifactMatch?.[1]
    ) {
      return await handlers.handleGetArtifact!(
        request,
        env,
        artifactMatch[1],
        ctx,
      );
    }
    const auditExportMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/audit-export$/,
    );
    if (request.method === "GET" && auditExportMatch?.[1]) {
      return await handlers.handleExportWorkspaceAudit!(
        request,
        env,
        auditExportMatch[1],
        ctx,
      );
    }
    const backupMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/backup$/,
    );
    if (request.method === "POST" && backupMatch?.[1]) {
      return await handlers.handleCreateWorkspaceBackup!(
        request,
        env,
        backupMatch[1],
        ctx,
      );
    }
    const backupRestoreDrillMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/backup\/restore-drill$/,
    );
    if (request.method === "POST" && backupRestoreDrillMatch?.[1]) {
      return await handlers.handleVerifyWorkspaceBackup!(
        request,
        env,
        backupRestoreDrillMatch[1],
        ctx,
      );
    }
    // Workspace runtime Gateway & Protocol routes
    if (
      request.method === "GET" &&
      url.pathname === "/api/workspace-gateway/connect"
    ) {
      return await handlers.handleWorkspaceGatewayConnect!(request, env);
    }
    // Execution Workspace enrollments. The old Host enrollment URL is gone;
    // enrollment is owned by the execution Workspace and has no tenant
    // membership semantics.
    const agentEnrollmentsMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/enrollments$/,
    );
    if (request.method === "GET" && agentEnrollmentsMatch?.[1]) {
      return await handlers.handleListWorkspaceEnrollments!(
        request,
        env,
        agentEnrollmentsMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && agentEnrollmentsMatch?.[1]) {
      return await handlers.handleCreateWorkspaceEnrollment!(
        request,
        env,
        agentEnrollmentsMatch[1],
        ctx,
      );
    }
    const revokeEnrollmentMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/enrollments\/([^/]+)$/,
    );
    if (
      request.method === "DELETE" &&
      revokeEnrollmentMatch?.[1] &&
      revokeEnrollmentMatch?.[2]
    ) {
      return await handlers.handleRevokeWorkspaceEnrollment!(
        request,
        env,
        revokeEnrollmentMatch[1],
        revokeEnrollmentMatch[2],
        ctx,
      );
    }
    // Workspace Agents Fleet
    const toolProfileChannelMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/tool-profile-channel$/,
    );
    if (request.method === "PATCH" && toolProfileChannelMatch?.[1]) {
      return await handlers.handleSetWorkspaceToolProfileChannel!(
        request,
        env,
        decodeURIComponent(toolProfileChannelMatch[1]),
        ctx,
      );
    }
    // Workspace application release routes.
    if (
      request.method === "GET" &&
      url.pathname === "/api/workspace-releases/latest"
    ) {
      return await handlers.handleGetLatestWorkspaceRelease!(request, env);
    }
    if (
      request.method === "POST" &&
      url.pathname === "/api/workspace-releases/publish"
    ) {
      return await handlers.handlePublishWorkspaceRelease!(request, env, ctx);
    }
    const workspaceReleaseDownloadMatch = url.pathname.match(
      /^\/api\/workspace-releases\/([^/]+)\/download$/,
    );
    if (request.method === "GET" && workspaceReleaseDownloadMatch?.[1]) {
      return await handlers.handleDownloadWorkspaceRelease!(
        request,
        env,
        workspaceReleaseDownloadMatch[1],
        ctx,
      );
    }
    const workspaceReleaseRevokeMatch = url.pathname.match(
      /^\/api\/workspace-releases\/([^/]+)\/revoke$/,
    );
    if (request.method === "POST" && workspaceReleaseRevokeMatch?.[1]) {
      return await handlers.handleRevokeWorkspaceRelease!(
        request,
        env,
        workspaceReleaseRevokeMatch[1],
        ctx,
      );
    }
    const singleWorkspaceReleaseMatch = url.pathname.match(
      /^\/api\/workspace-releases\/([^/]+)$/,
    );
    if (request.method === "GET" && singleWorkspaceReleaseMatch?.[1]) {
      return await handlers.handleGetWorkspaceRelease!(
        env,
        singleWorkspaceReleaseMatch[1],
      );
    }

    const workspaceMatch = url.pathname.match(/^\/api\/workspaces\/([^/]+)$/);
    if (request.method === "DELETE" && workspaceMatch?.[1]) {
      return await handlers.handleRevokeWorkspace!(
        request,
        env,
        workspaceMatch[1],
        ctx,
      );
    }
    if (request.method === "PATCH" && workspaceMatch?.[1]) {
      return await handlers.handleUpdateWorkspace!(
        request,
        env,
        workspaceMatch[1],
        ctx,
      );
    }
    if (request.method === "GET" && workspaceMatch?.[1]) {
      return await handlers.handleGetWorkspace!(
        request,
        env,
        workspaceMatch[1],
        ctx,
      );
    }

    if (request.method === "GET" && url.pathname === "/api/projects") {
      return await handlers.handleListProjects!(request, env, ctx);
    }
    if (request.method === "POST" && url.pathname === "/api/projects") {
      return await handlers.handleCreateProject!(request, env, ctx);
    }
    const projectMembersMatch = url.pathname.match(
      /^\/api\/projects\/([^/]+)\/members$/,
    );
    if (request.method === "GET" && projectMembersMatch?.[1]) {
      return await handlers.handleListProjectMembers!(
        request,
        env,
        projectMembersMatch[1],
        ctx,
      );
    }
    const projectMemberRoleMatch = url.pathname.match(
      /^\/api\/projects\/([^/]+)\/members\/([^/]+)\/role$/,
    );
    if (
      request.method === "PATCH" &&
      projectMemberRoleMatch?.[1] &&
      projectMemberRoleMatch[2]
    ) {
      return await handlers.handleChangeProjectMemberRole!(
        request,
        env,
        projectMemberRoleMatch[1],
        projectMemberRoleMatch[2],
        ctx,
      );
    }
    const projectMemberRemoveMatch = url.pathname.match(
      /^\/api\/projects\/([^/]+)\/members\/([^/]+)\/remove$/,
    );
    if (
      request.method === "POST" &&
      projectMemberRemoveMatch?.[1] &&
      projectMemberRemoveMatch[2]
    ) {
      return await handlers.handleRemoveProjectMember!(
        request,
        env,
        projectMemberRemoveMatch[1],
        projectMemberRemoveMatch[2],
        ctx,
      );
    }
    const projectInvitationsMatch = url.pathname.match(
      /^\/api\/projects\/([^/]+)\/invitations$/,
    );
    if (request.method === "GET" && projectInvitationsMatch?.[1]) {
      return await handlers.handleListProjectInvitations!(
        request,
        env,
        projectInvitationsMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && projectInvitationsMatch?.[1]) {
      return await handlers.handleCreateProjectInvitation!(
        request,
        env,
        projectInvitationsMatch[1],
        ctx,
      );
    }
    const projectAuditMatch = url.pathname.match(
      /^\/api\/projects\/([^/]+)\/audit$/,
    );
    if (request.method === "GET" && projectAuditMatch?.[1]) {
      return await handlers.handleListProjectAudit!(
        request,
        env,
        projectAuditMatch[1],
        ctx,
      );
    }
    const projectInvitationExpireMatch = url.pathname.match(
      /^\/api\/projects\/([^/]+)\/invitations\/([^/]+)\/expire$/,
    );
    if (
      request.method === "POST" &&
      projectInvitationExpireMatch?.[1] &&
      projectInvitationExpireMatch[2]
    ) {
      return await handlers.handleExpireProjectInvitation!(
        request,
        env,
        projectInvitationExpireMatch[1],
        projectInvitationExpireMatch[2],
        ctx,
      );
    }
    const projectInvitationAcceptMatch = url.pathname.match(
      /^\/api\/project-invitations\/([^/]+)\/accept$/,
    );
    if (request.method === "POST" && projectInvitationAcceptMatch?.[1]) {
      return await handlers.handleAcceptProjectInvitation!(
        request,
        env,
        projectInvitationAcceptMatch[1],
        ctx,
      );
    }
    const projectMatch = url.pathname.match(/^\/api\/projects\/([^/]+)$/);
    if (request.method === "GET" && projectMatch?.[1]) {
      return await handlers.handleGetProject!(
        request,
        env,
        projectMatch[1],
        ctx,
      );
    }
    if (request.method === "PATCH" && projectMatch?.[1]) {
      return await handlers.handleUpdateProject!(
        request,
        env,
        projectMatch[1],
        ctx,
      );
    }
    if (request.method === "DELETE" && projectMatch?.[1]) {
      return await handlers.handleDeleteProject!(
        request,
        env,
        projectMatch[1],
        ctx,
      );
    }

    const projectWorkstreamsMatch = url.pathname.match(
      /^\/api\/projects\/([^/]+)\/workstreams$/,
    );
    if (request.method === "GET" && projectWorkstreamsMatch?.[1]) {
      return await handlers.handleListProjectWorkstreams!(
        request,
        env,
        projectWorkstreamsMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && projectWorkstreamsMatch?.[1]) {
      return await handlers.handleCreateWorkstream!(
        request,
        env,
        projectWorkstreamsMatch[1],
        ctx,
      );
    }

    const workstreamMatch = url.pathname.match(/^\/api\/workstreams\/([^/]+)$/);
    if (request.method === "PATCH" && workstreamMatch?.[1]) {
      return await handlers.handleUpdateWorkstream!(
        request,
        env,
        workstreamMatch[1],
        ctx,
      );
    }
    if (request.method === "DELETE" && workstreamMatch?.[1]) {
      return await handlers.handleDeleteWorkstream!(
        request,
        env,
        workstreamMatch[1],
        ctx,
      );
    }

    const workstreamDiscussionMatch = url.pathname.match(
      /^\/api\/workstreams\/([^/]+)\/discussion-messages$/,
    );
    if (request.method === "GET" && workstreamDiscussionMatch?.[1]) {
      return await handlers.handleListDiscussionMessages!(
        request,
        env,
        workstreamDiscussionMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && workstreamDiscussionMatch?.[1]) {
      return await handlers.handleCreateDiscussionMessage!(
        request,
        env,
        workstreamDiscussionMatch[1],
        ctx,
      );
    }
    const workstreamCheckoutsMatch = url.pathname.match(
      /^\/api\/workstreams\/([^/]+)\/checkouts$/,
    );
    if (request.method === "GET" && workstreamCheckoutsMatch?.[1]) {
      return await handlers.handleListWorkstreamCheckouts!(
        request,
        env,
        workstreamCheckoutsMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && workstreamCheckoutsMatch?.[1]) {
      return await handlers.handleProvisionWorkstreamCheckout!(
        request,
        env,
        workstreamCheckoutsMatch[1],
        ctx,
      );
    }
    const discussionMessageMatch = url.pathname.match(
      /^\/api\/discussion-messages\/([^/]+)$/,
    );
    if (request.method === "PATCH" && discussionMessageMatch?.[1]) {
      return await handlers.handleEditDiscussionMessage!(
        request,
        env,
        discussionMessageMatch[1],
        ctx,
      );
    }
    const createWorkRequestMatch = url.pathname.match(
      /^\/api\/workstreams\/([^/]+)\/work-requests$/,
    );
    const validateWorkRequestMatch = url.pathname.match(
      /^\/api\/workstreams\/([^/]+)\/work-requests\/validate$/,
    );
    if (request.method === "POST" && validateWorkRequestMatch?.[1]) {
      return await handlers.handleValidateWorkRequest!(
        request,
        env,
        validateWorkRequestMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && createWorkRequestMatch?.[1]) {
      return await handlers.handleCreateWorkRequest!(
        request,
        env,
        createWorkRequestMatch[1],
        ctx,
      );
    }
    if (request.method === "GET" && createWorkRequestMatch?.[1]) {
      return await handlers.handleListWorkRequests!(
        request,
        env,
        createWorkRequestMatch[1],
        ctx,
      );
    }
    const cancelWorkRequestMatch = url.pathname.match(
      /^\/api\/work-requests\/([^/]+)\/cancel$/,
    );
    const retryWorkRequestMatch = url.pathname.match(
      /^\/api\/work-requests\/([^/]+)\/retry$/,
    );
    const workRequestMatch = url.pathname.match(
      /^\/api\/work-requests\/([^/]+)$/,
    );
    if (request.method === "GET" && workRequestMatch?.[1]) {
      return await handlers.handleGetWorkRequest!(
        request,
        env,
        workRequestMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && cancelWorkRequestMatch?.[1]) {
      return await handlers.handleCancelWorkRequest!(
        request,
        env,
        cancelWorkRequestMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && retryWorkRequestMatch?.[1]) {
      return await handlers.handleRetryWorkRequest!(
        request,
        env,
        retryWorkRequestMatch[1],
        ctx,
      );
    }

    if (request.method === "GET" && url.pathname === "/api/studio/snapshot") {
      return await handlers.handleStudioSnapshot!(
        env,
        request,
        url.searchParams.get("projectId"),
        ctx,
      );
    }
    const projectReadModelMatch = url.pathname.match(
      /^\/api\/projects\/([^/]+)\/read-model$/,
    );
    if (request.method === "GET" && projectReadModelMatch?.[1]) {
      return await handlers.handleProjectReadModel!(
        env,
        request,
        projectReadModelMatch[1],
        ctx,
      );
    }
    const runMatch = url.pathname.match(
      /^\/api\/runs\/([^/]+)(?:\/(pause|resume|restart|cancel|events|ci-evidence|forge-events))?$/,
    );
    if (runMatch?.[1] && request.method === "GET" && !runMatch[2]) {
      const securityEnv = env;
      const projectId = deps.testAuthenticationEnabled(securityEnv)
        ? undefined
        : await deps.runProjectId(securityEnv, runMatch[1]);
      await deps.authorizeRequest(
        request,
        securityEnv,
        "projects:read",
        projectId,
        ctx,
      );
      const workflowInstanceId = await deps.resolveWorkflowInstanceId(
        env,
        runMatch[1],
      );
      const instance = await env.CONCLAVE_RUN_WORKFLOW.get(workflowInstanceId);
      return deps.json({
        id: runMatch[1],
        workflowInstanceId,
        ...(await instance.status()),
      });
    }
    if (runMatch?.[1] && request.method === "POST" && runMatch[2]) {
      const command =
        runMatch[2] === "events"
          ? "event"
          : runMatch[2] === "ci-evidence"
            ? "ci-evidence"
            : runMatch[2] === "forge-events"
              ? "forge-terminal"
              : (runMatch[2] as "pause" | "resume" | "restart" | "cancel");
      return await handlers.handleRunCommand!(
        request,
        env,
        runMatch[1],
        command,
        ctx,
      );
    }
  } catch (error) {
    return deps.json(
      { error: deps.errorMessage(error) },
      {
        status:
          error instanceof deps.HttpError ||
          (typeof error === "object" &&
            error !== null &&
            "status" in error &&
            typeof error.status === "number")
            ? (error as { status: number }).status
            : 400,
      },
    );
  }

  return deps.json({ error: "not_found" }, { status: 404 });
}
