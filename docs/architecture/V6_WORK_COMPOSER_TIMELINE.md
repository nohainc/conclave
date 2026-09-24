# V6 Work Composer and Timeline

## Purpose

V6 separates discussion from execution. A Workstream's Discuss surface is for
context and references; execution begins only after an authorized user submits
an explicit Work request with Run.

## Composer contract

The Work composer contains:

- request text;
- an immutable-version Workflow selector;
- optional references;
- an explicit Run action.

Advanced controls may select an Account override, model preference, and quality
preference. They may expose only Workspace controls that are valid for the
Workstream's execution policy. A Workstream does not own a fixed Worker
default: the workflow step and selected Workspace capabilities determine the
Worker at scheduling time.

Viewers can inspect Workstream history but cannot submit, cancel, or respond to
Work. Owners and collaborators may submit Work when Workstream policy permits.

## Timeline contract

The timeline is a read model for Work Requests and their Runs. It must make the
following states and outcomes understandable without exposing orchestration
internals:

- queued, preparing, and running;
- needs input, including an explicit response action;
- completed and failed;
- cancellation;
- checkpoint, changes, tests, and findings summaries.

Each submitted request records its Workflow version and execution policy
snapshot. Stateful work remains bound to the Workstream Primary Workspace,
managed checkout, and execution lease; stateless work may use the scheduler's
eligible auxiliary Workspace selection. The UI must not offer an arbitrary
Workspace override for stateful work.

The initial application shell may use local state or fixtures while the
Workstream read model and Work Request API are integrated. That shell must keep
the same explicit-Run, role-gating, and state vocabulary as the eventual
server-backed implementation.
