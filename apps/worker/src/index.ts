export { ConclaveRunWorkflow } from "./workflow.js";
export { HostGateway } from "./host-gateway.js";
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
  accessServiceTokenId,
  requireSameOriginForCookieMutation,
} from "./routes/handlers.js";

import * as handlers from "./routes/handlers.js";
import {
  routeWorkerRequest,
  type WorkerRouteDependencies,
  type WorkerRouteHandlers,
} from "./routes/router.js";

const routeHandlers = {
  handleSession: handlers.handleSession,
  handleSessionLogout: handlers.handleSessionLogout,
  handleConnectorRequest: handlers.handleConnectorRequest,
  handleConnectorTaskRequest: handlers.handleConnectorTaskRequest,
  handleListWorkspaces: handlers.handleListWorkspaces,
  handleCreateWorkspace: handlers.handleCreateWorkspace,
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
  handleRunCommand: handlers.handleRunCommand,
} as unknown as WorkerRouteHandlers;

const routeDependencies = {
  json: handlers.json,
  requireSameOriginForCookieMutation:
    handlers.requireSameOriginForCookieMutation,
  anonymousDevelopment: handlers.anonymousDevelopment,
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
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") {
      return handlers.json({
        ok: true,
        environment: env.CONCLAVE_ENVIRONMENT,
      });
    }
    return routeWorkerRequest(
      request,
      env,
      ctx,
      routeHandlers,
      routeDependencies,
    );
  },
} satisfies ExportedHandler<Env>;
