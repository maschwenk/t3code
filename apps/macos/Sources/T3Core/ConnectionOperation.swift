import Foundation

public struct ConnectionOperation: Sendable {
  public let environment: String
  public let connection: RPCConnection?
  public init(environment: String, connection: RPCConnection?) {
    self.environment = environment
    self.connection = connection
  }
  public func requireCurrent(environment: String, connection: RPCConnection?) throws {
    try Task.checkCancellation()
    guard self.environment == environment, self.connection === connection else {
      throw T3Error(
        "The connection changed while this operation was running. Refresh Connections before continuing."
      )
    }
  }
}
