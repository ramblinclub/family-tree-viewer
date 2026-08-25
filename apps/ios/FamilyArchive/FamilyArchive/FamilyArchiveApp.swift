import SwiftUI
import UIKit

@main
struct FamilyArchiveApp: App {
    @StateObject private var loader = FamilyRepositoryLoader()

    private var previewPersonID: Person.ID? {
        guard let flagIndex = ProcessInfo.processInfo.arguments.firstIndex(of: "-preview-person"),
              ProcessInfo.processInfo.arguments.indices.contains(flagIndex + 1) else {
            return nil
        }

        return ProcessInfo.processInfo.arguments[flagIndex + 1]
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let repository = loader.repository {
                    MainTabView(repository: repository, initialPersonID: previewPersonID)
                } else {
                    ArchiveLaunchView()
                }
            }
            .task {
                loader.loadIfNeeded()
            }
        }
    }
}

@MainActor
private final class FamilyRepositoryLoader: ObservableObject {
    @Published private(set) var repository: FamilyRepository?
    private var hasStarted = false

    func loadIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true

        DispatchQueue.global(qos: .userInitiated).async {
            let repository = FamilyRepository.localOrBundled()
            DispatchQueue.main.async {
                self.repository = repository
            }
        }
    }
}

private struct ArchiveLaunchView: View {
    var body: some View {
        VStack(spacing: 18) {
            if let icon = UIImage(named: "AppIcon-1024") {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 92, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }

            Text("FamSpam")
                .font(.title2.weight(.semibold))
                .foregroundStyle(ArchiveTheme.ink)

            ProgressView()
                .tint(ArchiveTheme.action)
                .accessibilityLabel(ArchiveCopy.text(english: "Loading family archive", russian: "Загрузка семейного архива"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}
