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

const hostProtocolName = 'conclave.host-protocol';
const hostProtocolVersion = '4.0';
const hostProtocolMaxMessageSizeBytes = 4194304;
const hostProtocolMessageTypes = <String>{
  'host.hello',
  'host.hello.ack',
  'host.heartbeat',
  'host.heartbeat.ack',
  'host.sync.request',
  'host.sync.result',
  'host.status',
  'host.update',
  'worker.install',
  'worker.remove',
  'worker.status',
  'credential.status',
  'assignment.start',
  'assignment.ack',
  'assignment.progress',
  'assignment.result',
  'assignment.error',
  'assignment.cancel',
  'assignment.cancel.ack',
};
const hostProtocolBaseEnvelopeFields = <String>[
  'protocol',
  'protocolVersion',
  'messageId',
  'correlationId',
  'timestamp',
  'type',
  'payload',
];
const hostProtocolAssignmentEnvelopeFields = <String>[
  'workspaceId',
  'hostId',
  'workerId',
  'runId',
  'taskId',
  'attemptId',
  'assignmentId',
  'idempotencyKey',
];

const realtimeEventsName = 'conclave.realtime-events';
const realtimeEventsVersion = '1.0';
const realtimeEventEnvelopeFields = <String>[
  'eventId',
  'type',
  'version',
  'timestamp',
  'workspaceId',
  'sequence',
  'payload',
];
const realtimeEventOptionalEnvelopeFields = <String>[
  'projectId',
  'chatId',
  'runId',
  'taskId',
  'attemptId',
  'assignmentId',
  'hostId',
];
const durableRealtimeEventTypes = <String>{
  'chat.message.created',
  'run.started',
  'run.paused',
  'run.resumed',
  'run.completed',
  'run.failed',
  'task.started',
  'task.completed',
  'task.failed',
  'attempt.started',
  'attempt.completed',
  'attempt.failed',
  'assignment.accepted',
  'assignment.completed',
  'assignment.failed',
  'assignment.cancelled',
  'artifact.created',
  'finding.created',
  'finding.resolved',
  'verification.completed',
  'host.enrolled',
  'host.revoked',
  'account.sharing.changed',
};
const ephemeralRealtimeEventTypes = <String>{
  'assignment.progress',
  'worker.status',
  'stream.delta',
  'tool.invocation.status',
  'typing',
  'heartbeat',
  'host.load',
};
const realtimeEventPayloadSchema = '#/\$defs/realtimeEventPayload';

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
