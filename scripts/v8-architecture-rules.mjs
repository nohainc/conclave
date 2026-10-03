export const forbiddenArchitecture = [
  [
    "retired Host product naming",
    /\b(?:HostConfig|HostRegistration|HostCloudConnection|HostLifecycleController|HostLogger|HostUi(?:Mode|Snapshot)|HostCloudSocket|ExecutionHost|HostRegistry|HostService)\b|\bhostId\b|\bhost_id\b|CONCLAVE_HOST_|\/api\/hosts(?:\/|\b)/,
  ],
  ["Studio AX naming", /\bStudio\w*\b|\/studio\//i],
  ["Studio snapshot API", /\/api\/studio\/snapshot/i],
  ["compatibility Project read model", /\/read-model\b/i],
  ["legacy snapshot API client", /\bloadSnapshot\s*\(/],
  ["V7Adapter", /V7Adapter/],
  ["FirstPartyWorkerPackage", /FirstPartyWorkerPackage/],
  ["ConfiguredWorker identifier", /\bConfiguredWorker\b|\bconfiguredWorker\w*/],
  ["worker_releases", /worker_releases/i],
  ["worker_versions", /worker_versions/i],
  ["credential_profiles", /credential_profiles/i],
  ["ai_accounts", /ai_accounts/i],
  ["host_workspace_bindings", /host_workspace_bindings/i],
  ["AgentEngine", /AgentEngine/],
  ["workerPlugin", /workerPlugin/i],
  ["Web AI Worker", /\bWebAiWorker\b|web_ai_worker/i],
  ["Interactive Connector", /\bInteractiveConnector\b|interactive-connector/i],
  [
    "Forge orchestration",
    /\bForge(?:Execution|Pipeline)\b|forge-execution|forge-terminal|forge-events/i,
  ],
  ["connector API route", /\/api\/connector\//i],
  ["managed provider credential identity", /\bcredentialProfileId\b/],
  [
    "retired Workstream Checkout architecture",
    /WorkstreamCheckout|WorkstreamCheckpoint|checkoutId|checkout_id|require_checkout|workstream_(?:current_)?checkpoints|workstream_checkouts|workstream_diff_artifacts|checkout\.(?:provision|status|recover|archive|finalize)|checkpointCommit|resetHard/i,
  ],
  [
    "repository registration architecture",
    /LocalRepositoryRegistry|repositoriesFile|CONCLAVE_WORKSPACE_REPOSITORIES|--repositories|repository_mappings_json|path_mappings_json|repositoryMappings|pathMappings|project_repository|selected_paths|full_workspace/i,
  ],
  ["write-only Workstream memberships", /workstream_memberships/i],
  [
    "retired Workspace token pairing flow",
    /workspace_pairing_intents|workspace-pairing-intents|workspace_enrollments|workspace-runtime\/enroll|\/enrollments|CONCLAVE_ENROLLMENT_TOKEN|WorkspacePairingIntent|handle\w*WorkspacePairingIntent|handle\w*WorkspaceEnrollment|conclave_pair_|conclave_enroll_|WorkspacePairing(?:Service|ErrorKind|Exception)|AxWorkspaceEnrollment|createWorkspaceEnrollment/i,
  ],
  ["legacy runtime credential key reference", /credential_key_ref/i],
  ["retired checkout policy field", /require_checkout/i],
  [
    "retired desktop auth compatibility",
    /DESKTOP_AUTH_INTENT_VERSION\s*=\s*["']1\.0["']|\buserCode\b|\buser_code\b|installationId:\s*json\[['"]installationId['"]\]\s+is\s+String|String\?\s+installationId\s*[,)]|registration\.installationId\s*\?\?|existingRegistration\s*==\s*null\s*\?\s*null\s*:\s*await\s+identityStore\.getOrCreate\(\)/i,
  ],
  [
    "provider-specific Worker executable",
    /provider-specific\s+Worker\s+executable/i,
  ],
  [
    "Profile Lab import in Workspace or AX",
    /package:conclave_profile_lab|import\s+['"][^'"]*profile_lab|\/api\/admin\/workers\//i,
  ],
  [
    "Profile Lab draft class under Workspace",
    /\b(?:DraftProfileStore|LocalDraftProfileCandidate|DraftToolProfile|ProfileLabController)\b/,
  ],
  [
    "desktop application private key signing material",
    /CONCLAVE_WORKSPACE_ED25519_SEED|Ed25519PrivateKey/,
  ],
];
