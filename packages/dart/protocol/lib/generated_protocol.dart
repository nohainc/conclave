// GENERATED FILE. Do not edit by hand.

const protocolName = 'conclave.protocol';
const protocolVersion = '0.1';
const requiredEnvelopeFields = <String>[
  'protocol',
  'version',
  'messageId',
  'goalId',
  'runId',
  'workerId',
  'createdAt',
  'messageType',
  'payload',
];
const protocolMessageTypes = <String>{
  'PlanRequest',
  'PlanResult',
  'TaskRequest',
  'TaskResult',
  'ResearchResult',
  'ImplementationResult',
  'ReviewResult',
  'TestResult',
  'VerificationResult',
  'DecisionResult',
  'CompletionResult',
  'RuntimeOperationRequest',
};
const protocolMessagePayloadSchemas = <String, String>{
  'PlanRequest': '#/\$defs/planRequestPayload',
  'PlanResult': '#/\$defs/planResultPayload',
  'TaskRequest': '#/\$defs/taskRequestPayload',
  'TaskResult': '#/\$defs/taskResultPayload',
  'ResearchResult': '#/\$defs/researchResultPayload',
  'ImplementationResult': '#/\$defs/implementationResultPayload',
  'ReviewResult': '#/\$defs/reviewResultPayload',
  'TestResult': '#/\$defs/testResultPayload',
  'VerificationResult': '#/\$defs/verificationResultPayload',
  'DecisionResult': '#/\$defs/decisionResultPayload',
  'CompletionResult': '#/\$defs/completionResultPayload',
  'RuntimeOperationRequest': '#/\$defs/runtimeOperationPayload',
};
const agentProtocolName = 'conclave.agent-protocol';
const agentProtocolVersion = '2.0';
const agentProtocolMaxMessageSizeBytes = 4194304;
const agentProtocolMessageTypes = <String>{
  'agent.hello',
  'agent.hello.ack',
  'agent.heartbeat',
  'agent.heartbeat.ack',
  'agent.sync.request',
  'agent.sync.response',
  'agent.capabilities',
  'agent.update.available',
  'agent.update.status',
  'plugin.install',
  'plugin.update',
  'plugin.remove',
  'plugin.status',
  'worker.configure',
  'worker.status',
  'assignment.start',
  'assignment.ack',
  'assignment.progress',
  'assignment.result',
  'assignment.error',
  'assignment.cancelled',
  'assignment.cancel',
  'assignment.cancel.ack',
};
const agentProtocolBaseEnvelopeFields = <String>[
  'protocol',
  'protocolVersion',
  'messageId',
  'correlationId',
  'timestamp',
  'type',
  'payload',
];
const agentProtocolAssignmentEnvelopeFields = <String>[
  'workspaceId',
  'agentId',
  'workerId',
  'runId',
  'taskId',
  'attemptId',
  'assignmentId',
  'idempotencyKey',
];
