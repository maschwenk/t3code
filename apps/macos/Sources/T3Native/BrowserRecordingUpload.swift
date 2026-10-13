import Foundation
import T3Core

@MainActor enum BrowserRecordingUpload {
  static func upload(
    _ file: URL, connection: RPCConnection, endpoint: URL,
    deadline: BrowserAutomationDeadline, check: @MainActor () throws -> Void
  ) async throws -> String {
    try check()
    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, size <= AttachmentPolicy.fileLimit else {
      throw BrowserAutomationError(
        "PreviewAutomationRecordingTooLargeError",
        "The recording exceeds 50 MiB. The saved copy remains on this Mac.")
    }
    var minted: String?
    do {
      let issued = try await connection.call(
        "attachments.createUploadUrl",
        payload: .object([
          "type": .string("file"), "name": .string(file.lastPathComponent),
          "mimeType": .string("video/mp4"), "sizeBytes": .number(Double(size)),
        ]))
      minted = try issued.requiredString("attachmentId")
      try check()
      let url = try AttachmentHTTP.signedURL(
        issued.requiredString("relativeUrl"), endpoint: endpoint,
        prefix: "/api/attachments/upload/")
      // A signed upload requires no copied bearer credential. Share the broker request deadline.
      let session = URLSession(configuration: .ephemeral)
      defer { session.invalidateAndCancel() }
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
      let remaining = deadline.remaining.components
      request.timeoutInterval = max(
        0.001, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
      let (_, response) = try await session.upload(for: request, fromFile: file)
      try check()
      guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
        let minted
      else { throw T3Error("Browser recording upload failed.") }
      return minted
    } catch {
      if let minted {
        // Cancellation must still delete the unclaimed pending attachment on the original server.
        let cleanup = Task {
          _ = try? await connection.call(
            "attachments.delete", payload: .object(["attachmentId": .string(minted)]))
        }
        await cleanup.value
      }
      if error is CancellationError
        || (error as? BrowserAutomationError)?.tag == BrowserAutomationError.interrupted.tag
      {
        throw error
      }
      throw BrowserAutomationError(
        "PreviewAutomationRecordingTransferError",
        "The recording could not be transferred. The saved copy remains on this Mac. "
          + error.localizedDescription)
    }
  }
}
