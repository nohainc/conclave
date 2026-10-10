import Foundation
import Security

/// Read only the job's top-level state, not nested resource-coalition states.
/// Never return launchd's environment or other unrequested job attributes.
func parseWorkspaceLaunchdStatus(_ text: String) -> [String: Any] {
  var result: [String: Any] = ["launchdState": "unknown"]
  var foundState = false
  for line in text.split(separator: "\n") {
    let value = line.trimmingCharacters(in: .whitespaces)
    if !foundState && value.hasPrefix("state = ") {
      foundState = true
      result["launchdState"] = String(value.dropFirst("state = ".count))
    } else if value.hasPrefix("last exit code = ") {
      result["lastExitCode"] = Int(value.dropFirst("last exit code = ".count))
    } else if value.hasPrefix("last exit reason = ") {
      result["lastExitReason"] = String(value.dropFirst("last exit reason = ".count))
    }
  }
  return result
}

/// SMAppService launch constraints require an Apple-trusted signing chain.
func workspaceServiceHasTrustedSignature(_ url: URL) -> Bool {
  var code: SecStaticCode?
  var requirement: SecRequirement?
  guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
        SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
        let code = code, let requirement = requirement else { return false }
  // Use strict validation so a stale, incomplete, or untrusted embedded
  // certificate is reported before SMAppService registers a job that launchd
  // can never start.
  return SecStaticCodeCheckValidity(
      code,
      SecCSFlags(rawValue: kSecCSStrictValidate),
      requirement
    ) == errSecSuccess
}
