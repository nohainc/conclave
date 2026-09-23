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
    if (
      request.method === "POST" ||
      request.method === "PUT" ||
      request.method === "PATCH" ||
      request.method === "DELETE"
    ) {
      deps.requireSameOriginForCookieMutation(request);
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
    const workspaceInvitationsMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/invitations$/,
    );
    if (workspaceInvitationsMatch?.[1]) {
      if (request.method === "GET") {
        return await handlers.handleListWorkspaceInvitations!(
          request,
          env,
          workspaceInvitationsMatch[1],
          ctx,
        );
      }
      if (request.method === "POST") {
        return await handlers.handleCreateWorkspaceInvitation!(
          request,
          env,
          workspaceInvitationsMatch[1],
          ctx,
        );
      }
    }
    const invitationExpireMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/invitations\/([^/]+)\/expire$/,
    );
    if (
      request.method === "POST" &&
      invitationExpireMatch?.[1] &&
      invitationExpireMatch[2]
    ) {
      return await handlers.handleExpireWorkspaceInvitation!(
        request,
        env,
        invitationExpireMatch[1],
        invitationExpireMatch[2],
        ctx,
      );
    }
    const invitationAcceptMatch = url.pathname.match(
      /^\/api\/invitations\/([^/]+)\/accept$/,
    );
    if (request.method === "POST" && invitationAcceptMatch?.[1]) {
      return await handlers.handleAcceptWorkspaceInvitation!(
        request,
        env,
        invitationAcceptMatch[1],
        ctx,
      );
    }
    const memberRoleMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/members\/([^/]+)\/role$/,
    );
    if (
      request.method === "PATCH" &&
      memberRoleMatch?.[1] &&
      memberRoleMatch[2]
    ) {
      return await handlers.handleChangeWorkspaceMemberRole!(
        request,
        env,
        memberRoleMatch[1],
        memberRoleMatch[2],
        ctx,
      );
    }
    const memberStatusMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/members\/([^/]+)\/(suspend|remove|activate)$/,
    );
    if (
      request.method === "POST" &&
      memberStatusMatch?.[1] &&
      memberStatusMatch[2] &&
      memberStatusMatch[3]
    ) {
      const status =
        memberStatusMatch[3] === "suspend"
          ? "suspended"
          : memberStatusMatch[3] === "remove"
            ? "removed"
            : "active";
      return await handlers.handleWorkspaceMemberStatus!(
        request,
        env,
        memberStatusMatch[1],
        memberStatusMatch[2],
        status,
        ctx,
      );
    }

    // Host Gateway & Protocol routes
    if (
      request.method === "POST" &&
      url.pathname === "/api/internal/agent-assignments/dispatch"
    ) {
      return await handlers.handleInternalDispatchTaskAssignment!(request, env);
    }
    if (
      request.method === "GET" &&
      (url.pathname === "/api/host-gateway/connect" ||
        url.pathname === "/api/v2/host-gateway/connect")
    ) {
      return await handlers.handleHostGatewayConnect!(request, env);
    }
    if (
      request.method === "POST" &&
      (url.pathname === "/api/host-protocol/messages" ||
        url.pathname === "/api/v2/host-protocol/messages")
    ) {
      return await handlers.handleHostProtocolMessage!(request, env);
    }
    if (
      request.method === "POST" &&
      (url.pathname === "/api/hosts/enroll" ||
        url.pathname === "/api/v2/hosts/enroll")
    ) {
      return await handlers.handleEnrollHost!(request, env);
    }

    // Workspace Agent Enrollments
    const agentEnrollmentsMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/host-enrollments$/,
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
      /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/host-enrollments\/([^/]+)$/,
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
      return await handlers.handleSetWorkspaceWorkerAvailability!(
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

    const accountsMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/accounts$/,
    );
    if (request.method === "GET" && accountsMatch?.[1]) {
      return await handlers.handleListCredentialProfiles!(
        request,
        env,
        accountsMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && accountsMatch?.[1]) {
      return await handlers.handleCreateCredentialProfile!(
        request,
        env,
        accountsMatch[1],
        ctx,
      );
    }
    const accountMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/accounts\/([^/]+)$/,
    );
    if (request.method === "PATCH" && accountMatch?.[1] && accountMatch?.[2]) {
      return await handlers.handleUpdateCredentialProfile!(
        request,
        env,
        accountMatch[1],
        accountMatch[2],
        ctx,
      );
    }
    if (request.method === "DELETE" && accountMatch?.[1] && accountMatch?.[2]) {
      return await handlers.handleRevokeCredentialProfile!(
        request,
        env,
        accountMatch[1],
        accountMatch[2],
        ctx,
      );
    }
    const setupIntentMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/accounts\/([^/]+)\/setup-intent$/,
    );
    if (
      request.method === "POST" &&
      setupIntentMatch?.[1] &&
      setupIntentMatch?.[2]
    ) {
      return await handlers.handleCreateCredentialSetupIntent!(
        request,
        env,
        setupIntentMatch[1],
        setupIntentMatch[2],
        ctx,
      );
    }
    const accountGrantsMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/accounts\/([^/]+)\/grants$/,
    );
    if (
      request.method === "POST" &&
      accountGrantsMatch?.[1] &&
      accountGrantsMatch?.[2]
    ) {
      return await handlers.handleCreateCredentialGrant!(
        request,
        env,
        accountGrantsMatch[1],
        accountGrantsMatch[2],
        ctx,
      );
    }
    const accountGrantMatch = url.pathname.match(
      /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/accounts\/([^/]+)\/grants\/([^/]+)$/,
    );
    if (
      request.method === "DELETE" &&
      accountGrantMatch?.[1] &&
      accountGrantMatch?.[2] &&
      accountGrantMatch?.[3]
    ) {
      return await handlers.handleRevokeCredentialGrant!(
        request,
        env,
        accountGrantMatch[1],
        accountGrantMatch[2],
        accountGrantMatch[3],
        ctx,
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
    const usageReadModelMatch = url.pathname.match(
      /^\/api\/workspaces\/([^/]+)\/usage$/,
    );
    if (request.method === "GET" && usageReadModelMatch?.[1]) {
      return await handlers.handleWorkspaceUsage!(
        request,
        env,
        usageReadModelMatch[1],
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
