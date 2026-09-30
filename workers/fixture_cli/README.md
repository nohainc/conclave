# Development-only fixture CLI Worker

This third Worker package demonstrates that provider integration belongs in a
Worker package. It is registered only in `workers/development_catalog.json`, is
development-channel only, and is not part of the fixed ChatGPT/Gemini product
catalog or AX Worker selection.

The Worker discovers the companion `fixture-provider` executable beside its
own executable, checks its version, runs a local live probe when explicitly
requested, and delegates execution to it. The fake tool has no network or
credential behavior. Workspace only launches and supervises the Worker through
Local Worker Protocol 3.0.

The release acceptance test compiles both console executables into one signed
development Worker release and runs candidate validation and an assignment
through the generic Workspace release verifier and process supervisor.
