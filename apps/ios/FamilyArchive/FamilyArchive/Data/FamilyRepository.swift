import Foundation

struct FamilyRepository {
    let document: FamilyArchiveDocument

    private let peopleByID: [Person.ID: Person]

    init(document: FamilyArchiveDocument) {
        self.document = document
        peopleByID = Dictionary(uniqueKeysWithValues: document.people.map { ($0.id, $0) })
    }

    var people: [Person] {
        document.people.sorted {
            ($0.familyName.localizedStandardCompare($1.familyName) == .orderedAscending) ||
                ($0.familyName == $1.familyName &&
                    $0.givenName.localizedStandardCompare($1.givenName) == .orderedAscending)
        }
    }

    func person(id: Person.ID) -> Person? {
        peopleByID[id]
    }

    func people(ids: [Person.ID]) -> [Person] {
        ids.compactMap { peopleByID[$0] }
    }

    static func bundled(bundle: Bundle = .main) -> FamilyRepository {
        guard let url = bundle.url(forResource: "sample-family", withExtension: "json") else {
            return FamilyRepository(document: .empty)
        }

        do {
            let data = try Data(contentsOf: url)
            let document = try JSONDecoder().decode(FamilyArchiveDocument.self, from: data)
            return FamilyRepository(document: document)
        } catch {
            assertionFailure("Unable to load bundled family data: \(error)")
            return FamilyRepository(document: .empty)
        }
    }
}

private extension FamilyArchiveDocument {
    static let empty = FamilyArchiveDocument(
        schemaVersion: 1,
        title: "Family Archive",
        people: []
    )
}
