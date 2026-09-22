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
