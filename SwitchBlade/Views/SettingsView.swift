import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var shelves: [MediaShelf]
    @Query private var items: [ShelfItem]
    @Query private var words: [WordOfTheDayItem]
    @Query private var articles: [KnowledgeArticleItem]

    @State private var showingResetAlert = false
    @State private var showingClearFeedAlert = false

    private let settings = AppSettings.shared
    private let budget = AIBudget.shared
    private let icons = AppIconStore.shared

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                appIconSection
                homeSection
                modelSection
                budgetSection
                credentialsSection
                libraryStatsSection
                dataSection
            }
            .navigationTitle("Settings")
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .alert("Reset everything?", isPresented: $showingResetAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) { resetDatabase() }
            } message: {
                Text("Deletes every shelf, entry, word, and article. API keys are kept. This can't be undone.")
            }
            .alert("Clear the Learn feed?", isPresented: $showingClearFeedAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) { clearFeed() }
            } message: {
                Text("Empties the current feed. Saved articles are kept.")
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: Binding(
                get: { settings.appearance },
                set: { settings.appearance = $0 }
            )) {
                ForEach(AppAppearance.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - App icon

    @ViewBuilder
    private var appIconSection: some View {
        if icons.isSupported {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(AppIconStyle.allCases) { style in
                        iconChoice(style)
                    }
                }
                .padding(.vertical, 6)

                if let error = icons.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.appWarning)
                }
            } header: {
                Text("App Icon")
            } footer: {
                Text("Adaptive follows your system appearance, including the tinted home screen. The other three stay as they are. iOS shows its own confirmation each time the icon changes.")
            }
        }
    }

    private func iconChoice(_ style: AppIconStyle) -> some View {
        let isSelected = icons.current == style

        return Button {
            icons.select(style)
        } label: {
            VStack(spacing: 7) {
                Image(style.previewAsset)
                    .resizable()
                    .frame(width: 60, height: 60)
                    // 13.5 of 60 is the ratio iOS uses for a home-screen icon.
                    .clipShape(RoundedRectangle(cornerRadius: 13.5, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13.5, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.appAccent : Color.appBorder,
                                lineWidth: isSelected ? 2.5 : 1
                            )
                    }

                Text(style.label)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.appAccent : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(style.label) icon")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Home

    private var homeSection: some View {
        Section {
            Toggle("Show location and weather", isOn: Binding(
                get: { settings.useLocation },
                set: {
                    settings.useLocation = $0
                    if $0 { PlaceService.shared.refreshIfNeeded() }
                }
            ))

        } header: {
            Text("Home")
        } footer: {
            Text("Weather comes from Open-Meteo and needs no account. Words come straight from Merriam-Webster's and Wordsmith's own daily feeds, and the Learn feed from Wikipedia \u{2014} none of the three costs anything.")
        }
    }

    // MARK: - AI budget

    private var modelSection: some View {
        Section {
            Picker("Model", selection: Binding(
                get: { settings.geminiModel },
                set: { settings.geminiModel = $0 }
            )) {
                ForEach(GeminiModel.allCases) { model in
                    Text(model.label).tag(model)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("Gemini Model")
        } footer: {
            Text(settings.geminiModel.blurb)
        }
    }

    private var budgetSection: some View {
        Section {
            HStack {
                Text("Calls today")
                Spacer()
                Text("\(budget.callsToday) of \(budget.dailyCallLimit)")
                    .foregroundStyle(budget.isExhausted ? Color.appWarning : .secondary)
                    .monospacedDigit()
            }

            ProgressView(value: budget.fractionUsed)
                .tint(budget.isExhausted ? Color.appWarning : Color.appAccent)

            Stepper(
                "Daily limit: \(budget.dailyCallLimit)",
                value: Binding(
                    get: { budget.dailyCallLimit },
                    set: { budget.dailyCallLimit = $0 }
                ),
                in: 2...100,
                step: 1
            )

            if budget.tokensToday > 0 {
                HStack {
                    Text("Tokens today")
                    Spacer()
                    Text(budget.tokensToday.formatted())
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            usageChart
        } header: {
            Text("AI Budget")
        } footer: {
            Text("This cap is the app's own guard against runaway loops, and sits well under Gemini's free-tier quota. Films and TV come from TMDB and games from Steam, none of which count against it — the model is used only for vibe tags, batched 20 titles per call, and for custom shelves.")
        }
    }

    private var usageChart: some View {
        let usage = budget.recentUsage()
        let peak = max(budget.dailyCallLimit, usage.map(\.calls).max() ?? 1)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(usage, id: \.day) { entry in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(entry.calls > 0 ? Color.appAccent : Color.appSurfaceElevated)
                            .frame(height: max(3, CGFloat(entry.calls) / CGFloat(peak) * 40))

                        Text(dayInitial(entry.day))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 56, alignment: .bottom)

            Text("Last 7 days")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func dayInitial(_ dayKey: String) -> String {
        guard let date = DateFormatter.dayKey.date(from: dayKey) else { return "" }
        let index = Calendar.current.component(.weekday, from: date) - 1
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return symbols.indices.contains(index) ? symbols[index] : ""
    }

    // MARK: - Credentials

    private var credentialsSection: some View {
        Section {
            ForEach(CredentialProvider.allCases) { provider in
                NavigationLink {
                    CredentialEditorView(provider: provider)
                } label: {
                    credentialRow(for: provider)
                }
            }
        } header: {
            Text("API Keys")
        } footer: {
            Text("Stored in the iOS keychain, never in plain preferences. All four have a free tier and none needs a card.")
        }
    }

    @ViewBuilder
    private func credentialRow(for provider: CredentialProvider) -> some View {
        let filled = provider.slots.filter { settings.hasKey(for: $0) }.count
        let total = provider.slots.count

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.title)

                // A partially-filled provider is useless, so say so rather
                // than showing a bare "Optional".
                Text(filled > 0 && filled < total
                     ? "Incomplete — \(filled) of \(total) fields"
                     : (provider.isOptional ? "Optional" : "Required"))
                    .font(.caption2)
                    .foregroundStyle(filled > 0 && filled < total ? AnyShapeStyle(Color.appWarning) : AnyShapeStyle(.tertiary))
            }

            Spacer()

            if filled == total {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.appPositive)
            } else if filled > 0 {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color.appWarning)
            } else {
                Image(systemName: provider.isOptional ? "minus.circle" : "exclamationmark.circle.fill")
                    .foregroundStyle(provider.isOptional ? Color.secondary : Color.appWarning)
            }
        }
    }

    // MARK: - Stats

    private var libraryStatsSection: some View {
        Section("Library") {
            statRow("Shelves", shelves.count)
            statRow("Waiting", items.count)
            statRow("Awaiting details", items.filter { $0.enrichment == .pending || $0.enrichment == .failed }.count)
            statRow("Words saved", words.count)
            statRow("Articles in feed", articles.filter(\.isInFeed).count)
            statRow("Saved articles", articles.filter(\.isFavorite).count)
        }
    }

    private func statRow(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(value)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        Section {
            Button("Clear Learn feed cache") { showingClearFeedAlert = true }
                .tint(.appAccent)

            Button("Reset all data", role: .destructive) { showingResetAlert = true }
        } header: {
            Text("Data")
        } footer: {
            Text("SwitchBlade \(appVersion) · Everything is stored on this device.")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func clearFeed() {
        // Same rule as "New set": saved articles keep their record but give up
        // their feed slot, rather than lingering in a feed the user just
        // emptied.
        for article in articles {
            if article.isFavorite {
                article.isInFeed = false
            } else {
                modelContext.delete(article)
            }
        }
        try? modelContext.save()
    }

    private func resetDatabase() {
        try? modelContext.delete(model: ShelfItem.self)
        try? modelContext.delete(model: MediaShelf.self)
        try? modelContext.delete(model: WordOfTheDayItem.self)
        try? modelContext.delete(model: KnowledgeArticleItem.self)
        try? modelContext.save()

        settings.hasSeeded = false
        settings.hasCompletedImport = false
        SeedData.installIfNeeded(context: modelContext)
    }
}

// MARK: - Credential editor

/// Edits every field a provider needs on one screen.
struct CredentialEditorView: View {
    let provider: CredentialProvider

    @Environment(\.dismiss) private var dismiss
    @State private var values: [CredentialSlot: String] = [:]
    @State private var isRevealed = false
    @State private var saveFailure: String?

    private let settings = AppSettings.shared

    private func trimmed(_ slot: CredentialSlot) -> String {
        (values[slot] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every field must be present — a provider with half its credentials
    /// can't authenticate, so saving one alone would just look broken later.
    private var isComplete: Bool {
        provider.slots.allSatisfy { !trimmed($0).isEmpty }
    }

    private var hasAnyStored: Bool {
        provider.slots.contains { settings.hasKey(for: $0) }
    }

    var body: some View {
        Form {
            Section {
                ForEach(provider.slots) { slot in
                    VStack(alignment: .leading, spacing: 6) {
                        if provider.slots.count > 1 {
                            Text(slot.fieldLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Group {
                            if isRevealed {
                                TextField(slot.fieldLabel, text: binding(for: slot), axis: .vertical)
                                    .lineLimit(1...4)
                            } else {
                                SecureField(slot.fieldLabel, text: binding(for: slot))
                            }
                        }
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .textContentType(.password)
                        .font(.system(.footnote, design: .monospaced))

                        if !trimmed(slot).isEmpty {
                            // Catches a truncated paste, which is invisible
                            // behind the dots.
                            Text("\(trimmed(slot).count) characters")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Toggle("Show values", isOn: $isRevealed)
            } header: {
                Text(provider.title)
            } footer: {
                Text(provider.purpose)
            }

            if let url = provider.signupURL {
                Section {
                    Link(destination: url) {
                        Label(
                            provider.slots.count > 1 ? "Create an app" : "Get a free key",
                            systemImage: "arrow.up.right.square"
                        )
                    }
                    .tint(.appAccent)
                } footer: {
                    if let note = provider.fallbackNote {
                        Text(note)
                    }
                }
            }

            Section {
                Button("Save") { save() }
                    .disabled(!isComplete)

                if hasAnyStored {
                    Button("Remove", role: .destructive) {
                        for slot in provider.slots { settings.setKey(nil, for: slot) }
                        values = [:]
                        dismiss()
                    }
                }
            } footer: {
                if !isComplete && provider.slots.count > 1 {
                    Text("Both fields are required — IGDB can't authenticate with only one.")
                }
            }
        }
        .navigationTitle(provider.title)
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .onAppear {
            for slot in provider.slots {
                values[slot] = settings.key(for: slot) ?? ""
            }
        }
        .alert(
            "Couldn't save",
            isPresented: Binding(
                get: { saveFailure != nil },
                set: { if !$0 { saveFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) { saveFailure = nil }
        } message: {
            Text(saveFailure ?? "")
        }
    }

    private func binding(for slot: CredentialSlot) -> Binding<String> {
        Binding(
            get: { values[slot] ?? "" },
            set: { values[slot] = $0 }
        )
    }

    private func save() {
        for slot in provider.slots {
            settings.setKey(trimmed(slot), for: slot)

            // Verify rather than assume: a keychain write can fail, and
            // reporting success regardless sends the user off to debug a
            // credential that was never stored.
            guard settings.key(for: slot) == trimmed(slot) else {
                saveFailure = KeychainStore.lastError.map(KeychainStore.describe)
                    ?? "The \(slot.fieldLabel.lowercased()) could not be stored."
                return
            }
        }

        dismiss()
    }
}
