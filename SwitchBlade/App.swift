import SwiftUI
import SwiftData

@main
struct SwitchBladeApp: App {
    private let container: ModelContainer

    init() {
        let schema = Schema([
            MediaShelf.self,
            ShelfItem.self,
            WordOfTheDayItem.self,
            KnowledgeArticleItem.self
        ])

        do {
            container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)]
            )
        } catch {
            // A store that fails to open is almost always an incompatible
            // schema left over from a previous build. Rebuilding it loses local
            // data but leaves the app usable, which beats crashing on launch.
            let recovered = try? ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
            guard let recovered else {
                fatalError("Could not open or rebuild the data store: \(error)")
            }
            container = recovered
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .modelContainer(container)
        }
    }
}

/// Owns the appearance preference so a theme change re-renders the whole tree.
private struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    private let settings = AppSettings.shared

    var body: some View {
        MainTabView()
            .preferredColorScheme(settings.appearance.colorScheme)
            .tint(.appAccent)
            .task {
                SeedData.installIfNeeded(context: modelContext)
                FeedService.shared.repairStoredArticles(context: modelContext)
            }
    }
}

// MARK: - First launch

enum SeedData {
    /// Creates the three built-in shelves on first launch.
    ///
    /// Guarded by a preference rather than an emptiness check, so a user who
    /// deletes them doesn't get them back on the next launch.
    @MainActor
    static func installIfNeeded(context: ModelContext) {
        guard !AppSettings.shared.hasSeeded else { return }

        let existing = (try? context.fetch(FetchDescriptor<MediaShelf>())) ?? []
        guard existing.isEmpty else {
            AppSettings.shared.hasSeeded = true
            return
        }

        // Films and series are separate shelves: they have separate TMDB
        // catalogues, and a title can exist as both.
        for (index, kind) in [ShelfKind.movie, .tv, .game].enumerated() {
            context.insert(MediaShelf(
                name: kind.label,
                iconName: kind.defaultIcon,
                kind: kind,
                sortIndex: index,
                isBuiltIn: true
            ))
        }

        try? context.save()
        AppSettings.shared.hasSeeded = true
    }
}
