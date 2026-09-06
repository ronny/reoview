import Foundation
import Network

/// The real connection: one long-lived TCP socket to port 9000.
///
/// One connection carries every message, and the client keeps one read in
/// flight at a time, so `receive` is never called concurrently with itself.
public actor NetworkConnection: BaichuanConnection {
    public static let defaultPort: UInt16 = 9000

    private let endpoint: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "au.ronny.ReoView.baichuan")
    private var connection: NWConnection?

    public init(host: String, port: UInt16 = NetworkConnection.defaultPort) {
        endpoint = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(integerLiteral: 9000)
    }

    public func open() async throws {
        guard connection == nil else { return }

        let options = NWProtocolTCP.Options()
        // Audio blocks are 64 ms apart and small. Nagle would hold them.
        options.noDelay = true
        let connection = NWConnection(host: endpoint, port: port, using: NWParameters(tls: nil, tcp: options))
        self.connection = connection

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedThrowingContinuationBox) in
                let box = OneShot(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        box.succeed(())
                    case let .failed(error):
                        box.fail(.connection(error))
                    case .cancelled:
                        box.fail(.connection(NWError.posix(.ECANCELED)))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } catch {
            connection.cancel()
            self.connection = nil
            throw error
        }
        // A later failure must not resume the settled continuation.
        connection.stateUpdateHandler = nil
    }

    public func send(_ data: Data) async throws {
        guard let connection else { throw BaichuanError.connection(NWError.posix(.ENOTCONN)) }
        try await withCheckedThrowingContinuation { (continuation: CheckedThrowingContinuationBox) in
            let box = OneShot(continuation)
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    box.fail(.connection(error))
                } else {
                    box.succeed(())
                }
            })
        }
    }

    public func receive() async throws -> Data {
        guard let connection else { throw BaichuanError.connection(NWError.posix(.ENOTCONN)) }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            let box = OneShot(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error {
                    box.fail(.connection(error))
                } else if let data, !data.isEmpty {
                    box.succeed(data)
                } else if isComplete {
                    box.succeed(Data())
                } else {
                    box.succeed(Data())
                }
            }
        }
    }

    public func close() async {
        connection?.cancel()
        connection = nil
    }
}

private typealias CheckedThrowingContinuationBox = CheckedContinuation<Void, any Error>

/// Network.framework hands its results to callbacks that are not actor
/// isolated and that can fire more than once, while a continuation must be
/// resumed exactly once. The first result wins and the rest are dropped.
///
/// `@unchecked Sendable` is the C-shaped API forcing the issue: the mutable
/// slot is guarded by the lock and nothing else touches it.
private final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: T) { take()?.resume(returning: value) }

    func fail(_ error: BaichuanError) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<T, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        let pending = continuation
        continuation = nil
        return pending
    }
}
