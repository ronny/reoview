import Foundation

public struct BaichuanCredentials: Sendable, Equatable {
    public var user: String
    public var password: String

    public init(user: String, password: String) {
        self.user = user
        self.password = password
    }
}

/// Talks Baichuan to one device on port 9000.
///
/// The actor owns the socket, the login state, and the reply table. One TCP
/// connection carries every message, so a reply is matched to its request by
/// the four bytes at header offset 12, which the device echoes back verbatim.
///
/// Nothing here logs. The nonce, the password and the derived key would all
/// otherwise reach a log file, and a Baichuan nonce plus a log of the login
/// message is enough to recover the session key.
public actor BaichuanClient {
    public struct Configuration: Sendable {
        public var requestTimeout: Duration
        /// The release of the talk slot gets its own, shorter deadline, so a
        /// wedged connection cannot leave the camera busy for the next talker.
        public var releaseTimeout: Duration
        /// `reolink_aio` sends message 93 every 30 s, measured from the last
        /// receive rather than the last send.
        public var keepaliveInterval: Duration
        public var frameRules: BcMediaFrameRules

        public init(
            requestTimeout: Duration = .seconds(5),
            releaseTimeout: Duration = .seconds(3),
            keepaliveInterval: Duration = .seconds(30),
            frameRules: BcMediaFrameRules = .neolinkRust
        ) {
            self.requestTimeout = requestTimeout
            self.releaseTimeout = releaseTimeout
            self.keepaliveInterval = keepaliveInterval
            self.frameRules = frameRules
        }
    }

    private struct MessageKey: Hashable {
        let messageID: UInt32
        let correlationID: UInt32
    }

    /// A reply can land before the caller has installed its continuation,
    /// because the write suspends. The result is parked here when it does.
    private struct Pending {
        var continuation: CheckedContinuation<BcFrame, any Error>?
        var result: Result<BcFrame, any Error>?
        var timeout: Task<Void, Never>?
    }

    private struct TalkState {
        /// One message number for the whole stream, because `binaryData` mode
        /// is keyed on it. The device does the same with its own 202 pushes.
        let messageNumber: UInt32
        let fullBlockSize: Int
    }

    private let connection: any BaichuanConnection
    private let credentials: BaichuanCredentials
    private let configuration: Configuration

    private var cipher: BcCipher = .bcEncrypt
    private var encryptionLevel: BcEncryptionLevel = .bcEncrypt
    private var loginHashes: (user: String, password: String)?
    private var messageCounter: UInt32 = 0
    private var pending: [MessageKey: Pending] = [:]
    private var talk: [Int: TalkState] = [:]
    private var readTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var lastReceive = ContinuousClock.now
    private var isOpen = false

    public private(set) var isLoggedIn = false

    public init(
        connection: any BaichuanConnection,
        credentials: BaichuanCredentials,
        configuration: Configuration = Configuration()
    ) {
        self.connection = connection
        self.credentials = credentials
        self.configuration = configuration
    }

    // MARK: - Session

    /// Opens the socket and logs in.
    public func connect() async throws {
        guard !isOpen else { return }
        do {
            try await connection.open()
        } catch let error as BaichuanError {
            throw error
        } catch {
            throw BaichuanError.connection(error)
        }
        isOpen = true
        lastReceive = .now
        readTask = Task { [weak self] in await self?.pump() }

        do {
            try await logIn()
        } catch {
            await disconnect()
            throw error
        }
        keepaliveTask = Task { [weak self] in await self?.keepalive() }
    }

    /// Releases every talk slot, logs out, and closes the socket.
    public func disconnect() async {
        for channel in talk.keys.sorted() {
            await stopTalk(channel: channel)
        }
        if isLoggedIn, let hashes = loginHashes {
            _ = try? await call(
                BcMessageID.logout,
                channel: nil,
                body: BcXML.logout(userHash: hashes.user, passwordHash: hashes.password),
                timeout: configuration.releaseTimeout
            )
        }
        isLoggedIn = false
        isOpen = false
        keepaliveTask?.cancel()
        keepaliveTask = nil
        readTask?.cancel()
        readTask = nil
        await connection.close()
        failAll(with: BaichuanError.connection(URLError(.cancelled)))
        cipher = .bcEncrypt
        encryptionLevel = .bcEncrypt
        loginHashes = nil
    }

    /// Four steps: ask for the nonce, read it, send the modern login, read the
    /// reply.
    ///
    /// FullAes is compulsory on firmware v3.6.5.562. The word `12dc` is the
    /// only one the device answers; `03dc`, `02dc`, `01dc` and `00dc` each get
    /// silence on an accepted connection, so there is no weaker mode to fall
    /// back to and none is attempted.
    private func logIn() async throws {
        let nonceReply = try await call(
            BcMessageID.login,
            channel: nil,
            cipher: BcCipher.plaintext,
            messageClass: BcMessageClass.legacy,
            status: BcEncryptionLevel.fullAes.requestWord
        )
        guard let level = BcEncryptionLevel(replyWord: nonceReply.frame.header.status) else {
            throw BaichuanError.protocolViolation(
                detail: String(format: "the login reply carried encryption word 0x%04x", nonceReply.frame.header.status)
            )
        }
        guard level.usesAES else {
            throw BaichuanError.protocolViolation(detail: "the device chose a cipher this client does not use")
        }

        let nonce = try BcXML.nonce(from: nonceReply.xml)
        encryptionLevel = level
        cipher = .aes(key: BcCrypto.aesKey(nonce: nonce, password: credentials.password))

        let hashes = (
            user: BcCrypto.loginHash(credentials.user + nonce),
            password: BcCrypto.loginHash(credentials.password + nonce)
        )
        loginHashes = hashes

        // The AES key is not usable until the login is accepted, so this one
        // message goes out under BCEncrypt and its reply comes back the same
        // way, even though the header is modern.
        _ = try await call(
            BcMessageID.login,
            channel: nil,
            body: BcXML.login(userHash: hashes.user, passwordHash: hashes.password),
            cipher: .bcEncrypt
        )
        isLoggedIn = true
    }

    // MARK: - Commands

    /// Message 199. Reports `ipcAudioTalk` for every channel.
    ///
    /// It answers status **300**, which is a success on this firmware.
    public func deviceInfo() async throws -> BaichuanDeviceInfo {
        let reply = try await call(BcMessageID.support, channel: nil)
        return try BcXML.deviceInfo(from: reply.xml)
    }

    /// Message 10. What the camera on that channel accepts. Read it; do not
    /// assume it.
    public func talkAbility(channel: Int) async throws -> TalkAbility {
        let reply = try await call(
            BcMessageID.talkAbility,
            channel: channel,
            extensionXML: BcXML.channelExtension(channel)
        )
        return try BcXML.talkAbility(from: reply.xml)
    }

    /// Message 201. Opens the talk slot, which the device grants to one client
    /// at a time.
    ///
    /// The reply is a 200 with an empty body. A wrong config, or a channel with
    /// no camera, answers 400.
    public func startTalk(channel: Int, ability: TalkAbility) async throws -> any TalkSession {
        guard ability.isTalkable else {
            throw BaichuanError.protocolViolation(
                detail: "the device offers \(ability.audioType) for talk, and only adpcm is supported"
            )
        }

        let body = BcXML.talkConfig(
            channel: channel,
            ability: ability,
            mode: ability.preferredAudioStreamMode
        )
        var number = nextMessageNumber()
        do {
            try await openTalk(channel: channel, body: body, messageNumber: number)
        } catch let error as BaichuanError where error.isTalkSlotBusy {
            // 422 means another client holds the slot, possibly a crashed
            // session of ours. Release it and try once.
            await releaseTalkSlot(channel: channel)
            number = nextMessageNumber()
            try await openTalk(channel: channel, body: body, messageNumber: number)
        }

        talk[channel] = TalkState(messageNumber: number, fullBlockSize: ability.fullBlockSize)
        return BaichuanTalkSession(client: self, channel: channel, format: ability.audioFormat)
    }

    private func openTalk(channel: Int, body: String, messageNumber: UInt32) async throws {
        _ = try await call(
            BcMessageID.talkConfig,
            channel: channel,
            messageNumber: messageNumber,
            extensionXML: BcXML.channelExtension(channel),
            body: body
        )
    }

    /// Message 202. One ADPCM block, DVI state header included.
    ///
    /// Under FullAes the binary payload is encrypted and the extension declares
    /// how many bytes of it are. Neither neolink nor `reolink_aio` ever sends
    /// an encrypted binary payload, because neither meets a device that forces
    /// FullAes, so the outbound direction here copies the shape of the inbound
    /// 202 frames the NVR sends.
    public func send(block: Data, channel: Int) async throws {
        guard isLoggedIn else {
            throw BaichuanError.protocolViolation(detail: "send before login")
        }
        guard let state = talk[channel] else {
            throw BaichuanError.protocolViolation(detail: "no talk session on channel \(channel)")
        }
        guard block.count > BcMedia.dviStateLength, block.count <= state.fullBlockSize else {
            throw BaichuanError.protocolViolation(
                detail: "an ADPCM block is \(block.count) bytes, and the device asked for \(state.fullBlockSize)"
            )
        }

        let channelID = BcChannelID.forChannel(channel)
        let offset = UInt32(channelID)
        let media = BcMedia.adpcmFrame(block: block, rules: configuration.frameRules)

        let encryptsPayload = encryptionLevel.encryptsBinaryPayloads
        // AES-CFB is length preserving, so the declared length is both the
        // plaintext and the on-wire count. `bodyLength` and `payloadOffset`
        // are computed from the bytes about to be written either way.
        let payload = encryptsPayload ? try cipher.encrypt(media, offset: offset) : media
        let extensionXML = BcXML.talkExtension(
            channel: channel,
            encryptLen: encryptsPayload ? payload.count : nil
        )
        let extensionBytes = try cipher.encrypt(Data(extensionXML.utf8), offset: offset)

        let header = BcHeader(
            messageID: BcMessageID.talk,
            bodyLength: UInt32(extensionBytes.count + payload.count),
            channelID: channelID,
            messageNumber: state.messageNumber,
            payloadOffset: UInt32(extensionBytes.count)
        )
        // The camera sends no reply to a talk message, so this does not wait.
        try await write(BcFrame(header: header, extensionBytes: extensionBytes, payloadBytes: payload).encoded())
    }

    /// Message 11. Releases the slot. Safe to call when nothing is open.
    public func stopTalk(channel: Int) async {
        talk[channel] = nil
        await releaseTalkSlot(channel: channel)
    }

    private func releaseTalkSlot(channel: Int) async {
        _ = try? await call(
            BcMessageID.talkReset,
            channel: channel,
            extensionXML: BcXML.channelExtension(channel),
            timeout: configuration.releaseTimeout
        )
    }

    // MARK: - Request and reply

    private func nextMessageNumber() -> UInt32 {
        messageCounter = (messageCounter &+ 1) % 0x0100_0000
        return messageCounter
    }

    @discardableResult
    private func call(
        _ messageID: UInt32,
        channel: Int?,
        messageNumber: UInt32? = nil,
        extensionXML: String = "",
        body: String = "",
        cipher overrideCipher: BcCipher? = nil,
        messageClass: UInt16 = BcMessageClass.modernWithPayloadOffset,
        status: UInt16 = 0,
        timeout: Duration? = nil
    ) async throws -> (frame: BcFrame, xml: String) {
        let channelID = BcChannelID.forChannel(channel)
        let offset = UInt32(channelID)
        let requestCipher = overrideCipher ?? cipher
        let extensionBytes = try requestCipher.encrypt(Data(extensionXML.utf8), offset: offset)
        let bodyBytes = try requestCipher.encrypt(Data(body.utf8), offset: offset)

        let header = BcHeader(
            messageID: messageID,
            bodyLength: UInt32(extensionBytes.count + bodyBytes.count),
            channelID: channelID,
            messageNumber: messageNumber ?? nextMessageNumber(),
            status: status,
            messageClass: messageClass,
            payloadOffset: UInt32(extensionBytes.count)
        )
        let request = BcFrame(header: header, extensionBytes: extensionBytes, payloadBytes: bodyBytes)
        let key = MessageKey(messageID: messageID, correlationID: header.correlationID)

        pending[key] = Pending()
        arm(key, timeout: timeout ?? configuration.requestTimeout, messageID: messageID)
        do {
            try await write(request.encoded())
        } catch {
            finish(key, with: .failure(error))
            throw error
        }

        let frame = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BcFrame, any Error>) in
            guard var slot = pending[key] else {
                continuation.resume(throwing: BaichuanError.timeout(messageID: messageID))
                return
            }
            if let result = slot.result {
                pending[key] = nil
                continuation.resume(with: result)
            } else {
                slot.continuation = continuation
                pending[key] = slot
            }
        }

        let replyCipher = replyCipher(for: frame.header, request: requestCipher)
        let plain = try replyCipher.decrypt(frame.extensionBytes, offset: frame.header.encryptionOffset)
        guard let xml = String(data: plain, encoding: .utf8) else {
            throw BaichuanError.decryption(detail: "the reply to message \(messageID) is not UTF-8")
        }
        return (frame, xml)
    }

    /// Which cipher opens a reply body.
    ///
    /// A 20-byte header names the cipher in its own encryption word, and there
    /// `12dd` means BCEncrypt, not AES: FullAes describes the session that is
    /// about to start, while the nonce that starts it is still XOR-scrambled.
    /// A 24-byte reply always comes back under whatever the request used.
    private func replyCipher(for header: BcHeader, request: BcCipher) -> BcCipher {
        guard header.length == 20 else { return request }
        switch BcEncryptionLevel(replyWord: header.status) {
        case .unencrypted: return .plaintext
        case .bcEncrypt, .fullAes: return .bcEncrypt
        case .aes, .aesAlternate: return cipher
        case nil: return request
        }
    }

    private func write(_ data: Data) async throws {
        do {
            try await connection.send(data)
        } catch let error as BaichuanError {
            throw error
        } catch {
            throw BaichuanError.connection(error)
        }
    }

    private func arm(_ key: MessageKey, timeout: Duration, messageID: UInt32) {
        pending[key]?.timeout = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.finish(key, with: .failure(BaichuanError.timeout(messageID: messageID)))
        }
    }

    private func finish(_ key: MessageKey, with result: Result<BcFrame, any Error>) {
        guard var slot = pending[key] else { return }
        slot.timeout?.cancel()
        if let continuation = slot.continuation {
            pending[key] = nil
            continuation.resume(with: result)
        } else {
            slot.timeout = nil
            slot.result = result
            pending[key] = slot
        }
    }

    private func failAll(with error: any Error) {
        let keys = Array(pending.keys)
        for key in keys {
            finish(key, with: .failure(error))
        }
    }

    // MARK: - Read loop

    private func pump() async {
        var reader = BcFrameReader()
        while isOpen {
            let chunk: Data
            do {
                chunk = try await connection.receive()
            } catch {
                failAll(with: error)
                return
            }
            guard !chunk.isEmpty else {
                failAll(with: BaichuanError.connection(URLError(.networkConnectionLost)))
                return
            }
            lastReceive = .now
            reader.append(chunk)
            do {
                while let frame = try reader.next() {
                    await handle(frame)
                }
            } catch {
                failAll(with: error)
                return
            }
        }
    }

    private func handle(_ frame: BcFrame) async {
        if frame.header.messageID == BcMessageID.udpKeepalive {
            await answerHeartbeat(frame.header)
            return
        }

        let key = MessageKey(messageID: frame.header.messageID, correlationID: frame.header.correlationID)
        guard pending[key] != nil else {
            // Unsolicited. The NVR pushes message 202 with the camera's own
            // microphone once talk is open; this client does not consume it.
            return
        }

        // A 20-byte header has no status: those two bytes carry the encryption
        // word during login.
        if frame.header.length == 24, !BcStatus.isSuccess(Int(frame.header.status)) {
            finish(key, with: .failure(
                BaichuanError.status(messageID: frame.header.messageID, status: Int(frame.header.status))
            ))
            return
        }
        finish(key, with: .success(frame))
    }

    /// The device sends message 234 on its own. It wants a header-only message
    /// back with the same message number. `reolink_aio` puts 0 in the status
    /// field, the same as every other request it sends; neolink's notes say
    /// 200. The 0 is used here, because it is what a device on this firmware
    /// has been seen to accept.
    private func answerHeartbeat(_ received: BcHeader) async {
        let header = BcHeader(
            messageID: BcMessageID.udpKeepalive,
            bodyLength: 0,
            channelID: received.channelID,
            messageNumber: received.messageNumber,
            payloadOffset: 0
        )
        try? await write(header.encoded())
    }

    private func keepalive() async {
        while !Task.isCancelled {
            let delay = keepaliveDelay()
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, isOpen, isLoggedIn else {
                if !isOpen { return }
                continue
            }
            _ = try? await call(BcMessageID.linkType, channel: nil)
        }
    }

    /// Measured from the last receive, not the last send, so a busy connection
    /// never sends a keepalive it does not need.
    private func keepaliveDelay() -> Duration {
        let elapsed = ContinuousClock.now - lastReceive
        let remaining = configuration.keepaliveInterval - elapsed
        return max(remaining, .milliseconds(100))
    }
}

/// One open talk slot on one channel.
struct BaichuanTalkSession: TalkSession {
    let client: BaichuanClient
    let channel: Int
    let format: TalkAudioFormat

    func send(block: Data) async throws {
        try await client.send(block: block, channel: channel)
    }

    func stop() async {
        await client.stopTalk(channel: channel)
    }
}
