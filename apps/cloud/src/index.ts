export { ConclaveRunWorkflow } from "./workflow.js";
export { WorkspaceGateway } from "./workspace-gateway.js";
export { WorkstreamExecutionCoordinator } from "./workstream-coordinator.js";
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
import {
  isTrustedOrigin,
  isTrustedRealtimeOrigin,
  logStructured,
  requestIdFor,
  withRequestId,
} from "./observability.js";

function applyCorsHeaders(
  response: Response,
  origin: string | null,
  isTrusted: boolean,
): Response {
  if (!origin || !isTrusted || response.status === 101) return response;
  const headers = new Headers(response.headers);
  headers.set("access-control-allow-origin", origin);
  headers.set("access-control-allow-credentials", "true");
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

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
  handleWorkspaceGatewayConnect: handlers.handleWorkspaceGatewayConnect,
  handleEnrollHost: handlers.handleEnrollHost,
  handleBindHostWorkspace: handlers.handleBindHostWorkspace,
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
  handleListConfiguredWorkers: handlers.handleListConfiguredWorkers,
  handleConfiguredWorkerObservability:
    handlers.handleConfiguredWorkerObservability,
  handleCreateConfiguredWorker: handlers.handleCreateConfiguredWorker,
  handleGetConfiguredWorker: handlers.handleGetConfiguredWorker,
  handleUpdateConfiguredWorker: handlers.handleUpdateConfiguredWorker,
  handleRevokeConfiguredWorker: handlers.handleRevokeConfiguredWorker,
  handleListConfiguredWorkerWorkspaces:
    handlers.handleListConfiguredWorkerWorkspaces,
  handleUpdateConfiguredWorkerWorkspaces:
    handlers.handleUpdateConfiguredWorkerWorkspaces,
  handleConfiguredWorkerWorkspaceSetup:
    handlers.handleConfiguredWorkerWorkspaceSetup,
  handleGetConfiguredWorkerWorkspaceCredential:
    handlers.handleGetConfiguredWorkerWorkspaceCredential,
  handleRevokeConfiguredWorkerWorkspaceCredential:
    handlers.handleRevokeConfiguredWorkerWorkspaceCredential,
  handleSetWorkspaceWorkerAvailability:
    handlers.handleSetWorkspaceWorkerAvailability,
  handleSetWorkspaceDesiredWorkerState:
    handlers.handleSetWorkspaceDesiredWorkerState,
  handleListWorkspaceProjectGrants: handlers.handleListWorkspaceProjectGrants,
  handleCreateWorkspaceProjectGrant: handlers.handleCreateWorkspaceProjectGrant,
  handleListProjectWorkspaces: handlers.handleListProjectWorkspaces,
  handleRequestProjectWorkspace: handlers.handleRequestProjectWorkspace,
  handleUpdateWorkspaceProjectGrant: handlers.handleUpdateWorkspaceProjectGrant,
  handleRevokeWorkspaceProjectGrant: handlers.handleRevokeWorkspaceProjectGrant,
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
  handleUpdateWorkspace: handlers.handleUpdateWorkspace,
  handleRevokeWorkspace: handlers.handleRevokeWorkspace,
  handleListProjects: handlers.handleListProjects,
  handleCreateProject: handlers.handleCreateProject,
  handleUpdateProject: handlers.handleUpdateProject,
  handleDeleteProject: handlers.handleDeleteProject,
  handleListProjectMembers: handlers.handleListProjectMembers,
  handleListProjectInvitations: handlers.handleListProjectInvitations,
  handleListProjectAudit: handlers.handleListProjectAudit,
  handleCreateProjectInvitation: handlers.handleCreateProjectInvitation,
  handleChangeProjectMemberRole: handlers.handleChangeProjectMemberRole,
  handleRemoveProjectMember: handlers.handleRemoveProjectMember,
  handleExpireProjectInvitation: handlers.handleExpireProjectInvitation,
  handleAcceptProjectInvitation: handlers.handleAcceptProjectInvitation,
  handleListChats: handlers.handleListChats,
  handleCreateChat: handlers.handleCreateChat,
  handleGetProject: handlers.handleGetProject,
  handleListChatGoals: handlers.handleListChatGoals,
  handleListChatMessages: handlers.handleListChatMessages,
  handleCreateChatMessage: handlers.handleCreateChatMessage,
  handleListProjectWorkstreams: handlers.handleListProjectWorkstreams,
  handleCreateWorkstream: handlers.handleCreateWorkstream,
  handleUpdateWorkstream: handlers.handleUpdateWorkstream,
  handleDeleteWorkstream: handlers.handleDeleteWorkstream,
  handleListDiscussionMessages: handlers.handleListDiscussionMessages,
  handleCreateDiscussionMessage: handlers.handleCreateDiscussionMessage,
  handleEditDiscussionMessage: handlers.handleEditDiscussionMessage,
  handleListWorkstreamCheckouts: handlers.handleListWorkstreamCheckouts,
  handleProvisionWorkstreamCheckout: handlers.handleProvisionWorkstreamCheckout,
  handleCreateWorkRequest: handlers.handleCreateWorkRequest,
  handleCancelWorkRequest: handlers.handleCancelWorkRequest,
  handleGetChat: handlers.handleGetChat,
  handleUpdateChat: handlers.handleUpdateChat,
  handleRunRequest: handlers.handleRunRequest,
  handleGoalRequest: handlers.handleGoalRequest,
  handleStudioSnapshot: handlers.handleStudioSnapshot,
  handleProjectReadModel: handlers.handleProjectReadModel,
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

    const origin = request.headers.get("origin");
    const configuredOrigins = (
      env as unknown as { BETTER_AUTH_TRUSTED_ORIGINS?: string }
    ).BETTER_AUTH_TRUSTED_ORIGINS?.split(",")
      .map((item) => item.trim().replace(/\/$/, ""))
      .filter(Boolean);
    const isTrusted = origin
      ? isTrustedOrigin(request, configuredOrigins)
      : false;

    if (request.method === "OPTIONS" && origin && isTrusted) {
      return withRequestId(
        new Response(null, {
          status: 204,
          headers: {
            "access-control-allow-origin": origin,
            "access-control-allow-credentials": "true",
            "access-control-allow-methods":
              "GET, POST, PUT, PATCH, DELETE, OPTIONS",
            "access-control-allow-headers":
              request.headers.get("access-control-request-headers") ||
              "authorization, content-type, accept, x-request-id",
            "access-control-max-age": "86400",
          },
        }),
        requestId,
      );
    }

    const response = await (async (): Promise<Response> => {
      if (request.method === "GET" && url.pathname === "/health") {
        return handlers.json({
          ok: true,
          environment: env.CONCLAVE_ENVIRONMENT,
        });
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
      if (
        url.pathname === "/api/auth" ||
        url.pathname.startsWith("/api/auth/")
      ) {
        return handleBetterAuthRequest(request, env);
      }
      if (url.pathname === "/api/realtime") {
        if (!isTrustedRealtimeOrigin(request, configuredOrigins)) {
          return handlers.json(
            { error: "Trusted realtime Origin required" },
            { status: 403 },
          );
        }
        const identity = await identityService.resolve(request, env);
        if (!identity) {
          return handlers.json(
            { error: "Authentication required" },
            { status: 401 },
          );
        }
        const gateway = env.CONCLAVE_REALTIME_GATEWAY.getByName(
          `user:${identity.userId}`,
        );
        return gateway.fetch(request);
      }
      return routeWorkerRequest(
        request,
        env,
        ctx,
        routeHandlers,
        routeDependencies,
      );
    })();

    return applyCorsHeaders(
      withRequestId(response, requestId),
      origin,
      isTrusted,
    );
  },
} satisfies ExportedHandler<Env>;
