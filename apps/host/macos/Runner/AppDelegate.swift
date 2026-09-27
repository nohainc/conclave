import Cocoa
import FlutterMacOS
import ServiceManagement
import LocalAuthentication

@main
class AppDelegate: FlutterAppDelegate {
  private var statusItem: NSStatusItem?
  private var desktopChannel: FlutterMethodChannel?
  private var protectedMenuItems: [NSMenuItem] = []
  private var managementLocked = false

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(name: "com.conclave.workspace/desktop", binaryMessenger: controller.engine.binaryMessenger)
    desktopChannel = channel
    DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
    ) { [weak self] _ in self?.requestManagementLock() }
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "status":
        self?.updateStatus(call.arguments as? [String: Any] ?? [:])
        result(nil)
      case "localManagementAuthAvailable":
        let context = LAContext()
        var error: NSError?
        result(context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error))
      case "authenticateLocalManagement":
        let reason = call.arguments as? String ?? "Unlock Conclave Workspace management"
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
          DispatchQueue.main.async { result(success) }
        }
      case "setManagementLocked":
        self?.setManagementLocked(call.arguments as? Bool ?? false)
        result(nil)
      case "hideMainWindow":
        // Login-item launches are not activated by the user. Preserve the
        // normal first window when the user explicitly starts the app.
        if NSApp.isActive == false {
          self?.mainFlutterWindow?.orderOut(nil)
        }
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
      case "setLaunchAtLogin":
        guard let enabled = call.arguments as? Bool else {
          result(FlutterError(code: "bad_argument", message: "Expected a Boolean", details: nil))
          return
        }
        guard #available(macOS 13.0, *) else {
          result(FlutterError(code: "unsupported_os", message: "Launch at login requires macOS 13 or later", details: nil))
          return
        }
        do {
          if enabled && SMAppService.mainApp.status != .enabled {
            try SMAppService.mainApp.register()
          } else if !enabled && SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
          }
          result(nil)
        } catch {
          result(FlutterError(code: "launch_at_login_failed", message: error.localizedDescription, details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem = item
    item.button?.title = "Conclave · Starting"
    let menu = NSMenu()
    add(menu, "Open Conclave Workspace", action: "openWorkspace")
    add(menu, "Lock Workspace", action: "lock")
    protectedMenuItems.append(add(menu, "Open Conclave AX", action: "openAX"))
    menu.addItem(NSMenuItem.separator())
    protectedMenuItems.append(add(menu, "Pause New Work", action: "pause"))
    protectedMenuItems.append(add(menu, "Resume New Work", action: "resume"))
    protectedMenuItems.append(add(menu, "Drain", action: "drain"))
    menu.addItem(NSMenuItem.separator())
    protectedMenuItems.append(add(menu, "Export Diagnostics", action: "diagnostics"))
    protectedMenuItems.append(add(menu, "Open Logs", action: "logs"))
    menu.addItem(NSMenuItem.separator())
    add(menu, "Quit Conclave Workspace", action: "quit")
    item.menu = menu
  }

  @discardableResult private func add(_ menu: NSMenu, _ title: String, action: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = action
    menu.addItem(item)
    return item
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
    setManagementLocked(status["managementLocked"] as? Bool ?? managementLocked)
  }

  private func setManagementLocked(_ locked: Bool) {
    managementLocked = locked
    protectedMenuItems.forEach { $0.isHidden = locked }
    if let lockItem = statusItem?.menu?.items.first(where: { ($0.representedObject as? String) == "lock" }) {
      lockItem.title = locked ? "Workspace Locked · Unlock in App" : "Lock Workspace"
      lockItem.isEnabled = !locked
    }
  }

  private func requestManagementLock() {
    desktopChannel?.invokeMethod("managementLockRequested", arguments: nil)
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
