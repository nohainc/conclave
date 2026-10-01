// The ChatGPT acceptance contract now runs through the generic Engine and its
// signed Tool Profile. Keep the historical test command as an alias while the
// provider-specific Worker v2 implementation remains migration-only.
import '../../../engines/cli_worker/test/codex_profile_acceptance_test.dart'
    as codex_profile_acceptance;

void main() => codex_profile_acceptance.main();
