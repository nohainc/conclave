import { handleListPeople } from "./people.js";
import { handleWorkflowWorkspace } from "./workflow-workspace.js";
import { handleWorkflowConfigurations } from "./workflow-configurations.js";
import { handleWorkflowDefault } from "./workflow-default.js";
import { conditionalJson } from "./conditional-read.js";
import {
  BUILTIN_WORKFLOW_CATALOG,
  CONVERSATION_WORKFLOWS,
  workflowCatalogEntry,
} from "@conclave/core";

export type RouteHandler = (...args: unknown[]) => Promise<Response>;
export type WorkerRouteHandlers = Record<string, RouteHandler>;

export interface WorkerRouteDependencies {
  readonly json: (data: unknown, init?: ResponseInit) => Response;
  readonly requireSameOriginForCookieMutation: (request: Request) => void;
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
    const desktopWorkspaceRegistration =
      request.method === "POST" &&
      url.pathname === "/api/workspace-runtime/register";
    const desktopWorkspaceOwnershipCheck =
      request.method === "POST" &&
      url.pathname === "/api/workspace-runtime/ownership";
    const desktopWorkspaceOwnershipReconcile =
      request.method === "POST" &&
      url.pathname === "/api/workspace-runtime/ownership/reconcile";
    const desktopWorkspaceRelease =
      request.method === "POST" &&
      url.pathname === "/api/workspace-runtime/release";
    const desktopWorkspaceDisconnect =
      request.method === "POST" &&
      url.pathname === "/api/workspace-runtime/disconnect";
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
      !desktopWorkspaceRegistration &&
      !desktopWorkspaceOwnershipCheck &&
      !desktopWorkspaceOwnershipReconcile &&
      !desktopWorkspaceRelease &&
      !desktopWorkspaceDisconnect &&
      !workspaceRuntimeTransport &&
      (!desktopAuthPath || desktopAuthRequiresSameOrigin) &&
      (request.method === "POST" ||
        request.method === "PUT" ||
        request.method === "PATCH" ||
        request.method === "DELETE")
    ) {
      deps.requireSameOriginForCookieMutation(request);
    }
    if (
      request.method === "GET" &&
      url.pathname === "/api/admin/profile-lab/access"
    ) {
      return await handlers.handleProfileLabAccess!(request, env, ctx);
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
    if (desktopWorkspaceOwnershipReconcile) {
      return await handlers.handleReconcileWorkspaceOwnership!(request, env);
    }
    if (desktopWorkspaceRelease) {
      return await handlers.handleReleaseDesktopWorkspace!(request, env);
    }
    if (desktopWorkspaceDisconnect) {
      return await handlers.handleDisconnectDesktopWorkspace!(request, env);
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
    if (url.pathname === "/api/people")
      return await handleListPeople(request, env, ctx);
    if (request.method === "GET" && url.pathname === "/api/session") {
      return await handlers.handleSession!(request, env, ctx);
    }
    if (request.method === "POST" && url.pathname === "/api/session/logout") {
      return await handlers.handleSessionLogout!(request, env, ctx);
    }
    if (request.method === "GET" && url.pathname === "/api/workspaces") {
      return await handlers.handleListWorkspaces!(request, env, ctx);
    }
    const workspaceSettingsMatch = url.pathname.match(
      /^\/api\/(user|spaces\/([^/]+))\/workflow-workspace$/,
    );
    if (workspaceSettingsMatch)
      return await handleWorkflowWorkspace(
        request,
        env,
        workspaceSettingsMatch[2],
        ctx,
      );
    const spaceWorkflowDefaultMatch = url.pathname.match(
      /^\/api\/spaces\/([^/]+)\/workflow-default$/,
    );
    if (spaceWorkflowDefaultMatch)
      return await handleWorkflowDefault(
        request,
        env,
        decodeURIComponent(spaceWorkflowDefaultMatch[1]!),
        ctx,
      );
    if (url.pathname === "/api/user/workflow-default")
      return await handleWorkflowDefault(request, env, undefined, ctx);
    const spaceWorkflowMatch = url.pathname.match(
      /^\/api\/spaces\/([^/]+)\/workflow-configurations(?:\/([^/]+))?$/,
    );
    if (spaceWorkflowMatch)
      return await handleWorkflowConfigurations(
        request,
        env,
        spaceWorkflowMatch[2]
          ? decodeURIComponent(spaceWorkflowMatch[2])
          : undefined,
        ctx,
        decodeURIComponent(spaceWorkflowMatch[1]!),
      );
    const workflowConfigurationMatch = url.pathname.match(
      /^\/api\/user\/workflow-configurations(?:\/([^/]+))?$/,
    );
    if (workflowConfigurationMatch) {
      return await handleWorkflowConfigurations(
        request,
        env,
        workflowConfigurationMatch[1]
          ? decodeURIComponent(workflowConfigurationMatch[1])
          : undefined,
        ctx,
      );
    }
    if (request.method === "GET" && url.pathname === "/api/workflows/catalog") {
      return conditionalJson(request, {
        workflows: Object.values(BUILTIN_WORKFLOW_CATALOG).map(
          workflowCatalogEntry,
        ),
      });
    }
    if (
      request.method === "GET" &&
      url.pathname === "/api/workflows/definitions"
    ) {
      return conditionalJson(request, {
        workflows: Object.values(CONVERSATION_WORKFLOWS),
      });
    }
    if (request.method === "GET" && url.pathname === "/api/release-trust") {
      return await handlers.handleGetReleaseTrustState!(env);
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
    if (
      request.method === "GET" &&
      url.pathname === "/api/admin/tool-profiles/signing-preflight"
    ) {
      return await handlers.handleToolProfileSigningPreflight!(
        request,
        env,
        ctx,
      );
    }
    if (request.method === "GET" && url.pathname === "/api/workers/catalog") {
      return await handlers.handleListWorkerCatalog!(request, env, ctx);
    }
    if (
      request.method === "GET" &&
      url.pathname === "/api/workspace-runtime/workers/catalog"
    ) {
      return await handlers.handleListWorkspaceWorkerCatalog!(
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
      request.method === "GET" &&
      url.pathname === "/api/admin/tool-profiles/definitions"
    ) {
      return await handlers.handleListToolProfileDefinitions!(
        request,
        env,
        ctx,
      );
    }
    const toolProfileDefinitionMatch = url.pathname.match(
      /^\/api\/admin\/tool-profiles\/definitions\/([^/]+)$/,
    );
    if (request.method === "GET" && toolProfileDefinitionMatch?.[1]) {
      return await handlers.handleGetToolProfileDefinition!(
        request,
        env,
        decodeURIComponent(toolProfileDefinitionMatch[1]),
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
    if (
      request.method === "GET" &&
      url.pathname === "/api/admin/workers/catalog"
    ) {
      return await handlers.handleListAdminWorkerCatalog!(request, env, ctx);
    }
    if (
      request.method === "GET" &&
      url.pathname === "/api/admin/workspace-channels"
    ) {
      return await handlers.handleListAdminWorkspaceChannels!(
        request,
        env,
        ctx,
      );
    }
    if (
      request.method === "GET" &&
      url.pathname === "/api/admin/tool-profiles/channels"
    ) {
      return await handlers.handleListAllToolProfileChannels!(
        request,
        env,
        ctx,
      );
    }
    if (
      request.method === "GET" &&
      url.pathname === "/api/admin/tool-profiles/audit"
    ) {
      return await handlers.handleListGlobalToolProfileAudit!(
        request,
        env,
        ctx,
      );
    }
    const toolProfileChannelRollbackMatch = url.pathname.match(
      /^\/api\/admin\/tool-profiles\/([^/]+)\/channels\/([^/]+)\/rollback$/,
    );
    if (
      request.method === "POST" &&
      toolProfileChannelRollbackMatch?.[1] &&
      toolProfileChannelRollbackMatch?.[2]
    ) {
      return await handlers.handleRollbackToolProfileChannel!(
        request,
        env,
        decodeURIComponent(toolProfileChannelRollbackMatch[1]),
        decodeURIComponent(toolProfileChannelRollbackMatch[2]),
        ctx,
      );
    }
    const toolProfileChannelsMatch = url.pathname.match(
      /^\/api\/admin\/tool-profiles\/([^/]+)\/channels$/,
    );
    if (request.method === "GET" && toolProfileChannelsMatch?.[1]) {
      return await handlers.handleListToolProfileChannels!(
        request,
        env,
        decodeURIComponent(toolProfileChannelsMatch[1]),
        ctx,
      );
    }
    const toolProfileDefAuditMatch = url.pathname.match(
      /^\/api\/admin\/tool-profiles\/([^/]+)\/audit$/,
    );
    if (request.method === "GET" && toolProfileDefAuditMatch?.[1]) {
      return await handlers.handleListToolProfileDefinitionAudit!(
        request,
        env,
        decodeURIComponent(toolProfileDefAuditMatch[1]),
        ctx,
      );
    }
    const toolProfileReleaseMatch = url.pathname.match(
      /^\/api\/admin\/tool-profiles\/([^/]+)\/releases(?:\/(\d+)(?:\/(draft|publish|promote|retire|revoke|audit|evidence|qualification))?)?$/,
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
      if (version && !action && request.method === "GET") {
        return await handlers.handleGetToolProfileRelease!(
          request,
          env,
          profileDefinitionId,
          version,
          ctx,
        );
      }
      if (version && action === "evidence" && request.method === "GET") {
        return await handlers.handleListToolProfileReleaseEvidence!(
          request,
          env,
          profileDefinitionId,
          version,
          ctx,
        );
      }
      if (version && action === "evidence" && request.method === "POST") {
        return await handlers.handleSubmitToolProfileReleaseEvidence!(
          request,
          env,
          profileDefinitionId,
          version,
          ctx,
        );
      }
      if (version && action === "qualification" && request.method === "POST") {
        return await handlers.handleSubmitToolProfileLocalQualification!(
          request,
          env,
          profileDefinitionId,
          version,
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
    // Workspace runtime Gateway & Protocol routes
    if (
      request.method === "GET" &&
      url.pathname === "/api/workspace-gateway/connect"
    ) {
      return await handlers.handleWorkspaceGatewayConnect!(request, env);
    }
    // Workspace Tool Profile administration
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

    if (
      request.method === "GET" &&
      (url.pathname === "/api/home" || url.pathname === "/home")
    ) {
      return await handlers.handleGetHomeReadModel!(request, env, ctx);
    }

    if (request.method === "GET" && url.pathname === "/api/spaces") {
      return await handlers.handleListSpaces!(request, env, ctx);
    }
    if (request.method === "POST" && url.pathname === "/api/spaces") {
      return await handlers.handleCreateSpace!(request, env, ctx);
    }
    const spaceMembersMatch = url.pathname.match(
      /^\/api\/spaces\/([^/]+)\/members$/,
    );
    if (request.method === "GET" && spaceMembersMatch?.[1]) {
      return await handlers.handleListSpaceMembers!(
        request,
        env,
        spaceMembersMatch[1],
        ctx,
      );
    }
    const spaceMemberRoleMatch = url.pathname.match(
      /^\/api\/spaces\/([^/]+)\/members\/([^/]+)\/(?:role|permissions)$/,
    );
    if (
      request.method === "PATCH" &&
      spaceMemberRoleMatch?.[1] &&
      spaceMemberRoleMatch[2]
    ) {
      return await handlers.handleChangeSpaceMemberRole!(
        request,
        env,
        spaceMemberRoleMatch[1],
        spaceMemberRoleMatch[2],
        ctx,
      );
    }
    const spaceMemberRemoveMatch = url.pathname.match(
      /^\/api\/spaces\/([^/]+)\/members\/([^/]+)\/remove$/,
    );
    if (
      request.method === "POST" &&
      spaceMemberRemoveMatch?.[1] &&
      spaceMemberRemoveMatch[2]
    ) {
      return await handlers.handleRemoveSpaceMember!(
        request,
        env,
        spaceMemberRemoveMatch[1],
        spaceMemberRemoveMatch[2],
        ctx,
      );
    }
    const spaceInvitationsMatch = url.pathname.match(
      /^\/api\/spaces\/([^/]+)\/invitations$/,
    );
    if (request.method === "GET" && spaceInvitationsMatch?.[1]) {
      return await handlers.handleListSpaceInvitations!(
        request,
        env,
        spaceInvitationsMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && spaceInvitationsMatch?.[1]) {
      return await handlers.handleCreateSpaceInvitation!(
        request,
        env,
        spaceInvitationsMatch[1],
        ctx,
      );
    }
    const spaceAuditMatch = url.pathname.match(
      /^\/api\/spaces\/([^/]+)\/audit$/,
    );
    if (request.method === "GET" && spaceAuditMatch?.[1]) {
      return await handlers.handleListSpaceAudit!(
        request,
        env,
        spaceAuditMatch[1],
        ctx,
      );
    }
    const spaceInvitationExpireMatch = url.pathname.match(
      /^\/api\/spaces\/([^/]+)\/invitations\/([^/]+)\/expire$/,
    );
    if (
      request.method === "POST" &&
      spaceInvitationExpireMatch?.[1] &&
      spaceInvitationExpireMatch[2]
    ) {
      return await handlers.handleExpireSpaceInvitation!(
        request,
        env,
        spaceInvitationExpireMatch[1],
        spaceInvitationExpireMatch[2],
        ctx,
      );
    }
    const spaceInvitationAcceptMatch = url.pathname.match(
      /^\/api\/(?:space-)?invitations\/([^/]+)\/accept$/,
    );
    if (request.method === "POST" && spaceInvitationAcceptMatch?.[1]) {
      return await handlers.handleAcceptSpaceInvitation!(
        request,
        env,
        spaceInvitationAcceptMatch[1],
        ctx,
      );
    }
    const spaceInvitationDeclineMatch = url.pathname.match(
      /^\/api\/(?:space-)?invitations\/([^/]+)\/decline$/,
    );
    if (request.method === "POST" && spaceInvitationDeclineMatch?.[1]) {
      return await handlers.handleDeclineSpaceInvitation!(
        request,
        env,
        spaceInvitationDeclineMatch[1],
        ctx,
      );
    }
    if (
      request.method === "GET" &&
      (url.pathname === "/api/me/invitations" ||
        url.pathname === "/api/invitations")
    ) {
      return await handlers.handleListCurrentUserInvitations!(
        request,
        env,
        ctx,
      );
    }
    const spaceMatch = url.pathname.match(/^\/api\/spaces\/([^/]+)$/);
    if (request.method === "GET" && spaceMatch?.[1]) {
      return await handlers.handleGetSpace!(request, env, spaceMatch[1], ctx);
    }
    if (request.method === "PATCH" && spaceMatch?.[1]) {
      return await handlers.handleUpdateSpace!(
        request,
        env,
        spaceMatch[1],
        ctx,
      );
    }
    if (request.method === "DELETE" && spaceMatch?.[1]) {
      return await handlers.handleDeleteSpace!(
        request,
        env,
        spaceMatch[1],
        ctx,
      );
    }

    const spaceThreadsMatch = url.pathname.match(
      /^\/api\/spaces\/([^/]+)\/threads$/,
    );
    if (request.method === "GET" && spaceThreadsMatch?.[1]) {
      return await handlers.handleListSpaceThreads!(
        request,
        env,
        spaceThreadsMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && spaceThreadsMatch?.[1]) {
      return await handlers.handleCreateThread!(
        request,
        env,
        spaceThreadsMatch[1],
        ctx,
      );
    }

    const threadMatch = url.pathname.match(/^\/api\/threads\/([^/]+)$/);
    if (request.method === "PATCH" && threadMatch?.[1]) {
      return await handlers.handleUpdateThread!(
        request,
        env,
        threadMatch[1],
        ctx,
      );
    }
    if (request.method === "DELETE" && threadMatch?.[1]) {
      return await handlers.handleDeleteThread!(
        request,
        env,
        threadMatch[1],
        ctx,
      );
    }

    const threadDiscussionMatch = url.pathname.match(
      /^\/api\/threads\/([^/]+)\/discussion-messages$/,
    );
    if (request.method === "GET" && threadDiscussionMatch?.[1]) {
      return await handlers.handleListDiscussionMessages!(
        request,
        env,
        threadDiscussionMatch[1],
        ctx,
      );
    }
    if (request.method === "POST" && threadDiscussionMatch?.[1]) {
      return await handlers.handleCreateDiscussionMessage!(
        request,
        env,
        threadDiscussionMatch[1],
        ctx,
      );
    }
    const discussionMessageMatch = url.pathname.match(
      /^\/api\/discussion-messages\/([^/]+)$/,
    );
    if (request.method === "GET" && discussionMessageMatch?.[1]) {
      return await handlers.handleGetDiscussionMessage!(
        request,
        env,
        discussionMessageMatch[1],
        ctx,
      );
    }
    if (request.method === "PATCH" && discussionMessageMatch?.[1]) {
      return await handlers.handleEditDiscussionMessage!(
        request,
        env,
        discussionMessageMatch[1],
        ctx,
      );
    }
    if (request.method === "DELETE" && discussionMessageMatch?.[1]) {
      return await handlers.handleDeleteDiscussionMessage!(
        request,
        env,
        discussionMessageMatch[1],
        ctx,
      );
    }
    const createWorkRequestMatch = url.pathname.match(
      /^\/api\/threads\/([^/]+)\/work-requests$/,
    );
    const conversationHistoryMatch = url.pathname.match(
      /^\/api\/threads\/([^/]+)\/conversations\/([^/]+)\/history$/,
    );
    if (
      request.method === "GET" &&
      conversationHistoryMatch?.[1] &&
      conversationHistoryMatch[2]
    ) {
      return await handlers.handleListConversationHistory!(
        request,
        env,
        conversationHistoryMatch[1],
        conversationHistoryMatch[2],
        ctx,
      );
    }
    const conversationsMatch = url.pathname.match(
      /^\/api\/threads\/([^/]+)\/conversations$/,
    );
    if (request.method === "GET" && conversationsMatch?.[1]) {
      return await handlers.handleListConversations!(
        request,
        env,
        conversationsMatch[1],
        ctx,
      );
    }
    const validateWorkRequestMatch = url.pathname.match(
      /^\/api\/threads\/([^/]+)\/work-requests\/validate$/,
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
