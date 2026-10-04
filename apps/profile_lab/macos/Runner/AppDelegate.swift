import Cocoa
import FlutterMacOS
import Security

@main
class AppDelegate: FlutterAppDelegate {
  private let profileLabKeychainChannel = "com.conclaveax.profile-lab/keychain"
  private let profileLabKeychainService = "com.conclaveax.profile-lab"

  override func applicationDidFinishLaunching(_ notification: Notification) {
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else {
      super.applicationDidFinishLaunching(notification)
      return
    }
    let channel = FlutterMethodChannel(
      name: profileLabKeychainChannel,
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self,
            let arguments = call.arguments as? [String: Any],
            arguments["account"] as? String == "profile-lab-human-session" else {
        result(FlutterError(code: "invalid_arguments", message: "Invalid Keychain account", details: nil))
        return
      }
      switch call.method {
      case "read": self.readKeychain(result: result)
      case "write":
        guard let value = arguments["value"] as? String else {
          result(FlutterError(code: "invalid_arguments", message: "Keychain value is required", details: nil))
          return
        }
        self.writeKeychain(value, result: result)
      case "delete": self.deleteKeychain(result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }
    super.applicationDidFinishLaunching(notification)
  }

  private func keychainQuery() -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: profileLabKeychainService,
     kSecAttrAccount as String: "profile-lab-human-session"]
  }

  private func readKeychain(result: FlutterResult) {
    var query = keychainQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { result(nil); return }
    guard status == errSecSuccess, let data = item as? Data,
          let value = String(data: data, encoding: .utf8) else {
      result(FlutterError(code: "keychain_read_failed", message: "Could not read Profile Lab session from Keychain", details: status))
      return
    }
    result(value)
  }

  private func writeKeychain(_ value: String, result: FlutterResult) {
    guard let data = value.data(using: .utf8) else {
      result(FlutterError(code: "invalid_value", message: "Keychain value is not UTF-8", details: nil))
      return
    }
    let query = keychainQuery()
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]
    let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if update == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      let status = SecItemAdd(item as CFDictionary, nil)
      guard status == errSecSuccess else {
        result(FlutterError(code: "keychain_write_failed", message: "Could not save Profile Lab session to Keychain", details: status))
        return
      }
    } else if update != errSecSuccess {
      result(FlutterError(code: "keychain_write_failed", message: "Could not update Profile Lab session in Keychain", details: update))
      return
    }
    result(nil)
  }

  private func deleteKeychain(result: FlutterResult) {
    let status = SecItemDelete(keychainQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      result(FlutterError(code: "keychain_delete_failed", message: "Could not delete Profile Lab session from Keychain", details: status))
      return
    }
    result(nil)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
