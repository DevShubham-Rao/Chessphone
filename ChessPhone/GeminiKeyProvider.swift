import Foundation
import Security

/// Loads the Gemini API key WITHOUT hard-coding it in source. Lookup order:
///  1. Keychain  (typed once into the app's settings; safest for a personal build)
///  2. Secrets.plist in the app bundle (untracked file, see Secrets.example.plist)
///  3. GEMINI_API_KEY environment variable (only exists when launched from Xcode's scheme)
///
/// NOTE: anything that ships inside the app (plist) or sits on the device can be extracted by
/// someone determined. For a build you give to other people, put a small proxy in front of
/// Gemini and keep the real key on the server.
enum GeminiKeyProvider {
    private static let service = "ChessPhone.Gemini"
    private static let account = "apiKey"

    static func apiKey() throws -> String {
        if let k = readKeychain(), !k.isEmpty { return k }

        if let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
           let dict = NSDictionary(contentsOf: url),
           let k = dict["GEMINI_API_KEY"] as? String,
           !k.isEmpty, !k.hasPrefix("PASTE") {
            return k
        }

        if let k = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !k.isEmpty { return k }

        throw VisionError.missingAPIKey
    }

    static var hasKey: Bool { (try? apiKey()) != nil }

    static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
