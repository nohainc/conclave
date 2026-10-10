import Cocoa
import FlutterMacOS
import ServiceManagement
import LocalAuthentication

private enum WorkspaceBackgroundService {
  static let launchAgentPlist = "com.conclaveax.workspace.service.plist"
  static let launchAgentLabel = "com.conclaveax.workspace.service"
  static let helperRelativePath = "Contents/Helpers/conclave-service"

  @available(macOS 13.0, *)
  static var service: SMAppService {
    SMAppService.agent(plistName: launchAgentPlist)
  }

  static func registeredProcessIsRunning() throws -> Bool {
    return (try launchdStatus()["launchdState"] as? String) == "running"
  }

  static var launchdTarget: String {
    "gui/\(getuid())/\(launchAgentLabel)"
  }

  static func launchdStatus() throws -> [String: Any] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["print", launchdTarget]
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

  static func runLaunchctl(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let message = String(data: data, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines) ?? "launchctl failed"
      throw NSError(
        domain: "ConclaveWorkspaceService",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }
  }

  static func processState(_ launchd: [String: Any]) -> String {
    switch launchd["launchdState"] as? String {
    case "running": return "running"
    case "starting": return "starting"
    case "stopping": return "stopping"
    case "stopped", "not running":
      return launchd["lastExitReason"] != nil ? "failed" : "stopped"
    default: return "unknown"
    }
  }

  @available(macOS 13.0, *)
  static func validateBundle() throws {
    let helperURL = Bundle.main.bundleURL.appendingPathComponent(helperRelativePath)
    let plistURL = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Library/LaunchAgents")
      .appendingPathComponent(launchAgentPlist)
    guard FileManager.default.isExecutableFile(atPath: helperURL.path),
          FileManager.default.fileExists(atPath: plistURL.path) else {
      throw NSError(
        domain: "ConclaveWorkspaceService",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey:
          "The Workspace Service helper or LaunchAgent manifest is missing."]
      )
    }
    guard workspaceServiceHasTrustedSignature(helperURL) else {
      throw NSError(
        domain: "ConclaveWorkspaceService",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey:
          "The Workspace Service helper does not have a trusted Apple signature. Rebuild with an Apple signing identity."]
      )
    }
  }

  @available(macOS 13.0, *)
  static func registerService() throws -> [String: Any] {
    try validateBundle()
    if service.status == .enabled {
      // Re-import a stopped registration so updates replace a stale embedded
      // BundleProgram. Registration itself does not request a launch.
      if !(try registeredProcessIsRunning()) {
        try service.unregister()
        try service.register()
      }
    } else {
      try service.register()
    }
    return status()
  }

  @available(macOS 13.0, *)
  static func startService() throws -> [String: Any] {
    try validateBundle()
    guard service.status == .enabled else {
      throw NSError(
        domain: "ConclaveWorkspaceService",
        code: 4,
        userInfo: [NSLocalizedDescriptionKey:
          "The Workspace Service is not registered. Register it before starting it."]
      )
    }
    if !(try registeredProcessIsRunning()) {
      // Explicitly ask launchd to start the already-registered agent. This is
      // intentionally separate from SMAppService.register().
      try runLaunchctl(["kickstart", launchdTarget])
    }
    return status()
  }

  @available(macOS 13.0, *)
  static func stopService() throws -> [String: Any] {
    if try registeredProcessIsRunning() {
      try runLaunchctl(["kill", "SIGTERM", launchdTarget])
    }
    return status()
  }

  @available(macOS 13.0, *)
  static func restartService() throws -> [String: Any] {
    try validateBundle()
    if service.status != .enabled {
      _ = try registerService()
    }
    try runLaunchctl(["kickstart", "-k", launchdTarget])
    return status()
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
        "launchSupported": false,
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
    let launchSupported = workspaceServiceHasTrustedSignature(helperURL)
    return [
      "supported": true,
      "registration": registration,
      "launchdState": launchd["launchdState"] ?? "unknown",
      "process": processState(launchd),
      "pid": launchd["pid"] ?? NSNull(),
      "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? NSNull(),
      "ipc": "unavailable",
      "lastExitCode": launchd["lastExitCode"] ?? NSNull(),
      "lastExitReason": launchd["lastExitReason"] ?? NSNull(),
      "helperPresent": true,
      "plistPresent": true,
      "launchSupported": launchSupported,
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
      case "getServiceInfo", "getServiceStatus":
        result(WorkspaceBackgroundService.status())
      case "registerService":
        guard #available(macOS 13.0, *) else {
          result(FlutterError(code: "unsupported_os", message: "The background service requires macOS 13 or later.", details: nil))
          return
        }
        do {
          result(try WorkspaceBackgroundService.registerService())
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
      case "startService":
        guard #available(macOS 13.0, *) else {
          result(FlutterError(code: "unsupported_os", message: "The background service requires macOS 13 or later.", details: nil))
          return
        }
        do {
          result(try WorkspaceBackgroundService.startService())
        } catch {
          result(FlutterError(code: "service_start_failed", message: error.localizedDescription, details: WorkspaceBackgroundService.status()))
        }
      case "stopService":
        guard #available(macOS 13.0, *) else {
          result(FlutterError(code: "unsupported_os", message: "The background service requires macOS 13 or later.", details: nil))
          return
        }
        do {
          result(try WorkspaceBackgroundService.stopService())
        } catch {
          result(FlutterError(code: "service_stop_failed", message: error.localizedDescription, details: WorkspaceBackgroundService.status()))
        }
      case "restartService":
        guard #available(macOS 13.0, *) else {
          result(FlutterError(code: "unsupported_os", message: "The background service requires macOS 13 or later.", details: nil))
          return
        }
        do {
          result(try WorkspaceBackgroundService.restartService())
        } catch {
          result(FlutterError(code: "service_restart_failed", message: error.localizedDescription, details: WorkspaceBackgroundService.status()))
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
