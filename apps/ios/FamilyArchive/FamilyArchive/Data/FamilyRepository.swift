import Foundation
import Combine
import ImageIO
import UIKit

/// The app's canonical private document store. Metadata is split into one
/// file per person so an edit does not rewrite the complete family archive.
/// Media and documents remain ordinary persistent files and are referenced by
/// their relative paths from the app's Documents directory.
private struct PrivateDocumentStore {
    struct Manifest: Codable {
        let format: String
        let version: Int
        let schemaVersion: Int
        let title: String
        let accountHolderID: Person.ID?
        let personIDs: [Person.ID]
        let updatedAt: String
    }

    let fileManager: FileManager
    let rootURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.rootURL = documentsURL.appendingPathComponent("FamilyArchiveStore", isDirectory: true)
    }

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootURL = rootURL
    }

    var manifestURL: URL { rootURL.appendingPathComponent("manifest.json") }
    var peopleURL: URL { rootURL.appendingPathComponent("people", isDirectory: true) }
    var privateDataURL: URL { rootURL.appendingPathComponent("PrivateData", isDirectory: true) }
    var gedcomURL: URL { rootURL.appendingPathComponent("family.ged") }

    func loadDocument() throws -> FamilyArchiveDocument? {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder.archive.decode(Manifest.self, from: manifestData)
        var people: [Person] = []
        people.reserveCapacity(manifest.personIDs.count)

        for personID in manifest.personIDs {
            guard let filename = safeFilename(for: personID) else { throw StoreError.invalidPersonID }
            let url = peopleURL.appendingPathComponent(filename)
            let data = try Data(contentsOf: url)
            people.append(try JSONDecoder.archive.decode(Person.self, from: data))
        }

        guard !people.isEmpty else { return nil }
        return FamilyArchiveDocument(
            schemaVersion: manifest.schemaVersion,
            title: manifest.title,
            accountHolderID: manifest.accountHolderID,
            people: people
        )
    }

    func bootstrap(document: FamilyArchiveDocument) throws {
        try save(document: document, changedPersonIDs: Set(document.people.map(\.id)), rebuildGEDCOM: true)
        try copyReferencedAssetsIfNeeded(document: document)
        try copySidecarsIfAvailable()
    }

    /// Writes only changed person records plus the small manifest. The GEDCOM
    /// derivative is regenerated because it is small and must reflect any
    /// relationship/date edits, but media files are never read or rewritten.
    func save(
        document: FamilyArchiveDocument,
        changedPersonIDs: Set<Person.ID>,
        rebuildGEDCOM: Bool
    ) throws {
        try fileManager.createDirectory(at: peopleURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: privateDataURL, withIntermediateDirectories: true)

        // Keep legacy Documents/media and Documents/documents references in
        // the canonical store. Otherwise the JSON points at assets that are
        // visible in the app but are absent from the exported store archive.
        try copyReferencedAssetsIfNeeded(document: document)

        let peopleByID = Dictionary(uniqueKeysWithValues: document.people.map { ($0.id, $0) })
        let idsToWrite = changedPersonIDs.isEmpty ? Set(peopleByID.keys) : changedPersonIDs
        for personID in idsToWrite {
            guard let person = peopleByID[personID], let filename = safeFilename(for: personID) else { continue }
            let data = try JSONEncoder.archive.encode(person)
            try data.write(to: peopleURL.appendingPathComponent(filename), options: .atomic)
        }

        // Remove person records deleted from the document, without touching
        // any media/document asset.
        let currentFiles = Set(peopleByID.keys.compactMap(safeFilename(for:)))
        for url in try fileManager.contentsOfDirectory(at: peopleURL, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" && !currentFiles.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }

        let manifest = Manifest(
            format: "family-archive-private-store",
            version: 1,
            schemaVersion: document.schemaVersion,
            title: document.title,
            accountHolderID: document.accountHolderID,
            personIDs: document.people.map(\.id).sorted(),
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
        let manifestData = try JSONEncoder.archive.encode(manifest)
        try manifestData.write(to: manifestURL, options: .atomic)

        if rebuildGEDCOM {
            try GEDCOMExporter(document: document).makeGEDCOM().write(to: gedcomURL, options: .atomic)
        }
    }

    func exportDirectoryURL() throws -> URL {
        guard fileManager.fileExists(atPath: rootURL.path) else { throw StoreError.storeUnavailable }
        return rootURL
    }

    func copyStore(to destinationURL: URL) throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { throw StoreError.storeUnavailable }
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try copyDirectoryContents(from: rootURL, to: destinationURL)
    }

    func exportArchive(to destinationURL: URL) throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { throw StoreError.storeUnavailable }
        if let document = try loadDocument() {
            // Export is also a repair point for records created by older
            // builds, before referenced assets were synchronized on save.
            try copyReferencedAssetsIfNeeded(document: document)
        }
        try PrivateArchiveFile.write(directory: rootURL, to: destinationURL, fileManager: fileManager)
    }

    func replaceContents(with sourceDirectory: URL) throws {
        guard fileManager.fileExists(atPath: sourceDirectory.path) else { throw StoreError.storeUnavailable }
        try? fileManager.removeItem(at: rootURL)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try copyDirectoryContents(from: sourceDirectory, to: rootURL)
    }

    private func copyDirectoryContents(from source: URL, to destination: URL) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let items = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey])
        for item in items {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory {
                try copyDirectoryContents(from: item, to: target)
            } else {
                try? fileManager.removeItem(at: target)
                try fileManager.copyItem(at: item, to: target)
            }
        }
    }

    private func copyReferencedAssetsIfNeeded(document: FamilyArchiveDocument) throws {
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        for person in document.people {
            let paths = person.media.compactMap(\.path) + [person.profileImagePath].compactMap { $0 }
            for path in Set(paths) {
                guard !path.isEmpty,
                      !path.hasPrefix("/"),
                      !path.split(separator: "/").contains("..") else { continue }
                let destination = rootURL.appendingPathComponent(path)
                if fileManager.fileExists(atPath: destination.path) { continue }

                let candidates = [
                    documentsURL?.appendingPathComponent(path),
                    Bundle.main.url(forResource: path, withExtension: nil)
                ].compactMap { $0 }
                guard let source = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else { continue }
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: destination)
            }
        }
    }

    private func copySidecarsIfAvailable() throws {
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        for filename in ["name-localizations.private.json", "narrative-translations.private.json"] {
            let destination = privateDataURL.appendingPathComponent(filename)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            let candidates = [
                documentsURL?.appendingPathComponent("PrivateData").appendingPathComponent(filename),
                documentsURL?.appendingPathComponent(filename),
                Bundle.main.url(forResource: filename.replacingOccurrences(of: ".json", with: ""), withExtension: "json")
            ].compactMap { $0 }
            if let source = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
                try fileManager.copyItem(at: source, to: destination)
            }
        }
    }

    private func safeFilename(for personID: Person.ID) -> String? {
        guard !personID.isEmpty,
              !personID.contains("/"),
              !personID.contains("\\"),
              !personID.contains("..") else { return nil }
        return "\(personID).json"
    }

    enum StoreError: LocalizedError {
        case invalidPersonID
        case storeUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidPersonID: "The private store contains an invalid person identifier."
            case .storeUnavailable: "The private document store is unavailable."
            }
        }
    }
}

/// A streaming, uncompressed private archive format. It deliberately keeps
/// the portable export as one ordinary file without loading media into memory.
/// Each record is: UTF-8 path length (UInt64), file length (UInt64), path, bytes.
private enum PrivateArchiveFile {
    private static let magic = Data("FAR1".utf8)
    private static let chunkSize = 1024 * 1024

    static func write(directory: URL, to destinationURL: URL, fileManager: FileManager) throws {
        try? fileManager.removeItem(at: destinationURL)
        fileManager.createFile(atPath: destinationURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }
        try output.write(contentsOf: magic)

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { throw ArchivePackageError.documentsUnavailable }

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let relativePath = fileURL.path.replacingOccurrences(of: directory.path + "/", with: "")
            guard !relativePath.isEmpty,
                  !relativePath.hasPrefix("/"),
                  !relativePath.split(separator: "/").contains("..") else { continue }
            let pathData = Data(relativePath.utf8)
            let fileSize = UInt64(values.fileSize ?? 0)
            try output.write(contentsOf: uint64Data(UInt64(pathData.count)))
            try output.write(contentsOf: uint64Data(fileSize))
            try output.write(contentsOf: pathData)

            do {
                let input = try FileHandle(forReadingFrom: fileURL)
                defer { try? input.close() }
                var remaining = fileSize
                while remaining > 0 {
                    let requested = Int(min(UInt64(chunkSize), remaining))
                    guard let data = try input.read(upToCount: requested), !data.isEmpty else {
                        throw ArchivePackageError.invalidZip
                    }
                    try output.write(contentsOf: data)
                    remaining -= UInt64(data.count)
                }
            }
        }
    }

    static func isArchive(at url: URL) -> Bool {
        guard let input = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? input.close() }
        guard let header = try? readExact(from: input, count: magic.count) else { return false }
        return header == magic
    }

    static func extract(_ archiveURL: URL, to destinationURL: URL, fileManager: FileManager) throws {
        guard isArchive(at: archiveURL) else { throw ArchivePackageError.invalidZip }
        try? fileManager.removeItem(at: destinationURL)
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        let input = try FileHandle(forReadingFrom: archiveURL)
        defer { try? input.close() }
        guard try readExact(from: input, count: magic.count) == magic else {
            throw ArchivePackageError.invalidZip
        }

        while true {
            // Files-provider URLs can return a short read even when more bytes
            // are available. Read the fixed-size record header until complete,
            // while still treating EOF between records as a clean end.
            guard let header = try readHeader(from: input, count: 16) else { break }
            let pathLength = Int(try readUInt64(header, at: 0))
            let fileSize = try readUInt64(header, at: 8)
            guard pathLength > 0, pathLength <= 4096, fileSize <= UInt64(Int.max) else {
                throw ArchivePackageError.invalidZip
            }
            let pathData = try readExact(from: input, count: pathLength)
            guard let relativePath = String(data: pathData, encoding: .utf8),
                  !relativePath.hasPrefix("/"),
                  !relativePath.split(separator: "/").contains("..") else {
                throw ArchivePackageError.invalidZip
            }
            let outputURL = destinationURL.appendingPathComponent(relativePath)
            try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            fileManager.createFile(atPath: outputURL.path, contents: nil)
            do {
                let output = try FileHandle(forWritingTo: outputURL)
                defer { try? output.close() }
                var remaining = fileSize
                while remaining > 0 {
                    let requested = Int(min(UInt64(chunkSize), remaining))
                    guard let data = try input.read(upToCount: requested), !data.isEmpty else {
                        throw ArchivePackageError.invalidZip
                    }
                    try output.write(contentsOf: data)
                    remaining -= UInt64(data.count)
                }
            }
        }
    }

    private static func uint64Data(_ value: UInt64) -> Data {
        var littleEndian = value.littleEndian
        return Data(bytes: &littleEndian, count: MemoryLayout<UInt64>.size)
    }

    private static func readUInt64(_ data: Data, at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { throw ArchivePackageError.invalidZip }
        return data[offset..<(offset + 8)].enumerated().reduce(UInt64(0)) { result, pair in
            result | (UInt64(pair.element) << (UInt64(pair.offset) * 8))
        }
    }

    private static func readExact(from handle: FileHandle, count: Int) throws -> Data {
        guard count >= 0 else { throw ArchivePackageError.invalidZip }
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw ArchivePackageError.invalidZip
            }
            data.append(chunk)
        }
        return data
    }

    private static func readHeader(from handle: FileHandle, count: Int) throws -> Data? {
        guard count > 0 else { return Data() }
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count) else {
                if data.isEmpty { return nil }
                throw ArchivePackageError.invalidZip
            }
            if chunk.isEmpty {
                if data.isEmpty { return nil }
                throw ArchivePackageError.invalidZip
            }
            data.append(chunk)
        }
        return data
    }
}

final class FamilyRepository: ObservableObject {
    @Published private(set) var document: FamilyArchiveDocument
    @Published var appLanguage: ArchiveLanguage {
        didSet {
            UserDefaults.standard.set(appLanguage.rawValue, forKey: NameLocalizationStore.appLanguageKey)
            // Refresh private sidecars when the locale changes. This keeps
            // names and narrative translations in sync immediately, rather
            // than waiting for a relaunch or an import cycle.
            NameLocalizationStore.shared.reload()
            NarrativeLocalizationStore.shared.reload()
        }
    }

    private var peopleByID: [Person.ID: Person]
    private let presumedDeathBeforeBirthYear = 1921
    private var profilePhotoPathCache: [Person.ID: String] = [:]
    private var coloredPhotoCache: [String: Bool] = [:]
    private let privateStore: PrivateDocumentStore

    private struct PhotoCandidate {
        let path: String
        let date: String?
        let order: Int
    }

    init(document: FamilyArchiveDocument, fileManager: FileManager = .default) {
        self.document = document
        self.privateStore = PrivateDocumentStore(fileManager: fileManager)
        self.appLanguage = ArchiveLanguage(
            rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? ArchiveLanguage.russian.rawValue
        ) ?? .russian
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

    /// Resolves one media record without rebuilding the complete shared-media
    /// list. Detail views call this during every SwiftUI refresh while an
    /// image is loading, so keeping the lookup narrow avoids repeated scans
    /// of every person's media collection.
    func mediaItem(withID mediaID: MediaReference.ID, preferredPersonID: Person.ID? = nil) -> MediaReference? {
        if let preferredPersonID,
           let preferred = peopleByID[preferredPersonID],
           let item = preferred.media.first(where: { $0.id == mediaID }) {
            return item
        }

        for person in document.people {
            if let item = person.media.first(where: { $0.id == mediaID }) {
                return item
            }
        }
        return nil
    }

    /// Finds the person record that physically owns a media item. Shared
    /// items can be shown from any tagged profile, but edits must be applied
    /// through the record that actually stores the item.
    func mediaOwnerID(for item: MediaReference, preferredID: Person.ID? = nil) -> Person.ID? {
        if let preferredID,
           peopleByID[preferredID]?.media.contains(where: { $0.id == item.id }) == true {
            return preferredID
        }
        return document.people.first(where: { person in
            person.media.contains(where: { $0.id == item.id })
        })?.id
    }

    func photoPath(for personID: Person.ID) -> String? {
        guard let person = person(id: personID) else { return nil }
        if let cachedPath = profilePhotoPathCache[personID] {
            return cachedPath
        }
        // An explicitly selected profile image takes precedence over the
        // automatic colored/recency choice. The editor can therefore select
        // any existing private media item and keep that choice stable.
        if let selectedPath = person.profileImagePath,
           resolvedFileURL(for: selectedPath) != nil {
            profilePhotoPathCache[personID] = selectedPath
            return selectedPath
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
            let storeURL = privateStore.rootURL.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: storeURL.path) {
                return storeURL
            }
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
        replaceDocument(people: people, changedPersonIDs: [person.id])
    }

    func updateMedia(_ item: MediaReference, for ownerID: Person.ID) {
        var people = document.people
        guard let resolvedOwnerID = mediaOwnerID(for: item, preferredID: ownerID),
              let ownerIndex = people.firstIndex(where: { $0.id == resolvedOwnerID }),
              let mediaIndex = people[ownerIndex].media.firstIndex(where: { $0.id == item.id }) else { return }

        let previousIDs = Set(people[ownerIndex].media[mediaIndex].personIDs ?? [resolvedOwnerID])
        let updatedIDs = Set(item.personIDs ?? [resolvedOwnerID]).union([resolvedOwnerID])
        people[ownerIndex].media[mediaIndex] = item

        for index in people.indices where people[index].id != resolvedOwnerID {
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
        replaceDocument(people: people, changedPersonIDs: updatedIDs.union(previousIDs))
    }

    func removeMedia(_ item: MediaReference, from ownerID: Person.ID) {
        var people = document.people
        // A shared image may be opened from any tagged profile. Resolve the
        // record that actually owns the media before removing it, otherwise a
        // delete from a linked profile would silently do nothing.
        guard let resolvedOwnerID = mediaOwnerID(for: item, preferredID: ownerID),
              let ownerIndex = people.firstIndex(where: { $0.id == resolvedOwnerID }) else { return }
        let relatedIDs = Set(item.personIDs ?? [resolvedOwnerID])
        people[ownerIndex].media.removeAll { $0.id == item.id }
        for index in people.indices where relatedIDs.contains(people[index].id) || people[index].id == resolvedOwnerID {
            people[index].media.removeAll { $0.id == item.id }
        }

        var changedPersonIDs = relatedIDs.union([resolvedOwnerID])

        // Removing a media record also removes any profile-photo selection
        // that points at that same asset. Do this for every person because a
        // shared photo can be selected as the profile image from any profile.
        if let path = item.path {
            for index in people.indices where people[index].profileImagePath == path {
                people[index].profileImagePath = nil
                people[index].profileImageScale = nil
                people[index].profileImageOffsetX = nil
                people[index].profileImageOffsetY = nil
                changedPersonIDs.insert(people[index].id)
            }
        }

        let stillReferenced = people.contains { person in
            person.media.contains { $0.path == item.path } || person.profileImagePath == item.path
        }
        replaceDocument(people: people, changedPersonIDs: changedPersonIDs)

        // Only delete the canonical normalized-store asset. Absolute paths
        // and legacy Documents/ or bundled copies are deliberately left
        // alone, so the original archive remains untouched and recoverable.
        if !stillReferenced {
            removePrivateAsset(at: item.path)
        }
    }

    private func removePrivateAsset(at path: String?) {
        guard let path,
              !path.isEmpty,
              !path.hasPrefix("/"),
              !path.split(separator: "/").contains(".."),
              (path.hasPrefix("media/") || path.hasPrefix("documents/")) else { return }

        let root = privateStore.rootURL.standardizedFileURL
        let assetURL = root.appendingPathComponent(path).standardizedFileURL
        guard assetURL.path.hasPrefix(root.path + "/"),
              privateStore.fileManager.fileExists(atPath: assetURL.path) else { return }
        try? privateStore.fileManager.removeItem(at: assetURL)
    }

    private func replaceDocument(people: [Person], changedPersonIDs: Set<Person.ID> = []) {
        document = FamilyArchiveDocument(
            schemaVersion: document.schemaVersion,
            title: document.title,
            accountHolderID: document.accountHolderID,
            people: people
        )
        peopleByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        profilePhotoPathCache.removeAll()
        coloredPhotoCache.removeAll()
        try? privateStore.save(document: document, changedPersonIDs: changedPersonIDs, rebuildGEDCOM: true)
    }

    /// Legacy ZIP export retained for compatibility with packages created by
    /// earlier builds. New UI uses the streaming single-file archive below.
    func exportPrivateArchive(fileManager: FileManager = .default) throws -> Data {
        try ArchivePackageBuilder(repository: self, fileManager: fileManager).build()
    }

    /// Returns the already-persisted private store for internal diagnostics.
    func exportPrivateStoreURL() throws -> URL {
        try privateStore.exportDirectoryURL()
    }

    func exportPrivateStore(to destinationURL: URL) throws {
        try privateStore.copyStore(to: destinationURL)
    }

    func exportPrivateArchiveFile(to destinationURL: URL, fileManager: FileManager = .default) throws {
        try privateStore.exportArchive(to: destinationURL)
    }

    /// Builds and reads a tiny synthetic archive without touching the user's
    /// private store. This is exposed only for the temporary DEBUG importer
    /// diagnostic in Settings.
    func validateBuiltInPrivateArchive(fileManager: FileManager = .default) throws -> ArchivePackageSummary {
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent("FamilyArchiveSynthetic-(UUID().uuidString)", isDirectory: true)
        let archiveURL = fileManager.temporaryDirectory.appendingPathComponent("FamilyArchiveSynthetic-(UUID().uuidString).familyarchive")
        let copiedURL = fileManager.temporaryDirectory.appendingPathComponent("FamilyArchiveSyntheticCopy-(UUID().uuidString).familyarchive")
        defer {
            try? fileManager.removeItem(at: rootURL)
            try? fileManager.removeItem(at: archiveURL)
            try? fileManager.removeItem(at: copiedURL)
        }

        let person = Person(
            id: "TEST-001",
            givenName: "Test",
            familyName: "Person",
            alternateNames: [],
            lifespan: "2000–",
            summary: "Synthetic importer test record.",
            biography: "",
            privacy: .sample,
            relationshipToMe: nil,
            profileImagePath: nil,
            facts: [],
            events: [],
            storyChapters: [],
            immediateFamily: ImmediateFamily(parents: [], partners: [], siblings: [], children: []),
            media: [],
            sources: []
        )
        let manifest = PrivateDocumentStore.Manifest(
            format: "family-archive-private-store",
            version: 1,
            schemaVersion: 1,
            title: "Synthetic importer test",
            accountHolderID: person.id,
            personIDs: [person.id],
            updatedAt: "2026-01-01T00:00:00Z"
        )
        let peopleURL = rootURL.appendingPathComponent("people", isDirectory: true)
        try fileManager.createDirectory(at: peopleURL, withIntermediateDirectories: true)
        try JSONEncoder.archive.encode(manifest).write(to: rootURL.appendingPathComponent("manifest.json"), options: .atomic)
        try JSONEncoder.archive.encode(person).write(to: peopleURL.appendingPathComponent("TEST-001.json"), options: .atomic)

        try PrivateArchiveFile.write(directory: rootURL, to: archiveURL, fileManager: fileManager)
        try fileManager.copyItem(at: archiveURL, to: copiedURL)
        return try previewPrivateArchive(at: copiedURL, fileManager: fileManager)
    }

    func previewPrivateArchive(at url: URL, fileManager: FileManager = .default) throws -> ArchivePackageSummary {
        if PrivateArchiveFile.isArchive(at: url) {
            let stagingURL = fileManager.temporaryDirectory.appendingPathComponent("FamilyArchivePreview-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: stagingURL) }
            try PrivateArchiveFile.extract(url, to: stagingURL, fileManager: fileManager)
            return try previewPrivateArchive(at: stagingURL, fileManager: fileManager)
        }
        if url.hasDirectoryPath || fileManager.fileExists(atPath: url.appendingPathComponent("manifest.json").path) {
            let sourceStore = PrivateDocumentStore(rootURL: url, fileManager: fileManager)
            guard let document = try sourceStore.loadDocument() else { throw ArchivePackageError.emptyArchive }
            return ArchivePackageSummary(document: document, fileCount: countFiles(at: url, fileManager: fileManager))
        }
        return try Self.previewPrivateArchive(Data(contentsOf: url))
    }

    func importPrivateArchive(at url: URL, fileManager: FileManager = .default) throws -> ArchivePackageSummary {
        if PrivateArchiveFile.isArchive(at: url) {
            let stagingURL = fileManager.temporaryDirectory.appendingPathComponent("FamilyArchiveImport-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: stagingURL) }
            try PrivateArchiveFile.extract(url, to: stagingURL, fileManager: fileManager)
            return try importPrivateArchive(at: stagingURL, fileManager: fileManager)
        }
        if url.hasDirectoryPath || fileManager.fileExists(atPath: url.appendingPathComponent("manifest.json").path) {
            let sourceStore = PrivateDocumentStore(rootURL: url, fileManager: fileManager)
            guard let importedDocument = try sourceStore.loadDocument() else { throw ArchivePackageError.emptyArchive }
            // Keep the imported media and documents inside the canonical
            // private store so a later export remains complete. The mirrored
            // Documents copies below preserve compatibility with older paths.
            try privateStore.replaceContents(with: url)
            try privateStore.bootstrap(document: importedDocument)

            let sourcePrivateData = url.appendingPathComponent("PrivateData", isDirectory: true)
            let destinationPrivateData = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("PrivateData", isDirectory: true)
            if fileManager.fileExists(atPath: sourcePrivateData.path), let destinationPrivateData {
                try copyDirectoryContents(from: sourcePrivateData, to: destinationPrivateData, fileManager: fileManager)
            }

            document = importedDocument
            peopleByID = Dictionary(uniqueKeysWithValues: importedDocument.people.map { ($0.id, $0) })
            profilePhotoPathCache.removeAll()
            coloredPhotoCache.removeAll()
            NarrativeLocalizationStore.shared.reload(fileManager: fileManager)
            NameLocalizationStore.shared.reload(fileManager: fileManager)
            return ArchivePackageSummary(document: importedDocument, fileCount: countFiles(at: url, fileManager: fileManager))
        }
        return try importPrivateArchive(Data(contentsOf: url), fileManager: fileManager)
    }

    private func countFiles(at url: URL, fileManager: FileManager) -> Int {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        return enumerator.reduce(into: 0) { count, item in
            guard let fileURL = item as? URL,
                  (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return }
            count += 1
        }
    }

    private func copyDirectoryContents(from source: URL, to destination: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let items = try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return }
        for item in items {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try copyDirectoryContents(from: item, to: target, fileManager: fileManager)
            } else {
                try? fileManager.removeItem(at: target)
                try fileManager.copyItem(at: item, to: target)
            }
        }
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
        try privateStore.bootstrap(document: importedDocument)
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

    static func bundled(bundle: Bundle = .main, fileManager: FileManager = .default) -> FamilyRepository {
        guard let url = bundle.url(forResource: "sample-family", withExtension: "json") else {
            let repository = FamilyRepository(document: .empty, fileManager: fileManager)
            try? repository.privateStore.bootstrap(document: .empty)
            return repository
        }

        do {
            let data = try Data(contentsOf: url)
            let document = try JSONDecoder().decode(FamilyArchiveDocument.self, from: data)
            let repository = FamilyRepository(document: document, fileManager: fileManager)
            try? repository.privateStore.bootstrap(document: document)
            return repository
        } catch {
            assertionFailure("Unable to load bundled family data: \(error)")
            let repository = FamilyRepository(document: .empty, fileManager: fileManager)
            try? repository.privateStore.bootstrap(document: .empty)
            return repository
        }
    }

    static func localOrBundled(
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> FamilyRepository {
        let store = PrivateDocumentStore(fileManager: fileManager)
        if let document = try? store.loadDocument() {
            return FamilyRepository(document: document, fileManager: fileManager)
        }

        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let localURL = documentsURL.appendingPathComponent("family-archive.json")
            if let data = try? Data(contentsOf: localURL),
               let document = try? JSONDecoder().decode(FamilyArchiveDocument.self, from: data) {
                let repository = FamilyRepository(document: document, fileManager: fileManager)
                try? repository.privateStore.bootstrap(document: document)
                return repository
            }
        }

        return bundled(bundle: bundle, fileManager: fileManager)
    }
}

private extension JSONEncoder {
    static var archive: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension JSONDecoder {
    static var archive: JSONDecoder {
        JSONDecoder()
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
