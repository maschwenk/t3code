import Foundation
import Testing

@testable import T3Core

@Suite @MainActor struct BackendRuntimeSmokeTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["T3_NATIVE_SMOKE_RESOURCES"] != nil))
  func packagedRuntimeAuthenticatesServesWebAndStopsOwnedChild() async throws {
    let resources = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["T3_NATIVE_SMOKE_RESOURCES"]!)
    let home = URL(fileURLWithPath: "/tmp/t3-native-evidence/backend-test-" + UUID().uuidString)
    let report = try await BackendRuntimeSmoke.run(resources: resources, newHome: home)
    #expect(report.authenticatedSession)
    #expect(report.webIndexMatchesBundle)
    #expect(!report.environmentID.isEmpty)
    #expect(report.childStopped)
    #expect(report.exitStatus != nil)
    #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("userdata").path))
  }
}
