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
    var people: [String: NarrativePersonLocalization]
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
}

/// Reads approved English narrative translations from the private app data
/// area. The Russian source remains in the archive JSON and is never replaced.
final class NarrativeLocalizationStore {
    nonisolated(unsafe) static let shared = NarrativeLocalizationStore()

    private var people: [String: NarrativePersonLocalization] = [:]

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
            people = document.people
            return
        }

        people = [:]
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

    func mediaTitle(_ personID: String, mediaID: String, source: String) -> String {
        localized(source: source, translation: people[personID]?.media?[mediaID]?.title, pending: "English title pending")
    }

    func mediaCaption(_ personID: String, mediaID: String, source: String) -> String {
        localized(source: source, translation: people[personID]?.media?[mediaID]?.caption, pending: "English caption pending")
    }

    func storedMediaCaption(_ personID: String, mediaID: String) -> String? {
        people[personID]?.media?[mediaID]?.caption
    }

    /// Persists an English media caption in the private localization sidecar.
    /// Russian/source captions stay in the person record and are handled by
    /// FamilyRepository.updateMedia(_:for:).
    func updateMediaCaption(
        personID: String,
        mediaID: String,
        caption: String,
        fileManager: FileManager = .default
    ) throws {
        let value = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        var person = people[personID] ?? NarrativePersonLocalization(
            summary: nil,
            biography: nil,
            stories: nil,
            events: nil,
            media: nil
        )
        var media = person.media ?? [:]
        var record = media[mediaID] ?? NarrativeMediaLocalization(title: nil, caption: nil)
        record.caption = value.isEmpty ? nil : value
        media[mediaID] = record
        person.media = media
        people[personID] = person

        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let destination = documentsURL
            .appendingPathComponent("FamilyArchiveStore", isDirectory: true)
            .appendingPathComponent("PrivateData", isDirectory: true)
            .appendingPathComponent("narrative-translations.private.json")
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(NarrativeLocalizationDocument(people: people))
        try data.write(to: destination, options: Data.WritingOptions.atomic)
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
        guard let localized = namesByID[personID]?.localizedNames[selectedLanguage.rawValue],
              !localized.isEmpty else {
            return fallback
        }
        return localized
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
        lifespan.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("–") ||
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
}

struct MediaReference: Codable, Identifiable, Hashable {
    var id: String
    var kind: MediaKind
    var title: String
    var date: String?
    var path: String?
    var caption: String?
    var tags: [String]?
    var collection: String?
    var isApproximate: Bool?
    var personIDs: [Person.ID]?
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
