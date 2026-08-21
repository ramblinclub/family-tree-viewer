import Foundation
import Combine
import ImageIO
import UIKit

final class FamilyRepository: ObservableObject {
    @Published private(set) var document: FamilyArchiveDocument

    private var peopleByID: [Person.ID: Person]
    private let presumedDeathBeforeBirthYear = 1921
    private var profilePhotoPathCache: [Person.ID: String] = [:]
    private var coloredPhotoCache: [String: Bool] = [:]

    private struct PhotoCandidate {
        let path: String
        let date: String?
        let order: Int
    }

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

    /// Returns the recorded birth year or a family-context estimate used for
    /// ordering and status display. Estimates are never written back to data.
    func chronologicalBirthYear(for personID: Person.ID) -> Int? {
        guard let person = person(id: personID) else { return nil }
        return chronologicalBirthYear(for: person, visited: [])
    }

    /// A person with no recorded death date is presumed deceased when their
    /// recorded or family-estimated birth year predates 1921.
    func isLiving(_ person: Person) -> Bool {
        guard !hasRecordedDeathDate(for: person) else { return false }
        guard let birthYear = chronologicalBirthYear(for: person.id),
              birthYear < presumedDeathBeforeBirthYear else {
            return person.isLiving
        }
        return false
    }

    func hasUnknownDeathDate(_ person: Person) -> Bool {
        !isLiving(person) && !hasRecordedDeathDate(for: person)
    }

    private func chronologicalBirthYear(for person: Person, visited: Set<Person.ID>) -> Int? {
        guard !visited.contains(person.id) else { return nil }
        if let recordedYear = person.birthYear {
            return recordedYear
        }

        let nextVisited = visited.union([person.id])
        let siblingBirthYears = person.immediateFamily.siblings.compactMap { siblingID in
            self.person(id: siblingID)?.birthYear
        }
        if !siblingBirthYears.isEmpty {
            return siblingBirthYears.reduce(0, +) / siblingBirthYears.count
        }

        let parentBirthYears = person.immediateFamily.parents.compactMap { parentID in
            self.person(id: parentID)?.birthYear
        }
        if let youngestParentYear = parentBirthYears.max() {
            return youngestParentYear + 16
        }

        let childBirthYears: [Int] = person.immediateFamily.children.compactMap { childID in
            guard let child = self.person(id: childID) else { return nil }
            return chronologicalBirthYear(for: child, visited: nextVisited)
        }
        return childBirthYears.min().map { $0 - 16 }
    }

    private func hasRecordedDeathDate(for person: Person) -> Bool {
        if person.deathFact != nil { return true }

        let parts = person.lifespan.split { character in
            character == "–" || character == "—" || character == "-"
        }
        guard parts.count > 1, let deathPart = parts.last else { return false }
        return deathPart.contains { $0.isNumber }
    }

    /// Returns media owned by a person plus shared media records that reference them.
    func media(for personID: Person.ID) -> [MediaReference] {
        var result: [MediaReference] = []
        var seen = Set<MediaReference.ID>()
        for owner in document.people {
            for item in owner.media {
                let belongsToPerson = item.personIDs?.contains(personID) == true ||
                    (item.personIDs == nil && owner.id == personID)
                guard belongsToPerson, seen.insert(item.id).inserted else { continue }
                result.append(item)
            }
        }
        return result
    }

    func photoPath(for personID: Person.ID) -> String? {
        guard let person = person(id: personID) else { return nil }
        if let cachedPath = profilePhotoPathCache[personID] {
            return cachedPath
        }
        // Prefer the person's own portrait/media. Shared tagged photos are a
        // fallback, so a family group photograph cannot replace the profile
        // image in the profile header or Home account avatar.
        var candidates: [PhotoCandidate] = []
        if let profileImagePath = person.profileImagePath {
            candidates.append(PhotoCandidate(path: profileImagePath, date: nil, order: -1))
        }

        let ownCandidates = person.media
            .filter { $0.kind == .photo }
        candidates.append(contentsOf: ownCandidates.enumerated().compactMap { index, item in
            guard let path = item.path else { return nil }
            return PhotoCandidate(path: path, date: item.date, order: index)
        })

        let sharedCandidates = document.people
            .filter { $0.id != personID }
            .flatMap(\.media)
            .filter { $0.kind == .photo && $0.personIDs?.contains(personID) == true }
        let sharedStart = ownCandidates.count
        candidates.append(contentsOf: sharedCandidates.enumerated().compactMap { index, item in
            guard let path = item.path else { return nil }
            return PhotoCandidate(path: path, date: item.date, order: sharedStart + index)
        })

        let validCandidates = candidates.filter { resolvedFileURL(for: $0.path) != nil }
        guard !validCandidates.isEmpty else { return nil }

        let selectedPath: String?
        if isLiving(person) {
            let colored = validCandidates.filter { isColoredPhoto(at: $0.path) }
            selectedPath = (colored.isEmpty ? validCandidates : colored)
                .max { photoRecencyScore($0) < photoRecencyScore($1) }?.path
        } else {
            selectedPath = validCandidates.first?.path
        }

        if let selectedPath {
            profilePhotoPathCache[personID] = selectedPath
        }
        return selectedPath
    }

    private func photoRecencyScore(_ candidate: PhotoCandidate) -> Int64 {
        // Undated photos are the modern/default records in this archive. They
        // outrank historical dated scans; input order breaks ties consistently.
        if let year = candidate.date?
            .split(whereSeparator: { !$0.isNumber })
            .compactMap({ Int($0) })
            .first(where: { (1000...2100).contains($0) }) {
            return Int64(year) * 1_000_000 + Int64(candidate.order)
        }
        return 3_000_000_000 + Int64(candidate.order)
    }

    private func isColoredPhoto(at path: String) -> Bool {
        if let cachedResult = coloredPhotoCache[path] {
            return cachedResult
        }

        guard let url = resolvedFileURL(for: path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 64,
                      kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary
              ),
              cgImage.width > 0,
              cgImage.height > 0 else { return false }

        let sampleWidth = min(cgImage.width, 64)
        let sampleHeight = max(1, Int(Double(cgImage.height) * Double(sampleWidth) / Double(cgImage.width)))
        let bytesPerRow = sampleWidth * 4
        var pixels = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)

        let result = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: sampleWidth,
                height: sampleHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }

            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

            var colorfulPixels = 0
            let totalPixels = sampleWidth * sampleHeight
            let sampledPixels = buffer.bindMemory(to: UInt8.self)
            for index in stride(from: 0, to: sampledPixels.count, by: 4) {
                let red = Int(sampledPixels[index])
                let green = Int(sampledPixels[index + 1])
                let blue = Int(sampledPixels[index + 2])
                if max(red, green, blue) - min(red, green, blue) > 12 {
                    colorfulPixels += 1
                }
            }
            return colorfulPixels >= max(1, totalPixels / 100)
        }
        coloredPhotoCache[path] = result
        return result
    }

    private func resolvedFileURL(for path: String) -> URL? {
        if path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = documentsURL.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        if let bundledURL = Bundle.main.url(forResource: path, withExtension: nil) {
            return bundledURL
        }
        return nil
    }

    func updatePerson(_ person: Person) {
        var people = document.people
        guard let index = people.firstIndex(where: { $0.id == person.id }) else { return }
        people[index] = person
        replaceDocument(people: people)
    }

    func updateMedia(_ item: MediaReference, for ownerID: Person.ID) {
        var people = document.people
        guard let ownerIndex = people.firstIndex(where: { $0.id == ownerID }),
              let mediaIndex = people[ownerIndex].media.firstIndex(where: { $0.id == item.id }) else { return }

        let previousIDs = Set(people[ownerIndex].media[mediaIndex].personIDs ?? [ownerID])
        let updatedIDs = Set(item.personIDs ?? [ownerID]).union([ownerID])
        people[ownerIndex].media[mediaIndex] = item

        for index in people.indices where people[index].id != ownerID {
            if updatedIDs.contains(people[index].id) {
                if let existingIndex = people[index].media.firstIndex(where: { $0.id == item.id }) {
                    people[index].media[existingIndex] = item
                } else {
                    people[index].media.append(item)
                }
            } else if previousIDs.contains(people[index].id) {
                people[index].media.removeAll { $0.id == item.id }
            }
        }
        replaceDocument(people: people)
    }

    func removeMedia(_ item: MediaReference, from ownerID: Person.ID) {
        var people = document.people
        guard let ownerIndex = people.firstIndex(where: { $0.id == ownerID }) else { return }
        let relatedIDs = Set(item.personIDs ?? [ownerID])
        people[ownerIndex].media.removeAll { $0.id == item.id }
        for index in people.indices where relatedIDs.contains(people[index].id) {
            people[index].media.removeAll { $0.id == item.id }
        }
        replaceDocument(people: people)
    }

    private func replaceDocument(people: [Person]) {
        document = FamilyArchiveDocument(
            schemaVersion: document.schemaVersion,
            title: document.title,
            accountHolderID: document.accountHolderID,
            people: people
        )
        peopleByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        profilePhotoPathCache.removeAll()
        coloredPhotoCache.removeAll()
        savePrivateCopy()
    }

    private func savePrivateCopy(fileManager: FileManager = .default) {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONEncoder.archive.encode(document) else { return }
        try? data.write(to: documentsURL.appendingPathComponent("family-archive.json"), options: .atomic)
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

    static func localOrBundled(
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> FamilyRepository {
        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let localURL = documentsURL.appendingPathComponent("family-archive.json")
            if let data = try? Data(contentsOf: localURL),
               let document = try? JSONDecoder().decode(FamilyArchiveDocument.self, from: data) {
                return FamilyRepository(document: document)
            }
        }

        return bundled(bundle: bundle)
    }
}

private extension JSONEncoder {
    static var archive: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension FamilyArchiveDocument {
    static let empty = FamilyArchiveDocument(
        schemaVersion: 1,
        title: "Family Archive",
        accountHolderID: nil,
        people: []
    )
}
