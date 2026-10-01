# Historical Worker Runtime v2 fixture package

This package preserves the v2 third-Worker migration test only. It is not the
v8 scalability proof or a template for a new CLI integration. The current
development-only v8 example is the `fixture-worker` Logical Worker mapped to
the `fixture-cli` Tool Profile Definition and release fixture in
`packages/tool-profile/test/fixtures/`.

The v8 fixture CLI is launched by the generic CLI Worker Engine using Profile
arguments and is covered by the Profile fixture harness and Engine acceptance
test. It does not compile a provider-specific Worker executable.
