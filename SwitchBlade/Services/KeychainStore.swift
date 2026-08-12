import Foundation
import Security

/// API keys live in the keychain rather than UserDefaults — UserDefaults is a
/// plist in the app container and is included in unencrypted backups.
enum KeychainStore {
    private static let service = "com.lalitmangal.SwitchBlade.credentials"

    static func set(_ value: String?, for account: String) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let trimmed, !trimmed.isEmpty else {
            remove(account)
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }

        // Silently discarding this status hides a whole class of failure: an
        // unsigned build has no keychain entitlement, every write returns
        // -34018, and the UI cheerfully reports the key as saved while nothing
        // is stored.
        if status != errSecSuccess {
            lastError = status
            NSLog("[SwitchBlade] Keychain write for '%@' failed: %d (%@)",
                  account, status, describe(status))
        } else {
            lastError = nil
        }
    }

    /// Status of the most recent write, so the UI can tell the user a save
    /// didn't take rather than pretending it did.
    private(set) nonisolated(unsafe) static var lastError: OSStatus?

    static func describe(_ status: OSStatus) -> String {
        switch status {
        case errSecSuccess:
            return "ok"
        case errSecMissingEntitlement:
            return "missing keychain entitlement — the build isn't signed"
        case errSecInteractionNotAllowed:
            return "keychain locked"
        case errSecDuplicateItem:
            return "duplicate item"
        default:
            return (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown error"
        }
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty
        else { return nil }

        return string
    }

    static func remove(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Named slots for the providers the app talks to.
///
/// Wikipedia (the Learn feed) and the two dictionary feeds need no credentials
/// at all, so they have no slot here.
enum CredentialSlot: String, CaseIterable, Identifiable {
    case gemini
    case tmdb
    case omdb
    case igdbClientID
    case igdbClientSecret

    var id: String { rawValue }

    /// Label for this individual field, used inside a provider's editor.
    var fieldLabel: String {
        switch self {
        case .gemini: return "API key"
        case .tmdb: return "API key"
        case .omdb: return "API key"
        case .igdbClientID: return "Client ID"
        case .igdbClientSecret: return "Client Secret"
        }
    }

    var title: String {
        switch self {
        case .gemini: return "Google Gemini"
        case .tmdb: return "TMDB"
        case .omdb: return "OMDb"
        case .igdbClientID: return "IGDB Client ID"
        case .igdbClientSecret: return "IGDB Client Secret"
        }
    }

    var purpose: String {
        switch self {
        case .gemini: return "Vibe tags and custom-shelf entries. Free tier, no card required."
        case .tmdb: return "Descriptions, genres, posters, and years for films and TV. Free."
        case .omdb: return "Exact IMDb ratings. Optional — TMDB scores are used without it. Free."
        case .igdbClientID: return "Cover art and details for console games, including PS5 exclusives. Optional but recommended if you play on console. Free via Twitch."
        case .igdbClientSecret: return "The secret paired with the IGDB Client ID above. Both are needed."
        }
    }

    var signupURL: URL? {
        switch self {
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .tmdb: return URL(string: "https://www.themoviedb.org/settings/api")
        case .omdb: return URL(string: "https://www.omdbapi.com/apikey.aspx")
        case .igdbClientID, .igdbClientSecret:
            return URL(string: "https://api-docs.igdb.com/#account-creation")
        }
    }

    /// Whether the app degrades gracefully without this key.
    var isOptional: Bool {
        switch self {
        case .omdb, .igdbClientID, .igdbClientSecret: return true
        case .gemini, .tmdb: return false
        }
    }
}


// MARK: - Providers

/// A service as the user thinks of it, which may need more than one field.
///
/// IGDB authenticates through Twitch and so needs a client id *and* a secret;
/// showing those as two unrelated rows made it look like two services, and
/// half-configuring it is useless.
enum CredentialProvider: String, CaseIterable, Identifiable {
    case gemini
    case tmdb
    case omdb
    case igdb

    var id: String { rawValue }

    var slots: [CredentialSlot] {
        switch self {
        case .gemini: return [.gemini]
        case .tmdb: return [.tmdb]
        case .omdb: return [.omdb]
        case .igdb: return [.igdbClientID, .igdbClientSecret]
        }
    }

    var title: String {
        switch self {
        case .gemini: return "Google Gemini"
        case .tmdb: return "TMDB"
        case .omdb: return "OMDb"
        case .igdb: return "IGDB"
        }
    }

    var purpose: String {
        switch self {
        case .gemini:
            return "Vibe tags and custom-shelf entries. Free tier, no card required."
        case .tmdb:
            return "Descriptions, genres, posters, cast, and years for films and TV. Free."
        case .omdb:
            return "Exact IMDb ratings. Without it, TMDB's own community score is shown instead. Free."
        case .igdb:
            return "Cover art and details for console games, including PS5 exclusives. Free, but authenticates through Twitch so it needs both an ID and a secret."
        }
    }

    var signupURL: URL? {
        switch self {
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .tmdb: return URL(string: "https://www.themoviedb.org/settings/api")
        case .omdb: return URL(string: "https://www.omdbapi.com/apikey.aspx")
        case .igdb: return URL(string: "https://api-docs.igdb.com/#account-creation")
        }
    }

    var isOptional: Bool {
        switch self {
        case .omdb, .igdb: return true
        case .gemini, .tmdb: return false
        }
    }

    /// What the app falls back to when this provider isn't set up.
    var fallbackNote: String? {
        switch self {
        case .omdb: return "Falls back to TMDB scores."
        case .igdb: return "Falls back to Steam and Wikipedia, which have no cover art for console exclusives."
        case .gemini, .tmdb: return nil
        }
    }
}
