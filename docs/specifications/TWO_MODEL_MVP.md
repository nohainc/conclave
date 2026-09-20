# Two-Model MVP

Phase 5 has exactly two real provider adapters:

- `OpenAIResponsesWorker` calls the OpenAI Responses API.
- `AnthropicMessagesWorker` calls the Anthropic Messages API.

Both implement the same `ModelWorker` interface and return model text plus usage metadata. The orchestration layer validates the text against the Conclave Protocol before accepting it. Provider keys and model names are runtime configuration; they are never committed or inferred from role names.

## Runtime configuration

Production configuration supplies `OPENAI_API_KEY`, `OPENAI_MODEL`, `ANTHROPIC_API_KEY`, and `ANTHROPIC_MODEL` through the platform secret/configuration system. Worker resources are separately registered with capabilities and roles. Either provider may be configured as Lead or Specialist; the provider adapter does not make that decision.

## MVP loop

1. Persist the Goal and Run, then emit `GoalReceived` and `RunStarted`.
2. Lead receives `PlanRequest`; persist the request Artifact, ModelCall, Attempt, and events.
3. Validate and persist `PlanResult`; create the delegated Task.
4. Specialist receives `TaskRequest`; persist and validate `TaskResult`.
5. Lead receives an evaluation `TaskRequest`; validate `CompletionResult`.
6. Persist the completion report Artifact and emit `RunCompleted`.

Malformed results become validation failures and rejected Attempts. Provider failures become errored Attempts and `ModelCallFailed` events. The orchestration loop is provider-neutral and accepts any two registry-resolved workers that satisfy the Lead and Specialist requirements.
