import SwiftUI

@main
struct FamilyArchiveApp: App {
    private let repository = FamilyRepository.bundled()

    private var previewPersonID: Person.ID? {
        guard let flagIndex = ProcessInfo.processInfo.arguments.firstIndex(of: "-preview-person"),
              ProcessInfo.processInfo.arguments.indices.contains(flagIndex + 1) else {
            return nil
        }

        return ProcessInfo.processInfo.arguments[flagIndex + 1]
    }

    var body: some Scene {
        WindowGroup {
            MainTabView(repository: repository, initialPersonID: previewPersonID)
        }
    }
}
