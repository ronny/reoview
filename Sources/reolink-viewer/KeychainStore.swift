import Foundation
import Security

enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case malformedData
}

/// The NVR password, held as a `kSecClassGenericPassword` item in the file
/// keychain.
///
/// The data protection keychain is not available here. It needs a
/// `keychain-access-groups` entitlement, which needs an embedded provisioning
/// profile. Without one, `SecItemAdd` returns `errSecMissingEntitlement`
/// (-34018), and a binary signed with `com.apple.application-identifier` and no
/// profile is killed on launch. A Developer ID app gets neither for free.
///
/// Nothing here ever logs the password, and no caller should.
enum KeychainStore {
    static let service = "au.ronny.ReolinkViewer"

    static func account(username: String, host: String) -> String {
        "\(username)@\(host)"
    }

    static func password(username: String, host: String) throws -> String? {
        var query = baseQuery(username: username, host: host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
                throw KeychainError.malformedData
            }
            return password
        case errSecItemNotFound:
            return nil
        default:
            Log.keychain.error("keychain read failed with status \(status, privacy: .public)")
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func setPassword(_ password: String, username: String, host: String) throws {
        let query = baseQuery(username: username, host: host)
        let data = Data(password.utf8)

        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = data
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else {
                Log.keychain.error("keychain write failed with status \(insertStatus, privacy: .public)")
                throw KeychainError.unexpectedStatus(insertStatus)
            }
        default:
            Log.keychain.error("keychain update failed with status \(status, privacy: .public)")
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func deletePassword(username: String, host: String) throws {
        let status = SecItemDelete(baseQuery(username: username, host: host) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Log.keychain.error("keychain delete failed with status \(status, privacy: .public)")
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private static func baseQuery(username: String, host: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(username: username, host: host),
        ]
    }
}
