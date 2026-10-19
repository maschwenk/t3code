import Combine
import Foundation
import Network
import T3Core

/// The existing CLI protocol uses a loopback callback, not a custom URL containing access tokens.
@MainActor final class ConnectCallback {
  private var listener: NWListener?
  private var generation = UUID()
  private var pending: CheckedContinuation<URL, any Error>?
  private var timeout: Task<Void, Never>?

  func authorize(_ authorization: ConnectAuthorization, open: @escaping @MainActor (URL) -> Bool)
    async throws -> URL
  {
    cancel()
    let current = UUID()
    generation = current
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(
      host: .ipv4(.loopback),
      port: NWEndpoint.Port(rawValue: UInt16(authorization.configuration.callbackPort))!)
    parameters.allowLocalEndpointReuse = false
    let listener = try NWListener(using: parameters)
    self.listener = listener
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending = continuation
        listener.stateUpdateHandler = { [weak self] state in
          Task { @MainActor in
            guard let self, self.generation == current else { return }
            switch state {
            case .ready:
              if !open(authorization.url) {
                self.finish(.failure(T3Error("Could not open the T3 Connect sign-in page.")))
              }
            case .failed:
              self.finish(
                .failure(
                  T3Error(
                    "Cannot listen on T3 Connect's loopback callback port 34338. Close another pending T3 sign-in and try again."
                  )))
            default: break
            }
          }
        }
        listener.newConnectionHandler = { [weak self] connection in
          Task { @MainActor in
            guard let self, self.generation == current else {
              connection.cancel()
              return
            }
            self.receive(connection, authorization: authorization, generation: current)
          }
        }
        timeout = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(300)) } catch { return }
          guard let self, self.generation == current else { return }
          self.finish(.failure(T3Error("T3 Connect sign-in timed out. Try again.")))
        }
        listener.start(queue: .main)
      }
    } onCancel: {
      Task { @MainActor [weak self] in if self?.generation == current { self?.cancel() } }
    }
  }
  private func receive(
    _ connection: NWConnection, authorization: ConnectAuthorization, generation current: UUID
  ) {
    connection.start(queue: .main)
    read(connection, authorization: authorization, generation: current, bytes: Data())
  }
  private func read(
    _ connection: NWConnection, authorization: ConnectAuthorization, generation current: UUID,
    bytes: Data
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
      [weak self] data, _, complete, error in
      Task { @MainActor in
        guard let self, self.generation == current else {
          connection.cancel()
          return
        }
        let bytes = bytes + (data ?? Data())
        guard bytes.count <= 8192, error == nil else {
          connection.cancel()
          return
        }
        if bytes.range(of: Data("\r\n\r\n".utf8)) == nil, !complete {
          self.read(connection, authorization: authorization, generation: current, bytes: bytes)
          return
        }
        let line =
          String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let fields = line.split(separator: " ")
        let callback =
          fields.count == 3 && fields[0] == "GET" && fields[1].hasPrefix("/callback?")
          ? URL(string: String(fields[1]), relativeTo: authorization.configuration.redirectURI)?
            .absoluteURL : nil
        let valid = callback.flatMap { try? authorization.code(from: $0) } != nil
        let body =
          valid
          ? "T3 Connect authorization received. Return to T3 Native."
          : "Invalid T3 Connect callback."
        let response =
          "HTTP/1.1 \(valid ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(
          content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        if valid, let callback { self.finish(.success(callback)) }
      }
    }
  }
  private func finish(_ result: Result<URL, any Error>) {
    let continuation = pending
    pending = nil
    listener?.cancel()
    listener = nil
    timeout?.cancel()
    timeout = nil
    generation = UUID()
    continuation?.resume(with: result)
  }
  func cancel() { finish(.failure(CancellationError())) }
}
