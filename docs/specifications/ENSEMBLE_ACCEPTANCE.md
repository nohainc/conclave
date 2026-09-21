# Ensemble acceptance scenarios

The Core acceptance suite covers the first five routing promises:

| Scenario | Required behavior |
| --- | --- |
| One-worker | A `single` policy executes one correlated Worker request. |
| Multi-research | Independent researcher, architect, and reviewer roles run as a read-only panel. |
| High assurance | Two independent candidates feed an ordinary synthesis Task and an accepted `DecisionResult`. |
| Competitive implementation | Independent implementers receive distinct workspace repository IDs. |
| Subscription → API fallback | A retryable local subscription failure falls through to the ordered API Worker. |

The suite uses injected Worker executors and workspace IDs, so it tests policy,
correlation, independence, and fallback behavior without requiring provider
credentials or modifying a real repository. Provider and Local Runtime
integration tests remain separate and can be enabled when those services are
available.
