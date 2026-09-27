import Cocoa
import FlutterMacOS
import Security

@main
class AppDelegate: FlutterAppDelegate {
  private var statusItem: NSStatusItem?
  private var desktopChannel: FlutterMethodChannel?
  private var keychainChannel: FlutterMethodChannel?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(name: "com.conclave.workspace/desktop", binaryMessenger: controller.engine.binaryMessenger)
    desktopChannel = channel
    let keychain = FlutterMethodChannel(name: "com.conclave.workspace/keychain", binaryMessenger: controller.engine.binaryMessenger)
    keychainChannel = keychain
    keychain.setMethodCallHandler { [weak self] call, result in
      self?.handleKeychainCall(call, result: result)
    }
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "status":
        self?.updateStatus(call.arguments as? [String: Any] ?? [:])
        result(nil)
      case "openPath":
        guard let path = call.arguments as? String else { result(FlutterError(code: "bad_path", message: nil, details: nil)); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        result(nil)
      case "openAX":
        if let url = URL(string: "https://app.conclaveax.com") { NSWorkspace.shared.open(url) }
        result(nil)
      case "terminate":
        NSApp.terminate(nil)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem = item
    item.button?.title = "Conclave · Starting"
    let menu = NSMenu()
    add(menu, "Open Conclave Workspace", action: "openWorkspace")
    add(menu, "Open Conclave AX", action: "openAX")
    menu.addItem(NSMenuItem.separator())
    add(menu, "Pause New Work", action: "pause")
    add(menu, "Resume New Work", action: "resume")
    add(menu, "Drain", action: "drain")
    menu.addItem(NSMenuItem.separator())
    add(menu, "Export Diagnostics", action: "diagnostics")
    add(menu, "Open Logs", action: "logs")
    menu.addItem(NSMenuItem.separator())
    add(menu, "Quit Conclave Workspace", action: "quit")
    item.menu = menu
  }

  private func handleKeychainCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
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
      let attributes = [kSecValueData as String: valueData] as CFDictionary
      let updateStatus = SecItemUpdate(query as CFDictionary, attributes)
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

  private func add(_ menu: NSMenu, _ title: String, action: String) {
    let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = action
    menu.addItem(item)
  }

  @objc private func menuAction(_ item: NSMenuItem) {
    guard let action = item.representedObject as? String else { return }
    if action == "openWorkspace" {
      NSApp.activate(ignoringOtherApps: true)
      mainFlutterWindow?.makeKeyAndOrderFront(nil)
    } else {
      desktopChannel?.invokeMethod("menuAction", arguments: action)
    }
  }

  private func updateStatus(_ status: [String: Any]) {
    let state = status["state"] as? String ?? "Offline"
    let active = status["active"] as? Int ?? 0
    statusItem?.button?.title = "Conclave · \(state) · \(active)"
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
    return true
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
