import Foundation
import Observation
import SwiftUI

/// User-facing preferences plus a live view of which credentials are present.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let appearance = "settings.appearance"
        static let useLocation = "settings.use_location"
        static let geminiModel = "settings.gemini_model"
        static let resolvedGeminiModel = "settings.gemini_model_resolved"
        static let hasSeeded = "settings.has_seeded"
        static let hasCompletedImport = "settings.has_completed_import"
    }

    var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    /// When off, the home header shows date and time only and CoreLocation is
    /// never started.
    var useLocation: Bool {
        didSet { defaults.set(useLocation, forKey: Keys.useLocation) }
    }

    /// Which Gemini model handles vibe tags and custom shelves.
    var geminiModel: GeminiModel {
        didSet {
            defaults.set(geminiModel.rawValue, forKey: Keys.geminiModel)
            // A deliberate choice clears any automatic substitution, so the
            // picker means what it says.
            resolvedGeminiModelID = nil
        }
    }

    /// Model id discovered after the configured one 404'd. Nil means the
    /// configured id is being used as-is.
    var resolvedGeminiModelID: String? {
        didSet { defaults.set(resolvedGeminiModelID, forKey: Keys.resolvedGeminiModel) }
    }

    /// Set once the default shelves exist, so seeding never runs twice even if
    /// the user empties both shelves themselves.
    var hasSeeded: Bool {
        didSet { defaults.set(hasSeeded, forKey: Keys.hasSeeded) }
    }

    /// Drives the one-time import prompt on the Library tab.
    var hasCompletedImport: Bool {
        didSet { defaults.set(hasCompletedImport, forKey: Keys.hasCompletedImport) }
    }

    /// Bumped whenever a key is written so views observing this object refresh
    /// their "configured / not configured" badges.
    private(set) var credentialRevision: Int = 0

    private init() {
        appearance = AppAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .dark
        useLocation = defaults.object(forKey: Keys.useLocation) as? Bool ?? true
        geminiModel = GeminiModel(rawValue: defaults.string(forKey: Keys.geminiModel) ?? "") ?? .flash
        resolvedGeminiModelID = defaults.string(forKey: Keys.resolvedGeminiModel)
        hasSeeded = defaults.bool(forKey: Keys.hasSeeded)
        hasCompletedImport = defaults.bool(forKey: Keys.hasCompletedImport)
    }

    // MARK: - Credentials

    func key(for slot: CredentialSlot) -> String? {
        KeychainStore.get(slot.rawValue)
    }

    func hasKey(for slot: CredentialSlot) -> Bool {
        key(for: slot) != nil
    }

    func setKey(_ value: String?, for slot: CredentialSlot) {
        KeychainStore.set(value, for: slot.rawValue)
        credentialRevision &+= 1
    }

    /// Providers that are required but not yet configured.
    var missingRequiredSlots: [CredentialSlot] {
        CredentialSlot.allCases.filter { !$0.isOptional && !hasKey(for: $0) }
    }
}
