import Foundation
import Combine
import ImageIO
import UIKit
import UniformTypeIdentifiers
import CoreLocation
import Translation

struct StagedMediaItem: Identifiable, Hashable {
    let url: URL
    let filename: String
    let kind: MediaKind

    var id: String { url.path }
}

struct MediaMentionReviewItem: Identifiable, Hashable {
    let media: MediaReference
    let ownerID: Person.ID

    var id: MediaReference.ID { media.id }
}

enum MediaUpdateError: LocalizedError {
    case editingUnavailable
    case mediaNotFound

    var errorDescription: String? {
        switch self {
        case .editingUnavailable:
            "This archive is read-only and cannot save media changes."
        case .mediaNotFound:
            "The media record could not be found, so its caption was not saved."
        }
    }
}

struct SavedMediaCaption {
    let canonicalCaption: String
    let personIDs: Set<Person.ID>
    let media: MediaReference
}

/// The app's canonical private document store. Metadata is split into one
/// file per person so an edit does not rewrite the complete family archive.
/// Media and documents remain ordinary persistent files and are referenced by
/// their relative paths from the app's Documents directory.
private struct PrivateDocumentStore {
    static let accountHandoffFilename = "account-handoff.json"

    struct AccountHandoff: Codable {
        let personID: Person.ID
        let displayName: String
        let createdAt: String
        let readOnly: Bool

        init(personID: Person.ID, displayName: String, createdAt: String, readOnly: Bool = true) {
            self.personID = personID
            self.displayName = displayName
            self.createdAt = createdAt
            self.readOnly = readOnly
        }

        private enum CodingKeys: String, CodingKey {
            case personID, displayName, createdAt, readOnly
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            personID = try container.decode(Person.ID.self, forKey: .personID)
            displayName = try container.decode(String.self, forKey: .displayName)
            createdAt = try container.decode(String.self, forKey: .createdAt)
            // Older handoffs had no permission field and are safely treated
            // as read-only recipient archives.
            readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? true
        }
    }

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
    var familyUnionsURL: URL { rootURL.appendingPathComponent("family-unions.json") }
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

        let familyUnions: [FamilyUnion]?
        if fileManager.fileExists(atPath: familyUnionsURL.path) {
            let data = try Data(contentsOf: familyUnionsURL)
            familyUnions = try JSONDecoder.archive.decode([FamilyUnion].self, from: data)
        } else {
            familyUnions = nil
        }

        guard !people.isEmpty else { return nil }
        return FamilyArchiveDocument(
            schemaVersion: manifest.schemaVersion,
            title: manifest.title,
            accountHolderID: manifest.accountHolderID,
            people: people,
            familyUnions: familyUnions
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
            version: 2,
            schemaVersion: document.schemaVersion,
            title: document.title,
            accountHolderID: document.accountHolderID,
            personIDs: document.people.map(\.id).sorted(),
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
        let manifestData = try JSONEncoder.archive.encode(manifest)
        try manifestData.write(to: manifestURL, options: .atomic)

        if let familyUnions = document.familyUnions {
            let familyData = try JSONEncoder.archive.encode(familyUnions)
            try familyData.write(to: familyUnionsURL, options: .atomic)
        } else if fileManager.fileExists(atPath: familyUnionsURL.path) {
            try fileManager.removeItem(at: familyUnionsURL)
        }

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

    func exportArchive(
        to destinationURL: URL,
        preparedForPersonID: Person.ID? = nil,
        readOnly: Bool = true
    ) throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { throw StoreError.storeUnavailable }
        guard let document = try loadDocument() else { throw ArchivePackageError.emptyArchive }
        // Export is also a repair point for records created by older builds,
        // before referenced assets were synchronized on save.
        try copyReferencedAssetsIfNeeded(document: document)

        guard let preparedForPersonID else {
            try PrivateArchiveFile.write(directory: rootURL, to: destinationURL, fileManager: fileManager)
            return
        }

        guard let preparedPerson = document.people.first(where: { $0.id == preparedForPersonID }) else {
            throw StoreError.invalidAccountID
        }

        // Handoff metadata belongs to the exported package, not the shared
        // store. This lets the recipient become the intended account without
        // changing the administrator's local perspective.
        let stagingURL = fileManager.temporaryDirectory
            .appendingPathComponent("FamilyArchiveHandoff-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingURL) }
        try copyDirectoryContents(from: rootURL, to: stagingURL)
        let handoff = AccountHandoff(
            personID: preparedPerson.id,
            displayName: preparedPerson.sourceDisplayName,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            readOnly: readOnly
        )
        let handoffData = try JSONEncoder.archive.encode(handoff)
        try handoffData.write(to: stagingURL.appendingPathComponent(Self.accountHandoffFilename), options: .atomic)
        try PrivateArchiveFile.write(directory: stagingURL, to: destinationURL, fileManager: fileManager)
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
        case invalidAccountID
        case storeUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidPersonID: "The private store contains an invalid person identifier."
            case .invalidAccountID: "The selected account person is not in the private archive."
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
        // A prepared archive inside app-owned temporary storage is not visible
        // to the user. Write it there directly so large exports do not require
        // a second full-size temporary copy before the system Files exporter
        // publishes it.
        let temporaryRoot = fileManager.temporaryDirectory.standardizedFileURL.path
        let standardizedDestination = destinationURL.standardizedFileURL.path
        if standardizedDestination.hasPrefix(temporaryRoot + "/") {
            try writeContents(directory: directory, to: destinationURL, fileManager: fileManager)
            return
        }

        // Build in app-owned temporary storage first. The Files exporter has
        // already created a small placeholder at the selected destination;
        // keeping it in place until this archive is complete prevents a
        // cancelled or interrupted export from leaving a valid-looking FAR1
        // header with no records.
        let stagedURL = fileManager.temporaryDirectory
            .appendingPathComponent("FamilyArchiveExport-\(UUID().uuidString)")
            .appendingPathExtension("partial")
        defer { try? fileManager.removeItem(at: stagedURL) }
        try writeContents(directory: directory, to: stagedURL, fileManager: fileManager)

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagedURL)
        } else {
            try fileManager.copyItem(at: stagedURL, to: destinationURL)
        }
    }

    private static func writeContents(directory: URL, to outputURL: URL, fileManager: FileManager) throws {
        try? fileManager.removeItem(at: outputURL)
        fileManager.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        var didCloseOutput = false
        defer {
            if !didCloseOutput { try? output.close() }
        }
        try output.write(contentsOf: magic)

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { throw ArchivePackageError.documentsUnavailable }

        var containsManifest = false
        var personRecordCount = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let relativePath = fileURL.path.replacingOccurrences(of: directory.path + "/", with: "")
            guard !relativePath.isEmpty,
                  !relativePath.hasPrefix("/"),
                  !relativePath.split(separator: "/").contains("..") else { continue }
            containsManifest = containsManifest || relativePath == "manifest.json"
            if relativePath.hasPrefix("people/"), relativePath.hasSuffix(".json") {
                personRecordCount += 1
            }
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

        guard containsManifest, personRecordCount > 0 else {
            throw ArchivePackageError.emptyArchive
        }
        try output.synchronize()
        try output.close()
        didCloseOutput = true
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

        var recordCount = 0
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
            recordCount += 1
        }
        guard recordCount > 0 else { throw ArchivePackageError.incompleteArchive }
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
    static let activeAccountIDKey = "FamilyArchive.activeAccountID"
    /// A prepared account handoff is opened on the recipient's device in
    /// read-only mode. This is device state, not part of the private family
    /// records, so the administrator's own archive remains editable.
    static let readOnlyModeKey = "FamilyArchive.readOnlyMode"

    @Published private(set) var document: FamilyArchiveDocument
    @Published private(set) var activeAccountID: Person.ID?
    @Published private(set) var isReadOnly: Bool
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
        self.activeAccountID = document.accountHolderID
        self.isReadOnly = UserDefaults.standard.bool(forKey: Self.readOnlyModeKey)
        self.appLanguage = ArchiveLanguage(
            rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? ArchiveLanguage.russian.rawValue
        ) ?? .russian
        peopleByID = Dictionary(uniqueKeysWithValues: document.people.map { ($0.id, $0) })
        if let savedID = UserDefaults.standard.string(forKey: Self.activeAccountIDKey),
           peopleByID[savedID] != nil {
            activeAccountID = savedID
        } else if let documentAccountID = document.accountHolderID,
                  peopleByID[documentAccountID] != nil {
            activeAccountID = documentAccountID
            UserDefaults.standard.set(documentAccountID, forKey: Self.activeAccountIDKey)
        } else {
            activeAccountID = nil
            UserDefaults.standard.removeObject(forKey: Self.activeAccountIDKey)
        }
        NameLocalizationStore.shared.reload()
        normalizeMediaMentionStorage()
    }

    /// One-time, idempotent upgrade for imported media. Captions used to store
    /// visible names, which became stale after a rename or locale switch. The
    /// private store now keeps immutable person-ID markers and renders names
    /// at the point of use.
    private func normalizeMediaMentionStorage() {
        var updatedPeople = document.people
        var changedPersonIDs = Set<Person.ID>()

        for personIndex in updatedPeople.indices {
            let person = updatedPeople[personIndex]
            var updatedMedia = person.media
            var personChanged = false
            for mediaIndex in updatedMedia.indices {
                let media = updatedMedia[mediaIndex]
                let storedCaption = media.caption ?? ""
                let canonical = MediaMentionToken.hasUnstructuredMention(in: storedCaption)
                    ? MediaMentionToken.canonicalize(
                        storedCaption,
                        people: document.people,
                        // The old index can resolve a legacy ambiguous visible
                        // name during migration, but it is never retained unless
                        // the resulting caption actually contains that token.
                        preferredPersonIDs: Set(media.personIDs ?? [])
                    )
                    : storedCaption
                let sortedIDs = MediaMentionToken.personIDs(in: canonical)
                    .filter { peopleByID[$0] != nil }
                    .sorted()
                let needsReview = sortedIDs.isEmpty ? true : nil
                let captionChanged = canonical != (media.caption ?? "")
                let linksChanged = sortedIDs != (media.personIDs ?? []).sorted()
                let reviewChanged = media.needsMentionReview != needsReview
                guard captionChanged || linksChanged || reviewChanged else { continue }
                updatedMedia[mediaIndex].caption = canonical.isEmpty ? nil : canonical
                updatedMedia[mediaIndex].personIDs = sortedIDs
                updatedMedia[mediaIndex].needsMentionReview = needsReview
                personChanged = true
            }
            if personChanged {
                updatedPeople[personIndex].media = updatedMedia
                changedPersonIDs.insert(person.id)
            }
        }
        if !changedPersonIDs.isEmpty {
            replaceDocument(people: updatedPeople, changedPersonIDs: changedPersonIDs)
        }
        _ = NarrativeLocalizationStore.shared.migrateMediaMentions(
            people: document.people,
            fileManager: privateStore.fileManager
        )
        NarrativeLocalizationStore.shared.reload(fileManager: privateStore.fileManager)
    }

    /// Whether this account may change the private family archive. A prepared
    /// recipient account can browse everything, but cannot edit or delete
    /// profiles, stories, events, captions, or media. The archive owner keeps
    /// admin access even if a read-only handoff flag was left on this device.
    var canEdit: Bool {
        guard isReadOnly else { return true }
        guard let adminID = document.accountHolderID else { return false }
        return activeAccountID == adminID
    }

    var people: [Person] {
        document.people.sorted {
            ($0.familyName.localizedStandardCompare($1.familyName) == .orderedAscending) ||
                ($0.familyName == $1.familyName &&
                    $0.givenName.localizedStandardCompare($1.givenName) == .orderedAscending)
        }
    }

    var familyUnions: [FamilyUnion] {
        document.resolvedFamilyUnions
    }

    func partnerRelationships(for personID: Person.ID) -> [FamilyPartnerRelationship] {
        familyUnions.compactMap { union in
            guard union.partnerIDs.contains(personID),
                  let partnerID = union.partnerIDs.first(where: { $0 != personID }),
                  let partner = peopleByID[partnerID] else { return nil }
            return FamilyPartnerRelationship(
                union: union,
                partner: partner,
                sequence: union.partnerSequence?[personID]
            )
        }
        .sorted { left, right in
            let leftSequence = left.sequence ?? Int.max
            let rightSequence = right.sequence ?? Int.max
            if leftSequence != rightSequence { return leftSequence < rightSequence }
            if left.union.marriageDate != right.union.marriageDate {
                return (left.union.marriageDate ?? "") < (right.union.marriageDate ?? "")
            }
            return left.partner.displayName.localizedStandardCompare(right.partner.displayName) == .orderedAscending
        }
    }

    func person(id: Person.ID) -> Person? {
        peopleByID[id]
    }

    var accountHolderID: Person.ID? {
        activeAccountID
    }

    var accountHolder: Person? {
        guard let activeAccountID else { return nil }
        return person(id: activeAccountID)
    }

    /// The app's private intake area. Files here are unreviewed and are not
    /// included in a family archive export until they are approved.
    private var stagingInboxURL: URL {
        privateStore.rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("StagingMedia", isDirectory: true)
            .appendingPathComponent("inbox", isDirectory: true)
    }

    private var stagingReviewedURL: URL {
        stagingInboxURL.deletingLastPathComponent().appendingPathComponent("reviewed", isDirectory: true)
    }

    func stagedMediaItems() -> [StagedMediaItem] {
        let fileManager = privateStore.fileManager
        guard let urls = try? fileManager.contentsOfDirectory(
            at: stagingInboxURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let kind = mediaKind(for: url) else { return nil }
            return StagedMediaItem(url: url, filename: url.lastPathComponent, kind: kind)
        }
        .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    }

    /// Reads the camera's original capture date when the staged image carries
    /// EXIF metadata. This is only a convenience for the review form; the
    /// user can edit the date directly as part of the caption.
    func originalMediaDate(for item: StagedMediaItem) -> String? {
        guard item.kind == .photo,
              let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let rawValue = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }

        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = input.date(from: rawValue) else { return nil }

        let output = DateFormatter()
        output.locale = Locale(identifier: appLanguage == .russian ? "ru_RU" : "en_US_POSIX")
        output.dateFormat = appLanguage == .russian ? "d MMMM yyyy" : "MMM d, yyyy"
        return output.string(from: date)
    }

    /// Reads GPS metadata and turns it into a human-readable place when the
    /// system geocoder can resolve it. If geocoding is unavailable, the
    /// coordinates are returned so the user can correct or remove them.
    @MainActor
    func originalMediaLocation(for item: StagedMediaItem) async -> String? {
        guard let coordinate = originalMediaCoordinate(for: item) else { return nil }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first {
            let parts = [placemark.locality, placemark.administrativeArea, placemark.country]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !parts.isEmpty {
                return Array(NSOrderedSet(array: parts))
                    .compactMap { $0 as? String }
                    .joined(separator: ", ")
            }
        }
        return String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private func originalMediaCoordinate(for item: StagedMediaItem) -> CLLocationCoordinate2D? {
        guard item.kind == .photo,
              let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let latitude = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
              let longitude = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue else { return nil }

        let latitudeSign = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -1.0 : 1.0
        let longitudeSign = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -1.0 : 1.0
        return CLLocationCoordinate2D(latitude: latitude * latitudeSign, longitude: longitude * longitudeSign)
    }

    /// Copies user-selected files into the app's private staging inbox. The
    /// source files remain where the user selected them.
    @discardableResult
    func importMediaFilesToStaging(_ urls: [URL]) throws -> Int {
        guard canEdit else { return 0 }
        let fileManager = privateStore.fileManager
        try fileManager.createDirectory(at: stagingInboxURL, withIntermediateDirectories: true)
        var imported = 0

        for sourceURL in urls {
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
            guard let kind = mediaKind(for: sourceURL) else { continue }

            var destination = stagingInboxURL.appendingPathComponent(sourceURL.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                let stem = sourceURL.deletingPathExtension().lastPathComponent
                let suffix = UUID().uuidString.prefix(8)
                destination = stagingInboxURL.appendingPathComponent("\(stem)-\(suffix).\(sourceURL.pathExtension)")
            }
            try fileManager.copyItem(at: sourceURL, to: destination)
            _ = kind
            imported += 1
        }
        return imported
    }

    /// Stores image data selected through PhotosPicker in the same private
    /// staging inbox used by Files imports. The bytes are kept intact so EXIF
    /// date and GPS metadata can still be reviewed when present.
    @discardableResult
    func importPhotoDataToStaging(_ data: Data, filename: String? = nil) throws -> Int {
        guard canEdit, !data.isEmpty else { return 0 }
        let fileManager = privateStore.fileManager
        try fileManager.createDirectory(at: stagingInboxURL, withIntermediateDirectories: true)
        let baseName = filename?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? filename!
            : "photo-\(UUID().uuidString).jpg"
        var destination = stagingInboxURL.appendingPathComponent(baseName)
        if fileManager.fileExists(atPath: destination.path) {
            destination = stagingInboxURL.appendingPathComponent("photo-\(UUID().uuidString).jpg")
        }
        try data.write(to: destination, options: .atomic)
        return 1
    }

    /// Approves one staged file. The file is copied into the canonical private
    /// media store, its normal media record is written, and only then is the
    /// staging copy moved to `reviewed`.
    @discardableResult
    func reviewStagedMedia(
        _ item: StagedMediaItem,
        caption: String,
        date: String?,
        personIDs: [Person.ID],
        isApproximate: Bool = false,
        captionLanguage: ArchiveLanguage = .russian
    ) throws -> String {
        guard canEdit else { return "" }
        let sourceURL = item.url.standardizedFileURL
        let fileManager = privateStore.fileManager
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw StagedMediaError.invalidReview
        }

        let selectedPersonIDs = Set(personIDs.filter { peopleByID[$0] != nil })

        let mediaID = "media-\(UUID().uuidString.lowercased())"
        let extensionName = sourceURL.pathExtension.isEmpty ? "bin" : sourceURL.pathExtension.lowercased()
        let relativePath = "media/imported/\(mediaID).\(extensionName)"
        let canonicalURL = privateStore.rootURL.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: canonicalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: sourceURL, to: canonicalURL)

        let cleanedCaption = MediaMentionToken.canonicalize(
            caption.trimmingCharacters(in: .whitespacesAndNewlines),
            people: document.people,
            preferredPersonIDs: selectedPersonIDs
        )
        let uniquePersonIDs = Array(Set(
            MediaMentionToken.personIDs(in: cleanedCaption).filter { peopleByID[$0] != nil }
        )).sorted()
        guard !uniquePersonIDs.isEmpty else { throw StagedMediaError.invalidReview }
        let cleanedDate = date?.trimmingCharacters(in: .whitespacesAndNewlines)
        let media = MediaReference(
            id: mediaID,
            kind: item.kind,
            title: sourceURL.deletingPathExtension().lastPathComponent,
            date: cleanedDate?.isEmpty == false ? cleanedDate : nil,
            path: relativePath,
            // Keep the entered caption on the media record as the durable
            // fallback. English captions are also copied to the private
            // narrative sidecar below, but storing the text here prevents a
            // newly reviewed image from appearing uncaptioned if the sidecar
            // is unavailable, stale, or is opened in another locale.
            caption: cleanedCaption.isEmpty ? nil : cleanedCaption,
            tags: nil,
            collection: nil,
            isApproximate: isApproximate ? true : nil,
            needsMentionReview: nil,
            personIDs: uniquePersonIDs
        )

        var updatedPeople = document.people
        for index in updatedPeople.indices where uniquePersonIDs.contains(updatedPeople[index].id) {
            updatedPeople[index].media.removeAll { $0.id == media.id }
            updatedPeople[index].media.append(media)
        }

        do {
            try privateStore.save(
                document: FamilyArchiveDocument(
                    schemaVersion: document.schemaVersion,
                    title: document.title,
                    accountHolderID: document.accountHolderID,
                    people: updatedPeople,
                    familyUnions: document.familyUnions
                ),
                changedPersonIDs: Set(uniquePersonIDs),
                rebuildGEDCOM: true
            )
            document = FamilyArchiveDocument(
                schemaVersion: document.schemaVersion,
                title: document.title,
                accountHolderID: document.accountHolderID,
                people: updatedPeople,
                familyUnions: document.familyUnions
            )
            peopleByID = Dictionary(uniqueKeysWithValues: updatedPeople.map { ($0.id, $0) })
            profilePhotoPathCache.removeAll()
            coloredPhotoCache.removeAll()

            // Keep one centralized source caption for this media ID. The
            // opposite supported locale is cleared before its asynchronous
            // translation is generated, preventing stale text from appearing
            // for any tagged profile.
            let targetLanguage: ArchiveLanguage = captionLanguage == .english ? .russian : .english
            try? NarrativeLocalizationStore.shared.updateMediaCaption(
                mediaID: media.id,
                caption: cleanedCaption,
                language: captionLanguage,
                fileManager: fileManager
            )
            try? NarrativeLocalizationStore.shared.updateMediaCaption(
                mediaID: media.id,
                caption: "",
                language: targetLanguage,
                fileManager: fileManager
            )
            NarrativeLocalizationStore.shared.reload(fileManager: fileManager)

            try fileManager.createDirectory(at: stagingReviewedURL, withIntermediateDirectories: true)
            var reviewedURL = stagingReviewedURL.appendingPathComponent(sourceURL.lastPathComponent)
            if fileManager.fileExists(atPath: reviewedURL.path) {
                reviewedURL = stagingReviewedURL.appendingPathComponent("\(sourceURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(8)).\(extensionName)")
            }
            try fileManager.moveItem(at: sourceURL, to: reviewedURL)
        } catch {
            try? fileManager.removeItem(at: canonicalURL)
            throw error
        }
        return media.id
    }

    /// Translates a newly saved caption on-device and stores the result in
    /// the private narrative sidecar. The source caption and media record are
    /// already durable before this best-effort step begins, so an unavailable
    /// language model can never lose the user's text.
    @available(iOS 26.0, *)
    @MainActor
    func autoTranslateMediaCaption(
        _ caption: String,
        mediaID: String,
        personIDs: [Person.ID],
        from sourceLanguage: ArchiveLanguage,
        fileManager: FileManager = .default
    ) async {
        let targetLanguage: ArchiveLanguage = sourceLanguage == .english ? .russian : .english
        let normalizedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedIDs = Set(personIDs)
        guard let currentMedia = mediaItem(withID: mediaID),
              currentMedia.caption?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCaption,
              !Set(MediaMentionToken.personIDs(in: currentMedia.caption ?? "")).intersection(expectedIDs).isEmpty else { return }

        let source = Locale.Language(identifier: sourceLanguage.rawValue)
        let target = Locale.Language(identifier: targetLanguage.rawValue)

        do {
            let session = TranslationSession(installedSource: source, target: target)
            let protected = MediaMentionToken.protectedForTranslation(caption)
            let response = try await session.translate(protected.text)
            let translated = MediaMentionToken.restoreAfterTranslation(
                response.targetText,
                tokens: protected.tokens
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty else { return }

            // Re-check the source text and links after translation; the user
            // may have edited or removed the media while the model ran.
            guard let latestMedia = mediaItem(withID: mediaID),
                  latestMedia.caption?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCaption,
                  !Set(MediaMentionToken.personIDs(in: latestMedia.caption ?? "")).intersection(expectedIDs).isEmpty else { return }

            try NarrativeLocalizationStore.shared.updateMediaCaption(
                mediaID: mediaID,
                caption: translated,
                language: targetLanguage,
                fileManager: fileManager
            )
            NarrativeLocalizationStore.shared.reload(fileManager: fileManager)
        } catch {
            // Translation is intentionally best effort. The source caption
            // remains available and can be translated later from an edit.
        }
    }

    enum StagedMediaError: LocalizedError {
        case invalidReview

        var errorDescription: String? {
            switch self {
            case .invalidReview:
                "Choose at least one family member and keep the staged file available before saving."
            }
        }
    }

    private func mediaKind(for url: URL) -> MediaKind? {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey])
        let type = values?.contentType
        if type?.conforms(to: .image) == true { return .photo }
        if type?.conforms(to: .movie) == true { return .video }
        if type?.conforms(to: .audio) == true { return .audio }
        if type?.conforms(to: .pdf) == true { return .document }

        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tif", "tiff": return .photo
        case "mov", "mp4", "m4v": return .video
        case "m4a", "mp3", "wav", "aiff": return .audio
        case "pdf": return .document
        default: return nil
        }
    }

    func setActiveAccountID(_ personID: Person.ID) {
        guard peopleByID[personID] != nil else { return }
        activeAccountID = personID
        UserDefaults.standard.set(personID, forKey: Self.activeAccountIDKey)
    }

    private func restoreActiveAccountAfterImport(
        importedDocument: FamilyArchiveDocument,
        preparedAccountID: Person.ID? = nil
    ) {
        peopleByID = Dictionary(uniqueKeysWithValues: importedDocument.people.map { ($0.id, $0) })
        if let preparedAccountID, peopleByID[preparedAccountID] != nil {
            setActiveAccountID(preparedAccountID)
        } else if let savedID = UserDefaults.standard.string(forKey: Self.activeAccountIDKey),
                  peopleByID[savedID] != nil {
            activeAccountID = savedID
        } else if let documentAccountID = importedDocument.accountHolderID,
                  peopleByID[documentAccountID] != nil {
            setActiveAccountID(documentAccountID)
        } else {
            activeAccountID = nil
            UserDefaults.standard.removeObject(forKey: Self.activeAccountIDKey)
        }
    }

    func people(ids: [Person.ID]) -> [Person] {
        ids.compactMap { peopleByID[$0] }
    }

    /// Returns the shortest relationship-link distance from a person to every
    /// reachable profile. A link is any recorded parent, partner, sibling, or
    /// child connection. The graph is made bidirectional here so older
    /// imports with only one side of a relationship still filter correctly.
    func connectionDistances(from personID: Person.ID?) -> [Person.ID: Int] {
        guard let personID, peopleByID[personID] != nil else { return [:] }

        var neighbors: [Person.ID: Set<Person.ID>] = [:]
        for person in peopleByID.values {
            var relatedIDs = Set<Person.ID>()
            relatedIDs.formUnion(person.immediateFamily.parents)
            relatedIDs.formUnion(person.immediateFamily.partners)
            relatedIDs.formUnion(person.immediateFamily.siblings)
            relatedIDs.formUnion(person.immediateFamily.children)

            for relatedID in relatedIDs where peopleByID[relatedID] != nil && relatedID != person.id {
                neighbors[person.id, default: []].insert(relatedID)
                neighbors[relatedID, default: []].insert(person.id)
            }
        }

        var distances: [Person.ID: Int] = [personID: 0]
        var queue = [personID]
        var queueIndex = 0
        while queueIndex < queue.count {
            let currentID = queue[queueIndex]
            queueIndex += 1
            let nextDistance = (distances[currentID] ?? 0) + 1

            for neighborID in neighbors[currentID, default: []] where distances[neighborID] == nil {
                distances[neighborID] = nextDistance
                queue.append(neighborID)
            }
        }

        return distances
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
        // Any death fact, including an explicitly unknown date, means the
        // person is deceased. Unknown dates are represented as "????".
        if person.deathFact != nil { return false }
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
        if let deathFact = person.deathFact {
            let normalized = deathFact.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "????" || normalized == "unknown" || normalized == "unknown date" || normalized.isEmpty {
                return false
            }
            return deathFact.value.contains { $0.isNumber }
        }

        let parts = person.lifespan.split { character in
            character == "–" || character == "—" || character == "-"
        }
        guard parts.count > 1, let deathPart = parts.last else { return false }
        return deathPart.contains { $0.isNumber }
    }

    /// Returns media owned by a person plus shared media records that reference them.
    func media(for personID: Person.ID) -> [MediaReference] {
        var result: [MediaReference] = []
        // A legacy import can contain the same asset under multiple media IDs
        // or person collections. Prefer its shared path as the identity so a
        // single photograph is shown once while still being available from
        // every tagged profile.
        var seen = Set<String>()
        for owner in document.people {
            for item in owner.media {
                let belongsToPerson = MediaMentionToken.personIDs(in: item.caption ?? "").contains(personID)
                let identity = item.path ?? item.id
                guard belongsToPerson, seen.insert(identity).inserted else { continue }
                result.append(item)
            }
        }
        return result
    }

    /// Saved media without a caption mention is intentionally absent from
    /// every profile and gallery. It remains reachable here so the user can
    /// add the missing mention or delete the record.
    func mediaNeedingMentionReview() -> [MediaMentionReviewItem] {
        var seen = Set<String>()
        var result: [MediaMentionReviewItem] = []
        for owner in document.people {
            for item in owner.media {
                let identity = item.path ?? item.id
                guard seen.insert(identity).inserted else { continue }
                let validMentions = MediaMentionToken.personIDs(in: item.caption ?? "")
                    .contains { peopleByID[$0] != nil }
                guard item.needsMentionReview == true || !validMentions else { continue }
                result.append(MediaMentionReviewItem(media: item, ownerID: owner.id))
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
        // A profile image must always be one of this person's tagged media
        // records. This prevents a stale profileImagePath (for example after
        // correcting an ambiguous @mention) from showing another person's
        // photograph on the profile.
        let collectionMedia = media(for: personID).filter { $0.kind == .photo }
        let collectionPaths = Set(collectionMedia.compactMap(\.path))
        if let cachedPath = profilePhotoPathCache[personID] {
            if collectionPaths.contains(cachedPath), resolvedFileURL(for: cachedPath) != nil {
                return cachedPath
            }
            profilePhotoPathCache.removeValue(forKey: personID)
        }
        // An explicitly selected profile image takes precedence over the
        // automatic colored/recency choice, but only while it remains in this
        // person's media collection.
        if let selectedPath = person.profileImagePath,
           collectionPaths.contains(selectedPath),
           resolvedFileURL(for: selectedPath) != nil {
            profilePhotoPathCache[personID] = selectedPath
            return selectedPath
        }
        // All candidates come from the person's tagged collection. Shared
        // media is valid when it explicitly references this person; it is not
        // a separate fallback pool.
        let candidates: [PhotoCandidate] = collectionMedia.enumerated().compactMap { index, item -> PhotoCandidate? in
            guard let path = item.path else { return nil }
            return PhotoCandidate(path: path, date: item.date, order: index)
        }

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
        guard canEdit else { return }
        var people = document.people
        guard let index = people.firstIndex(where: { $0.id == person.id }) else { return }
        people[index] = person
        replaceDocument(people: people, changedPersonIDs: [person.id])
    }

    @discardableResult
    func updateMedia(_ item: MediaReference, for ownerID: Person.ID) throws -> MediaReference {
        guard canEdit else { throw MediaUpdateError.editingUnavailable }
        var people = document.people
        // A shared media item may be opened from any tagged profile. Resolve
        // the physical record by ID, then update every tagged profile from
        // that one record. This avoids silently keeping an old copy when the
        // same-name person was selected from the @mention picker.
        guard let ownerIndex = people.firstIndex(where: { person in
            person.media.contains(where: { $0.id == item.id })
        }),
        let mediaIndex = people[ownerIndex].media.firstIndex(where: { $0.id == item.id }) else {
            throw MediaUpdateError.mediaNotFound
        }

        let previousIDs = Set(people.flatMap { person in
            person.media
                .filter { $0.id == item.id }
                .flatMap { MediaMentionToken.personIDs(in: $0.caption ?? "") }
        })
        var updatedItem = item
        let canonicalCaption = MediaMentionToken.canonicalize(
            item.caption ?? "",
            people: people,
            preferredPersonIDs: Set(item.personIDs ?? [])
        )
        let updatedIDs = Set(MediaMentionToken.personIDs(in: canonicalCaption).filter { peopleByID[$0] != nil })
        updatedItem.personIDs = Array(updatedIDs).sorted()
        updatedItem.needsMentionReview = updatedIDs.isEmpty ? true : nil
        updatedItem.caption = canonicalCaption.isEmpty ? nil : canonicalCaption
        var changedIDs = updatedIDs.union(previousIDs).union([people[ownerIndex].id, ownerID])

        for index in people.indices {
            if index == ownerIndex {
                people[index].media[mediaIndex] = updatedItem
            } else if updatedIDs.contains(people[index].id) {
                if let existingIndex = people[index].media.firstIndex(where: { $0.id == item.id }) {
                    people[index].media[existingIndex] = updatedItem
                } else {
                    people[index].media.append(updatedItem)
                }
            } else if people[index].media.contains(where: { $0.id == item.id }) {
                people[index].media.removeAll { $0.id == item.id }
            }

            // A profile image is valid only while that profile is mentioned
            // in the caption of the asset.
            if !updatedIDs.contains(people[index].id), people[index].profileImagePath == item.path {
                changedIDs.insert(people[index].id)
                people[index].profileImagePath = nil
                people[index].profileImageScale = nil
                people[index].profileImageOffsetX = nil
                people[index].profileImageOffsetY = nil
            }
        }
        let updatedDocument = FamilyArchiveDocument(
            schemaVersion: document.schemaVersion,
            title: document.title,
            accountHolderID: document.accountHolderID,
            people: people,
            familyUnions: document.familyUnions
        )
        // Persist before publishing the new document. The old implementation
        // discarded write errors, allowing the UI to appear saved while the
        // archive on disk remained unchanged.
        try privateStore.save(
            document: updatedDocument,
            changedPersonIDs: changedIDs,
            rebuildGEDCOM: true
        )
        applyDocument(updatedDocument, changedPersonIDs: changedIDs)
        return updatedItem
    }

    /// The one persistence operation used by every caption editor. The
    /// visible text is converted to immutable person-ID tokens, written to the
    /// private archive, then mirrored to the optional localization sidecar.
    func saveMediaCaption(
        _ visibleCaption: String,
        for item: MediaReference,
        ownerID: Person.ID,
        preferredPersonIDs: Set<Person.ID>,
        date: String?,
        language: ArchiveLanguage
    ) throws -> SavedMediaCaption {
        let canonicalCaption = MediaMentionToken.canonicalize(
            visibleCaption,
            people: document.people,
            preferredPersonIDs: preferredPersonIDs
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let personIDs = Set(MediaMentionToken.personIDs(in: canonicalCaption))
        let cleanedDate = date?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var updated = item
        updated.caption = canonicalCaption.isEmpty ? nil : canonicalCaption
        updated.date = cleanedDate.isEmpty ? nil : cleanedDate
        updated.personIDs = Array(personIDs).sorted()
        updated.needsMentionReview = personIDs.isEmpty ? true : nil
        let savedMedia = try updateMedia(updated, for: ownerID)

        // Localization is a secondary presentation index. A sidecar problem
        // must not undo or conceal a caption already saved in the archive.
        let targetLanguage: ArchiveLanguage = language == .english ? .russian : .english
        try? NarrativeLocalizationStore.shared.updateMediaCaption(
            mediaID: item.id,
            caption: canonicalCaption,
            language: language,
            fileManager: privateStore.fileManager
        )
        try? NarrativeLocalizationStore.shared.updateMediaCaption(
            mediaID: item.id,
            caption: "",
            language: targetLanguage,
            fileManager: privateStore.fileManager
        )
        NarrativeLocalizationStore.shared.reload(fileManager: privateStore.fileManager)

        return SavedMediaCaption(
            canonicalCaption: canonicalCaption,
            personIDs: personIDs,
            media: savedMedia
        )
    }

    func removeMedia(_ item: MediaReference, from ownerID: Person.ID) {
        guard canEdit else { return }
        var people = document.people
        // A shared image may be opened from any tagged profile. Resolve the
        // record that actually owns the media before removing it, otherwise a
        // delete from a linked profile would silently do nothing.
        guard let resolvedOwnerID = mediaOwnerID(for: item, preferredID: ownerID),
              let ownerIndex = people.firstIndex(where: { $0.id == resolvedOwnerID }) else { return }
        let relatedIDs = Set(people.flatMap { person in
            person.media
                .filter { $0.id == item.id }
                .flatMap { MediaMentionToken.personIDs(in: $0.caption ?? "") }
        })
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

        // The asset is gone from every profile, so discard all language
        // variants from the private localization sidecar as well.
        try? NarrativeLocalizationStore.shared.removeMediaCaptions(
            mediaID: item.id,
            fileManager: privateStore.fileManager
        )
        NarrativeLocalizationStore.shared.reload(fileManager: privateStore.fileManager)

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
        let updatedDocument = FamilyArchiveDocument(
            schemaVersion: document.schemaVersion,
            title: document.title,
            accountHolderID: document.accountHolderID,
            people: people,
            familyUnions: document.familyUnions
        )
        applyDocument(updatedDocument, changedPersonIDs: changedPersonIDs)
        try? privateStore.save(document: updatedDocument, changedPersonIDs: changedPersonIDs, rebuildGEDCOM: true)
    }

    private func applyDocument(
        _ updatedDocument: FamilyArchiveDocument,
        changedPersonIDs: Set<Person.ID>
    ) {
        let previousPeopleByID = peopleByID
        let profileImageChanged = changedPersonIDs.contains { personID in
            guard let previous = previousPeopleByID[personID],
                  let updated = updatedDocument.people.first(where: { $0.id == personID }) else { return false }
            return previous.profileImagePath != updated.profileImagePath ||
                previous.profileImageScale != updated.profileImageScale ||
                previous.profileImageOffsetX != updated.profileImageOffsetX ||
                previous.profileImageOffsetY != updated.profileImageOffsetY
        }
        document = updatedDocument
        peopleByID = Dictionary(uniqueKeysWithValues: updatedDocument.people.map { ($0.id, $0) })
        profilePhotoPathCache.removeAll()
        coloredPhotoCache.removeAll()
        if profileImageChanged {
            ArchiveFileResolver.invalidateImages()
        }
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

    func exportPrivateArchiveFile(
        to destinationURL: URL,
        preparedForPersonID: Person.ID? = nil,
        readOnly: Bool = true,
        fileManager: FileManager = .default
    ) throws {
        try privateStore.exportArchive(
            to: destinationURL,
            preparedForPersonID: preparedForPersonID,
            readOnly: readOnly
        )
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
            guard fileManager.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else {
                throw ArchivePackageError.incompleteArchive
            }
            let sourceStore = PrivateDocumentStore(rootURL: url, fileManager: fileManager)
            guard let document = try sourceStore.loadDocument() else { throw ArchivePackageError.emptyArchive }
            let handoff = readAccountHandoff(at: url, fileManager: fileManager)
            return ArchivePackageSummary(
                document: document,
                fileCount: countFiles(at: url, fileManager: fileManager),
                preparedAccountID: handoff?.personID
            )
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
            guard fileManager.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else {
                throw ArchivePackageError.incompleteArchive
            }
            let sourceStore = PrivateDocumentStore(rootURL: url, fileManager: fileManager)
            guard let importedDocument = try sourceStore.loadDocument() else { throw ArchivePackageError.emptyArchive }
            let handoff = readAccountHandoff(at: url, fileManager: fileManager)
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
            restoreActiveAccountAfterImport(importedDocument: importedDocument, preparedAccountID: handoff?.personID)
            // A read-only recipient may import a newer archive, but importing
            // it must never elevate that device to an editable account.
            isReadOnly = isReadOnly || (handoff?.readOnly ?? false)
            UserDefaults.standard.set(isReadOnly, forKey: Self.readOnlyModeKey)
            profilePhotoPathCache.removeAll()
            coloredPhotoCache.removeAll()
            NarrativeLocalizationStore.shared.reload(fileManager: fileManager)
            NameLocalizationStore.shared.reload(fileManager: fileManager)
            try? fileManager.removeItem(at: privateStore.rootURL.appendingPathComponent(PrivateDocumentStore.accountHandoffFilename))
            return ArchivePackageSummary(
                document: importedDocument,
                fileCount: countFiles(at: url, fileManager: fileManager),
                preparedAccountID: handoff?.personID
            )
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

    private func readAccountHandoff(at url: URL, fileManager: FileManager) -> PrivateDocumentStore.AccountHandoff? {
        let handoffURL = url.appendingPathComponent(PrivateDocumentStore.accountHandoffFilename)
        guard let data = try? Data(contentsOf: handoffURL) else { return nil }
        return try? JSONDecoder.archive.decode(PrivateDocumentStore.AccountHandoff.self, from: data)
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
        let handoff = entries[PrivateDocumentStore.accountHandoffFilename].flatMap {
            try? JSONDecoder.archive.decode(PrivateDocumentStore.AccountHandoff.self, from: $0)
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
        if let handoff, peopleByID[handoff.personID] != nil {
            setActiveAccountID(handoff.personID)
        }
        // Preserve recipient read-only mode when a later owner export has no
        // handoff marker. The recipient can refresh data without gaining edit
        // access.
        isReadOnly = isReadOnly || (handoff?.readOnly ?? false)
        UserDefaults.standard.set(isReadOnly, forKey: Self.readOnlyModeKey)
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

struct FamilyPartnerRelationship: Identifiable {
    var id: String { union.id }
    let union: FamilyUnion
    let partner: Person
    let sequence: Int?
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
    let preparedAccountID: Person.ID?
    let preparedAccountName: String?

    init(document: FamilyArchiveDocument, fileCount: Int, preparedAccountID: Person.ID? = nil) {
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
        self.preparedAccountID = preparedAccountID
        self.preparedAccountName = preparedAccountID.flatMap { id in
            document.people.first(where: { $0.id == id })?.sourceDisplayName
        }
    }
}

enum ArchivePackageError: LocalizedError {
    case missingArchiveJSON
    case emptyArchive
    case incompleteArchive
    case documentsUnavailable
    case unsupportedZip
    case invalidZip

    var errorDescription: String? {
        switch self {
        case .missingArchiveJSON: "The package does not contain family-archive.json."
        case .emptyArchive: "The package contains no people."
        case .incompleteArchive: "The private archive is incomplete. Export it again and wait for ‘Private archive saved.’ before importing."
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
        let families = document.resolvedFamilyUnions.compactMap { union -> FamilyUnion? in
            let partners = union.partnerIDs.filter { peopleByID[$0] != nil }
            let children = union.childIDs.filter { peopleByID[$0] != nil }
            guard !partners.isEmpty, !children.isEmpty || partners.count > 1 else { return nil }
            return FamilyUnion(
                id: union.id,
                partnerIDs: partners,
                childIDs: children,
                relationshipStatus: union.relationshipStatus,
                marriageDate: union.marriageDate,
                statusDate: union.statusDate,
                marriageDateIsApproximate: union.marriageDateIsApproximate,
                partnerSequence: union.partnerSequence,
                sourceFamilyID: union.sourceFamilyID,
                provenance: union.provenance
            )
        }
        .sorted { $0.id < $1.id }

        var familiesForPerson: [String: [String]] = [:]
        var childFamilyForPerson: [String: [String]] = [:]
        for family in families {
            for partnerID in family.partnerIDs { familiesForPerson[partnerID, default: []].append(family.id) }
            for childID in family.childIDs { childFamilyForPerson[childID, default: []].append(family.id) }
        }

        var lines = ["0 HEAD", "1 SOUR FamilyArchive", "1 CHAR UTF-8", "1 GEDC", "2 VERS 5.5.1", "0 @U1@ SUBM", "1 NAME Family Archive"]
        for person in document.people.sorted(by: { $0.id < $1.id }) {
            lines.append("0 @\(person.id)@ INDI")
            let given = gedcomSafe(person.givenName)
            let family = gedcomSafe(person.familyName)
            let name = family.isEmpty ? given : "\(given) /\(family)/"
            lines.append("1 NAME \(name.isEmpty ? "Unknown" : name)")
            if let sex = gedcomSex(person.archiveGender) { lines.append("1 SEX \(sex)") }
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

        for family in families {
            lines.append("0 @\(family.id)@ FAM")
            let roles = gedcomPartnerRoles(family.partnerIDs, peopleByID: peopleByID)
            if let husband = roles.husband { lines.append("1 HUSB @\(husband)@") }
            if let wife = roles.wife { lines.append("1 WIFE @\(wife)@") }
            for childID in family.childIDs { lines.append("1 CHIL @\(childID)@") }
            if let marriageDate = family.marriageDate, !marriageDate.isEmpty {
                lines.append("1 MARR")
                lines.append("2 DATE \(gedcomSafe(marriageDate))")
            } else if family.relationshipStatus?.lowercased() == "married" {
                lines.append("1 MARR")
            }
            if family.relationshipStatus?.lowercased() == "divorced" {
                lines.append("1 DIV")
                if let statusDate = family.statusDate, !statusDate.isEmpty {
                    lines.append("2 DATE \(gedcomSafe(statusDate))")
                }
            }
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
                    owner.media.filter {
                        $0.kind == .photo && MediaMentionToken.personIDs(in: $0.caption ?? "").contains(id)
                    }.compactMap(\.path)
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

    private func gedcomSex(_ gender: ArchiveGender) -> String? {
        switch gender {
        case .male: "M"
        case .female: "F"
        case .unknown: nil
        }
    }

    private func gedcomPartnerRoles(
        _ partnerIDs: [Person.ID],
        peopleByID: [Person.ID: Person]
    ) -> (husband: Person.ID?, wife: Person.ID?) {
        var husband: Person.ID?
        var wife: Person.ID?
        for partnerID in partnerIDs {
            switch peopleByID[partnerID]?.archiveGender ?? .unknown {
            case .male where husband == nil: husband = partnerID
            case .female where wife == nil: wife = partnerID
            default:
                if husband == nil { husband = partnerID }
                else if wife == nil { wife = partnerID }
            }
        }
        return (husband, wife)
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
