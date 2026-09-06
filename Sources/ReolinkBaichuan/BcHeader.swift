import Foundation

/// The value at header offset 18. It decides how long the header is.
///
/// "Legacy" is not a firmware generation. It is one message shape, used for
/// exactly one message: the first half of the login handshake.
public enum BcMessageClass {
    /// 20 bytes, no payload offset. Only the login nonce request uses it.
    public static let legacy: UInt16 = 0x6514
    /// 20 bytes, no payload offset. The nonce reply comes back as this.
    public static let modern: UInt16 = 0x6614
    /// 24 bytes, with a payload offset. Every request this client sends.
    public static let modernWithPayloadOffset: UInt16 = 0x6414
    /// 24 bytes, with a payload offset. What the device answers with.
    public static let modernZero: UInt16 = 0x0000

    public static func hasPayloadOffset(_ messageClass: UInt16) -> Bool {
        messageClass == modernWithPayloadOffset || messageClass == modernZero
    }

    public static func headerLength(for messageClass: UInt16) -> Int? {
        switch messageClass {
        case legacy, modern: 20
        case modernWithPayloadOffset, modernZero: 24
        default: nil
        }
    }
}

/// The 20 or 24 byte header in front of every Baichuan message.
///
/// All fields are little-endian. Bytes 12 to 15 are one block that the device
/// echoes back verbatim, so they are the correlation id for a pending request.
/// `reolink_aio` splits that block into a one-byte `ch_id` and a 24-bit
/// counter, which is the split this type uses, because the reply headers
/// measured off the RLN8-410 match it exactly.
///
/// Byte 12 does double duty: it is also the XOR key offset for `BCEncrypt`.
public struct BcHeader: Sendable, Equatable {
    /// `f0 de bc 0a` on the wire.
    public static let magic: UInt32 = 0x0abc_def0
    /// Enough bytes to learn the message class, which gives the real length.
    public static let minimumLength = 20

    public var messageID: UInt32
    /// Extension plus payload, counted in on-wire bytes after encryption.
    public var bodyLength: UInt32
    /// `channel + 1` for a channel command, 250 for the host, 251 for a push.
    public var channelID: UInt8
    /// The 24-bit counter in bytes 13 to 15.
    public var messageNumber: UInt32
    /// A status code on a 24-byte header, the encryption word during login.
    public var status: UInt16
    public var messageClass: UInt16
    /// The length of the extension region. Absent on a 20-byte header.
    public var payloadOffset: UInt32?

    public init(
        messageID: UInt32,
        bodyLength: UInt32 = 0,
        channelID: UInt8 = BcChannelID.host,
        messageNumber: UInt32 = 0,
        status: UInt16 = 0,
        messageClass: UInt16 = BcMessageClass.modernWithPayloadOffset,
        payloadOffset: UInt32? = nil
    ) {
        self.messageID = messageID
        self.bodyLength = bodyLength
        self.channelID = channelID
        self.messageNumber = messageNumber & 0x00ff_ffff
        self.status = status
        self.messageClass = messageClass
        self.payloadOffset = BcMessageClass.hasPayloadOffset(messageClass) ? (payloadOffset ?? 0) : nil
    }

    public var length: Int { BcMessageClass.headerLength(for: messageClass) ?? Self.minimumLength }

    /// Bytes 12 to 15 read as one little-endian word. A reply that does not
    /// carry the request's word back belongs to a different request.
    public var correlationID: UInt32 { UInt32(channelID) | (messageNumber << 8) }

    /// The `BCEncrypt` key offset, which is byte 12.
    public var encryptionOffset: UInt32 { UInt32(channelID) }

    /// The extension region ends here. A zero offset means the whole body is
    /// the XML region and there is no binary payload; the device answers
    /// message 199 and message 10 that way.
    public var extensionLength: Int {
        guard let payloadOffset, payloadOffset != 0 else { return Int(bodyLength) }
        return Int(payloadOffset)
    }

    public func encoded() -> Data {
        var out = Data(capacity: length)
        out.appendLittleEndian(Self.magic)
        out.appendLittleEndian(messageID)
        out.appendLittleEndian(bodyLength)
        out.append(channelID)
        out.append(UInt8(messageNumber & 0xff))
        out.append(UInt8((messageNumber >> 8) & 0xff))
        out.append(UInt8((messageNumber >> 16) & 0xff))
        out.appendLittleEndian(status)
        out.appendLittleEndian(messageClass)
        if let payloadOffset {
            out.appendLittleEndian(payloadOffset)
        }
        return out
    }

    public init(parsing data: Data) throws {
        guard data.count >= Self.minimumLength else {
            throw BaichuanError.protocolViolation(detail: "header is \(data.count) bytes, needs at least 20")
        }
        guard data.readLittleEndian(at: 0) as UInt32 == Self.magic else {
            throw BaichuanError.protocolViolation(detail: "bad magic")
        }
        let messageClass: UInt16 = data.readLittleEndian(at: 18)
        guard let headerLength = BcMessageClass.headerLength(for: messageClass) else {
            throw BaichuanError.protocolViolation(
                detail: String(format: "unknown message class 0x%04x", messageClass)
            )
        }
        guard data.count >= headerLength else {
            throw BaichuanError.protocolViolation(
                detail: "header is \(data.count) bytes, class needs \(headerLength)"
            )
        }
        let number = UInt32(data.byte(at: 13))
            | UInt32(data.byte(at: 14)) << 8
            | UInt32(data.byte(at: 15)) << 16
        self.init(
            messageID: data.readLittleEndian(at: 4),
            bodyLength: data.readLittleEndian(at: 8),
            channelID: data.byte(at: 12),
            messageNumber: number,
            status: data.readLittleEndian(at: 16),
            messageClass: messageClass,
            payloadOffset: headerLength == 24 ? data.readLittleEndian(at: 20) as UInt32 : nil
        )
    }
}

/// Header byte 12. Not a channel index: the host and the push channel live in
/// the same byte, above every real channel.
public enum BcChannelID {
    public static let push: UInt8 = 251
    public static let host: UInt8 = 250

    public static func forChannel(_ channel: Int?) -> UInt8 {
        guard let channel else { return host }
        return UInt8(clamping: channel + 1)
    }
}

/// One complete message: a header and the two body regions, still encrypted.
///
/// The two regions are ciphered separately and then concatenated, so they must
/// stay apart until each has been through the cipher on its own.
public struct BcFrame: Sendable, Equatable {
    public var header: BcHeader
    /// The XML region. Encrypted.
    public var extensionBytes: Data
    /// The binary region. Encrypted too, under FullAes.
    public var payloadBytes: Data

    public init(header: BcHeader, extensionBytes: Data = Data(), payloadBytes: Data = Data()) {
        self.header = header
        self.extensionBytes = extensionBytes
        self.payloadBytes = payloadBytes
    }

    public func encoded() -> Data {
        var out = header.encoded()
        out.append(extensionBytes)
        out.append(payloadBytes)
        return out
    }
}

/// Turns a TCP byte stream back into frames.
///
/// One Baichuan message can span several TCP segments and several can arrive in
/// one, so the reader keeps a buffer and only yields a frame once the header's
/// own `bodyLength` has been satisfied.
public struct BcFrameReader: Sendable {
    private var buffer = Data()

    public init() {}

    public var bufferedByteCount: Int { buffer.count }

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// The next complete frame, or nil when more bytes are needed.
    public mutating func next() throws -> BcFrame? {
        guard buffer.count >= BcHeader.minimumLength else { return nil }
        let messageClass: UInt16 = buffer.readLittleEndian(at: 18)
        guard let headerLength = BcMessageClass.headerLength(for: messageClass) else {
            throw BaichuanError.protocolViolation(
                detail: String(format: "unknown message class 0x%04x", messageClass)
            )
        }
        guard buffer.count >= headerLength else { return nil }

        let header = try BcHeader(parsing: buffer)
        let total = headerLength + Int(header.bodyLength)
        guard buffer.count >= total else { return nil }

        let bodyStart = buffer.startIndex + headerLength
        let split = buffer.startIndex + headerLength + min(header.extensionLength, Int(header.bodyLength))
        let frame = BcFrame(
            header: header,
            extensionBytes: Data(buffer[bodyStart..<split]),
            payloadBytes: Data(buffer[split..<(buffer.startIndex + total)])
        )
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + total))
        return frame
    }
}

extension Data {
    func byte(at offset: Int) -> UInt8 { self[startIndex + offset] }

    func readLittleEndian(at offset: Int) -> UInt16 {
        UInt16(byte(at: offset)) | UInt16(byte(at: offset + 1)) << 8
    }

    func readLittleEndian(at offset: Int) -> UInt32 {
        UInt32(byte(at: offset))
            | UInt32(byte(at: offset + 1)) << 8
            | UInt32(byte(at: offset + 2)) << 16
            | UInt32(byte(at: offset + 3)) << 24
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
