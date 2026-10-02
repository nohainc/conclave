import Cocoa
import FlutterMacOS
import XCTest
@testable import Conclave_Workspace

class RunnerTests: XCTestCase {

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

  func testScreenLockNotificationRequestsManagementLock() {
    let center = DistributedNotificationCenter.default()
    let name = Notification.Name("com.conclave.workspace.test.screenIsLocked")
    var lockRequested = false
    let observer = observeWorkspaceScreenLock(
      center: center,
      notificationName: name
    ) {
      lockRequested = true
    }
    defer { center.removeObserver(observer) }

    center.postNotificationName(name, object: nil, deliverImmediately: true)

    XCTAssertTrue(lockRequested)
  }

}
