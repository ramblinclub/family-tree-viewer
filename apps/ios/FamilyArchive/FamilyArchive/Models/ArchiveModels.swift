import Foundation

enum ArchiveLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case russian = "ru"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .english: "English"
        case .russian: "Русский"
        }
    }
}

private struct NameLocalizationDocument: Decodable {
    let approvedNames: [NameLocalization]
}

private struct NameLocalization: Decodable {
    let personID: String
    let original: String
    let localizedNames: [String: String]
}

private struct NarrativeLocalizationDocument: Decodable {
    let people: [String: NarrativePersonLocalization]
}

private struct NarrativePersonLocalization: Decodable {
    let summary: String?
    let biography: String?
    let stories: [String: NarrativeStoryLocalization]?
    let events: [String: NarrativeEventLocalization]?
    let media: [String: NarrativeMediaLocalization]?
}

private struct NarrativeStoryLocalization: Decodable {
    let title: String?
    let summary: String?
    let body: String?
}

private struct NarrativeEventLocalization: Decodable {
    let title: String?
    let summary: String?
}

private struct NarrativeMediaLocalization: Decodable {
    let title: String?
    let caption: String?
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
            bundle.url(forResource: "narrative-translations.private", withExtension: "json"),
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("narrative-translations.private.json"),
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("PrivateData/narrative-translations.private.json")
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
            bundle.url(forResource: "name-localizations.private", withExtension: "json"),
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("name-localizations.private.json"),
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("PrivateData/name-localizations.private.json")
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

    func displayName(for personID: String, fallback: String) -> String {
        if namesByID.isEmpty {
            reload()
        }
        let language = ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: Self.appLanguageKey) ?? ArchiveLanguage.russian.rawValue) ?? .russian
        guard let localized = namesByID[personID]?.localizedNames[language.rawValue],
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

enum ArchiveCopy {
    static func text(english: String, russian: String) -> String {
        let language = ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? ArchiveLanguage.russian.rawValue) ?? .russian
        return language == .russian ? russian : english
    }

    static func relationshipLabel(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "me", "you": return text(english: "You", russian: "Вы")
        case "parent": return text(english: "Parent", russian: "Родитель")
        case "child": return text(english: "Child", russian: "Ребёнок")
        case "grandfather": return text(english: "Grandfather", russian: "Дедушка")
        case "grandmother": return text(english: "Grandmother", russian: "Бабушка")
        case "grandparent": return text(english: "Grandparent", russian: "Бабушка или дедушка")
        case "sibling": return text(english: "Sibling", russian: "Брат или сестра")
        case "spouse": return text(english: "Spouse", russian: "Супруг(а)")
        default: return value
        }
    }

    static func factLabel(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "born", "birth": return text(english: "Born", russian: "Рождение")
        case "died", "death": return text(english: "Died", russian: "Смерть")
        case "education": return text(english: "Education", russian: "Образование")
        case "occupation": return text(english: "Occupation", russian: "Род занятий")
        case "residence": return text(english: "Residence", russian: "Место жительства")
        case "languages": return text(english: "Languages", russian: "Языки")
        case "known for": return text(english: "Known for", russian: "Известен(на) благодаря")
        case "archive status": return text(english: "Archive status", russian: "Статус архива")
        default: return value
        }
    }

    /// Displays place names in the selected app language without changing the
    /// original place stored in the archive. Russian remains the source form;
    /// English uses the approved spellings used throughout this family data.
    static func place(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let language = ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? ArchiveLanguage.russian.rawValue) ?? .russian
        let exact: [String: String] = [
            "Бежецк по документам | село Едрово по факту": "Bezhetsk by documents | Edrovo village in fact",
            "Бежецк по документам | село Едрово по факту, Россия": "Bezhetsk by documents | Edrovo village in fact, Russia",
            "Витебск, Россия": "Vitebsk, Russia",
            "Вольск, Россия": "Volsk, Russia",
            "Вольск, Саратовкой обл.": "Volsk, Saratov region",
            "Вольск, Саратовкой обл., Россия": "Volsk, Saratov region, Russia",
            "Вольск; Saint-Petersbourg": "Volsk; Saint Petersburg",
            "Воронеж": "Voronezh",
            "Воронеж, Россия": "Voronezh, Russia",
            "Гомель": "Gomel",
            "Гомель, Беларусь": "Gomel, Belarus",
            "Едрово": "Edrovo",
            "Едрово, Россия": "Edrovo, Russia",
            "Едрово - село в Валдайском районе Новгородской области России": "Edrovo — a village in Valdai district, Novgorod region, Russia",
            "Едрово, Валдайский р-н, Новгородской области": "Edrovo, Valdai district, Novgorod region",
            "Едрово, Валдайский р-н, Новгородской области, Россия": "Edrovo, Valdai district, Novgorod region, Russia",
            "Каменец-Подольск": "Kamianets-Podilskyi",
            "Каменец-Подольск, Украина": "Kamianets-Podilskyi, Ukraine",
            "Киев": "Kyiv",
            "Киев, Украина": "Kyiv, Ukraine",
            "Лемболово": "Lembolovo",
            "Ленинград": "Leningrad",
            "Ленинград, Россия": "Leningrad, Russia",
            "Луга, Россия": "Luga, Russia",
            "Луга, Санкт-Петербургская губерния": "Luga, Saint Petersburg Governorate",
            "Луга, Санкт-Петербургская губерния, Россия": "Luga, Saint Petersburg Governorate, Russia",
            "Москва": "Moscow",
            "Москва, Россия": "Moscow, Russia",
            "Орша, Витебская обл": "Orsha, Vitebsk region",
            "Орша, Витебская обл., Беларусь": "Orsha, Vitebsk region, Belarus",
            "Пензенская обл., Мокшанский р-н, с. Нечаевка": "Penza region, Mokshan district, Nechaevka village",
            "Пензенская обл., Мокшанский р-н, с. Нечаевка, Россия": "Penza region, Mokshan district, Nechaevka village, Russia",
            "Петровск, Аткарской губернии": "Petrovsk, Atkarsk Governorate",
            "Петровск, Аткарской губернии, Россия": "Petrovsk, Atkarsk Governorate, Russia",
            "Полтава, Россия": "Poltava, Russia",
            "Санкт-Петербург": "Saint Petersburg",
            "Санкт-Петербург, Россия": "Saint Petersburg, Russia",
            "Сасово, Рязанская область": "Sasovo, Ryazan region",
            "Сасово, Рязанская область, Россия": "Sasovo, Ryazan region, Russia",
            "Тбилиси": "Tbilisi",
            "Тбилиси, Грузия": "Tbilisi, Georgia",
            "Чита": "Chita",
            "Чита, Россия": "Chita, Russia",
            "г Балашово, Саратовской обл": "Balashov, Saratov region",
            "г Балашово, Саратовской обл., Россия": "Balashov, Saratov region, Russia",
            "г. Куйбышев (теперь Самара)": "Kuibyshev (now Samara)",
            "г. Куйбышев (теперь Самара), Россия": "Kuibyshev (now Samara), Russia",
            "дер. Середея Владайского района Новгородской обл": "Seredeya village, Valdai district, Novgorod region",
            "дер. Середея Владайского района Новгородской обл., Россия": "Seredeya village, Valdai district, Novgorod region, Russia",
            "деревня Раменье, Бежецкий район Калининской области": "Ramenye village, Bezhetsk district, Kalinin region",
            "деревня Раменье, Бежецкий район Калининской области, Россия": "Ramenye village, Bezhetsk district, Kalinin region, Russia",
            "погиб под Ленинградом": "Killed near Leningrad",
            "умер в детстве": "Died in childhood",
            "умер в раннем детстве": "Died in early childhood",
            "умерла в детстве": "Died in childhood",
            "Веденковский Cemetery, Saint Petersburg": "Vedenkovsky Cemetery, Saint Petersburg"
        ]

        if language == .russian {
            // A few migrated records contain an English place even though
            // Russian is the source/display language. Reverse the approved
            // place map so those records still render in Russian without
            // mutating the private source text.
            if let original = exact.first(where: {
                $0.value.caseInsensitiveCompare(trimmed) == .orderedSame
            })?.key {
                return original
            }
            return trimmed
        }

        if let translated = exact[trimmed] {
            return translated
        }

        return trimmed
            .replacingOccurrences(of: "Россия", with: "Russia")
            .replacingOccurrences(of: "Беларусь", with: "Belarus")
            .replacingOccurrences(of: "области", with: "region")
            .replacingOccurrences(of: "обл.", with: "region")
            .replacingOccurrences(of: "района", with: "district")
            .replacingOccurrences(of: "р-н", with: "district")
            .replacingOccurrences(of: "с.", with: "village")
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
        let translatedTitles: [String: (String, String)] = [
            "aviation research career": ("Aviation research career", "Карьера в авиационных исследованиях"),
            "beekeeping at lembolovo": ("Beekeeping at Lembolovo", "Пчеловодство в Лемболово"),
            "birth of daughter galina": ("Birth of daughter Galina", "Рождение дочери Галины"),
            "birth of daughter irina": ("Birth of daughter Irina", "Рождение дочери Ирины"),
            "birth of son sergei": ("Birth of son Sergei", "Рождение сына Сергея"),
            "bought a dacha in lembolovo": ("Bought a dacha in Lembolovo", "Покупка дачи в Лемболово"),
            "buried at vedenkovsky cemetery": ("Buried at Vedenkovsky Cemetery", "Похороны на Введенском кладбище"),
            "completed an ms in cs": ("Completed an MS in CS", "Окончание магистратуры по информатике"),
            "completed school": ("Completed school", "Окончание школы"),
            "death of father andrey nosov": ("Death of father Andrey Nosov", "Смерть отца Андрея Носова"),
            "death of mother elena feofarova": ("Death of mother Elena Feofarova", "Смерть матери Елены Феофаровой"),
            "entered the mozhaisky academy": ("Entered the Mozhaisky Academy", "Поступление в академию Можайского"),
            "family life begins": ("Family life begins", "Начало семейной жизни"),
            "garden observatory": ("Garden observatory", "Обсерватория в саду"),
            "graduated from the mozhaisky academy": ("Graduated from the Mozhaisky Academy", "Окончание академии Можайского"),
            "graduated in engineering": ("Graduated in engineering", "Окончание инженерного факультета"),
            "health and retirement": ("Health and retirement", "Здоровье и выход на пенсию"),
            "moved to study in saint petersburg": ("Moved to study in Saint Petersburg", "Переезд на учёбу в Санкт-Петербург"),
            "moved to the united states": ("Moved to the United States", "Переезд в Соединённые Штаты"),
            "railway engineering": ("Railway engineering", "Железнодорожная инженерия"),
            "recorded neighborhood memories": ("Recorded neighborhood memories", "Записи воспоминаний соседей"),
            "research and invention": ("Research and invention", "Исследования и изобретения"),
            "school years": ("School years", "Школьные годы"),
            "technical training": ("Technical training", "Техническая подготовка"),
            "wartime instructor": ("Wartime instructor", "Военный инструктор")
        ]
        if let pair = translatedTitles[lowercased] {
            return text(english: pair.0, russian: pair.1)
        }
        if lowercased == "born" || lowercased == "birth" {
            return text(english: "Born", russian: "Рождение")
        }
        if lowercased == "died" || lowercased == "death" {
            return text(english: "Died", russian: "Смерть")
        }
        if lowercased.hasPrefix("married ") {
            let name = String(trimmed.dropFirst("Married ".count))
            return localizeNames(text(english: "Married", russian: "Брак") + " " + name)
        }
        if lowercased == "married" {
            return text(english: "Married", russian: "Брак")
        }
        return trimmed
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

    static func display(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if ["unknown", "????"].contains(trimmed.lowercased()) {
            return ArchiveCopy.text(english: "Unknown", russian: "Неизвестно")
        }

        let inputFormatter = DateFormatter()
        inputFormatter.locale = Locale(identifier: "en_US_POSIX")

        for format in inputFormats {
            inputFormatter.dateFormat = format
            if let date = inputFormatter.date(from: trimmed) {
                let language = ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? ArchiveLanguage.russian.rawValue) ?? .russian
                let localizedFormatter = DateFormatter()
                localizedFormatter.locale = Locale(identifier: language == .russian ? "ru_RU" : "en_US_POSIX")
                if format == "MMMM yyyy" || format == "MMM yyyy" {
                    localizedFormatter.dateFormat = language == .russian ? "LLLL yyyy" : "MMM yyyy"
                } else {
                    localizedFormatter.dateFormat = language == .russian ? "d MMMM yyyy" : "MMM d, yyyy"
                }
                return localizedFormatter.string(from: date)
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
            ? ArchiveCopy.text(english: "Living", russian: "Жив")
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
        localized(titleTranslations, fallback: ArchiveCopy.eventTitle(title))
    }

    var localizedSummary: String {
        localized(summaryTranslations, fallback: NameLocalizationStore.shared.localizeEmbeddedNames(in: summary))
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
