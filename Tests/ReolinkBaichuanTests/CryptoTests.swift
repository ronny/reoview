import Foundation
import Testing
@testable import ReolinkBaichuan

@Suite("Ciphers")
struct CryptoTests {
    private let key = Data("716E3329F1E6E3BE".utf8)
    private let plaintext = Data("""
        <?xml version="1.0" encoding="UTF-8" ?>
        <Extension version="1.1">
        </Extension>

        """.utf8)

    @Test("BCEncrypt is its own inverse and depends on the offset")
    func bcEncryptRoundTrip() {
        let cipher = BcCipher.bcEncrypt
        for offset in [UInt32(0), 1, 2, 250, 251] {
            let sealed = try! cipher.encrypt(plaintext, offset: offset)
            #expect(sealed != plaintext)
            #expect(try! cipher.decrypt(sealed, offset: offset) == plaintext)
        }
        let atHost = try! cipher.encrypt(plaintext, offset: 250)
        let atChannel = try! cipher.encrypt(plaintext, offset: 1)
        #expect(atHost != atChannel)
    }

    @Test("BCEncrypt matches the reference XOR at the host offset")
    func bcEncryptVector() {
        let sealed = BcCrypto.bcEncrypt(Data("<?xml version=\"1.0\"".utf8), offset: 250)
        #expect(sealed.hexString == "fa8ed8feee2593b2b4c2c9fcec38c7e6e88182")
    }

    @Test("AES-128-CFB matches the reference implementation, 128-bit segment")
    func aesVector() throws {
        let sealed = try BcCrypto.aesCFB(plaintext, key: key, encrypt: true)
        // Produced by pycryptodome with segment_size=128, the same setting
        // reolink_aio uses. kCCModeCFB8 would give a different first block, so
        // this pins the mode as well as the key.
        let expected = "7777d79cd2fd3188b0c08f637c871275950c8cf4bc3ac81a088eceeda51c0db6"
            + "f2ba256789380251c0d511bc1bf9470bc0f7072d739f1cdd87a823eef75f0d9c"
            + "b81dc91da5f647a7a5979143367b3f"
        #expect(sealed.hexString == expected)
        #expect(sealed.count == plaintext.count)
    }

    @Test("AES round trips a payload that is not a whole number of blocks")
    func aesRoundTrip() throws {
        for count in [1, 15, 16, 17, 516, 532, 4160] {
            let data = Data((0..<count).map { UInt8($0 % 251) })
            let sealed = try BcCrypto.aesCFB(data, key: key, encrypt: true)
            #expect(sealed.count == count)
            #expect(try BcCrypto.aesCFB(sealed, key: key, encrypt: false) == data)
        }
    }

    @Test("The CFB state does not carry between messages")
    func freshCipherPerMessage() throws {
        let first = try BcCrypto.aesCFB(plaintext, key: key, encrypt: true)
        let second = try BcCrypto.aesCFB(plaintext, key: key, encrypt: true)
        #expect(first == second)
    }

    @Test("An empty region ciphers to nothing")
    func emptyRegion() throws {
        #expect(try BcCipher.aes(key: key).encrypt(Data(), offset: 1).isEmpty)
        #expect(try BcCipher.bcEncrypt.encrypt(Data(), offset: 1).isEmpty)
    }

    @Test("A key that is not 16 bytes is refused")
    func shortKey() {
        #expect(throws: BaichuanError.self) {
            try BcCrypto.aesCFB(plaintext, key: Data("short".utf8), encrypt: true)
        }
    }

    @Test("The AES key is the first 16 characters of the hex, not of the digest")
    func keyDerivation() {
        let derived = BcCrypto.aesKey(nonce: Fixture.nonce, password: Fixture.password)
        #expect(derived == key)
        #expect(String(data: derived, encoding: .utf8) == "716E3329F1E6E3BE")
    }

    @Test("The login hash is uppercase hex MD5 cut to 31 characters")
    func loginHash() {
        let user = BcCrypto.loginHash(Fixture.user + Fixture.nonce)
        let password = BcCrypto.loginHash(Fixture.password + Fixture.nonce)
        #expect(user == "3F4E4E7C4418492BA1A48B19839F18A")
        #expect(password == "849DAD014F63DF8B57130885C8044A8")
        #expect(user.count == 31)
    }

    @Test("The encryption words are the bytes the device answers to")
    func encryptionWords() {
        #expect(BcEncryptionLevel.fullAes.requestWord == 0xdc12)
        #expect(BcEncryptionLevel.fullAes.replyWord == 0xdd12)
        #expect(BcEncryptionLevel(replyWord: 0xdd12) == .fullAes)
        #expect(BcEncryptionLevel(replyWord: 0xdd02) == .aes)
        #expect(BcEncryptionLevel(replyWord: 0xdd03) == .aesAlternate)
        #expect(BcEncryptionLevel(replyWord: 0xdc12) == nil)
        #expect(BcEncryptionLevel.fullAes.encryptsBinaryPayloads)
        #expect(!BcEncryptionLevel.aes.encryptsBinaryPayloads)
    }
}
