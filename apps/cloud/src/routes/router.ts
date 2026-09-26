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
    if (
      !workspaceEnrollmentRedeem &&
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
    if (request.method === "GET" && url.pathname === "/api/session") {
      return await handlers.handleSession!(request, env, ctx);
    }
    if (request.method === "POST" && url.pathname === "/api/session/logout") {
      return await handlers.handleSessionLogout!(request, env, ctx);
    }
    if (
      request.method === "GET" &&
      url.pathname === "/api/invitations/pending"
    ) {
      return await handlers.handleListPendingInvitations!(request, env, ctx);
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
    if (request.method === "POST" && url.pathname === "/api/workspaces") {
      return await handlers.handleCreateWorkspace!(request, env, ctx);
    }
    if (request.method === "GET" && url.pathname === "/api/v7/workers") {
      return await handlers.handleListWorkspaceWorkerInventory!(
        request,
        env,
        ctx,
      );
    }
    const v7WorkerSchedulingMatch = url.pathname.match(
      /^\/api\/v7\/workers\/([^/]+)\/scheduling(?:\/(enable|disable|drain))?$/,
    );
    if (
      v7WorkerSchedulingMatch?.[1] &&
      ((request.method === "GET" && !v7WorkerSchedulingMatch[2]) ||
        (request.method === "POST" && v7WorkerSchedulingMatch[2]))
    ) {
      return await handlers.handleV7WorkerScheduling!(
        request,
        env,
        v7WorkerSchedulingMatch[1],
        v7WorkerSchedulingMatch[2],
        ctx,
      );
    }
    if (request.method === "GET" && url.pathname === "/api/v7/adapters") {
      return await handlers.handleListV7Adapters!(request, env, ctx);
    }
    if (request.method === "GET" && url.pathname === "/api/v7/release-trust") {
      return await handlers.handleGetReleaseTrustState!(request, env, ctx);
    }
    const releaseKeyRevocation = url.pathname.match(
      /^\/api\/v7\/release-trust\/keys\/([^/]+)\/revoke$/,
    );
    if (request.method === "POST" && releaseKeyRevocation?.[1]) {
      return await handlers.handleRevokeReleaseSigningKey!(
        request,
        env,
        decodeURIComponent(releaseKeyRevocation[1]),
        ctx,
      );
    }
    if (
      request.method === "POST" &&
      url.pathname === "/api/v7/adapters/publish"
    ) {
      return await handlers.handlePublishV7Adapter!(request, env, ctx);
    }
    const v7AdapterDownloadMatch = url.pathname.match(
      /^\/api\/v7\/adapters\/([^/]+)\/versions\/([^/]+)\/download$/,
    );
    if (
      request.method === "GET" &&
      v7AdapterDownloadMatch?.[1] &&
      v7AdapterDownloadMatch?.[2]
    ) {
      return await handlers.handleDownloadV7Adapter!(
        request,
        env,
        v7AdapterDownloadMatch[1],
        v7AdapterDownloadMatch[2],
        ctx,
      );
    }
    const v7AdapterRevokeMatch = url.pathname.match(
      /^\/api\/v7\/adapters\/([^/]+)\/versions\/([^/]+)\/revoke$/,
    );
    if (
      request.method === "POST" &&
      v7AdapterRevokeMatch?.[1] &&
      v7AdapterRevokeMatch?.[2]
    ) {
      return await handlers.handleRevokeV7Adapter!(
        request,
        env,
        v7AdapterRevokeMatch[1],
        v7AdapterRevokeMatch[2],
        ctx,
      );
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
      request.method === "POST" &&
      url.pathname === "/api/internal/agent-assignments/dispatch"
    ) {
      return await handlers.handleInternalDispatchTaskAssignment!(request, env);
    }
    if (
      request.method === "GET" &&
      (url.pathname === "/api/workspace-gateway/connect" ||
        url.pathname === "/api/v2/workspace-gateway/connect")
    ) {
      return await handlers.handleWorkspaceGatewayConnect!(request, env);
    }
    // Execution Workspace enrollments. The old Host enrollment URL is gone;
    // enrollment is owned by the execution Workspace and has no tenant
    // membership semantics.
    const agentEnrollmentsMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/enrollments$/,
    );
    if (request.method === "GET" && agentEnrollmentsMatch?.[1]) {
      return await handlers.handleListHostEnrollments!(
        request,
        env,
        agentEnrollmentsMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && agentEnrollmentsMatch?.[1]) {
      return await handlers.handleCreateHostEnrollment!(
        request,
        env,
        agentEnrollmentsMatch[1],
        ctx,
      );
    }
    const revokeEnrollmentMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/enrollments\/([^/]+)$/,
    );
    if (
      request.method === "DELETE" &&
      revokeEnrollmentMatch?.[1] &&
      revokeEnrollmentMatch?.[2]
    ) {
      return await handlers.handleRevokeHostEnrollment!(
        request,
        env,
        revokeEnrollmentMatch[1],
        revokeEnrollmentMatch[2],
        ctx,
      );
    }
    // Workspace Agents Fleet
    const hostsMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/hosts$/,
    );
    if (request.method === "GET" && hostsMatch?.[1]) {
      return await handlers.handleListHosts!(request, env, hostsMatch[1], ctx);
    }
    const bindHostMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/hosts\/([^/]+)\/bind$/,
    );
    if (request.method === "POST" && bindHostMatch?.[1] && bindHostMatch?.[2]) {
      return await handlers.handleBindHostWorkspace!(
        request,
        env,
        bindHostMatch[1],
        bindHostMatch[2],
        ctx,
      );
    }
    const singleAgentMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/hosts\/([^/]+)$/,
    );
    if (
      request.method === "PATCH" &&
      singleAgentMatch?.[1] &&
      singleAgentMatch?.[2]
    ) {
      return await handlers.handleUpdateHost!(
        request,
        env,
        singleAgentMatch[1],
        singleAgentMatch[2],
        ctx,
      );
    }
    if (
      request.method === "GET" &&
      singleAgentMatch?.[1] &&
      singleAgentMatch?.[2]
    ) {
      return await handlers.handleGetHost!(
        request,
        env,
        singleAgentMatch[1],
        singleAgentMatch[2],
        ctx,
      );
    }
    if (
      request.method === "DELETE" &&
      singleAgentMatch?.[1] &&
      singleAgentMatch?.[2]
    ) {
      return await handlers.handleRevokeHost!(
        request,
        env,
        singleAgentMatch[1],
        singleAgentMatch[2],
        ctx,
      );
    }
    const agentUpdateMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/hosts\/([^/]+)\/update$/,
    );
    if (
      request.method === "POST" &&
      agentUpdateMatch?.[1] &&
      agentUpdateMatch?.[2]
    ) {
      return await handlers.handleAnnounceHostUpdate!(
        request,
        env,
        agentUpdateMatch[1],
        agentUpdateMatch[2],
        ctx,
      );
    }
    const desiredStateMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/hosts\/([^/]+)\/desired-state$/,
    );
    if (
      request.method === "PUT" &&
      desiredStateMatch?.[1] &&
      desiredStateMatch?.[2]
    ) {
      return await handlers.handleSetHostDesiredState!(
        request,
        env,
        desiredStateMatch[1],
        desiredStateMatch[2],
        ctx,
      );
    }

    // Workspace Workers Fleet (Architecture v2)
    const workersMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/workers$/,
    );
    if (request.method === "GET" && workersMatch?.[1]) {
      return await handlers.handleListWorkerCatalog!(
        request,
        env,
        workersMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && workersMatch?.[1]) {
      return deps.json(
        { error: "Configured Worker instances were removed in v4" },
        { status: 410 },
      );
    }
    const singleWorkerMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/workers\/([^/]+)$/,
    );
    if (
      request.method === "GET" &&
      singleWorkerMatch?.[1] &&
      singleWorkerMatch?.[2]
    ) {
      return await handlers.handleGetWorkerCatalog!(
        request,
        env,
        singleWorkerMatch[1],
        singleWorkerMatch[2],
        ctx,
      );
    }
    if (
      request.method === "PUT" &&
      singleWorkerMatch?.[1] &&
      singleWorkerMatch?.[2]
    ) {
      return await handlers.handleSetWorkspaceDesiredWorkerState!(
        request,
        env,
        singleWorkerMatch[1],
        singleWorkerMatch[2],
        ctx,
      );
    }
    if (
      request.method === "DELETE" &&
      singleWorkerMatch?.[1] &&
      singleWorkerMatch?.[2]
    ) {
      return deps.json(
        { error: "Configured Worker instances were removed in v4" },
        { status: 410 },
      );
    }

    // Task Assignment Dispatcher (Architecture v2)
    const taskEnsembleDispatchMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/tasks\/([^/]+)\/ensemble-dispatch$/,
    );
    if (
      request.method === "POST" &&
      taskEnsembleDispatchMatch?.[1] &&
      taskEnsembleDispatchMatch?.[2]
    ) {
      return await handlers.handleDispatchEnsembleTaskAssignment!(
        request,
        env,
        taskEnsembleDispatchMatch[1],
        taskEnsembleDispatchMatch[2],
        ctx,
      );
    }

    const taskDispatchMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/tasks\/([^/]+)\/dispatch$/,
    );
    if (
      request.method === "POST" &&
      taskDispatchMatch?.[1] &&
      taskDispatchMatch?.[2]
    ) {
      return await handlers.handleDispatchTaskAssignment!(
        request,
        env,
        taskDispatchMatch[1],
        taskDispatchMatch[2],
        ctx,
      );
    }

    const assignmentCancelMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/assignments\/([^/]+)\/cancel$/,
    );
    if (
      request.method === "POST" &&
      assignmentCancelMatch?.[1] &&
      assignmentCancelMatch?.[2]
    ) {
      return await handlers.handleCancelTaskAssignment!(
        request,
        env,
        assignmentCancelMatch[1],
        assignmentCancelMatch[2],
        ctx,
      );
    }

    // Plugin Registry routes (Architecture v2)
    if (
      request.method === "GET" &&
      (url.pathname === "/api/plugins" || url.pathname === "/api/v2/plugins")
    ) {
      return await handlers.handleListPlugins!(request, env);
    }
    if (
      request.method === "POST" &&
      (url.pathname === "/api/plugins/publish" ||
        url.pathname === "/api/v2/plugins/publish")
    ) {
      return await handlers.handlePublishPlugin!(request, env, ctx);
    }

    const pluginDownloadMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/plugins\/([^/]+)\/versions\/([^/]+)\/download$/,
    );
    if (
      request.method === "GET" &&
      pluginDownloadMatch?.[1] &&
      pluginDownloadMatch?.[2]
    ) {
      return await handlers.handleDownloadPluginVersion!(
        request,
        env,
        pluginDownloadMatch[1],
        pluginDownloadMatch[2],
        ctx,
      );
    }

    const pluginRevokeMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/plugins\/([^/]+)\/versions\/([^/]+)\/revoke$/,
    );
    if (
      request.method === "POST" &&
      pluginRevokeMatch?.[1] &&
      pluginRevokeMatch?.[2]
    ) {
      return await handlers.handleRevokePluginVersion!(
        request,
        env,
        pluginRevokeMatch[1],
        pluginRevokeMatch[2],
        ctx,
      );
    }

    const pluginVersionMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/plugins\/([^/]+)\/versions\/([^/]+)$/,
    );
    if (
      request.method === "GET" &&
      pluginVersionMatch?.[1] &&
      pluginVersionMatch?.[2]
    ) {
      return await handlers.handleGetPluginVersion!(
        env,
        pluginVersionMatch[1],
        pluginVersionMatch[2],
      );
    }

    const pluginDeprecateMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/plugins\/([^/]+)\/deprecate$/,
    );
    if (request.method === "POST" && pluginDeprecateMatch?.[1]) {
      return await handlers.handleDeprecatePlugin!(
        request,
        env,
        pluginDeprecateMatch[1],
        ctx,
      );
    }

    const singlePluginMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/plugins\/([^/]+)$/,
    );
    if (request.method === "GET" && singlePluginMatch?.[1]) {
      return await handlers.handleGetPlugin!(env, singlePluginMatch[1]);
    }

    // Agent Releases routes (Architecture v2 Self-Update)
    if (
      request.method === "GET" &&
      (url.pathname === "/api/host-releases/latest" ||
        url.pathname === "/api/v2/host-releases/latest")
    ) {
      return await handlers.handleGetLatestHostRelease!(request, env);
    }
    if (
      request.method === "POST" &&
      (url.pathname === "/api/host-releases/publish" ||
        url.pathname === "/api/v2/host-releases/publish")
    ) {
      return await handlers.handlePublishHostRelease!(request, env, ctx);
    }
    const agentReleaseDownloadMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/host-releases\/([^/]+)\/download$/,
    );
    if (request.method === "GET" && agentReleaseDownloadMatch?.[1]) {
      return await handlers.handleDownloadHostRelease!(
        request,
        env,
        agentReleaseDownloadMatch[1],
        ctx,
      );
    }
    const agentReleaseRevokeMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/host-releases\/([^/]+)\/revoke$/,
    );
    if (request.method === "POST" && agentReleaseRevokeMatch?.[1]) {
      return await handlers.handleRevokeHostRelease!(
        request,
        env,
        agentReleaseRevokeMatch[1],
        ctx,
      );
    }
    const singleHostReleaseMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/host-releases\/([^/]+)$/,
    );
    if (request.method === "GET" && singleHostReleaseMatch?.[1]) {
      return await handlers.handleGetHostRelease!(
        env,
        singleHostReleaseMatch[1],
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
    const projectChatsMatch = url.pathname.match(
      /^\/api\/projects\/([^/]+)\/chats$/,
    );
    if (request.method === "GET" && projectChatsMatch?.[1]) {
      return await handlers.handleListChats!(
        request,
        env,
        projectChatsMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && projectChatsMatch?.[1]) {
      return await handlers.handleCreateChat!(
        request,
        env,
        projectChatsMatch[1],
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

    const chatGoalsMatch = url.pathname.match(/^\/api\/chats\/([^/]+)\/goals$/);
    if (request.method === "GET" && chatGoalsMatch?.[1]) {
      return await handlers.handleListChatGoals!(
        request,
        env,
        chatGoalsMatch[1],
        ctx,
      );
    }
    const chatMessagesMatch = url.pathname.match(
      /^\/api\/chats\/([^/]+)\/messages$/,
    );
    if (request.method === "GET" && chatMessagesMatch?.[1]) {
      return await handlers.handleListChatMessages!(
        request,
        env,
        chatMessagesMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && chatMessagesMatch?.[1]) {
      return await handlers.handleCreateChatMessage!(
        request,
        env,
        chatMessagesMatch[1],
        ctx,
      );
    }
    const chatMatch = url.pathname.match(/^\/api\/chats\/([^/]+)$/);
    if (request.method === "GET" && chatMatch?.[1]) {
      return await handlers.handleGetChat!(request, env, chatMatch[1], ctx);
    }
    if (request.method === "PATCH" && chatMatch?.[1]) {
      return await handlers.handleUpdateChat!(request, env, chatMatch[1], ctx);
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
    const workRequestMatch = url.pathname.match(
      /^\/api\/workstreams\/([^/]+)\/work-requests$/,
    );
    if (request.method === "POST" && workRequestMatch?.[1]) {
      return await handlers.handleCreateWorkRequest!(
        request,
        env,
        workRequestMatch[1],
        ctx,
      );
    }
    const cancelWorkRequestMatch = url.pathname.match(
      /^\/api\/work-requests\/([^/]+)\/cancel$/,
    );
    if (request.method === "POST" && cancelWorkRequestMatch?.[1]) {
      return await handlers.handleCancelWorkRequest!(
        request,
        env,
        cancelWorkRequestMatch[1],
        ctx,
      );
    }

    if (request.method === "POST" && url.pathname === "/api/runs") {
      return await handlers.handleRunRequest!(request, env, ctx);
    }
    if (request.method === "POST" && url.pathname === "/api/goals") {
      return await handlers.handleGoalRequest!(request, env, ctx);
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
        "project:read",
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
