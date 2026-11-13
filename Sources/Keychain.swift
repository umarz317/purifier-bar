import Foundation
import Security

/// Stores the Mi Home cloud sign-in (needed for remote access) in the login Keychain.
enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Purifier Bar",
        kSecAttrAccount as String: "Mi Home",
    ]

    static func load<T: Decodable>(_ type: T.Type) -> T? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save(_ value: some Encodable) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        delete()
        var item = query
        item[kSecValueData as String] = data
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() { SecItemDelete(query as CFDictionary) }
}
