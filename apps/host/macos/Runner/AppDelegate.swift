import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var statusItem: NSStatusItem?
  private var desktopChannel: FlutterMethodChannel?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(name: "com.conclave.workspace/desktop", binaryMessenger: controller.engine.binaryMessenger)
    desktopChannel = channel
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
