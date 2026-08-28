import Foundation

enum ArchiveLanguage: String, CaseIterable, Identifiable, Hashable {
    case english = "en"
    case russian = "ru"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .english: "English"
        case .russian: "Русский"
        }
    }

    static var current: ArchiveLanguage {
        ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? ArchiveLanguage.russian.rawValue) ?? .russian
    }
}

private struct NameLocalizationDocument: Codable {
    let approvedNames: [NameLocalization]
}

private struct NameLocalization: Codable {
    let personID: String
    let original: String
    let localizedNames: [String: String]
}

private struct NarrativeLocalizationDocument: Codable {
    /// Narrative text remains person-scoped, while media captions are shared
    /// by media ID so every tagged profile reads the same localized record.
    var people: [String: NarrativePersonLocalization]
    var media: [String: NarrativeMediaLocalization]

    private enum CodingKeys: String, CodingKey {
        case people
        case media
    }

    init(
        people: [String: NarrativePersonLocalization] = [:],
        media: [String: NarrativeMediaLocalization] = [:]
    ) {
        self.people = people
        self.media = media
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        people = try container.decodeIfPresent([String: NarrativePersonLocalization].self, forKey: .people) ?? [:]
        media = try container.decodeIfPresent([String: NarrativeMediaLocalization].self, forKey: .media) ?? [:]
    }
}

private struct NarrativePersonLocalization: Codable {
    var summary: String?
    var biography: String?
    var stories: [String: NarrativeStoryLocalization]?
    var events: [String: NarrativeEventLocalization]?
    var media: [String: NarrativeMediaLocalization]?
}

private struct NarrativeStoryLocalization: Codable {
    var title: String?
    var summary: String?
    var body: String?
}

private struct NarrativeEventLocalization: Codable {
    var title: String?
    var summary: String?
}

private struct NarrativeMediaLocalization: Codable {
    var title: String?
    var caption: String?
    /// Captions translated into a locale other than the source locale. The
    /// older `caption` field remains the English value for backward
    /// compatibility with existing private sidecars.
    var captionTranslations: [String: String]?
}

/// Reads private narrative translations. Media captions are centrally keyed by
/// media ID; the old person-scoped media entries are read once and flattened
/// during load for backward compatibility with earlier private exports.
final class NarrativeLocalizationStore {
    nonisolated(unsafe) static let shared = NarrativeLocalizationStore()

    private var people: [String: NarrativePersonLocalization] = [:]
    private var mediaByID: [String: NarrativeMediaLocalization] = [:]

    private init() {
        reload()
    }

    func reload(fileManager: FileManager = .default, bundle: Bundle = .main) {
        let candidateURLs: [URL] = [
            // The persistent private store is authoritative. Earlier builds
            // also left a legacy copy at Documents/; prefer the store so a
            // caption edit cannot be masked by that stale sidecar.
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("FamilyArchiveStore/PrivateData/narrative-translations.private.json"),
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("narrative-translations.private.json"),
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("PrivateData/narrative-translations.private.json"),
            bundle.url(forResource: "narrative-translations.private", withExtension: "json")
        ].compactMap { $0 }

        for url in candidateURLs {
            guard let data = try? Data(contentsOf: url),
                  let document = try? JSONDecoder().decode(NarrativeLocalizationDocument.self, from: data) else {
                continue
            }
            let hasLegacyMedia = document.media.isEmpty && document.people.values.contains { $0.media?.isEmpty == false }
            people = document.people
            mediaByID = document.media
            if mediaByID.isEmpty {
                mediaByID = Self.flattenLegacyMedia(from: people)
            }
            // Do not keep the denormalized person-scoped media copy in memory;
            // all subsequent writes use the centralized media dictionary.
            for personID in people.keys {
                people[personID]?.media = nil
            }
            if hasLegacyMedia {
                try? persist(fileManager: fileManager)
            }
            return
        }

        people = [:]
        mediaByID = [:]
    }

    private static func flattenLegacyMedia(
        from people: [String: NarrativePersonLocalization]
    ) -> [String: NarrativeMediaLocalization] {
        var result: [String: NarrativeMediaLocalization] = [:]
        for person in people.values {
            for (mediaID, legacyRecord) in person.media ?? [:] {
                guard var record = result[mediaID] else {
                    result[mediaID] = legacyRecord
                    continue
                }

                if let caption = legacyRecord.caption,
                   Self.captionQuality(caption) > Self.captionQuality(record.caption ?? "") {
                    // Legacy exports could contain one copy of a shared
                    // photo per person. Keep the most informative caption,
                    // rather than whichever duplicate happened to be read
                    // first. This prevents a short/ambiguous @mention copy
                    // from replacing the original descriptive caption.
                    record.caption = caption
                }
                var translations = record.captionTranslations ?? [:]
                for (language, value) in legacyRecord.captionTranslations ?? [:]
                    where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if Self.captionQuality(value) > Self.captionQuality(translations[language] ?? "") {
                        translations[language] = value
                    }
                }
                record.captionTranslations = translations.isEmpty ? nil : translations
                result[mediaID] = record
            }
        }
        return result
    }

    private static func captionQuality(_ value: String) -> Int {
        // Ignore implementation-only person markers when comparing legacy
        // copies; the remaining letters/numbers approximate how much actual
        // descriptive text the caption contains.
        let prose = value.replacingOccurrences(
            of: #"\[\[person:[^\]]+\]\]"#,
            with: "",
            options: .regularExpression
        )
        return prose.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.alphanumerics.contains(scalar) { count += 1 }
        }
    }

    private func persist(fileManager: FileManager) throws {
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let destination = documentsURL
            .appendingPathComponent("FamilyArchiveStore", isDirectory: true)
            .appendingPathComponent("PrivateData", isDirectory: true)
            .appendingPathComponent("narrative-translations.private.json")
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        var normalizedPeople = people
        for personID in normalizedPeople.keys {
            normalizedPeople[personID]?.media = nil
        }
        let document = NarrativeLocalizationDocument(people: normalizedPeople, media: mediaByID)
        let data = try JSONEncoder().encode(document)
        try data.write(to: destination, options: Data.WritingOptions.atomic)
    }

    func personSummary(_ personID: String, source: String) -> String {
        localized(source: source, translation: people[personID]?.summary, pending: "English summary pending")
    }

    func personBiography(_ personID: String, source: String) -> String {
        localized(source: source, translation: people[personID]?.biography, pending: "English biography pending")
    }

    func storyTitle(_ personID: String, storyID: String, source: String) -> String {
        localized(source: source, translation: people[personID]?.stories?[storyID]?.title, pending: "English title pending")
    }

    func storySummary(_ personID: String, storyID: String, source: String) -> String {
        localized(source: source, translation: people[personID]?.stories?[storyID]?.summary, pending: "English summary pending")
    }

    func storyBody(_ personID: String, storyID: String, source: String) -> String {
        localized(source: source, translation: people[personID]?.stories?[storyID]?.body, pending: "English story pending")
    }

    func eventTitle(_ personID: String, eventID: String, source: String) -> String {
        localized(source: source, translation: people[personID]?.events?[eventID]?.title, pending: "English event title pending")
    }

    func eventSummary(_ personID: String, eventID: String, source: String) -> String {
        localized(source: source, translation: people[personID]?.events?[eventID]?.summary, pending: "English event description pending")
    }

    func mediaTitle(mediaID: String, source: String) -> String {
        localized(source: source, translation: mediaByID[mediaID]?.title, pending: "English title pending")
    }

    func mediaCaption(
        mediaID: String,
        language: ArchiveLanguage = .current,
        source: String
    ) -> String {
        let record = mediaByID[mediaID]
        let expectedPersonIDs = Set(MediaMentionToken.personIDs(in: source))
        let localeTranslation = record?.captionTranslations?[language.rawValue]
        if let localeTranslation,
           !localeTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           Set(MediaMentionToken.personIDs(in: localeTranslation)) == expectedPersonIDs {
            return localeTranslation
        }
        if language == .english,
           let legacyEnglishCaption = record?.caption,
           !legacyEnglishCaption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           Set(MediaMentionToken.personIDs(in: legacyEnglishCaption)) == expectedPersonIDs {
            return legacyEnglishCaption
        }
        return source
    }

    func storedMediaCaption(mediaID: String, source: String) -> String? {
        let expectedPersonIDs = Set(MediaMentionToken.personIDs(in: source))
        guard let caption = mediaByID[mediaID]?.caption,
              Set(MediaMentionToken.personIDs(in: caption)) == expectedPersonIDs else { return nil }
        return caption
    }

    /// Upgrades legacy visible `@Name` captions to ID-backed mention tokens.
    /// The migration is intentionally private-store-only and is idempotent;
    /// original archive files are never changed.
    @discardableResult
    func migrateMediaMentions(
        people: [Person],
        fileManager: FileManager = .default
    ) -> Bool {
        var preferredIDsByMediaID: [String: Set<Person.ID>] = [:]
        var authoritativeIDsByMediaID: [String: Set<Person.ID>] = [:]
        for person in people {
            for media in person.media {
                preferredIDsByMediaID[media.id, default: []].formUnion(media.personIDs ?? [person.id])
                authoritativeIDsByMediaID[media.id, default: []].formUnion(
                    MediaMentionToken.personIDs(in: media.caption ?? "")
                )
            }
        }

        var changed = false
        for mediaID in mediaByID.keys {
            guard var record = mediaByID[mediaID] else { continue }
            let preferredIDs = preferredIDsByMediaID[mediaID] ?? []
            let authoritativeIDs = authoritativeIDsByMediaID[mediaID] ?? []
            if let caption = record.caption {
                var normalizedCaption = caption
                if MediaMentionToken.hasUnstructuredMention(in: caption) {
                    normalizedCaption = MediaMentionToken.canonicalize(caption, people: people, preferredPersonIDs: preferredIDs)
                }
                if Set(MediaMentionToken.personIDs(in: normalizedCaption)) != authoritativeIDs {
                    normalizedCaption = ""
                }
                if normalizedCaption != caption {
                    record.caption = normalizedCaption.isEmpty ? nil : normalizedCaption
                    changed = true
                }
            }
            if var translations = record.captionTranslations {
                for language in translations.keys {
                    guard let caption = translations[language] else { continue }
                    var normalizedCaption = caption
                    if MediaMentionToken.hasUnstructuredMention(in: caption) {
                        normalizedCaption = MediaMentionToken.canonicalize(caption, people: people, preferredPersonIDs: preferredIDs)
                    }
                    if Set(MediaMentionToken.personIDs(in: normalizedCaption)) != authoritativeIDs {
                        normalizedCaption = ""
                    }
                    if normalizedCaption != caption {
                        translations[language] = normalizedCaption.isEmpty ? nil : normalizedCaption
                        changed = true
                    }
                }
                record.captionTranslations = translations
            }
            mediaByID[mediaID] = record
        }
        if changed {
            try? persist(fileManager: fileManager)
        }
        return changed
    }

    /// Persists one locale of a centralized media caption. The media record's
    /// personIDs field supplies the profile references; no person-specific
    /// caption copies are created.
    func updateMediaCaption(
        mediaID: String,
        caption: String,
        language: ArchiveLanguage = .english,
        expectedPersonIDs: Set<Person.ID>,
        fileManager: FileManager = .default
    ) throws {
        let value = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty || Set(MediaMentionToken.personIDs(in: value)) == expectedPersonIDs else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        var record = mediaByID[mediaID] ?? NarrativeMediaLocalization(title: nil, caption: nil, captionTranslations: nil)
        var translations = record.captionTranslations ?? [:]
        translations[language.rawValue] = value.isEmpty ? nil : value
        record.captionTranslations = translations.isEmpty ? nil : translations
        // Keep the legacy field populated for English so older builds and
        // exports continue to display the translated caption.
        if language == .english {
            record.caption = value.isEmpty ? nil : value
        }
        mediaByID[mediaID] = record
        try persist(fileManager: fileManager)
    }

    /// Removes every localized caption record for a media item. Media IDs are
    /// shared across tagged profiles, so deleting the asset must also remove
    /// its private localization entries; otherwise an export can retain
    /// captions for a media file that no longer exists.
    func removeMediaCaptions(
        mediaID: String,
        fileManager: FileManager = .default
    ) throws {
        guard mediaByID.removeValue(forKey: mediaID) != nil else { return }
        try persist(fileManager: fileManager)
    }

    private func localized(source: String, translation: String?, pending: String) -> String {
        let language = ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? ArchiveLanguage.russian.rawValue) ?? .russian
        guard language == .english else { return source }
        if let translation, !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return translation
        }
        if source.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil {
            return pending
        }
        return source
    }
}

/// Reads the user-approved name variants from the private app data area.
/// This file is deliberately not bundled with the source-controlled app.
final class NameLocalizationStore {
    nonisolated(unsafe) static let shared = NameLocalizationStore()

    private var namesByID: [String: NameLocalization] = [:]

    private init() {
        reload()
    }

    func reload(fileManager: FileManager = .default, bundle: Bundle = .main) {
        let candidateURLs: [URL] = [
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("FamilyArchiveStore/PrivateData/name-localizations.private.json"),
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("PrivateData/name-localizations.private.json"),
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("name-localizations.private.json"),
            bundle.url(forResource: "name-localizations.private", withExtension: "json")
        ].compactMap { $0 }

        for url in candidateURLs {
            guard let data = try? Data(contentsOf: url),
                  let document = try? JSONDecoder().decode(NameLocalizationDocument.self, from: data) else {
                continue
            }
            namesByID = Dictionary(uniqueKeysWithValues: document.approvedNames.map { ($0.personID, $0) })
            return
        }

        namesByID = [:]
    }

    /// Updates only the selected locale in the private name sidecar. The
    /// source/original name remains unchanged unless the Russian/source
    /// locale is being edited.
    func update(
        personID: String,
        original: String,
        localizedName: String,
        language: ArchiveLanguage,
        counterpart: String? = nil,
        fileManager: FileManager = .default
    ) throws {
        let trimmedName = localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let existing = namesByID[personID]
        var localizedNames = existing?.localizedNames ?? [:]
        localizedNames[language.rawValue] = trimmedName
        if let counterpart {
            let trimmedCounterpart = counterpart.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedCounterpart.isEmpty {
                let counterpartLanguage: ArchiveLanguage = language == .russian ? .english : .russian
                localizedNames[counterpartLanguage.rawValue] = trimmedCounterpart
            }
        }
        let sourceName = language == .russian ? trimmedName : (existing?.original ?? original)
        let updated = NameLocalization(personID: personID, original: sourceName, localizedNames: localizedNames)
        namesByID[personID] = updated

        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let destination = documentsURL
            .appendingPathComponent("FamilyArchiveStore", isDirectory: true)
            .appendingPathComponent("PrivateData", isDirectory: true)
            .appendingPathComponent("name-localizations.private.json")
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let data = try JSONEncoder().encode(NameLocalizationDocument(
            approvedNames: namesByID.values.sorted { $0.personID < $1.personID }
        ))
        try data.write(to: destination, options: .atomic)
    }

    func localizedName(for personID: String, language: ArchiveLanguage) -> String? {
        namesByID[personID]?.localizedNames[language.rawValue]
    }

    func suggestedCounterpart(for name: String, language: ArchiveLanguage) -> String {
        language == .russian ? Self.transliterate(name) : Self.reverseTransliterate(name)
    }

    private static func transliterate(_ value: String) -> String {
        let map: [Character: String] = [
            "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo",
            "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
            "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
            "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
            "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya"
        ]

        return value.map { character in
            let lower = String(character).lowercased()
            guard let replacement = map[Character(lower)] else { return String(character) }
            return character.isUppercase ? replacement.capitalized : replacement
        }.joined()
    }

    private static func reverseTransliterate(_ value: String) -> String {
        let digraphs: [(String, String)] = [
            ("shch", "щ"), ("sch", "щ"), ("yo", "ё"), ("zh", "ж"), ("kh", "х"),
            ("ts", "ц"), ("ch", "ч"), ("sh", "ш"), ("yu", "ю"), ("ya", "я")
        ]
        let singles: [Character: String] = [
            "a": "а", "b": "б", "c": "к", "d": "д", "e": "е", "f": "ф", "g": "г",
            "h": "х", "i": "и", "j": "й", "k": "к", "l": "л", "m": "м", "n": "н",
            "o": "о", "p": "п", "q": "к", "r": "р", "s": "с", "t": "т", "u": "у",
            "v": "в", "w": "в", "x": "кс", "y": "й", "z": "з"
        ]

        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            let remaining = value[index...].lowercased()
            if let match = digraphs.first(where: { remaining.hasPrefix($0.0) }) {
                let end = value.index(index, offsetBy: match.0.count)
                let source = value[index..<end]
                result += source.first?.isUppercase == true ? match.1.capitalized : match.1
                index = end
                continue
            }

            let character = value[index]
            let lower = Character(String(character).lowercased())
            if let replacement = singles[lower] {
                result += character.isUppercase ? replacement.capitalized : replacement
            } else {
                result.append(character)
            }
            index = value.index(after: index)
        }
        return result
    }

    func displayName(for personID: String, fallback: String, language: ArchiveLanguage? = nil) -> String {
        if namesByID.isEmpty {
            reload()
        }
        let selectedLanguage = language ?? ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: Self.appLanguageKey) ?? ArchiveLanguage.russian.rawValue) ?? .russian
        if let localized = namesByID[personID]?.localizedNames[selectedLanguage.rawValue],
           !localized.isEmpty {
            return localizedUnknownName(localized, language: selectedLanguage)
        }
        // Older private archives used the English literal "Unknown" for an
        // unnamed given name. Keep those archives readable and make the
        // placeholder follow the app language without changing the person ID.
        return localizedUnknownName(fallback, language: selectedLanguage)
    }

    private func localizedUnknownName(_ value: String, language: ArchiveLanguage) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        let russianPlaceholder = "неизвестное имя"
        let isUnknown = normalized == "unknown" ||
            normalized.hasPrefix("unknown ") ||
            normalized == russianPlaceholder ||
            normalized.hasPrefix(russianPlaceholder + " ")
        guard isUnknown else { return value }

        let placeholder = language == .russian ? "Неизвестное имя" : "Unknown name"
        let suffix: String
        if normalized == "unknown" || normalized == russianPlaceholder {
            suffix = ""
        } else if normalized.hasPrefix("unknown ") {
            suffix = String(trimmed.dropFirst("Unknown ".count))
        } else {
            suffix = String(trimmed.dropFirst(russianPlaceholder.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return suffix.isEmpty ? placeholder : "\(placeholder) \(suffix)"
    }

    static let appLanguageKey = "familyArchive.appLanguage"

    func originalName(for personID: String, fallback: String) -> String {
        if namesByID.isEmpty {
            reload()
        }
        return namesByID[personID]?.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? namesByID[personID]!.original
            : fallback
    }

    func localizedFamilyName(for familyName: String) -> String? {
        if namesByID.isEmpty {
            reload()
        }

        let source = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        let language = ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: Self.appLanguageKey) ?? ArchiveLanguage.russian.rawValue) ?? .russian

        for record in namesByID.values {
            guard let originalSurname = record.original.split(separator: " ").last.map(String.init),
                  originalSurname.localizedCaseInsensitiveCompare(source) == .orderedSame,
                  let localized = record.localizedNames[language.rawValue],
                  let localizedSurname = localized.split(separator: " ").last.map(String.init) else {
                continue
            }
            return localizedSurname
        }
        return nil
    }

    func localizeEmbeddedNames(in text: String) -> String {
        if namesByID.isEmpty {
            reload()
        }

        let language = ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: Self.appLanguageKey) ?? ArchiveLanguage.russian.rawValue) ?? .russian
        return namesByID.values
            .sorted { $0.original.count > $1.original.count }
            .reduce(text) { result, record in
                let localized = record.localizedNames[language.rawValue] ?? record.original
                return Set([record.original] + Array(record.localizedNames.values))
                    .filter { !$0.isEmpty }
                    .sorted { $0.count > $1.count }
                    .reduce(result) { partial, variant in
                        partial.replacingOccurrences(of: variant, with: localized)
                    }
            }
    }
}

enum ArchiveGender {
    case female
    case male
    case unknown
}

enum ArchiveLanguageValidator {
    static func issue(language: ArchiveLanguage, fields: [(label: String, value: String)], unchanged: [String: String] = [:]) -> String? {
        for field in fields {
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value != unchanged[field.label] else { continue }
            let hasCyrillic = value.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil
            let hasLatin = value.range(of: "[A-Za-z]", options: .regularExpression) != nil

            if language == .russian, hasLatin {
                return "Поле «\(messageLabel(field.label, language: language))» должно быть на русском языке."
            }
            if language == .english, hasCyrillic {
                return "The “\(messageLabel(field.label, language: language))” field must be in English."
            }
        }
        return nil
    }

    private static func messageLabel(_ label: String, language: ArchiveLanguage) -> String {
        guard language == .russian else { return label }
        switch label {
        case "First name": return "Имя"
        case "Last name": return "Фамилия"
        case "Also known as": return "Другие имена"
        case "Full date": return "Полная дата"
        case "Birth date": return "Дата рождения"
        case "Birth place": return "Место рождения"
        case "Death date": return "Дата смерти"
        case "Death place": return "Место смерти"
        case "Place": return "Место"
        case "Title": return "Заголовок"
        case "Description": return "Описание"
        case "Caption": return "Подпись"
        case "Highlight": return "Выделение"
        case "Body": return "Текст"
        default: return label
        }
    }
}

enum ArchiveCopy {
    static func text(english: String, russian: String) -> String {
        let language = ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? ArchiveLanguage.russian.rawValue) ?? .russian
        return language == .russian ? russian : english
    }

    static func countdown(days: Int) -> String {
        let remaining = max(0, days)
        if remaining == 0 {
            return text(english: "Today", russian: "Сегодня")
        }

        let language = ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? ArchiveLanguage.russian.rawValue) ?? .russian
        guard language == .russian else {
            return remaining == 1 ? "In 1 day" : "In \(remaining) days"
        }

        let lastTwo = remaining % 100
        let last = remaining % 10
        let unit: String
        if (11...14).contains(lastTwo) {
            unit = "дней"
        } else {
            switch last {
            case 1: unit = "день"
            case 2...4: unit = "дня"
            default: unit = "дней"
            }
        }
        return "Через \(remaining) \(unit)"
    }

    static func relationshipLabel(_ value: String, gender: ArchiveGender = .unknown) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "me", "you": return text(english: "You", russian: "Вы")
        case "parent": return gendered(englishMale: "Father", englishFemale: "Mother", englishNeutral: "Parent", russianMale: "Отец", russianFemale: "Мать", russianNeutral: "Родитель", gender: gender)
        case "child": return gendered(englishMale: "Son", englishFemale: "Daughter", englishNeutral: "Child", russianMale: "Сын", russianFemale: "Дочь", russianNeutral: "Ребёнок", gender: gender)
        case "grandfather": return text(english: "Grandfather", russian: "Дедушка")
        case "grandmother": return text(english: "Grandmother", russian: "Бабушка")
        case "grandparent": return text(english: "Grandparent", russian: "Бабушка или дедушка")
        case "sibling": return text(english: "Sibling", russian: "Брат или сестра")
        case "spouse": return gendered(englishMale: "Husband", englishFemale: "Wife", englishNeutral: "Spouse", russianMale: "Супруг", russianFemale: "Супруга", russianNeutral: "Партнёр", gender: gender)
        default: return value
        }
    }

    static func gendered(englishMale: String, englishFemale: String, englishNeutral: String, russianMale: String, russianFemale: String, russianNeutral: String, gender: ArchiveGender) -> String {
        let language = ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? ArchiveLanguage.russian.rawValue) ?? .russian
        switch (language, gender) {
        case (.english, .male): return englishMale
        case (.english, .female): return englishFemale
        case (.russian, .male): return russianMale
        case (.russian, .female): return russianFemale
        case (.english, .unknown): return englishNeutral
        case (.russian, .unknown): return russianNeutral
        }
    }

    static func spouseLabel(gender: ArchiveGender) -> String {
        gendered(englishMale: "Husband", englishFemale: "Wife", englishNeutral: "Spouse", russianMale: "Супруг", russianFemale: "Супруга", russianNeutral: "Супруги", gender: gender)
    }

    static func relationshipStatus(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "married": return text(english: "Married", russian: "В браке")
        case "divorced": return text(english: "Divorced", russian: "В разводе")
        case "separated": return text(english: "Separated", russian: "Раздельно")
        case "partner": return text(english: "Partners", russian: "Партнёры")
        case "widowed": return text(english: "Widowed", russian: "Вдовство")
        default: return value
        }
    }

    static func livingLabel(gender: ArchiveGender) -> String {
        gendered(englishMale: "Living", englishFemale: "Living", englishNeutral: "Living", russianMale: "Жив", russianFemale: "Жива", russianNeutral: "Жив", gender: gender)
    }

    static func factLabel(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "born", "birth": return text(english: "Born", russian: "Рождение")
        case "died", "death": return text(english: "Died", russian: "Смерть")
        case "education": return text(english: "Education", russian: "Образование")
        case "occupation": return text(english: "Occupation", russian: "Род занятий")
        case "residence": return text(english: "Residence", russian: "Место жительства")
        case "languages": return text(english: "Languages", russian: "Языки")
        case "known for": return text(english: "Known for", russian: "Известен благодаря")
        case "archive status": return text(english: "Archive status", russian: "Статус архива")
        default: return value
        }
    }

    /// Displays place names in the selected app language without changing the
    /// original place stored in the archive. The approved mappings live in
    /// Resources/archive-locales.json so new locales do not require view code.
    static func place(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let language = ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? ArchiveLanguage.russian.rawValue) ?? .russian
        if let translated = ArchiveLocalizationStore.shared.place(trimmed, language: language) {
            return translated
        }

        return ArchiveLocalizationStore.shared.replacePlaceFragments(in: trimmed, language: language)
    }

    static func familyName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? ArchiveLanguage.russian.rawValue) ?? .russian
        guard language == .english else {
            switch trimmed.lowercased() {
            case "fedotova": return "Федотов"
            default: return trimmed
            }
        }

        switch trimmed.lowercased() {
        case "fedotova", "федотов", "федотова": return "Fedotov"
        case "saparov", "сапаров", "сапарова": return "Saparov"
        case "юмашев": return "Yumashev"
        default: return trimmed
        }
    }

    static func eventTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        let language = ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? ArchiveLanguage.russian.rawValue) ?? .russian

        if let translated = ArchiveLocalizationStore.shared.eventTitle(trimmed, language: language) {
            return localizeNames(translated)
        }
        if lowercased == "born" || lowercased == "birth" {
            return ArchiveLocalizationStore.shared.eventTitle("birth", language: language)
                ?? text(english: "Born", russian: "Рождение")
        }
        if lowercased == "died" || lowercased == "death" {
            return ArchiveLocalizationStore.shared.eventTitle("death", language: language)
                ?? text(english: "Died", russian: "Смерть")
        }
        if lowercased.hasPrefix("married ") {
            let name = String(trimmed.dropFirst("Married ".count))
            let marriageLabel = ArchiveLocalizationStore.shared.eventTitle("married", language: language)
                ?? text(english: "Married", russian: "Брак")
            return localizeNames(marriageLabel + " " + name)
        }
        if lowercased == "married" {
            return ArchiveLocalizationStore.shared.eventTitle("married", language: language)
                ?? text(english: "Married", russian: "Брак")
        }
        return trimmed
    }

    static func eventSummary(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? ArchiveLanguage.russian.rawValue) ?? .russian
        guard language == .russian else { return trimmed }

        let lowercased = trimmed.lowercased()
        let birthSuffix = " was born."
        if lowercased.hasSuffix(birthSuffix) {
            let subject = String(trimmed.dropLast(birthSuffix.count))
            return subject + (feminineSubject(subject) ? " родилась." : " родился.")
        }

        let deathSuffix = " died."
        if lowercased.hasSuffix(deathSuffix) {
            let subject = String(trimmed.dropLast(deathSuffix.count))
            return subject + (feminineSubject(subject) ? " умерла." : " умер.")
        }

        if let range = trimmed.range(of: " married ", options: .caseInsensitive) {
            let subject = String(trimmed[..<range.lowerBound])
            let spouse = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return subject + (feminineSubject(subject) ? " вступила в брак с " : " вступил в брак с ") + spouse
        }

        return trimmed
    }

    private static func feminineSubject(_ value: String) -> Bool {
        let words = value.split(whereSeparator: { $0 == " " || $0 == "\u{2019}" })
        let givenName = words.first.map(String.init)?.lowercased() ?? ""
        let familyName = words.last.map(String.init)?.lowercased() ?? ""
        return givenName.hasSuffix("а") || givenName.hasSuffix("я") ||
            familyName.hasSuffix("ова") || familyName.hasSuffix("ева") || familyName.hasSuffix("ина")
    }

    private static func localizeNames(_ value: String) -> String {
        NameLocalizationStore.shared.localizeEmbeddedNames(in: value)
    }
}

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

    static func display(_ value: String?, language: ArchiveLanguage? = nil) -> String? {
        guard let value else { return nil }
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s*[-–—]\s*$"#, with: "", options: .regularExpression)
        guard !trimmed.isEmpty else { return nil }

        if isUnknownDate(trimmed) {
            return "????"
        }

        let selectedLanguage = language ?? (ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? ArchiveLanguage.russian.rawValue) ?? .russian)
        for localeIdentifier in ["en_US_POSIX", "ru_RU"] {
            let inputFormatter = DateFormatter()
            inputFormatter.locale = Locale(identifier: localeIdentifier)
            for format in inputFormats {
                inputFormatter.dateFormat = format
                if let date = inputFormatter.date(from: trimmed) {
                    let localizedFormatter = DateFormatter()
                    localizedFormatter.locale = Locale(identifier: selectedLanguage == .russian ? "ru_RU" : "en_US_POSIX")
                    if format == "MMMM yyyy" || format == "MMM yyyy" {
                        localizedFormatter.dateFormat = selectedLanguage == .russian ? "LLLL yyyy" : "MMM yyyy"
                    } else {
                        localizedFormatter.dateFormat = selectedLanguage == .russian ? "d MMMM yyyy" : "MMM d, yyyy"
                    }
                    return localizedFormatter.string(from: date)
                }
            }
        }

        return trimmed
    }

    /// Normalizes date ranges everywhere they are shown. Source data has
    /// historically used em dashes, en dashes, and inconsistent spacing;
    /// presentation always uses `start - end`.
    static func displayRange(_ value: String?, language: ArchiveLanguage? = nil) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isUnknownDate(trimmed) {
            return "????"
        }

        // Some imported lifespan values contain two bare years separated by
        // whitespace rather than a dash. Treat that as a range, while leaving
        // full dates such as "16 Feb 1912" untouched.
        let yearParts = trimmed.split(whereSeparator: { $0.isWhitespace })
        if yearParts.count == 2,
           yearParts.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isNumber) }) {
            return "\(yearParts[0]) - \(yearParts[1])"
        }

        let normalized = trimmed.replacingOccurrences(of: #"\s*[–—-]\s*"#, with: " - ", options: .regularExpression)
        let parts = normalized.components(separatedBy: " - ")
        guard parts.count == 2 else {
            return display(trimmed, language: language) ?? normalized
        }

        let start = display(parts[0], language: language) ?? parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let endValue = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        // A trailing separator denotes an open-ended lifespan; the family
        // row supplies the separate Living status, so keep only the start.
        guard !endValue.isEmpty else { return start }
        let end = display(endValue, language: language) ?? endValue
        return "\(start) - \(end)"
    }

    private static func isUnknownDate(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[.!]$"#, with: "", options: .regularExpression)
        return normalized == "????" ||
            normalized == "unknown" ||
            normalized == "unknown date" ||
            normalized == "date unknown" ||
            normalized.contains("дата неизвест") ||
            normalized.contains("дата неизв")
    }
}

struct FamilyArchiveDocument: Codable {
    let schemaVersion: Int
    let title: String
    let accountHolderID: Person.ID?
    let people: [Person]
    /// Canonical couple/family records. Older archives omit this field and
    /// continue to use the person-scoped immediate-family compatibility index.
    /// New stores persist the same records separately as `family-unions.json`.
    let familyUnions: [FamilyUnion]?

    init(
        schemaVersion: Int,
        title: String,
        accountHolderID: Person.ID?,
        people: [Person],
        familyUnions: [FamilyUnion]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.title = title
        self.accountHolderID = accountHolderID
        self.people = people
        self.familyUnions = familyUnions
    }
}

/// One explicit spouse/partner union and the children who belong to that
/// union. Parentage and partnership are intentionally stored together here so
/// a later spouse cannot accidentally become a parent of an earlier child.
struct FamilyUnion: Codable, Identifiable, Hashable {
    let id: String
    let partnerIDs: [Person.ID]
    let childIDs: [Person.ID]
    let relationshipStatus: String?
    let marriageDate: String?
    let statusDate: String?
    let marriageDateIsApproximate: Bool?
    /// Per-person ordinal for display such as first, second, or third spouse.
    /// A union can be first for one partner and second for the other.
    let partnerSequence: [Person.ID: Int]?
    let sourceFamilyID: String?
    let provenance: String?
    /// Relationship events belong to the union rather than either partner.
    /// `sourcePersonID` and `sourceEventID` preserve access to older private
    /// narrative translations after duplicate spouse records are consolidated.
    let events: [FamilyEventRecord]?

    init(
        id: String,
        partnerIDs: [Person.ID],
        childIDs: [Person.ID] = [],
        relationshipStatus: String? = nil,
        marriageDate: String? = nil,
        statusDate: String? = nil,
        marriageDateIsApproximate: Bool? = nil,
        partnerSequence: [Person.ID: Int]? = nil,
        sourceFamilyID: String? = nil,
        provenance: String? = nil,
        events: [FamilyEventRecord]? = nil
    ) {
        self.id = id
        self.partnerIDs = Array(Set(partnerIDs)).sorted()
        self.childIDs = Array(Set(childIDs)).sorted()
        self.relationshipStatus = relationshipStatus
        self.marriageDate = marriageDate
        self.statusDate = statusDate
        self.marriageDateIsApproximate = marriageDateIsApproximate
        self.partnerSequence = partnerSequence
        self.sourceFamilyID = sourceFamilyID
        self.provenance = provenance
        self.events = events
    }
}

struct FamilyEventRecord: Codable, Identifiable, Hashable {
    let id: String
    var event: LifeEvent
    let sourcePersonID: Person.ID?
    let sourceEventID: LifeEvent.ID?
}

extension FamilyUnion {
    func replacing(events: [FamilyEventRecord]?) -> FamilyUnion {
        FamilyUnion(
            id: id,
            partnerIDs: partnerIDs,
            childIDs: childIDs,
            relationshipStatus: relationshipStatus,
            marriageDate: marriageDate,
            statusDate: statusDate,
            marriageDateIsApproximate: marriageDateIsApproximate,
            partnerSequence: partnerSequence,
            sourceFamilyID: sourceFamilyID,
            provenance: provenance,
            events: events
        )
    }
}

extension FamilyArchiveDocument {
    func canonicalizingCoreEvents() -> (document: FamilyArchiveDocument, changedPersonIDs: Set<Person.ID>) {
        var changedPersonIDs = Set<Person.ID>()
        var normalizedPeople = people.map { person in
            let result = person.canonicalizingCoreEvents()
            if result.changed { changedPersonIDs.insert(person.id) }
            return result.person
        }
        var normalizedUnions = familyUnions

        if var unions = normalizedUnions, !unions.isEmpty {
            let migration = Self.consolidateRelationshipEvents(people: normalizedPeople, unions: unions)
            normalizedPeople = migration.people
            unions = migration.unions
            let familyCleanup = Self.removingLegacyFamilyEventCopies(people: normalizedPeople, unions: unions)
            normalizedPeople = familyCleanup.people
            normalizedUnions = unions
            changedPersonIDs.formUnion(migration.changedPersonIDs)
            changedPersonIDs.formUnion(familyCleanup.changedPersonIDs)
        }
        let factCleanup = Self.removingEventBackedFactCopies(people: normalizedPeople)
        normalizedPeople = factCleanup.people
        changedPersonIDs.formUnion(factCleanup.changedPersonIDs)
        return (
            FamilyArchiveDocument(
                schemaVersion: schemaVersion,
                title: title,
                accountHolderID: accountHolderID,
                people: normalizedPeople,
                familyUnions: normalizedUnions
            ),
            changedPersonIDs
        )
    }

    private static func consolidateRelationshipEvents(
        people: [Person],
        unions: [FamilyUnion]
    ) -> (people: [Person], unions: [FamilyUnion], changedPersonIDs: Set<Person.ID>) {
        var updatedPeople = people
        var updatedUnions = unions
        var changedPersonIDs = Set<Person.ID>()
        let peopleByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })

        struct Candidate {
            let personIndex: Int
            let event: LifeEvent
        }
        var candidatesByUnion: [Int: [Candidate]] = [:]

        for personIndex in updatedPeople.indices {
            let person = updatedPeople[personIndex]
            for event in person.structuredEvents {
                guard let category = LifeEventCategory.category(for: event.category),
                      category == .marriage || category == .partnership,
                      let unionIndex = matchingUnionIndex(
                        for: event,
                        owner: person,
                        unions: unions,
                        peopleByID: peopleByID
                      ) else { continue }
                candidatesByUnion[unionIndex, default: []].append(Candidate(personIndex: personIndex, event: event))
            }
        }

        for (unionIndex, candidates) in candidatesByUnion {
            guard !candidates.isEmpty else { continue }
            let preferred = candidates.max { left, right in
                relationshipEventQuality(left.event) < relationshipEventQuality(right.event)
            } ?? candidates[0]
            var canonical = preferred.event
            for candidate in candidates where candidate.event.id != preferred.event.id {
                canonical.mergeMissingValues(from: candidate.event)
            }
            let category: LifeEventCategory = candidates.contains {
                LifeEventCategory.category(for: $0.event.category) == .marriage
            } ? .marriage : .partnership
            canonical.category = category.rawValue
            canonical.id = "\(updatedUnions[unionIndex].id)-event-\(category.rawValue)"

            var records = updatedUnions[unionIndex].events ?? []
            if let existingIndex = records.firstIndex(where: {
                LifeEventCategory.category(for: $0.event.category) == category
            }) {
                var merged = records[existingIndex].event
                merged.mergeMissingValues(from: canonical)
                records[existingIndex].event = merged
            } else {
                records.append(FamilyEventRecord(
                    id: canonical.id,
                    event: canonical,
                    sourcePersonID: preferred.personIndex < updatedPeople.count ? updatedPeople[preferred.personIndex].id : nil,
                    sourceEventID: preferred.event.id
                ))
            }

            let union = updatedUnions[unionIndex]
            updatedUnions[unionIndex] = FamilyUnion(
                id: union.id,
                partnerIDs: union.partnerIDs,
                childIDs: union.childIDs,
                relationshipStatus: union.relationshipStatus,
                marriageDate: union.marriageDate ?? (category == .marriage ? canonical.date : nil),
                statusDate: union.statusDate,
                marriageDateIsApproximate: union.marriageDateIsApproximate ?? canonical.isApproximate,
                partnerSequence: union.partnerSequence,
                sourceFamilyID: union.sourceFamilyID,
                provenance: union.provenance,
                events: records
            )

            let migratedIDs = Set(candidates.map(\.event.id))
            for personIndex in Set(candidates.map(\.personIndex)) {
                updatedPeople[personIndex].events?.removeAll { migratedIDs.contains($0.id) }
                changedPersonIDs.insert(updatedPeople[personIndex].id)
            }
        }

        return (updatedPeople, updatedUnions, changedPersonIDs)
    }

    /// Removes person-scoped Family records only when an explicit union links
    /// the owner to a canonical relative birth/death with the same sort date,
    /// the text names that relative, and the event kind also matches. This is
    /// intentionally stricter than display deduplication because it mutates
    /// stored data.
    private static func removingLegacyFamilyEventCopies(
        people: [Person],
        unions: [FamilyUnion]
    ) -> (people: [Person], changedPersonIDs: Set<Person.ID>) {
        var updatedPeople = people
        let peopleByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        var changedPersonIDs = Set<Person.ID>()

        for personIndex in updatedPeople.indices {
            let owner = updatedPeople[personIndex]
            var relatedIDs = Set<Person.ID>()
            for union in unions {
                if union.partnerIDs.contains(owner.id) {
                    relatedIDs.formUnion(union.childIDs)
                    relatedIDs.formUnion(union.partnerIDs.filter { $0 != owner.id })
                }
                if union.childIDs.contains(owner.id) {
                    relatedIDs.formUnion(union.partnerIDs)
                }
            }

            let canonicalRelativeEvents = relatedIDs.compactMap { peopleByID[$0] }.flatMap { relative in
                relative.structuredEvents.compactMap { event -> (Person, LifeEvent)? in
                    guard event.coreCategory == .birth || event.coreCategory == .death else { return nil }
                    return (relative, event)
                }
            }
            guard !canonicalRelativeEvents.isEmpty else { continue }

            let originalCount = updatedPeople[personIndex].structuredEvents.count
            updatedPeople[personIndex].events?.removeAll { candidate in
                guard LifeEventCategory.category(for: candidate.category) == .family else { return false }
                return canonicalRelativeEvents.contains { relative, canonical in
                    isStrictLegacyFamilyDuplicate(candidate, canonical: canonical, relative: relative)
                }
            }
            if updatedPeople[personIndex].structuredEvents.count != originalCount {
                changedPersonIDs.insert(owner.id)
            }
        }

        return (updatedPeople, changedPersonIDs)
    }

    /// Earlier normalized records sometimes retained a fact after creating a
    /// structured event from it. Remove only the unambiguous `fact-id` →
    /// `fact-id-event` copies; looser semantic matches remain untouched for
    /// manual review.
    private static func removingEventBackedFactCopies(
        people: [Person]
    ) -> (people: [Person], changedPersonIDs: Set<Person.ID>) {
        var updatedPeople = people
        var changedPersonIDs = Set<Person.ID>()

        for index in updatedPeople.indices {
            let eventIDs = Set(updatedPeople[index].structuredEvents.map(\.id))
            let originalCount = updatedPeople[index].facts.count
            updatedPeople[index].facts.removeAll { fact in
                eventIDs.contains("\(fact.id)-event")
            }
            if updatedPeople[index].facts.count != originalCount {
                changedPersonIDs.insert(updatedPeople[index].id)
            }
        }

        return (updatedPeople, changedPersonIDs)
    }

    private static func isStrictLegacyFamilyDuplicate(
        _ candidate: LifeEvent,
        canonical: LifeEvent,
        relative: Person
    ) -> Bool {
        let candidateSort = candidate.sortKey ?? LifeEvent.sortKey(for: candidate.date)
        let canonicalSort = canonical.sortKey ?? LifeEvent.sortKey(for: canonical.date)
        guard let candidateSort, candidateSort == canonicalSort else { return false }

        let text = [candidate.title, candidate.summary].joined(separator: " ").lowercased()
        var nameVariants = ArchiveLanguage.allCases.flatMap { language -> [String] in
            let fullName = NameLocalizationStore.shared.displayName(
                for: relative.id,
                fallback: relative.sourceDisplayName,
                language: language
            )
            return [fullName, fullName.split(separator: " ").first.map(String.init) ?? ""]
        } + [relative.sourceDisplayName, relative.givenName, relative.familyName]
        nameVariants += [relative.sourceDisplayName, relative.givenName].map {
            NameLocalizationStore.shared.suggestedCounterpart(for: $0, language: .russian)
        }
        let refersToRelative = nameVariants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .contains(where: text.contains)
        guard refersToRelative else { return false }

        let birthTerms = ["birth", "born", "рожд", "родил"]
        let deathTerms = ["death", "died", "смерт", "умер", "погиб"]
        switch canonical.coreCategory {
        case .birth: return birthTerms.contains(where: text.contains)
        case .death: return deathTerms.contains(where: text.contains)
        default: return false
        }
    }

    private static func matchingUnionIndex(
        for event: LifeEvent,
        owner: Person,
        unions: [FamilyUnion],
        peopleByID: [Person.ID: Person]
    ) -> Int? {
        let candidateIndexes = unions.indices.filter {
            unions[$0].partnerIDs.contains(owner.id) && unions[$0].partnerIDs.count > 1
        }
        guard !candidateIndexes.isEmpty else { return nil }

        let searchable = [event.id, event.title, event.summary]
            .joined(separator: " ")
            .lowercased()
        let scored = candidateIndexes.map { index -> (index: Int, score: Int) in
            let union = unions[index]
            var score = candidateIndexes.count == 1 ? 5 : 0
            if let unionDate = union.marriageDate,
               comparableEventDate(event.date) == comparableEventDate(unionDate) {
                score += 50
            }
            for partnerID in union.partnerIDs where partnerID != owner.id {
                if searchable.contains(partnerID.lowercased()) { score += 100 }
                guard let partner = peopleByID[partnerID] else { continue }
                let nameVariants = ArchiveLanguage.allCases.map {
                    NameLocalizationStore.shared.displayName(
                        for: partner.id,
                        fallback: partner.sourceDisplayName,
                        language: $0
                    )
                } + [partner.sourceDisplayName, partner.givenName, partner.familyName]
                if nameVariants
                    .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
                    .filter({ !$0.isEmpty })
                    .contains(where: searchable.contains) {
                    score += 75
                }
            }
            return (index, score)
        }
        guard let best = scored.max(by: { $0.score < $1.score }), best.score > 0 else { return nil }
        let tied = scored.filter { $0.score == best.score }
        return tied.count == 1 ? best.index : nil
    }

    private static func comparableEventDate(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func relationshipEventQuality(_ event: LifeEvent) -> Int {
        event.title.count + event.summary.count + (event.place?.count ?? 0) + (event.sourceIDs?.count ?? 0) * 20
    }

    /// Explicit unions are authoritative. Legacy documents get a conservative
    /// best-effort projection that refuses to invent pairings for a child with
    /// more than two recorded parents.
    var resolvedFamilyUnions: [FamilyUnion] {
        if let familyUnions, !familyUnions.isEmpty {
            return familyUnions
        }
        return FamilyUnion.deriveLegacyUnions(from: people)
    }
}

extension FamilyUnion {
    fileprivate static func deriveLegacyUnions(from people: [Person]) -> [FamilyUnion] {
        let validIDs = Set(people.map(\.id))
        var childrenByPair: [String: Set<Person.ID>] = [:]
        var partnersByPair: [String: [Person.ID]] = [:]
        var metadataByPair: [String: (status: String?, date: String?, approximate: Bool?)] = [:]

        func pairKey(_ ids: [Person.ID]) -> String {
            ids.sorted().joined(separator: "|")
        }

        for person in people {
            let parents = Array(Set(person.immediateFamily.parents.filter { validIDs.contains($0) })).sorted()
            if !parents.isEmpty, parents.count <= 2 {
                let key = pairKey(parents)
                partnersByPair[key] = parents
                childrenByPair[key, default: []].insert(person.id)
                if metadataByPair[key] == nil {
                    metadataByPair[key] = (
                        person.immediateFamily.parentsUnionStatus,
                        person.immediateFamily.parentsUnionDate,
                        person.immediateFamily.parentsUnionDateIsApproximate
                    )
                }
            }

            for partnerID in person.immediateFamily.partners where validIDs.contains(partnerID) {
                let partners = [person.id, partnerID].sorted()
                partnersByPair[pairKey(partners)] = partners
            }
        }

        return partnersByPair.keys.sorted().enumerated().map { offset, key in
            let metadata = metadataByPair[key]
            return FamilyUnion(
                id: "legacy-family-\(offset + 1)",
                partnerIDs: partnersByPair[key] ?? [],
                childIDs: Array(childrenByPair[key] ?? []).sorted(),
                relationshipStatus: metadata?.status,
                marriageDate: metadata?.status?.lowercased() == "divorced" ? nil : metadata?.date,
                statusDate: metadata?.status?.lowercased() == "divorced" ? metadata?.date : nil,
                marriageDateIsApproximate: metadata?.approximate,
                provenance: "legacy-immediate-family"
            )
        }
    }
}

struct Person: Codable, Identifiable, Hashable {
    var id: String
    var givenName: String
    var familyName: String
    var alternateNames: [String]
    var lifespan: String
    var summary: String
    var biography: String
    var privacy: PrivacyLevel
    var relationshipToMe: String?
    var profileImagePath: String?
    var profileImageScale: Double? = nil
    var profileImageOffsetX: Double? = nil
    var profileImageOffsetY: Double? = nil
    var facts: [PersonFact]
    var events: [LifeEvent]?
    var storyChapters: [StoryChapter]?
    var immediateFamily: ImmediateFamily
    var media: [MediaReference]
    var sources: [SourceReference]

    var sourceDisplayName: String {
        [givenName, familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Best-effort grammatical gender for Russian labels. The normalized
    /// archive keeps names rather than a separate gender field, so this uses
    /// approved given-name patterns first and surname endings as a fallback.
    var archiveGender: ArchiveGender {
        let normalizedGivenName = givenName
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")
        let normalizedFamilyName = familyName
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")

        let femaleNames: Set<String> = [
            "анна", "антонина", "александра", "галина", "елена", "евгения", "ирина",
            "лидия", "мария", "ольга", "татьяна", "валентина", "раиса", "нина",
            "тамара", "надежда", "вера", "зинаида", "людмила", "екатерина", "наталья",
            "светлана", "камиля", "берта", "виктория", "макси", "alice"
        ]
        let maleNames: Set<String> = [
            "иван", "владимир", "михаил", "константин", "яков", "сергей", "николай",
            "евгений", "антон", "алексей", "виктор", "степан", "илья", "юрий",
            "дмитрий", "исаак", "моисей", "андрей", "игнатий", "александр"
        ]

        if femaleNames.contains(normalizedGivenName) || normalizedGivenName.hasSuffix("а") || normalizedGivenName.hasSuffix("я") {
            return .female
        }
        if maleNames.contains(normalizedGivenName) || normalizedFamilyName.hasSuffix("ов") || normalizedFamilyName.hasSuffix("ев") {
            return .male
        }
        if normalizedFamilyName.hasSuffix("ова") || normalizedFamilyName.hasSuffix("ева") || normalizedFamilyName.hasSuffix("ина") {
            return .female
        }
        return .unknown
    }

    var displayName: String {
        NameLocalizationStore.shared.displayName(for: id, fallback: sourceDisplayName)
    }

    var originalDisplayName: String {
        NameLocalizationStore.shared.originalName(for: id, fallback: sourceDisplayName)
    }

    var localizedSummary: String {
        NarrativeLocalizationStore.shared.personSummary(id, source: summary)
    }

    var localizedBiography: String {
        NarrativeLocalizationStore.shared.personBiography(id, source: biography)
    }

    var displayGivenName: String {
        displayName.split(separator: " ").first.map(String.init) ?? givenName
    }

    var initials: String {
        let parts = displayName.split(separator: " ")
        return [parts.first?.first, parts.dropFirst().last?.first]
            .compactMap { $0 }
            .map(String.init)
            .joined()
            .uppercased()
    }

    var isLiving: Bool {
        guard !structuredEvents.contains(where: { $0.coreCategory == .death }) else { return false }
        return lifespan.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("–") ||
            lifespan.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("-")
    }

    var lifeStatusLabel: String {
        isLiving
            ? ArchiveCopy.livingLabel(gender: archiveGender)
            : ArchiveCopy.text(english: "Deceased", russian: "Ушедший")
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

    var birthEvent: LifeEvent? {
        structuredEvents.first { $0.coreCategory == .birth }
    }

    var deathEvent: LifeEvent? {
        structuredEvents.first { $0.coreCategory == .death }
    }

    /// Birth and death are canonical life events. Returning a fact-shaped
    /// projection keeps older list, tree, and GEDCOM consumers simple without
    /// storing a second editable copy of the same event.
    var birthFact: PersonFact? {
        birthEvent.map { $0.factProjection(for: .birth) }
            ?? facts.first { $0.coreEventCategory == .birth }
    }

    var deathFact: PersonFact? {
        deathEvent.map { $0.factProjection(for: .death) }
            ?? facts.first { $0.coreEventCategory == .death }
    }

    /// Converts legacy birth/death facts and mislabeled birth/death events into
    /// one canonical event per kind. Other facts remain untouched.
    func canonicalizingCoreEvents() -> (person: Person, changed: Bool) {
        var updated = self
        var events = structuredEvents
        var changed = false

        // Earlier archives used `family` for both marriages and events about
        // relatives. A short-lived migration also relabeled all of those as
        // `marriage`. Normalize only records whose text makes their meaning
        // explicit, preserving Family as a distinct category.
        for index in events.indices {
            let normalizedCategory = events[index].category
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let searchableText = [events[index].id, events[index].title, events[index].summary]
                .joined(separator: " ")
                .lowercased()

            let correctedCategory: LifeEventCategory?
            if normalizedCategory == "relationship" {
                correctedCategory = .partnership
            } else if normalizedCategory == "other" || normalizedCategory == "interests" {
                correctedCategory = .life
            } else if ["family", "marriage"].contains(normalizedCategory) && isBurialDescription(searchableText) {
                correctedCategory = .burial
            } else if normalizedCategory == "family" && isMarriageDescription(searchableText) {
                correctedCategory = .marriage
            } else if normalizedCategory == "marriage" && isRelativeLifeDescription(searchableText) {
                correctedCategory = .family
            } else {
                correctedCategory = nil
            }

            if let correctedCategory, events[index].category != correctedCategory.rawValue {
                events[index].category = correctedCategory.rawValue
                changed = true
            }
        }

        for category in [LifeEventCategory.birth, .death] {
            let matchingFacts = updated.facts.filter { $0.coreEventCategory == category }
            let matchingEventIndexes = events.indices.filter { events[$0].coreCategory == category }

            if let canonicalIndex = matchingEventIndexes.first {
                var canonical = events[canonicalIndex]
                if canonical.category != category.rawValue {
                    canonical.category = category.rawValue
                    changed = true
                }

                for index in matchingEventIndexes.dropFirst() {
                    canonical.mergeMissingValues(from: events[index])
                    changed = true
                }
                for fact in matchingFacts {
                    canonical.mergeValues(from: fact)
                }
                if canonical.sortKey == nil {
                    canonical.sortKey = LifeEvent.sortKey(for: canonical.date)
                }
                events[canonicalIndex] = canonical

                if matchingEventIndexes.count > 1 {
                    let duplicateIDs = Set(matchingEventIndexes.dropFirst().map { events[$0].id })
                    events.removeAll { duplicateIDs.contains($0.id) }
                }
            } else if let fact = matchingFacts.first {
                events.append(LifeEvent(
                    id: "\(fact.id)-event",
                    date: fact.value,
                    sortKey: LifeEvent.sortKey(for: fact.value),
                    title: category.defaultTitle,
                    summary: "",
                    place: fact.place,
                    category: category.rawValue,
                    isApproximate: fact.isApproximate,
                    sourceIDs: fact.sourceIDs,
                    titleTranslations: fact.labelTranslations,
                    summaryTranslations: nil
                ))
                changed = true
            }

            if !matchingFacts.isEmpty {
                updated.facts.removeAll { $0.coreEventCategory == category }
                changed = true
            }
        }

        if events != structuredEvents {
            updated.events = events
            changed = true
        }
        return (updated, changed)
    }

    private func isMarriageDescription(_ value: String) -> Bool {
        value.contains("marriage") ||
            value.contains("married") ||
            value.contains("wedding") ||
            value.contains("пожен") ||
            value.contains("свадьб") ||
            value.contains("брак")
    }

    private func isBurialDescription(_ value: String) -> Bool {
        value.contains("burial") ||
            value.contains("buried") ||
            value.contains("cemetery") ||
            value.contains("похорон") ||
            value.contains("захорон") ||
            value.contains("кладбищ")
    }

    private func isRelativeLifeDescription(_ value: String) -> Bool {
        let relativeTerms = [
            "mother", "father", "daughter", "son", "sister", "brother", "parent", "child",
            "мать", "отец", "дочь", "сын", "сестра", "брат", "родител", "ребен", "ребён"
        ]
        let lifeTerms = [
            "birth", "born", "death", "died", "рожд", "родил", "смерт", "умер", "погиб"
        ]
        return relativeTerms.contains(where: value.contains) && lifeTerms.contains(where: value.contains)
    }
}

enum PrivacyLevel: String, Codable, Hashable {
    case publicDeceased = "public-deceased"
    case privateLiving = "private-living"
    case restricted
    case sample
}

struct PersonFact: Codable, Identifiable, Hashable {
    var id: String
    var label: String
    var value: String
    var place: String?
    var isApproximate: Bool?
    var sourceIDs: [String]?
    var labelTranslations: [String: String]?
    var valueTranslations: [String: String]?

    var localizedLabel: String {
        localized(labelTranslations, fallback: ArchiveCopy.factLabel(label))
    }

    var localizedValue: String {
        localized(valueTranslations, fallback: value)
    }

    private func localized(_ values: [String: String]?, fallback: String) -> String {
        let language = ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? ArchiveLanguage.russian.rawValue) ?? .russian
        return values?[language.rawValue].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }

    var coreEventCategory: LifeEventCategory? {
        LifeEventCategory.coreCategory(for: label)
    }
}

enum LifeEventCategory: String, CaseIterable, Identifiable, Hashable {
    case birth
    case death
    case marriage
    case partnership
    case family
    case health
    case residence
    case education
    case career
    case military
    case migration
    case burial
    case life

    var id: String { rawValue }

    var defaultTitle: String {
        switch self {
        case .birth: "Born"
        case .death: "Died"
        default: ""
        }
    }

    var localizedLabel: String {
        switch self {
        case .birth: ArchiveCopy.text(english: "Birth", russian: "Рождение")
        case .death: ArchiveCopy.text(english: "Death", russian: "Смерть")
        case .marriage: ArchiveCopy.text(english: "Marriage", russian: "Брак")
        case .partnership: ArchiveCopy.text(english: "Partnership", russian: "Партнёрские отношения")
        case .family: ArchiveCopy.text(english: "Family", russian: "Семья")
        case .health: ArchiveCopy.text(english: "Health", russian: "Здоровье")
        case .residence: ArchiveCopy.text(english: "Residence", russian: "Место жительства")
        case .education: ArchiveCopy.text(english: "Education", russian: "Образование")
        case .career: ArchiveCopy.text(english: "Career", russian: "Карьера")
        case .military: ArchiveCopy.text(english: "Military service", russian: "Военная служба")
        case .migration: ArchiveCopy.text(english: "Migration", russian: "Переезд")
        case .burial: ArchiveCopy.text(english: "Burial", russian: "Захоронение")
        case .life: ArchiveCopy.text(english: "Life (Other)", russian: "Жизнь (другое)")
        }
    }

    static func coreCategory(for value: String) -> LifeEventCategory? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
        let birthLabels: Set<String> = ["birth", "born", "рождение", "родился", "родилась"]
        let deathLabels: Set<String> = ["death", "died", "смерть", "умер", "умерла", "погиб", "погибла"]
        if birthLabels.contains(normalized) { return .birth }
        if deathLabels.contains(normalized) { return .death }
        return nil
    }

    static func category(for value: String) -> LifeEventCategory? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Accept short-lived and legacy category names while the repository
        // normalizes them to the current vocabulary.
        if normalized == "relationship" { return .partnership }
        if normalized == "other" || normalized == "interests" { return .life }
        return LifeEventCategory(rawValue: normalized)
    }
}

struct LifeEvent: Codable, Identifiable, Hashable {
    var id: String
    var date: String
    var sortKey: Int?
    var title: String
    var summary: String
    var place: String?
    var category: String
    var isApproximate: Bool?
    var sourceIDs: [String]?
    var titleTranslations: [String: String]?
    var summaryTranslations: [String: String]?

    var localizedTitle: String {
        // Normalize both the source title and any stored translation through
        // the same approved event vocabulary. This prevents an English value
        // in an older `titleTranslations` entry from leaking into Russian UI.
        return ArchiveCopy.eventTitle(localized(titleTranslations, fallback: title))
    }

    var localizedSummary: String {
        ArchiveCopy.eventSummary(localized(summaryTranslations, fallback: NameLocalizationStore.shared.localizeEmbeddedNames(in: summary)))
    }

    private func localized(_ values: [String: String]?, fallback: String) -> String {
        let language = ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? ArchiveLanguage.russian.rawValue) ?? .russian
        return values?[language.rawValue].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }

    var coreCategory: LifeEventCategory? {
        if category.lowercased() == LifeEventCategory.birth.rawValue { return .birth }
        if category.lowercased() == LifeEventCategory.death.rawValue { return .death }
        return LifeEventCategory.coreCategory(for: title)
    }

    func factProjection(for category: LifeEventCategory) -> PersonFact {
        PersonFact(
            id: id,
            label: category.defaultTitle,
            value: date,
            place: place,
            isApproximate: isApproximate,
            sourceIDs: sourceIDs,
            labelTranslations: titleTranslations,
            valueTranslations: nil
        )
    }

    static func sortKey(for value: String) -> Int? {
        let years = value
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
            .filter { (1000...2100).contains($0) }
        return years.first.map { $0 * 10_000 }
    }

    mutating func mergeValues(from fact: PersonFact) {
        if date.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            date = fact.value
        }
        place = richer(place, fact.place)
        isApproximate = isApproximate ?? fact.isApproximate
        sourceIDs = merged(sourceIDs, fact.sourceIDs)
        if titleTranslations == nil { titleTranslations = fact.labelTranslations }
    }

    mutating func mergeMissingValues(from event: LifeEvent) {
        if date.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { date = event.date }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = event.title }
        if summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { summary = event.summary }
        place = richer(place, event.place)
        isApproximate = isApproximate ?? event.isApproximate
        sourceIDs = merged(sourceIDs, event.sourceIDs)
        titleTranslations = titleTranslations ?? event.titleTranslations
        summaryTranslations = summaryTranslations ?? event.summaryTranslations
    }

    private func richer(_ left: String?, _ right: String?) -> String? {
        let leftValue = left?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rightValue = right?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return rightValue.count > leftValue.count ? right : left
    }

    private func merged(_ left: [String]?, _ right: [String]?) -> [String]? {
        let values = Array(Set((left ?? []) + (right ?? []))).sorted()
        return values.isEmpty ? nil : values
    }
}

struct StoryChapter: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var dateRange: String?
    var summary: String?
    var body: String
}

struct ImmediateFamily: Codable, Hashable {
    let parents: [String]
    let partners: [String]
    let siblings: [String]
    let children: [String]
    var parentsUnionStatus: String? = nil
    var parentsUnionDate: String? = nil
    var parentsUnionDateIsApproximate: Bool? = nil
}

struct MediaReference: Codable, Identifiable, Hashable {
    var id: String
    var kind: MediaKind
    var title: String
    var date: String?
    var path: String?
    /// Captions use MediaMentionToken markers internally; the UI always
    /// renders these as localized @Name labels.
    var caption: String?
    var tags: [String]?
    var collection: String?
    var isApproximate: Bool?
    /// True when the caption contains no valid person mention. Such media is
    /// kept in the archive but is shown only in the media-review queue until
    /// a mention establishes which profile(s) should display it.
    var needsMentionReview: Bool? = nil
    /// Compatibility index derived from the caption's mention tokens. It is
    /// never an independent source of profile visibility.
    var personIDs: [Person.ID]?
}

/// Stable, language-independent mention references used inside media
/// captions. The marker is an implementation detail: it is converted to a
/// visible `@name_year` label whenever a caption is rendered or edited. Keeping the
/// ID in the caption means a name edit or locale switch never breaks a link.
enum MediaMentionToken {
    static let prefix = "[[person:"
    static let suffix = "]]"

    static func token(for personID: Person.ID) -> String {
        "\(prefix)\(personID)\(suffix)"
    }

    static func personIDs(in text: String) -> [Person.ID] {
        var result: [Person.ID] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let start = text.range(of: prefix, range: searchStart..<text.endIndex),
              let end = text.range(of: suffix, range: start.upperBound..<text.endIndex) {
            let id = String(text[start.upperBound..<end.lowerBound])
            if !id.isEmpty, !result.contains(id) {
                result.append(id)
            }
            searchStart = end.upperBound
        }
        return result
    }

    static func hasUnstructuredMention(in text: String) -> Bool {
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if let tokenStart = text.range(of: prefix, range: cursor..<text.endIndex),
               tokenStart.lowerBound == cursor,
               let tokenEnd = text.range(of: suffix, range: tokenStart.upperBound..<text.endIndex) {
                cursor = tokenEnd.upperBound
                continue
            }
            if text[cursor] == "@" { return true }
            cursor = text.index(after: cursor)
        }
        return false
    }

    /// Builds the human-readable mention from current profile data. The
    /// immutable ID remains in storage; this label is deliberately computed
    /// at render time so corrected names and dates cannot leave stale text in
    /// existing captions.
    static func displayLabel(
        for person: Person,
        people: [Person],
        language: ArchiveLanguage? = nil
    ) -> String {
        displayLabels(for: people, language: language)[person.id]
            ?? baseDisplayLabel(for: person, language: language)
    }

    /// Computes every label in one pass. Editors and migrations call this
    /// when presenting many people so uniqueness checks do not repeatedly
    /// scan the complete family.
    static func displayLabels(
        for people: [Person],
        language: ArchiveLanguage? = nil
    ) -> [Person.ID: String] {
        let bases = Dictionary(uniqueKeysWithValues: people.map { person in
            (person.id, baseDisplayLabel(for: person, language: language))
        })
        let groups = Dictionary(grouping: people, by: { person in
            (bases[person.id] ?? person.id).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        })
        return Dictionary(uniqueKeysWithValues: people.map { person in
            let base = bases[person.id] ?? person.id
            guard groups[base.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current), default: []].count > 1 else {
                return (person.id, base)
            }
            // This suffix disambiguates the visible label only. It is derived
            // from, and never replaces or mutates, the stable Person.id.
            return (person.id, "\(base)_\(person.id)")
        })
    }

    private static func baseDisplayLabel(
        for person: Person,
        language: ArchiveLanguage?
    ) -> String {
        let fallback = person.sourceDisplayName
        let localizedName = NameLocalizationStore.shared.displayName(
            for: person.id,
            fallback: fallback,
            language: language
        )
        let normalizedName = localizedName
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "_")
        let year = recordedBirthYear(for: person).map(String.init) ?? "unknown"
        return "\(normalizedName)_\(year)"
    }

    private static func recordedBirthYear(for person: Person) -> Int? {
        if let value = person.birthFact?.value {
            return value
                .split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }
                .first(where: { (1000...2100).contains($0) })
        }
        let lifespan = person.lifespan.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lifespan.hasPrefix("?") else { return nil }
        return lifespan
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
            .first(where: { (1000...2100).contains($0) })
    }

    /// Converts a stored tokenized caption to the current visible language.
    /// Unknown IDs are retained as an explicit `@ID` rather than silently
    /// dropping a reference from an imported private archive.
    static func visibleText(
        _ text: String,
        people: [Person],
        language: ArchiveLanguage? = nil
    ) -> String {
        let labels = displayLabels(for: people, language: language)
        var result = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard let start = text.range(of: prefix, range: cursor..<text.endIndex),
                  let end = text.range(of: suffix, range: start.upperBound..<text.endIndex) else {
                result += text[cursor...]
                break
            }
            result += text[cursor..<start.lowerBound]
            let id = String(text[start.upperBound..<end.lowerBound])
            if let person = people.first(where: { $0.id == id }) {
                result += "@\(labels[person.id] ?? person.id)"
            } else {
                result += "@\(id)"
            }
            cursor = end.upperBound
        }
        return result
    }

    /// Converts human-readable `@Name` mentions to immutable ID tokens. Existing
    /// tokens are preserved. For duplicate names, an explicitly selected ID is
    /// preferred; an ambiguous unselected name is left readable for manual
    /// review instead of being linked to the wrong person.
    static func canonicalize(
        _ text: String,
        people: [Person],
        preferredPersonIDs: Set<Person.ID> = []
    ) -> String {
        let defaultLabels = displayLabels(for: people, language: nil)
        let localizedLabels = Dictionary(uniqueKeysWithValues: ArchiveLanguage.allCases.map { language in
            (language, displayLabels(for: people, language: language))
        })
        let candidates = people.flatMap { person in
            let localizedNames = ArchiveLanguage.allCases.compactMap {
                NameLocalizationStore.shared.localizedName(for: person.id, language: $0)
            }
            let mentionLabels = ArchiveLanguage.allCases.compactMap {
                localizedLabels[$0]?[person.id]
            }
            let names = [
                person.displayName,
                person.sourceDisplayName,
                person.originalDisplayName,
                defaultLabels[person.id] ?? person.id
            ] + localizedNames + mentionLabels
            return names
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { ($0, person.id) }
        }
        .sorted { $0.0.count > $1.0.count }

        var result = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if let tokenStart = text.range(of: prefix, range: cursor..<text.endIndex),
               tokenStart.lowerBound == cursor,
               let tokenEnd = text.range(of: suffix, range: tokenStart.upperBound..<text.endIndex) {
                result += text[tokenStart.lowerBound..<tokenEnd.upperBound]
                cursor = tokenEnd.upperBound
                continue
            }

            guard text[cursor] == "@" else {
                result.append(text[cursor])
                cursor = text.index(after: cursor)
                continue
            }

            let queryStart = text.index(after: cursor)
            let matches = candidates.filter { name, _ in
                guard text[queryStart...].hasPrefix(name) else { return false }
                let end = text.index(queryStart, offsetBy: name.count)
                guard end < text.endIndex else { return true }
                let next = text[end]
                return !(next.isLetter || next.isNumber || next == "_")
            }
            let matchingIDs = Array(Set(matches.map(\.1))).sorted()
            let selectedMatches = matchingIDs.filter { preferredPersonIDs.contains($0) }
            let chosenID: Person.ID?
            if selectedMatches.count == 1 {
                chosenID = selectedMatches[0]
            } else if matchingIDs.count == 1 {
                chosenID = matchingIDs[0]
            } else {
                chosenID = nil
            }

            guard let chosenID, let matchedName = matches.first(where: { $0.1 == chosenID })?.0 else {
                result.append(text[cursor])
                cursor = text.index(after: cursor)
                continue
            }
            result += token(for: chosenID)
            cursor = text.index(queryStart, offsetBy: matchedName.count)
        }
        return result
    }

    /// Protects ID markers while sending caption prose through translation.
    /// Translation services should never be allowed to alter a person ID.
    static func protectedForTranslation(_ text: String) -> (text: String, tokens: [String]) {
        let tokens = personIDs(in: text).map(token)
        var protected = text
        for (index, token) in tokens.enumerated() {
            protected = protected.replacingOccurrences(of: token, with: "FAMILYMENTIONTOKEN\(index)X")
        }
        return (protected, tokens)
    }

    static func restoreAfterTranslation(_ text: String, tokens: [String]) -> String {
        var restored = text
        for (index, token) in tokens.enumerated() {
            restored = restored.replacingOccurrences(of: "FAMILYMENTIONTOKEN\(index)X", with: token)
        }
        return restored
    }
}

enum MediaCaptionMetadata {
    /// Media dates are an internal sorting index derived from caption prose.
    /// Mention labels have already been converted to ID tokens before this
    /// runs, so a person's birth year cannot be mistaken for the photo date.
    static func sortingDate(in canonicalCaption: String) -> String? {
        guard let range = canonicalCaption.range(
            of: #"\b(1\d{3}|20\d{2}|2100)\b"#,
            options: .regularExpression
        ) else { return nil }
        return String(canonicalCaption[range])
    }
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
