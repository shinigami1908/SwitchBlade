import Foundation
import Observation

/// Guards every call to the language model.
///
/// The failure mode this exists to prevent is the quiet one: a view that
/// re-renders, fires a generation, re-renders again, and drains a day's quota in
/// a few minutes. Nothing in the app may call Gemini without first claiming a
/// slot here, and a claim is refused once the daily cap is hit.
@MainActor
@Observable
final class AIBudget {
    static let shared = AIBudget()

    /// Calls permitted per calendar day. Deliberately small: metadata comes
    /// from TMDB and Steam, words from dictionary feeds, and the Learn feed from
    /// Wikipedia — so Gemini is only needed for vibe tags and custom shelves,
    /// both of which are batched.
    var dailyCallLimit: Int {
        didSet {
            defaults.set(dailyCallLimit, forKey: Keys.limit)
        }
    }

    /// Minimum spacing between model calls. A second line of defence against
    /// render loops, independent of the daily cap.
    private let minimumInterval: TimeInterval = 2.0

    private let defaults = UserDefaults.standard
    private var ledger: [String: Entry]
    private var lastCallAt: Date?

    private enum Keys {
        static let limit = "ai.daily_call_limit"
        static let ledger = "ai.usage_ledger"
    }

    private struct Entry: Codable {
        var calls: Int
        var estimatedTokens: Int
    }

    private init() {
        let storedLimit = defaults.integer(forKey: Keys.limit)
        dailyCallLimit = storedLimit > 0 ? storedLimit : 12

        if let data = defaults.data(forKey: Keys.ledger),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            ledger = decoded
        } else {
            ledger = [:]
        }

        pruneOldEntries()
    }

    // MARK: - Reading

    var callsToday: Int { ledger[Date.now.dayKey]?.calls ?? 0 }
    var tokensToday: Int { ledger[Date.now.dayKey]?.estimatedTokens ?? 0 }
    var remainingToday: Int { max(0, dailyCallLimit - callsToday) }
    var isExhausted: Bool { remainingToday == 0 }

    var fractionUsed: Double {
        guard dailyCallLimit > 0 else { return 1 }
        return min(1, Double(callsToday) / Double(dailyCallLimit))
    }

    /// Last 7 days, oldest first, for the usage chart in Settings.
    func recentUsage(days: Int = 7) -> [(day: String, calls: Int)] {
        let calendar = Calendar.current
        return (0..<days).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: .now) else { return nil }
            let key = date.dayKey
            return (day: key, calls: ledger[key]?.calls ?? 0)
        }
    }

    // MARK: - Claiming

    /// Reserves one call. Returns `false` if the cap is reached or the caller is
    /// hammering — the caller must then skip the request entirely.
    func claim() -> Bool {
        guard !isExhausted else { return false }

        if let lastCallAt, Date.now.timeIntervalSince(lastCallAt) < minimumInterval {
            return false
        }

        let key = Date.now.dayKey
        var entry = ledger[key] ?? Entry(calls: 0, estimatedTokens: 0)
        entry.calls += 1
        ledger[key] = entry
        lastCallAt = .now
        persist()
        return true
    }

    /// Records the size of a completed call, for the Settings readout.
    func record(tokens: Int) {
        let key = Date.now.dayKey
        var entry = ledger[key] ?? Entry(calls: 0, estimatedTokens: 0)
        entry.estimatedTokens += tokens
        ledger[key] = entry
        persist()
    }

    /// Returns a claim when the request failed before reaching the provider, so
    /// a network blip doesn't cost the user a slot.
    func refund() {
        let key = Date.now.dayKey
        guard var entry = ledger[key], entry.calls > 0 else { return }
        entry.calls -= 1
        ledger[key] = entry
        lastCallAt = nil
        persist()
    }

    // MARK: - Storage

    private func persist() {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: Keys.ledger)
    }

    private func pruneOldEntries() {
        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .day, value: -14, to: .now) else { return }
        let cutoffKey = cutoff.dayKey
        let before = ledger.count
        ledger = ledger.filter { $0.key >= cutoffKey }
        if ledger.count != before { persist() }
    }
}
