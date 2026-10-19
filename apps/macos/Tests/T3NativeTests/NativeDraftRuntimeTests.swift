import Foundation
import T3Core
import Testing

@testable import T3Native

@MainActor
@Test(
  .enabled(
    if: ProcessInfo.processInfo.environment["T3_NATIVE_NEW_DRAFT_SMOKE_CONNECTION_FILE"] != nil)
)
func localConversationDraftWithTheActualIsolatedClientStore() async throws {
  let path = try #require(
    ProcessInfo.processInfo.environment["T3_NATIVE_NEW_DRAFT_SMOKE_CONNECTION_FILE"])
  let root =
    ProcessInfo.processInfo.environment["T3_NATIVE_NEW_DRAFT_SMOKE_ROOT"]
    ?? "/tmp/t3-native-evidence"
  try await NativeDraftSmoke.run(
    settings: ConnectionSettings.load(URL(fileURLWithPath: path)), root: root)
}
