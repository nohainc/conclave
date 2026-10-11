# Runtime model catalog profiles

These are the replacement Tool Profile documents for the ChatGPT/Codex and Gemini/Antigravity workers.

They intentionally do not contain a signed model catalog or effort list. When a Worker starts or its catalog is refreshed, Workspace runs the profile's discovery protocol and publishes the sanitized result through the Cloud Worker inventory. AX reads that inventory; it never connects directly to a provider CLI.

The ChatGPT profile uses the Codex app-server JSON-RPC protocol (`initialize`, then `model/list`) so the installed Codex account supplies its current model and per-model reasoning-effort catalog. The generic Worker Engine still executes the signed profile command; app-server is used only for discovery.

The Gemini discovery output is tab separated:

```text
model-id<TAB>display name<TAB>effort1,effort2<TAB>default effort
```

The third and fourth fields are optional. A provider that does not report effort metadata simply produces model choices without effort choices. Do not add provider model names or guessed effort rules to these profiles.

Import each JSON document as a new Tool Profile release in Profile Lab. Retire older static-catalog releases after the new release has been qualified in Workspace.
Migrations `0034_runtime_model_catalog_starters.sql` and
`0035_codex_app_server_model_discovery.sql` update the untouched
development starters to these documents while preserving customized starters.

Profile Lab also migrates an existing local ChatGPT Draft that still uses the
old `codex models` TSV probe (or embeds a static catalog) to the app-server
discovery shape when the Draft is opened. The migration only changes the
unsigned local Draft; published releases remain immutable and must be
republished after the Draft passes its test ladder.

The ChatGPT profile requires a Codex CLI version that implements `codex app-server` and the `model/list` request. If the app-server cannot initialize or the account is not authenticated, the Worker will remain executable but its model list will use the last successful cache, or remain empty on first discovery.
