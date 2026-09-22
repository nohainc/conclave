// GENERATED FILE. Do not edit by hand.

export const AGENT_APP_IPC_PROTOCOL_NAME = "conclave.agent-app-ipc" as const;
export const AGENT_APP_IPC_PROTOCOL_VERSION = "1.0" as const;
export const AGENT_APP_IPC_MAX_FRAME_BYTES = 1048576 as const;
export const AGENT_APP_IPC_COMMAND_TYPES = [
  "engine.status",
  "engine.logs",
  "engine.restart",
] as const;
export const WORKER_PLUGIN_PROTOCOL_NAME = "conclave.worker-plugin" as const;
export const WORKER_PLUGIN_PROTOCOL_VERSION = "2.0" as const;
export const WORKER_PLUGIN_JSON_RPC_VERSION = "2.0" as const;
export const WORKER_PLUGIN_METHODS = [
  "initialize",
  "health",
  "getCapabilities",
  "configureWorker",
  "startAssignment",
  "cancelAssignment",
  "shutdown",
  "get_capabilities",
  "configure_worker",
  "start_assignment",
  "cancel_assignment",
] as const;
export const WORKER_PLUGIN_NOTIFICATIONS = [
  "progress",
  "log",
  "artifact",
  "usage",
  "result",
  "error",
  "authentication_required",
  "rate_limited",
] as const;
