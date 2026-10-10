import Cocoa
import FlutterMacOS
import Security

private enum WorkspaceKeychainChannel {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.conclave.workspace/keychain",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard let arguments = call.arguments as? [String: Any],
            let service = arguments["service"] as? String,
            let account = arguments["account"] as? String else {
        result(FlutterError(code: "invalid_keychain_request", message: "Credential identity is missing.", details: nil))
        return
      }
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
      ]
      switch call.method {
      case "read":
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound {
          result(nil)
        } else if status == errSecSuccess,
                  let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) {
          result(value)
        } else {
          result(FlutterError(code: "keychain_read_failed", message: "Could not read the local credential.", details: status))
        }
      case "write":
        guard let value = arguments["value"] as? String, !value.isEmpty else {
          result(FlutterError(code: "invalid_keychain_request", message: "Credential value is missing.", details: nil))
          return
        }
        let valueData = Data(value.utf8)
        let attributes: [String: Any] = [
          kSecValueData as String: valueData,
          kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
          result(nil)
          return
        }
        guard updateStatus == errSecItemNotFound else {
          result(FlutterError(code: "keychain_write_failed", message: "Could not save the local credential.", details: updateStatus))
          return
        }
        var item = query
        item[kSecValueData as String] = valueData
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecSuccess {
          result(nil)
        } else {
          result(FlutterError(code: "keychain_write_failed", message: "Could not save the local credential.", details: addStatus))
        }
      case "delete":
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
          result(nil)
        } else {
          result(FlutterError(code: "keychain_delete_failed", message: "Could not remove the local credential.", details: status))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    WorkspaceKeychainChannel.register(
      messenger: flutterViewController.engine.binaryMessenger
    )
    (NSApp.delegate as? AppDelegate)?.registerDesktopChannel(
      messenger: flutterViewController.engine.binaryMessenger
    )

    self.minSize = NSSize(width: 750, height: 650)
    var frame = self.frame
    frame.size.width = 750
    frame.size.height = 650
    self.setFrame(frame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
