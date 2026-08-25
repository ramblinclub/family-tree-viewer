import Foundation
import Combine
import ImageIO
import UIKit

final class FamilyRepository: ObservableObject {
    @Published private(set) var document: FamilyArchiveDocument
    @Published var appLanguage: ArchiveLanguage {
        didSet {
            UserDefaults.standard.set(appLanguage.rawValue, forKey: NameLocalizationStore.appLanguageKey)
        }
    }

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
        self.appLanguage = ArchiveLanguage(
            rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? ArchiveLanguage.english.rawValue
        ) ?? .english
        peopleByID = Dictionary(uniqueKeysWithValues: document.people.map { ($0.id, $0) })
        NameLocalizationStore.shared.reload()
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

    fileprivate func transferFileURL(for path: String) -> URL? {
        resolvedFileURL(for: path)
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

    /// Exports the current private archive as a self-contained package. The
    /// package contains the app JSON, generated GEDCOM, a Topola-ready GDZ,
    /// private localization sidecars, and referenced media/documents.
    func exportPrivateArchive(fileManager: FileManager = .default) throws -> Data {
        try ArchivePackageBuilder(repository: self, fileManager: fileManager).build()
    }

    static func previewPrivateArchive(_ data: Data) throws -> ArchivePackageSummary {
        try ArchivePackageBuilder.preview(data)
    }

    /// Replaces the app's private JSON and sidecars with an imported package.
    /// Existing unrelated files are deliberately left in Documents so an
    /// import remains recoverable; imported paths are written atomically.
    func importPrivateArchive(_ data: Data, fileManager: FileManager = .default) throws -> ArchivePackageSummary {
        let entries = try PrivateZipArchive.read(data)
        guard let archiveData = entries["family-archive.json"] else {
            throw ArchivePackageError.missingArchiveJSON
        }
        let importedDocument = try JSONDecoder().decode(FamilyArchiveDocument.self, from: archiveData)
        guard !importedDocument.people.isEmpty else { throw ArchivePackageError.emptyArchive }

        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw ArchivePackageError.documentsUnavailable
        }

        try writePrivateFile(archiveData, to: documentsURL.appendingPathComponent("family-archive.json"), fileManager: fileManager)
        for filename in ["name-localizations.private.json", "narrative-translations.private.json"] {
            if let sidecar = entries[filename] {
                try writePrivateFile(sidecar, to: documentsURL.appendingPathComponent("PrivateData").appendingPathComponent(filename), fileManager: fileManager)
            }
        }

        for (path, fileData) in entries where path.hasPrefix("media/") || path.hasPrefix("documents/") {
            guard let destination = safeRelativeURL(path, under: documentsURL) else { continue }
            try writePrivateFile(fileData, to: destination, fileManager: fileManager)
        }

        document = importedDocument
        peopleByID = Dictionary(uniqueKeysWithValues: importedDocument.people.map { ($0.id, $0) })
        profilePhotoPathCache.removeAll()
        coloredPhotoCache.removeAll()
        NarrativeLocalizationStore.shared.reload(fileManager: fileManager)
        NameLocalizationStore.shared.reload(fileManager: fileManager)
        return ArchivePackageSummary(document: importedDocument, fileCount: entries.count)
    }

    private func writePrivateFile(_ data: Data, to url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func safeRelativeURL(_ path: String, under root: URL) -> URL? {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        let url = root.appendingPathComponent(path)
        return url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") ? url : nil
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

struct ArchivePackageSummary: Identifiable {
    let id = UUID()
    let personCount: Int
    let relationshipCount: Int
    let mediaCount: Int
    let documentCount: Int
    let fileCount: Int

    init(document: FamilyArchiveDocument, fileCount: Int) {
        personCount = document.people.count
        relationshipCount = document.people.reduce(0) { partial, person in
            partial + person.immediateFamily.parents.count +
                person.immediateFamily.partners.count +
                person.immediateFamily.siblings.count +
                person.immediateFamily.children.count
        }
        mediaCount = document.people.reduce(0) { partial, person in
            partial + person.media.filter { $0.kind != .document }.count
        }
        documentCount = document.people.reduce(0) { partial, person in
            partial + person.media.filter { $0.kind == .document }.count
        }
        self.fileCount = fileCount
    }
}

enum ArchivePackageError: LocalizedError {
    case missingArchiveJSON
    case emptyArchive
    case documentsUnavailable
    case unsupportedZip
    case invalidZip

    var errorDescription: String? {
        switch self {
        case .missingArchiveJSON: "The package does not contain family-archive.json."
        case .emptyArchive: "The package contains no people."
        case .documentsUnavailable: "The app could not access its private Documents folder."
        case .unsupportedZip: "This archive uses a compression format the app cannot read yet."
        case .invalidZip: "The private archive is damaged or invalid."
        }
    }
}

private struct ArchivePackageManifest: Codable {
    let format: String
    let version: Int
    let personCount: Int
    let relationshipCount: Int
    let mediaCount: Int
    let documentCount: Int
    let missingFiles: [String]
}

private struct ArchivePackageBuilder {
    let repository: FamilyRepository
    let fileManager: FileManager

    func build() throws -> Data {
        let archiveJSON = try JSONEncoder.archive.encode(repository.document)
        let gedcom = GEDCOMExporter(document: repository.document).makeGEDCOM()
        var entries: [PrivateZipArchive.Entry] = [
            .init(name: "family-archive.json", data: archiveJSON),
            .init(name: "family.ged", data: gedcom)
        ]
        var missingFiles: [String] = []

        for name in ["name-localizations.private.json", "narrative-translations.private.json"] {
            if let data = sidecarData(named: name) {
                entries.append(.init(name: name, data: data))
            }
        }

        var topolaEntries: [PrivateZipArchive.Entry] = [.init(name: "family.ged", data: gedcom)]
        var copiedPaths = Set<String>()
        for person in repository.document.people {
            for item in person.media {
                guard let path = item.path, copiedPaths.insert(path).inserted else { continue }
                guard let url = repository.transferFileURL(for: path),
                      let data = try? Data(contentsOf: url) else {
                    missingFiles.append(path)
                    continue
                }
                entries.append(.init(name: path, data: data))
                if item.kind == .photo {
                    topolaEntries.append(.init(name: path, data: data))
                }
            }
        }

        let summary = ArchivePackageSummary(document: repository.document, fileCount: entries.count + 2)
        let manifest = ArchivePackageManifest(
            format: "family-archive-private",
            version: 1,
            personCount: summary.personCount,
            relationshipCount: summary.relationshipCount,
            mediaCount: summary.mediaCount,
            documentCount: summary.documentCount,
            missingFiles: missingFiles
        )
        entries.append(.init(name: "manifest.json", data: try JSONEncoder.archive.encode(manifest)))
        entries.append(.init(name: "topola.gdz", data: try PrivateZipArchive.write(topolaEntries)))
        return try PrivateZipArchive.write(entries)
    }

    static func preview(_ data: Data) throws -> ArchivePackageSummary {
        let entries = try PrivateZipArchive.read(data)
        guard let archiveData = entries["family-archive.json"] else { throw ArchivePackageError.missingArchiveJSON }
        let document = try JSONDecoder().decode(FamilyArchiveDocument.self, from: archiveData)
        guard !document.people.isEmpty else { throw ArchivePackageError.emptyArchive }
        return ArchivePackageSummary(document: document, fileCount: entries.count)
    }

    private func sidecarData(named name: String) -> Data? {
        let candidates: [URL] = [
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("PrivateData").appendingPathComponent(name),
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(name),
            Bundle.main.url(forResource: name.replacingOccurrences(of: ".json", with: ""), withExtension: "json")
        ].compactMap { $0 }
        return candidates.compactMap { try? Data(contentsOf: $0) }.first
    }
}

private struct GEDCOMExporter {
    let document: FamilyArchiveDocument

    func makeGEDCOM() -> Data {
        let peopleByID = Dictionary(uniqueKeysWithValues: document.people.map { ($0.id, $0) })
        var parentsByChild: [String: Set<String>] = [:]
        var partnerPairs = Set<[String]>()

        for person in document.people {
            let validParents = person.immediateFamily.parents.filter { peopleByID[$0] != nil }
            if !validParents.isEmpty { parentsByChild[person.id] = Set(validParents) }
            for partnerID in person.immediateFamily.partners where peopleByID[partnerID] != nil {
                partnerPairs.insert([person.id, partnerID].sorted())
            }
        }

        var familyParents: [String: [String]] = [:]
        var familyChildren: [String: Set<String>] = [:]
        func addFamily(parents: [String], child: String? = nil) {
            let normalized = parents.sorted()
            guard !normalized.isEmpty else { return }
            let key = normalized.joined(separator: "|")
            familyParents[key] = normalized
            if let child { familyChildren[key, default: []].insert(child) }
        }

        for (childID, parents) in parentsByChild {
            let parentList = Array(parents).sorted()
            if parentList.count <= 2 {
                addFamily(parents: parentList, child: childID)
            } else {
                for firstIndex in 0..<(parentList.count - 1) {
                    for secondIndex in (firstIndex + 1)..<parentList.count {
                        addFamily(parents: [parentList[firstIndex], parentList[secondIndex]], child: childID)
                    }
                }
            }
        }

        for pair in partnerPairs { addFamily(parents: pair) }

        let familyKeys = familyParents.keys.sorted()
        let familyIDs = Dictionary(uniqueKeysWithValues: familyKeys.enumerated().map { (key: $0.element, value: "F\($0.offset + 1)") })
        var familiesForPerson: [String: [String]] = [:]
        var childFamilyForPerson: [String: [String]] = [:]
        for key in familyKeys {
            guard let familyID = familyIDs[key], let parents = familyParents[key] else { continue }
            for parent in parents { familiesForPerson[parent, default: []].append(familyID) }
            for child in familyChildren[key] ?? [] { childFamilyForPerson[child, default: []].append(familyID) }
        }

        var lines = ["0 HEAD", "1 SOUR FamilyArchive", "1 CHAR UTF-8", "1 GEDC", "2 VERS 5.5.1", "0 @U1@ SUBM", "1 NAME Family Archive"]
        for person in document.people.sorted(by: { $0.id < $1.id }) {
            lines.append("0 @\(person.id)@ INDI")
            let given = gedcomSafe(person.givenName)
            let family = gedcomSafe(person.familyName)
            let name = family.isEmpty ? given : "\(given) /\(family)/"
            lines.append("1 NAME \(name.isEmpty ? "Unknown" : name)")
            if let birth = person.birthFact {
                lines.append("1 BIRT")
                lines.append("2 DATE \(gedcomSafe(birth.value))")
                if let place = birth.place, !place.isEmpty { lines.append("2 PLAC \(gedcomSafe(place))") }
            }
            if let death = person.deathFact {
                lines.append("1 DEAT")
                lines.append("2 DATE \(gedcomSafe(death.value))")
                if let place = death.place, !place.isEmpty { lines.append("2 PLAC \(gedcomSafe(place))") }
            }
            if !person.summary.isEmpty { lines.append("1 NOTE \(gedcomSafe(person.summary))") }
            for familyID in familiesForPerson[person.id] ?? [] { lines.append("1 FAMS @\(familyID)@") }
            for familyID in childFamilyForPerson[person.id] ?? [] { lines.append("1 FAMC @\(familyID)@") }
        }

        for key in familyKeys {
            guard let familyID = familyIDs[key], let parents = familyParents[key] else { continue }
            lines.append("0 @\(familyID)@ FAM")
            if let first = parents.first { lines.append("1 HUSB @\(first)@") }
            if parents.count > 1 { lines.append("1 WIFE @\(parents[1])@") }
            if parents.count > 2 {
                for parent in parents.dropFirst(2) { lines.append("1 NOTE Additional parent @\(parent)@") }
            }
            for child in (familyChildren[key] ?? []).sorted() { lines.append("1 CHIL @\(child)@") }
        }

        var mediaObjects: [(id: String, path: String)] = []
        var seenPaths = Set<String>()
        for person in document.people {
            for item in person.media where item.kind == .photo {
                guard let path = item.path, seenPaths.insert(path).inserted else { continue }
                mediaObjects.append(("O\(mediaObjects.count + 1)", path))
            }
        }
        for object in mediaObjects {
            lines.append("0 @\(object.id)@ OBJE")
            lines.append("1 FILE \(gedcomSafe(object.path))")
        }

        // Rebuild individual records with media tags in place. Topola can use
        // the FILE objects even when a profile has no photo reference.
        var finalLines: [String] = []
        for line in lines {
            finalLines.append(line)
            if line.hasSuffix(" INDI"), let id = line.split(separator: "@").dropFirst().first.map(String.init), peopleByID[id] != nil {
                let paths = document.people.flatMap { owner in
                    owner.media.filter { $0.kind == .photo && ($0.personIDs ?? [owner.id]).contains(id) }.compactMap(\.path)
                }
                for path in Set(paths).sorted() {
                    if let object = mediaObjects.first(where: { $0.path == path }) { finalLines.append("1 OBJE @\(object.id)@") }
                }
            }
        }

        finalLines.append("0 TRLR")
        return Data(finalLines.joined(separator: "\n").appending("\n").utf8)
    }

    private func gedcomSafe(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct PrivateZipArchive {
    struct Entry {
        let name: String
        let data: Data
    }

    static func write(_ entries: [Entry]) throws -> Data {
        var output = Data()
        var central = Data()
        var offset: UInt32 = 0
        let uniqueEntries = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) }).values.sorted { $0.name < $1.name }
        for entry in uniqueEntries {
            let nameData = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            appendUInt32(0x04034b50, to: &output)
            appendUInt16(20, to: &output)
            appendUInt16(0x0800, to: &output)
            appendUInt16(0, to: &output)
            appendUInt16(0, to: &output)
            appendUInt16(0, to: &output)
            appendUInt32(crc, to: &output)
            appendUInt32(size, to: &output)
            appendUInt32(size, to: &output)
            appendUInt16(UInt16(nameData.count), to: &output)
            appendUInt16(0, to: &output)
            output.append(nameData)
            output.append(entry.data)

            appendUInt32(0x02014b50, to: &central)
            appendUInt16(20, to: &central)
            appendUInt16(20, to: &central)
            appendUInt16(0x0800, to: &central)
            appendUInt16(0, to: &central)
            appendUInt16(0, to: &central)
            appendUInt16(0, to: &central)
            appendUInt32(crc, to: &central)
            appendUInt32(size, to: &central)
            appendUInt32(size, to: &central)
            appendUInt16(UInt16(nameData.count), to: &central)
            appendUInt16(0, to: &central)
            appendUInt16(0, to: &central)
            appendUInt16(0, to: &central)
            appendUInt16(0, to: &central)
            appendUInt32(0, to: &central)
            appendUInt32(offset, to: &central)
            central.append(nameData)
            offset += 30 + UInt32(nameData.count) + size
        }
        let centralOffset = UInt32(output.count)
        output.append(central)
        appendUInt32(0x06054b50, to: &output)
        appendUInt16(0, to: &output)
        appendUInt16(0, to: &output)
        let count = UInt16(uniqueEntries.count)
        appendUInt16(count, to: &output)
        appendUInt16(count, to: &output)
        appendUInt32(UInt32(central.count), to: &output)
        appendUInt32(centralOffset, to: &output)
        appendUInt16(0, to: &output)
        return output
    }

    static func read(_ data: Data) throws -> [String: Data] {
        var result: [String: Data] = [:]
        var offset = 0
        while offset + 4 <= data.count {
            let signature = readUInt32(data, at: offset)
            guard signature == 0x04034b50 else { break }
            guard offset + 30 <= data.count else { throw ArchivePackageError.invalidZip }
            let flags = readUInt16(data, at: offset + 6)
            let method = readUInt16(data, at: offset + 8)
            let compressedSize = Int(readUInt32(data, at: offset + 18))
            let nameLength = Int(readUInt16(data, at: offset + 26))
            let extraLength = Int(readUInt16(data, at: offset + 28))
            guard flags & 0x0008 == 0, method == 0 else { throw ArchivePackageError.unsupportedZip }
            let nameStart = offset + 30
            let dataStart = nameStart + nameLength + extraLength
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= data.count else { throw ArchivePackageError.invalidZip }
            let name = String(data: data[nameStart..<(nameStart + nameLength)], encoding: .utf8) ?? ""
            result[name] = data[dataStart..<dataEnd]
            offset = dataEnd
        }
        guard !result.isEmpty else { throw ArchivePackageError.invalidZip }
        return result
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) { data.append(contentsOf: [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]) }
    private static func appendUInt32(_ value: UInt32, to data: inout Data) { data.append(contentsOf: [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)]) }
    private static func readUInt16(_ data: Data, at index: Int) -> UInt16 { UInt16(data[index]) | (UInt16(data[index + 1]) << 8) }
    private static func readUInt32(_ data: Data, at index: Int) -> UInt32 { UInt32(data[index]) | (UInt32(data[index + 1]) << 8) | (UInt32(data[index + 2]) << 16) | (UInt32(data[index + 3]) << 24) }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
        }
        return crc ^ 0xffffffff
    }
}
