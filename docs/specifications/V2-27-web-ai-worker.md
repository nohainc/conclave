# V2-27 — Web AI Worker

> **Historical V2 acceptance note.** The current normative design is the
> Architecture v3 Agent Engine and language-independent Worker Plugin path.

ChatGPT Web, Claude Web, and similar browser sessions participate through the Web AI Worker Plugin and the connector relay. They are ordinary Worker resources with `web_app` transport, `subscription_session` authentication, `subscription` or `free` billing, and their own independence keys.

## Billing boundary

The Web AI Plugin never calls OpenAI, Anthropic, or another model API. It posts a structured task to the connector relay, waits for a native web session to claim it, and returns the submitted candidate through the normal attempt/result lifecycle. The relay does not create an API key or meter an API provider call.

An API worker may be selected only by an explicit fallback policy. Web candidates do not silently become API calls when a browser session is unavailable.

## Relay lifecycle

```text
Worker Plugin
  → POST /api/connector/tasks/register
  → ChatGPT Web or Claude Web claims the task
  → native session submits candidate/result/finding
  → plugin polls /api/connector/tasks/{taskId}/status
  → Core accepts the correlated result
```

The existing session endpoints remain available for native connectors: registration, task claim, bounded context/message retrieval, candidate/result/finding submission, status reporting, and release. Task status is authenticated with the relay registration token, and duplicate task registration is rejected.
