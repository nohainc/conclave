# Conclave Test Worker

This development-only executable exercises the shared Dart Worker SDK and
Local Worker Protocol 3.0. It is not a product Worker and is not included in
the first-party Worker catalog.

It accepts initialize, passive/live probe, and execute requests over NDJSON.
Probe responses use a local fake provider and never make network calls.
Execution emits progress and returns deterministic `echo: ...` output.
Prompts beginning with `delay=<milliseconds>;` can be used to exercise Worker
deadlines. Workspace cancellation is demonstrated by terminating the process
tree, as protocol cancellation frames are optional.

For durable-session tests, Workspace sets `CONCLAVE_WORKER_STATE_DIR` to its
local state directory and sends a `durable_session` request with a logical
session key. The Worker persists a monotonically increasing fake session run
count there. No provider credential or provider session is involved.

Build a standalone executable from this package with `dart compile exe
bin/test_worker.dart -o <output-path>`. The user does not need Dart installed
to run that compiled executable.
