import CommonCrypto
import CryptoKit
import Foundation

/// The cipher the device chose, from the low byte of the login reply's
/// encryption word.
///
/// The RLN8-410 on firmware v3.6.5.562 answers only `fullAes`. Asking for
/// anything less gets silence on an accepted connection, so there is no
/// weaker mode to fall back to.
public enum BcEncryptionLevel: UInt8, Sendable {
    case unencrypted = 0x00
    case bcEncrypt = 0x01
    case aes = 0x02
    /// Some firmware reports AES as 3 rather than 2.
    case aesAlternate = 0x03
    /// AES, and the binary media payload is encrypted too.
    case fullAes = 0x12

    /// The word a request puts in header bytes 16 and 17. `12 dc` on the wire.
    public var requestWord: UInt16 { 0xdc00 | UInt16(rawValue) }
    /// The word the reply carries back. `12 dd` on the wire.
    public var replyWord: UInt16 { 0xdd00 | UInt16(rawValue) }

    public var usesAES: Bool {
        switch self {
        case .aes, .aesAlternate, .fullAes: true
        case .unencrypted, .bcEncrypt: false
        }
    }

    /// The device also encrypts binary payloads, and expects the same back.
    public var encryptsBinaryPayloads: Bool { self == .fullAes }

    public init?(replyWord: UInt16) {
        guard replyWord & 0xff00 == 0xdd00 else { return nil }
        self.init(rawValue: UInt8(replyWord & 0x00ff))
    }
}

/// The cipher applied to one body region.
///
/// The header is never encrypted. The extension and the payload go through the
/// cipher separately and are then concatenated, because the device builds them
/// that way and CFB state is not carried between them.
public enum BcCipher: Sendable, Equatable {
    case plaintext
    case bcEncrypt
    case aes(key: Data)

    public func encrypt(_ data: Data, offset: UInt32) throws -> Data {
        guard !data.isEmpty else { return Data() }
        switch self {
        case .plaintext: return data
        case .bcEncrypt: return BcCrypto.bcEncrypt(data, offset: offset)
        case let .aes(key): return try BcCrypto.aesCFB(data, key: key, encrypt: true)
        }
    }

    public func decrypt(_ data: Data, offset: UInt32) throws -> Data {
        guard !data.isEmpty else { return Data() }
        switch self {
        case .plaintext: return data
        case .bcEncrypt: return BcCrypto.bcEncrypt(data, offset: offset)
        case let .aes(key): return try BcCrypto.aesCFB(data, key: key, encrypt: false)
        }
    }
}

/// The two ciphers Baichuan uses, and the hashes that feed them.
///
/// The AES key derivation and the CommonCrypto CFB call follow
/// `jestatsio/reolens`, `Sources/ReolinkBaichuan/Wire/Encryption.swift` (MIT),
/// which is a correct reference for both. Cross-checked against
/// `starkillerOG/reolink_aio` and `QuantumEntangledAndy/neolink`.
public enum BcCrypto {
    /// The rotating XOR key behind `BCEncrypt`.
    static let xmlKey: [UInt8] = [0x1F, 0x2D, 0x3C, 0x4B, 0x5A, 0x69, 0x78, 0xFF]

    /// Fixed for every message. The cipher is rebuilt per message, so the CFB
    /// state never carries across a message boundary.
    static let aesIV: [UInt8] = Array("0123456789abcdef".utf8)

    /// A rotating XOR, symmetric in both directions. `offset` is header byte 12.
    public static func bcEncrypt(_ data: Data, offset: UInt32) -> Data {
        let offsetByte = UInt8(truncatingIfNeeded: offset)
        let base = Int(offset)
        var out = Data(count: data.count)
        out.withUnsafeMutableBytes { (outBuffer: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (inBuffer: UnsafeRawBufferPointer) in
                for index in 0..<data.count {
                    outBuffer[index] = inBuffer[index] ^ xmlKey[(base &+ index) % xmlKey.count] ^ offsetByte
                }
            }
        }
        return out
    }

    /// AES-128 in CFB mode with a 128-bit segment.
    ///
    /// CryptoKit has no CFB, so this goes through CommonCrypto.
    /// `kCCModeCFB` is the full-block-segment variant; `kCCModeCFB8` is a
    /// different cipher and would decode to noise.
    public static func aesCFB(_ data: Data, key: Data, encrypt: Bool) throws -> Data {
        guard key.count == kCCKeySizeAES128 else {
            throw BaichuanError.decryption(detail: "AES key is \(key.count) bytes, needs 16")
        }
        guard !data.isEmpty else { return Data() }

        var cryptor: CCCryptorRef?
        let create = key.withUnsafeBytes { keyBytes in
            aesIV.withUnsafeBufferPointer { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                    CCMode(kCCModeCFB),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBytes.baseAddress,
                    keyBytes.baseAddress, key.count,
                    nil, 0, 0, 0,
                    &cryptor
                )
            }
        }
        guard create == kCCSuccess, let cryptor else {
            throw BaichuanError.decryption(detail: "CCCryptorCreateWithMode failed with \(create)")
        }
        defer { CCCryptorRelease(cryptor) }

        let capacity = CCCryptorGetOutputLength(cryptor, data.count, true)
        var out = Data(count: capacity)
        var produced = 0
        let update = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                CCCryptorUpdate(
                    cryptor,
                    inBytes.baseAddress, data.count,
                    outBytes.baseAddress, capacity,
                    &produced
                )
            }
        }
        guard update == kCCSuccess else {
            throw BaichuanError.decryption(detail: "CCCryptorUpdate failed with \(update)")
        }

        var finished = 0
        let final = out.withUnsafeMutableBytes { outBytes -> CCCryptorStatus in
            guard let base = outBytes.baseAddress else { return CCCryptorStatus(kCCSuccess) }
            return CCCryptorFinal(cryptor, base.advanced(by: produced), capacity - produced, &finished)
        }
        guard final == kCCSuccess else {
            throw BaichuanError.decryption(detail: "CCCryptorFinal failed with \(final)")
        }
        return out.prefix(produced + finished)
    }

    /// `aes_key = first 16 ASCII bytes of uppercase_hex(md5("<nonce>-<password>"))`.
    ///
    /// The first 16 characters of the hex string, not the first 16 bytes of the
    /// digest. The distinction is easy to get wrong and gives a key that is
    /// exactly as long and completely useless.
    public static func aesKey(nonce: String, password: String) -> Data {
        Data(md5Hex("\(nonce)-\(password)").prefix(16).utf8)
    }

    public static func md5Hex(_ input: String) -> String {
        Insecure.MD5.hash(data: Data(input.utf8))
            .map { String(format: "%02X", $0) }
            .joined()
    }

    /// The login hash: uppercase hex MD5 cut to 31 characters.
    ///
    /// The 32nd character is dropped because the camera compares a 32-byte
    /// buffer that ends in a NUL.
    public static func loginHash(_ input: String) -> String {
        String(md5Hex(input).prefix(31))
    }
}
