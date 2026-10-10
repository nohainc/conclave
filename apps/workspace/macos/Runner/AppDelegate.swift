import Cocoa
import FlutterMacOS
import ServiceManagement
import LocalAuthentication

private enum WorkspaceBackgroundService {
  static let launchAgentPlist = "com.conclaveax.workspace.service.plist"
  static let helperRelativePath = "Contents/Helpers/conclave-service"

  @available(macOS 13.0, *)
  static var service: SMAppService {
    SMAppService.agent(plistName: launchAgentPlist)
  }

  static func registeredProcessIsRunning() throws -> Bool {
    return try launchdStatus()["launchdState"] as? String == "running"
  }

  static func launchdStatus() throws -> [String: Any] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["print", "gui/\(getuid())/com.conclaveax.workspace.service"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    if process.terminationStatus != 0 {
      if text.contains("Could not find service") { return ["launchdState": "stopped"] }
      throw NSError(domain: "ConclaveWorkspaceService", code: 1,
        userInfo: [NSLocalizedDescriptionKey:
          "Could not verify whether the registered service is running. Open Login Items to inspect its status."])
    }
    return parseWorkspaceLaunchdStatus(text)
  }

  static func status() -> [String: Any] {
    guard #available(macOS 13.0, *) else {
      return ["supported": false, "registration": "unsupported"]
    }
    let helperURL = Bundle.main.bundleURL.appendingPathComponent(helperRelativePath)
    let plistURL = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Library/LaunchAgents")
      .appendingPathComponent(launchAgentPlist)
    guard FileManager.default.isExecutableFile(atPath: helperURL.path),
          FileManager.default.fileExists(atPath: plistURL.path) else {
      return [
        "supported": true,
        "registration": "serviceMissing",
        "running": false,
        "helperPresent": FileManager.default.isExecutableFile(atPath: helperURL.path),
        "plistPresent": FileManager.default.fileExists(atPath: plistURL.path),
      ]
    }
    let registration: String
    switch service.status {
    case .enabled:
      registration = "registered"
    case .requiresApproval:
      registration = "approvalRequired"
    case .notRegistered:
      registration = "notRegistered"
    case .notFound:
      registration = "serviceMissing"
    @unknown default:
      registration = "unknown"
    }
    // SMAppService reports registration/approval, not whether launchd has
    // started the process. Keep that distinction explicit for the UI.
    let launchd = (try? launchdStatus()) ?? ["launchdState": "unknown"]
    return [
      "supported": true,
      "registration": registration,
      "launchdState": launchd["launchdState"] ?? "unknown",
      "lastExitCode": launchd["lastExitCode"] ?? NSNull(),
      "lastExitReason": launchd["lastExitReason"] ?? NSNull(),
      "running": NSNull(),
      "runningStatus": "checkIpc",
      "helperPresent": true,
      "plistPresent": true,
    ]
  }
}

func observeWorkspaceScreenLock(
  center: DistributedNotificationCenter = .default(),
  notificationName: Notification.Name = Notification.Name("com.apple.screenIsLocked"),
  onLock: @escaping () -> Void
) -> NSObjectProtocol {
  center.addObserver(forName: notificationName, object: nil, queue: .main) { _ in
    onLock()
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  private var statusItem: NSStatusItem?
  private var desktopChannel: FlutterMethodChannel?
  private var connectedMenuItems: [NSMenuItem] = []
  private var workspaceStatusItem: NSMenuItem?
  private var assignmentCountItem: NSMenuItem?
  private var pauseItem: NSMenuItem?
  private var managementLocked = false
  private var runtimeConnected = false
  private var reauthRequired = false
  private var quitApproved = false
  private var screenLockObserver: NSObjectProtocol?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    installStatusMenu()
  }

  func registerDesktopChannel(messenger: FlutterBinaryMessenger) {
    guard desktopChannel == nil else { return }
    let channel = FlutterMethodChannel(
      name: "com.conclave.workspace/desktop",
      binaryMessenger: messenger
    )
    desktopChannel = channel
    screenLockObserver = observeWorkspaceScreenLock { [weak self] in
      self?.requestManagementLock()
    }
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
        context.localizedFallbackTitle = "Use Password"
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
          result(FlutterError(
            code: "local_auth_unavailable",
            message: evaluationError?.localizedDescription ?? "macOS local authentication is unavailable.",
            details: nil
          ))
          return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
          DispatchQueue.main.async {
            if success {
              result(true)
            } else {
              result(FlutterError(
                code: "local_auth_failed",
                message: error?.localizedDescription ?? "Authentication was not accepted.",
                details: nil
              ))
            }
          }
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
        self?.quitApproved = true
        result(nil)
        // Let Flutter complete the awaited method-channel call before macOS
        // starts application termination.
        DispatchQueue.main.async {
          NSApp.terminate(nil)
        }
      case "getServiceStatus":
        result(WorkspaceBackgroundService.status())
      case "registerService":
        guard #available(macOS 13.0, *) else {
          result(FlutterError(code: "unsupported_os", message: "The background service requires macOS 13 or later.", details: nil))
          return
        }
        let helperURL = Bundle.main.bundleURL.appendingPathComponent(WorkspaceBackgroundService.helperRelativePath)
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
          result(FlutterError(code: "service_missing", message: "The Workspace background service is missing from this app installation.", details: helperURL.path))
          return
        }
        do {
          // launchd rejects ad-hoc helpers before Dart or IPC can start.
          guard workspaceServiceHasTrustedSignature(helperURL) else {
            result(FlutterError(code: "service_signing_required",
              message: "macOS cannot start this background service because its signature is not trusted. Rebuild Workspace with an Apple signing identity using --sign. Ad-hoc builds can open the UI but cannot run the background service.", details: nil))
            return
          }
          if WorkspaceBackgroundService.service.status == .enabled {
            // An update may leave launchd with the previous BundleProgram.
            // Refresh only a stopped job; never interrupt a running runtime.
            if !(try WorkspaceBackgroundService.registeredProcessIsRunning()) {
              try WorkspaceBackgroundService.service.unregister()
              try WorkspaceBackgroundService.service.register()
            }
          } else {
            try WorkspaceBackgroundService.service.register()
          }
          result(WorkspaceBackgroundService.status())
        } catch {
          result(FlutterError(code: "service_registration_failed", message: error.localizedDescription, details: WorkspaceBackgroundService.status()))
        }
      case "unregisterService":
        guard #available(macOS 13.0, *) else {
          result(FlutterError(code: "unsupported_os", message: "The background service requires macOS 13 or later.", details: nil))
          return
        }
        do {
          if WorkspaceBackgroundService.service.status != .notRegistered {
            try WorkspaceBackgroundService.service.unregister()
          }
          result(WorkspaceBackgroundService.status())
        } catch {
          result(FlutterError(code: "service_unregistration_failed", message: error.localizedDescription, details: WorkspaceBackgroundService.status()))
        }
      case "openLoginItemsSettings":
        guard #available(macOS 13.0, *) else {
          result(FlutterError(code: "unsupported_os", message: "Login Items settings require macOS 13 or later.", details: nil))
          return
        }
        SMAppService.openSystemSettingsLoginItems()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func installStatusMenu() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem = item
    item.button?.title = "Conclave Workspace"
    let menu = NSMenu()
    let heading = NSMenuItem(title: "Conclave Workspace", action: nil, keyEquivalent: "")
    heading.isEnabled = false
    menu.addItem(heading)
    let workspaceStatus = NSMenuItem(title: "Workspace disconnected", action: nil, keyEquivalent: "")
    workspaceStatus.isEnabled = false
    workspaceStatusItem = workspaceStatus
    menu.addItem(workspaceStatus)
    let assignmentCount = NSMenuItem(title: "0 assignments", action: nil, keyEquivalent: "")
    assignmentCount.isEnabled = false
    assignmentCountItem = assignmentCount
    menu.addItem(assignmentCount)
    menu.addItem(NSMenuItem.separator())
    add(menu, "Open Conclave Workspace", action: "openWorkspace")
    connectedMenuItems.append(add(menu, "Lock Workspace", action: "lock"))
    let pause = add(menu, "Pause new work", action: "togglePause")
    pauseItem = pause
    connectedMenuItems.append(pause)
    menu.addItem(NSMenuItem.separator())
    connectedMenuItems.append(add(menu, "Diagnostics", action: "diagnostics"))
    connectedMenuItems.forEach { $0.isHidden = true }
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
      desktopChannel?.invokeMethod("menuAction", arguments: action)
    } else if action == "togglePause" {
      desktopChannel?.invokeMethod("menuAction", arguments: "togglePause")
    } else {
      desktopChannel?.invokeMethod("menuAction", arguments: action)
    }
  }

  private func updateStatus(_ status: [String: Any]) {
    let state = status["state"] as? String ?? "Offline"
    let active = status["active"] as? Int ?? 0
    let accepting = status["accepting"] as? Bool ?? true
    let draining = status["draining"] as? Bool ?? false
    runtimeConnected = status["runtimeRunning"] as? Bool ?? (state == "Connected")
    reauthRequired = status["reauthRequired"] as? Bool ?? false
    statusItem?.button?.title = "Conclave Workspace"
    let serviceRunning = status["serviceRunning"] as? Bool ?? false
    if serviceRunning {
      workspaceStatusItem?.title = runtimeConnected
        ? "Service running · Cloud connected"
        : "Service running · Cloud offline"
    } else {
      workspaceStatusItem?.title = state == "Attention"
        ? "Service needs attention" : "Service stopped"
    }
    assignmentCountItem?.title = reauthRequired && runtimeConnected
      ? "Sign in required to manage"
      : "\(active) assignments"
    assignmentCountItem?.isHidden = !runtimeConnected && !reauthRequired
    connectedMenuItems.forEach { $0.isHidden = !runtimeConnected || reauthRequired }
    pauseItem?.title = draining
      ? "Waiting for active work…"
      : accepting ? "Pause new work" : "Resume new work"
    pauseItem?.isEnabled = !draining
    setManagementLocked(status["managementLocked"] as? Bool ?? managementLocked)
  }

  private func setManagementLocked(_ locked: Bool) {
    managementLocked = locked
    connectedMenuItems.filter { ($0.representedObject as? String) != "lock" }
      .forEach { $0.isHidden = locked || !runtimeConnected || reauthRequired }
    if let lockItem = statusItem?.menu?.items.first(where: { ($0.representedObject as? String) == "lock" }) {
      lockItem.title = locked ? "Workspace Locked · Unlock in App" : "Lock Workspace"
      lockItem.isEnabled = !locked && runtimeConnected && !reauthRequired
      lockItem.isHidden = !runtimeConnected || reauthRequired
    }
  }

  private func requestManagementLock() {
    desktopChannel?.invokeMethod("managementLockRequested", arguments: nil)
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
    desktopChannel?.invokeMethod("menuAction", arguments: "openWorkspace")
    return true
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Closing the window only hides management UI. The Workspace runtime and
    // status menu remain alive until an explicit, confirmed Quit action.
    return false
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if quitApproved { return .terminateNow }
    desktopChannel?.invokeMethod("requestQuit", arguments: nil)
    return .terminateCancel
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
