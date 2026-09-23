export { ConclaveRunWorkflow } from "./workflow.js";
export { HostGateway } from "./host-gateway.js";
export { RealtimeGateway } from "./realtime-gateway.js";
export {
  CloudEventPublisher,
  createEventPublisher,
  type DomainEventInput,
  type EventPublisher,
  type EventPublisherEnv,
  type PublishedEventResult,
} from "./event-publisher.js";
export {
  selectWorkerForTask,
  dispatchTaskAssignment,
  recordAssignmentResult,
  recordAssignmentError,
  cancelTaskAssignment,
  type TaskToDispatch,
  type AssignmentDispatcherEnv,
} from "./assignment-dispatcher.js";
export {
  selectEnsembleCandidateWorkers,
  dispatchEnsembleTaskAssignment,
  type EnsembleDispatchParams,
  type SelectedEnsembleWorker,
} from "./ensemble-dispatcher.js";
export { handleConnectorRequest } from "./interactive-connector.js";
export {
  IdentityService,
  identityService,
  type AuthenticatedIdentity,
} from "./auth/index.js";
export { requireSameOriginForCookieMutation } from "./routes/handlers.js";

import * as handlers from "./routes/handlers.js";
import { handleBetterAuthRequest, identityService } from "./auth/index.js";
import {
  routeWorkerRequest,
  type WorkerRouteDependencies,
  type WorkerRouteHandlers,
} from "./routes/router.js";
import { logStructured, requestIdFor, withRequestId } from "./observability.js";

const routeHandlers = {
  handleSession: handlers.handleSession,
  handleSessionLogout: handlers.handleSessionLogout,
  handleCompleteStepUp: handlers.handleCompleteStepUp,
  handleListPendingInvitations: handlers.handleListPendingInvitations,
  handleConnectorRequest: handlers.handleConnectorRequest,
  handleConnectorTaskRequest: handlers.handleConnectorTaskRequest,
  handleListWorkspaces: handlers.handleListWorkspaces,
  handleCreateWorkspace: handlers.handleCreateWorkspace,
  handleUploadArtifact: handlers.handleUploadArtifact,
  handleGetArtifact: handlers.handleGetArtifact,
  handleExportWorkspaceAudit: handlers.handleExportWorkspaceAudit,
  handleCreateWorkspaceBackup: handlers.handleCreateWorkspaceBackup,
  handleVerifyWorkspaceBackup: handlers.handleVerifyWorkspaceBackup,
  handleListWorkspaceInvitations: handlers.handleListWorkspaceInvitations,
  handleCreateWorkspaceInvitation: handlers.handleCreateWorkspaceInvitation,
  handleExpireWorkspaceInvitation: handlers.handleExpireWorkspaceInvitation,
  handleAcceptWorkspaceInvitation: handlers.handleAcceptWorkspaceInvitation,
  handleChangeWorkspaceMemberRole: handlers.handleChangeWorkspaceMemberRole,
  handleWorkspaceMemberStatus: handlers.handleWorkspaceMemberStatus,
  handleInternalDispatchTaskAssignment:
    handlers.handleInternalDispatchTaskAssignment,
  handleHostGatewayConnect: handlers.handleHostGatewayConnect,
  handleHostProtocolMessage: handlers.handleHostProtocolMessage,
  handleEnrollHost: handlers.handleEnrollHost,
  handleListHostEnrollments: handlers.handleListHostEnrollments,
  handleCreateHostEnrollment: handlers.handleCreateHostEnrollment,
  handleRevokeHostEnrollment: handlers.handleRevokeHostEnrollment,
  handleListHosts: handlers.handleListHosts,
  handleGetHost: handlers.handleGetHost,
  handleRevokeHost: handlers.handleRevokeHost,
  handleAnnounceHostUpdate: handlers.handleAnnounceHostUpdate,
  handleSetHostDesiredState: handlers.handleSetHostDesiredState,
  handleListWorkerCatalog: handlers.handleListWorkerCatalog,
  handleGetWorkerCatalog: handlers.handleGetWorkerCatalog,
  handleDispatchEnsembleTaskAssignment:
    handlers.handleDispatchEnsembleTaskAssignment,
  handleDispatchTaskAssignment: handlers.handleDispatchTaskAssignment,
  handleCancelTaskAssignment: handlers.handleCancelTaskAssignment,
  handleListPlugins: handlers.handleListPlugins,
  handlePublishPlugin: handlers.handlePublishPlugin,
  handleDownloadPluginVersion: handlers.handleDownloadPluginVersion,
  handleRevokePluginVersion: handlers.handleRevokePluginVersion,
  handleGetPluginVersion: handlers.handleGetPluginVersion,
  handleDeprecatePlugin: handlers.handleDeprecatePlugin,
  handleGetPlugin: handlers.handleGetPlugin,
  handleGetLatestHostRelease: handlers.handleGetLatestHostRelease,
  handlePublishHostRelease: handlers.handlePublishHostRelease,
  handleDownloadHostRelease: handlers.handleDownloadHostRelease,
  handleRevokeHostRelease: handlers.handleRevokeHostRelease,
  handleGetHostRelease: handlers.handleGetHostRelease,
  handleGetWorkspace: handlers.handleGetWorkspace,
  handleListProjects: handlers.handleListProjects,
  handleCreateProject: handlers.handleCreateProject,
  handleListChats: handlers.handleListChats,
  handleCreateChat: handlers.handleCreateChat,
  handleGetProject: handlers.handleGetProject,
  handleListChatGoals: handlers.handleListChatGoals,
  handleListChatMessages: handlers.handleListChatMessages,
  handleCreateChatMessage: handlers.handleCreateChatMessage,
  handleGetChat: handlers.handleGetChat,
  handleUpdateChat: handlers.handleUpdateChat,
  handleRunRequest: handlers.handleRunRequest,
  handleGoalRequest: handlers.handleGoalRequest,
  handleStudioSnapshot: handlers.handleStudioSnapshot,
  handleProjectReadModel: handlers.handleProjectReadModel,
  handleWorkspaceUsage: handlers.handleWorkspaceUsage,
  handleRunCommand: handlers.handleRunCommand,
} as unknown as WorkerRouteHandlers;

const routeDependencies = {
  json: handlers.json,
  requireSameOriginForCookieMutation:
    handlers.requireSameOriginForCookieMutation,
  testAuthenticationEnabled: handlers.testAuthenticationEnabled,
  runProjectId: handlers.runProjectId,
  authorizeRequest: handlers.authorizeRequest,
  resolveWorkflowInstanceId: handlers.resolveWorkflowInstanceId,
  errorMessage: handlers.errorMessage,
  HttpError: handlers.HttpError,
} as unknown as WorkerRouteDependencies;

export default {
  async fetch(
    request: Request,
    env: Env,
    ctx?: ExecutionContext,
  ): Promise<Response> {
    const requestId = requestIdFor(request);
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      const requestHeaders = new Headers(request.headers);
      requestHeaders.set("x-request-id", requestId);
      request = new Request(request, { headers: requestHeaders });
    }
    const url = new URL(request.url);
    logStructured(
      "info",
      "http.request",
      { requestId },
      {
        method: request.method,
        path: url.pathname,
      },
    );
    if (request.method === "GET" && url.pathname === "/health") {
      return withRequestId(
        handlers.json({
          ok: true,
          environment: env.CONCLAVE_ENVIRONMENT,
        }),
        requestId,
      );
    }
    if (request.method === "GET" && url.pathname === "/api/dev/sign-in") {
      if (env.CONCLAVE_ENVIRONMENT !== "development") {
        return new Response("Not found", { status: 404 });
      }
      const provider = url.searchParams.get("provider") ?? "github";
      if (provider !== "github" && provider !== "google") {
        return handlers.json(
          { error: "provider must be github or google" },
          { status: 400 },
        );
      }
      const returnTo = url.searchParams.get("returnTo") ?? "/";
      const signInUrl = new URL(`/api/auth/sign-in/${provider}`, request.url);
      signInUrl.searchParams.set("returnTo", returnTo);
      return Response.redirect(signInUrl.toString(), 302);
    }
    if (
      request.method === "POST" &&
      url.pathname === "/api/auth/step-up/passkey/complete"
    ) {
      handlers.requireSameOriginForCookieMutation(request);
      return handlers.handleCompleteStepUp(request, env, ctx);
    }
    if (url.pathname === "/api/auth" || url.pathname.startsWith("/api/auth/")) {
      return withRequestId(
        await handleBetterAuthRequest(request, env),
        requestId,
      );
    }
    if (url.pathname === "/api/realtime") {
      const identity = await identityService.resolve(request, env);
      if (!identity) {
        return withRequestId(
          handlers.json({ error: "Authentication required" }, { status: 401 }),
          requestId,
        );
      }
      const gateway = env.CONCLAVE_REALTIME_GATEWAY.getByName(
        `user:${identity.userId}`,
      );
      return withRequestId(await gateway.fetch(request), requestId);
    }
    return withRequestId(
      await routeWorkerRequest(
        request,
        env,
        ctx,
        routeHandlers,
        routeDependencies,
      ),
      requestId,
    );
  },
} satisfies ExportedHandler<Env>;
