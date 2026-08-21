import Foundation

enum ArchiveDateFormatter {
    private static let inputFormats = [
        "d MMMM yyyy",
        "d MMM yyyy",
        "MMMM d, yyyy",
        "MMM d, yyyy",
        "MMMM yyyy",
        "MMM yyyy"
    ]

    private static let outputFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    static func display(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let inputFormatter = DateFormatter()
        inputFormatter.locale = Locale(identifier: "en_US_POSIX")

        for format in inputFormats {
            inputFormatter.dateFormat = format
            if let date = inputFormatter.date(from: trimmed) {
                if format == "MMMM yyyy" || format == "MMM yyyy" {
                    inputFormatter.dateFormat = "MMM yyyy"
                    return inputFormatter.string(from: date)
                }
                return outputFormatter.string(from: date)
            }
        }

        return trimmed
    }
}

struct FamilyArchiveDocument: Codable {
    let schemaVersion: Int
    let title: String
    let accountHolderID: Person.ID?
    let people: [Person]
}

struct Person: Codable, Identifiable, Hashable {
    let id: String
    let givenName: String
    let familyName: String
    let alternateNames: [String]
    let lifespan: String
    let summary: String
    let biography: String
    let privacy: PrivacyLevel
    let relationshipToMe: String?
    let profileImagePath: String?
    let facts: [PersonFact]
    let events: [LifeEvent]?
    let storyChapters: [StoryChapter]?
    let immediateFamily: ImmediateFamily
    let media: [MediaReference]
    let sources: [SourceReference]

    var displayName: String {
        [givenName, familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var initials: String {
        [givenName.first, familyName.first]
            .compactMap { $0 }
            .map(String.init)
            .joined()
            .uppercased()
    }

    var isLiving: Bool {
        lifespan.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("–") ||
            lifespan.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("-")
    }

    var lifeStatusLabel: String {
        isLiving ? "Living" : "Deceased"
    }

    var structuredEvents: [LifeEvent] {
        events ?? []
    }

    var structuredStories: [StoryChapter] {
        storyChapters ?? []
    }

    var orderedEvents: [LifeEvent] {
        structuredEvents.sorted { left, right in
            (left.sortKey ?? 0) > (right.sortKey ?? 0)
        }
    }

    var birthFact: PersonFact? {
        facts.first { $0.label.localizedCaseInsensitiveContains("born") || $0.label.localizedCaseInsensitiveContains("birth") }
    }

    var deathFact: PersonFact? {
        facts.first { $0.label.localizedCaseInsensitiveContains("died") || $0.label.localizedCaseInsensitiveContains("death") }
    }
}

enum PrivacyLevel: String, Codable, Hashable {
    case publicDeceased = "public-deceased"
    case privateLiving = "private-living"
    case restricted
    case sample
}

struct PersonFact: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    let value: String
    let place: String?
    let isApproximate: Bool?
    let sourceIDs: [String]?
}

struct LifeEvent: Codable, Identifiable, Hashable {
    let id: String
    let date: String
    let sortKey: Int?
    let title: String
    let summary: String
    let place: String?
    let category: String
    let isApproximate: Bool?
    let sourceIDs: [String]?
}

struct StoryChapter: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let dateRange: String?
    let summary: String?
    let body: String
}

struct ImmediateFamily: Codable, Hashable {
    let parents: [String]
    let partners: [String]
    let siblings: [String]
    let children: [String]
}

struct MediaReference: Codable, Identifiable, Hashable {
    let id: String
    let kind: MediaKind
    let title: String
    let date: String?
    let path: String?
    let caption: String?
    let tags: [String]?
    let collection: String?
    let isApproximate: Bool?
    let personIDs: [Person.ID]?
}

enum MediaKind: String, Codable, Hashable {
    case photo
    case document
    case audio
    case video

    var systemImage: String {
        switch self {
        case .photo: "photo"
        case .document: "doc.text"
        case .audio: "waveform"
        case .video: "film"
        }
    }
}

struct SourceReference: Codable, Identifiable, Hashable {
    let id: String
    let kind: String
    let locator: String
    let title: String?
    let notes: String?
}
