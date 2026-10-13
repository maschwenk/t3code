import Foundation

/// A handle to exactly one child. Never adopt a PID discovered in the environment.
@MainActor public final class OwnedBackendProcess {
  private let process = Process()
  private var stdin: Pipe?
  private var waiters: [CheckedContinuation<Void, Never>] = []
  public private(set) var started = false
  public var isRunning: Bool { started && process.isRunning }
  public var processIdentifier: Int32? { started ? process.processIdentifier : nil }
  public var exitStatus: Int32? { started && !process.isRunning ? process.terminationStatus : nil }

  public init() {}
  public func start(
    executable: URL, arguments: [String], directory: URL,
    environment: [String: String], input: Data? = nil
  ) throws {
    guard !started else { throw T3Error("This backend process was already started.") }
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let pipe = Pipe()
    stdin = pipe
    process.standardInput = pipe
    process.terminationHandler = { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
      }
    }
    try process.run()
    started = true
    do {
      if let input { try pipe.fileHandleForWriting.write(contentsOf: input) }
      try pipe.fileHandleForWriting.close()
    } catch {
      terminate()
      throw T3Error("Could not deliver the server bootstrap configuration.")
    }
  }
  public func terminate() {
    if isRunning { process.terminate() }
  }
  public func waitForExit() async {
    if !started || !process.isRunning { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}
