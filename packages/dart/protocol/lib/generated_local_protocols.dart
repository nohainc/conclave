// GENERATED FILE. Do not edit by hand.

const agentAppIpcProtocolName = 'conclave.agent-app-ipc';
const agentAppIpcProtocolVersion = '1.0';
const agentAppIpcMaxFrameBytes = 1048576;
const agentAppIpcCommandTypes = <String>{
  'engine.status',
  'engine.logs',
  'engine.restart',
};
const workerPluginProtocolName = 'conclave.worker-plugin';
const workerPluginProtocolVersion = '2.0';
const workerPluginJsonRpcVersion = '2.0';
const workerPluginMethods = <String>{
  'initialize',
  'health',
  'getCapabilities',
  'configureWorker',
  'startAssignment',
  'cancelAssignment',
  'shutdown',
  'get_capabilities',
  'configure_worker',
  'start_assignment',
  'cancel_assignment',
};
const workerPluginNotifications = <String>{
  'progress',
  'log',
  'artifact',
  'usage',
  'result',
  'error',
  'authentication_required',
  'rate_limited',
};
