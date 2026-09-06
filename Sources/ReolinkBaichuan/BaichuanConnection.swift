import Foundation

/// Moves bytes to the device on port 9000 and back.
///
/// This is the seam that tests replace, the way `Transport` is the seam under
/// `NVRClient`. An implementation must not frame, retry, or interpret
/// anything: it is a byte pipe. Framing lives in `BcFrameReader`, which is
/// pure and testable on its own.
public protocol BaichuanConnection: Sendable {
    func open() async throws
    func send(_ data: Data) async throws
    /// The next bytes to arrive. Returns empty `Data` once the peer is gone.
    func receive() async throws -> Data
    func close() async
}
