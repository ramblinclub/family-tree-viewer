import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CoreTransferable
import ImageIO
import AuthenticationServices
import PhotosUI

enum ArchiveFileResolver {
    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // Keep frequently viewed images warm without retaining the entire
        // archive in memory. This also prevents SwiftUI body refreshes from
        // reopening and decoding the same file repeatedly.
        cache.countLimit = 48
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    static func cachedImage(for path: String, maxPixelSize: Int? = nil) -> UIImage? {
        cache.object(forKey: cacheKey(path: path, maxPixelSize: maxPixelSize))
    }

    static func image(for path: String, maxPixelSize: Int? = nil) -> UIImage? {
        let key = cacheKey(path: path, maxPixelSize: maxPixelSize)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let image: UIImage?
        if let url = fileURL(for: path),
           let maxPixelSize,
           maxPixelSize > 0,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCache: false,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                ] as CFDictionary
           ) {
            image = UIImage(cgImage: thumbnail)
        } else if let url = fileURL(for: path) {
            image = UIImage(contentsOfFile: url.path)
        } else {
            image = UIImage(named: path)
        }

        if let image {
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }

    /// Profile selections can point at a path that was already decoded before
    /// the selection was saved (for example after replacing an imported asset
    /// in the private store). Clear the shared decoded cache so every screen
    /// picks up the current image immediately.
    static func invalidateImages() {
        cache.removeAllObjects()
    }

    private static func cacheKey(path: String, maxPixelSize: Int?) -> NSString {
        "\(path)|\(maxPixelSize ?? 0)" as NSString
    }

    private static func fileURL(for path: String) -> URL? {
        if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let storeURL = documentsURL
                .appendingPathComponent("FamilyArchiveStore", isDirectory: true)
                .appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: storeURL.path) {
                return storeURL
            }

            let localURL = documentsURL.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: localURL.path) {
                return localURL
            }
        }

        return Bundle.main.url(forResource: path, withExtension: nil)
    }
}

/// Loads local archive images away from the main thread. Media galleries can
/// contain many large originals, so a placeholder is rendered immediately and
/// the decoded image is published only when ready.
@MainActor
final class ArchiveImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    private var loadedKey: String?

    func load(path: String?, maxPixelSize: Int) {
        let key = path.map { "\($0)|\(maxPixelSize)" }
        guard key != loadedKey else { return }
        loadedKey = key
        image = nil
        guard let path else { return }

        if let cached = ArchiveFileResolver.cachedImage(for: path, maxPixelSize: maxPixelSize) {
            image = cached
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let decoded = ArchiveFileResolver.image(for: path, maxPixelSize: maxPixelSize)
            DispatchQueue.main.async {
                guard let self, self.loadedKey == key else { return }
                self.image = decoded
            }
        }
    }
}

private struct FamilyNameFilterOption: Identifiable {
    let id: String
    let displayName: String
    let variants: [String]
}

private enum ConnectionScope: String, CaseIterable, Identifiable {
    case all
    case withinOne
    case withinTwo
    case withinThree

    var id: String { rawValue }

    var maximumDistance: Int? {
        switch self {
        case .all: nil
        case .withinOne: 1
        case .withinTwo: 2
        case .withinThree: 3
        }
    }

    func label(count: Int) -> String {
        switch self {
        case .all:
            return ArchiveCopy.text(english: "Everyone · \(count)", russian: "Все · \(count)")
        case .withinOne:
            return ArchiveCopy.text(english: "Within 1 · \(count)", russian: "До 1 связи · \(count)")
        case .withinTwo:
            return ArchiveCopy.text(english: "Within 2 · \(count)", russian: "До 2 связей · \(count)")
        case .withinThree:
            return ArchiveCopy.text(english: "Within 3 · \(count)", russian: "До 3 связей · \(count)")
        }
    }
}

private enum DateFilterSelection: Equatable {
    case any
    case unknown
    case value(Int)
}

struct PeopleListView: View {
    @ObservedObject var repository: FamilyRepository
    let initialPersonID: Person.ID?

    @State private var searchText = ""
    @State private var selectedFamilyNameKey: String?
    @State private var storiesOnly = false
    @State private var selectedConnectionScope: ConnectionScope = .all
    @State private var selectedBirthMonth: DateFilterSelection = .any
    @State private var selectedDeathMonth: DateFilterSelection = .any
    @State private var selectedCentury: DateFilterSelection = .any
    @State private var navigationPath = NavigationPath()
    @State private var showingFilters = false

    private var connectionDistances: [Person.ID: Int] {
        repository.connectionDistances(from: repository.accountHolderID)
    }

    private var connectionScopeCounts: [ConnectionScope: Int] {
        let accountID = repository.accountHolderID
        let distances = connectionDistances
        return Dictionary(uniqueKeysWithValues: ConnectionScope.allCases.map { scope in
            if scope == .all {
                return (scope, repository.people.count)
            }

            let count = repository.people.reduce(into: 0) { result, person in
                if person.id == accountID { return }
                guard let distance = distances[person.id] else { return }
                if scope.maximumDistance.map({ distance <= $0 }) ?? true {
                    result += 1
                }
            }
            return (scope, count)
        })
    }

    private var filteredPeople: [Person] {
        let people = repository.people.sorted(by: birthYearOrder)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountID = repository.accountHolderID
        let distances = connectionDistances

        return people.filter { person in
            let searchableNames = [
                person.displayName,
                person.originalDisplayName,
                person.sourceDisplayName
            ] + person.alternateNames
            let matchesSearch = query.isEmpty ||
                searchableNames.contains { $0.localizedCaseInsensitiveContains(query) }
            let matchesFamilyName = selectedFamilyNameKey == nil ||
                normalizedFamilyNameKey(person.familyName) == selectedFamilyNameKey
            let matchesStories = !storiesOnly || person.hasStories
            let matchesBirthMonth = matchesDateFilter(selectedBirthMonth, value: dateMonth(for: person.birthFact?.value))
            let matchesDeathMonth = matchesDateFilter(selectedDeathMonth, value: dateMonth(for: person.deathFact?.value))
            let matchesLivedCentury = matchesCenturyFilter(selectedCentury, person: person)
            let matchesConnection: Bool
            if selectedConnectionScope == .all {
                matchesConnection = true
            } else if person.id == accountID {
                matchesConnection = false
            } else if let distance = distances[person.id],
                      let maximumDistance = selectedConnectionScope.maximumDistance {
                matchesConnection = distance <= maximumDistance
            } else {
                matchesConnection = false
            }
            return matchesSearch && matchesFamilyName && matchesStories &&
                matchesBirthMonth && matchesDeathMonth && matchesLivedCentury && matchesConnection
        }
    }

    private var activeFilterCount: Int {
        [selectedFamilyNameKey != nil,
         storiesOnly,
         selectedBirthMonth != .any,
         selectedDeathMonth != .any,
         selectedCentury != .any,
         selectedConnectionScope != .all]
            .filter { $0 }
            .count
    }

    private var availableBirthCenturies: [Int] {
        Set(repository.people.flatMap { livedInCenturies(for: $0) }).sorted()
    }

    private func matchesDateFilter(_ selection: DateFilterSelection, value: Int?) -> Bool {
        switch selection {
        case .any: true
        case .unknown: value == nil
        case .value(let expected): value == expected
        }
    }

    private func matchesCenturyFilter(_ selection: DateFilterSelection, person: Person) -> Bool {
        switch selection {
        case .any: true
        case .unknown: livedInCenturies(for: person).isEmpty
        case .value(let expected): livedInCenturies(for: person).contains(expected)
        }
    }

    private func livedInCenturies(for person: Person) -> Set<Int> {
        let values = [person.birthFact?.value, person.deathFact?.value, person.lifespan].compactMap { $0 }
        return Set(values.flatMap(years(in:)).map { (($0 - 1) / 100) + 1 })
    }

    private func years(in value: String) -> [Int] {
        let parts = value.split(whereSeparator: { !$0.isNumber })
        return parts.compactMap { Int($0) }.filter { (1000...2100).contains($0) }
    }

    private func dateMonth(for value: String?) -> Int? {
        guard let value, !value.isEmpty else { return nil }
        let normalized = value.lowercased()

        // The normalized archive commonly stores ISO dates (yyyy-mm-dd),
        // while the display formatter turns them into a localized date. Read
        // that source form directly so month filters work regardless of the
        // currently selected app language.
        let isoPattern = #"\b\d{4}[-/.]\d{1,2}(?:[-/.]\d{1,2})?\b"#
        if let range = normalized.range(of: isoPattern, options: .regularExpression) {
            let components = normalized[range].split { $0 == "." || $0 == "/" || $0 == "-" }
            if components.count >= 2,
               let year = Int(components[0]),
               (1000...2100).contains(year),
               let month = Int(components[1]),
               (1...12).contains(month) {
                return month
            }
        }

        let monthStems: [(Int, [String])] = [
            (1, ["january", "jan", "январ"]), (2, ["february", "feb", "феврал"]),
            (3, ["march", "mar", "март"]), (4, ["april", "apr", "апрел"]),
            (5, ["may", "май"]), (6, ["june", "jun", "июн"]),
            (7, ["july", "jul", "июл"]), (8, ["august", "aug", "август"]),
            (9, ["september", "sep", "sept", "сентябр"]), (10, ["october", "oct", "октябр"]),
            (11, ["november", "nov", "ноябр"]), (12, ["december", "dec", "декабр"])
        ]
        if let match = monthStems.first(where: { stems in
            stems.1.contains { normalized.contains($0) }
        }) {
            return match.0
        }

        // Numeric dates are primarily imported in day-month-year form.
        let pattern = #"\b\d{1,2}[./-]\d{1,2}[./-]\d{2,4}\b"#
        guard let range = normalized.range(of: pattern, options: .regularExpression) else { return nil }
        let components = normalized[range].split { $0 == "." || $0 == "/" || $0 == "-" }
        guard components.count >= 3,
              let first = Int(components[0]), let second = Int(components[1]) else { return nil }
        if first > 12 { return second }
        if second > 12 { return first }
        return second
    }

    private var familyNameOptions: [FamilyNameFilterOption] {
        let grouped = Dictionary(grouping: repository.people.map(\.familyName).filter { !$0.isEmpty }) {
            normalizedFamilyNameKey($0)
        }

        return grouped.map { key, variants in
            FamilyNameFilterOption(
                id: key,
                displayName: displayFamilyName(for: key, variants: variants),
                variants: variants.sorted()
            )
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private func cyrillicAlias(for familyName: String) -> String {
        switch familyName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "saparov": return "Сапаров"
        case "fedotova": return "Федотова"
        default: return familyName
        }
    }

    private func masculineFamilyName(_ familyName: String) -> String {
        let name = cyrillicAlias(for: familyName)
        let lower = name.lowercased()

        if lower.hasSuffix("ская") { return String(name.dropLast(4)) + "ской" }
        if lower.hasSuffix("ова") { return String(name.dropLast(3)) + "ов" }
        if lower.hasSuffix("ева") { return String(name.dropLast(3)) + "ев" }
        if lower.hasSuffix("ина") { return String(name.dropLast(3)) + "ин" }
        return name
    }

    private func normalizedFamilyNameKey(_ familyName: String) -> String {
        masculineFamilyName(familyName)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    private func displayFamilyName(for key: String, variants: [String]) -> String {
        // Use the same language-aware name data as the rows themselves. The
        // filter still collapses married/feminine variants to one masculine
        // key, but its visible label follows the selected app language.
        if let localizedSurname = variants.compactMap({ NameLocalizationStore.shared.localizedFamilyName(for: $0) }).first {
            return masculineFamilyName(localizedSurname)
        }

        if let localizedPerson = repository.people.first(where: {
            variants.contains($0.familyName) && $0.displayName != $0.sourceDisplayName
        }) {
            let localizedSurname = localizedPerson.displayName.split(separator: " ").last.map(String.init) ?? localizedPerson.familyName
            return masculineFamilyName(localizedSurname)
        }

        let cyrillicVariant = variants.first { variant in
            cyrillicAlias(for: variant).unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
        }
        let source = cyrillicVariant ?? variants.first ?? key
        return masculineFamilyName(ArchiveCopy.familyName(source))
    }

    private func birthYearOrder(_ left: Person, _ right: Person) -> Bool {
        let leftYear = sortingBirthYear(for: left) ?? Int.max
        let rightYear = sortingBirthYear(for: right) ?? Int.max
        if leftYear != rightYear { return leftYear < rightYear }
        return left.displayName.localizedStandardCompare(right.displayName) == .orderedAscending
    }

    private func sortingBirthYear(for person: Person) -> Int? {
        repository.chronologicalBirthYear(for: person.id)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    archiveHeader

                    SearchField(text: $searchText, placeholder: ArchiveCopy.text(english: "Search family", russian: "Поиск по семье"))
                        .padding(.top, 12)
                        .padding(.bottom, 10)

                    filterControls
                        .padding(.bottom, 16)

                    if activeFilterCount > 0 {
                        activeFilterBubbles
                            .padding(.bottom, 14)
                    }

                    if filteredPeople.isEmpty {
                        ContentUnavailableView(
                            searchText.isEmpty ? ArchiveCopy.text(english: "No matching people", russian: "Люди не найдены") : ArchiveCopy.text(english: "No results", russian: "Нет результатов"),
                            systemImage: "person.2"
                        )
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredPeople) { person in
                                NavigationLink(value: person.id) {
                                    PersonRow(
                                        person: person,
                                        repository: repository,
                                        isAccountHolder: repository.accountHolderID == person.id
                                    )
                                }
                                .buttonStyle(.plain)

                                Divider()
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, ArchiveLayout.pageHorizontal)
            .background(ArchiveTheme.background)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Person.ID.self) { personID in
                if let person = repository.person(id: personID) {
                    PersonDetailView(person: person, repository: repository)
                } else {
                    ContentUnavailableView(
                        "Person not found",
                        systemImage: "person.crop.circle.badge.questionmark"
                    )
                }
            }
            .sheet(isPresented: $showingFilters) {
                FamilyFilterSheet(
                    repository: repository,
                    familyNameOptions: familyNameOptions,
                    connectionScopeCounts: connectionScopeCounts,
                    availableCenturies: availableBirthCenturies,
                    familyNameKey: selectedFamilyNameKey,
                    storiesOnly: storiesOnly,
                    connectionScope: selectedConnectionScope,
                    birthMonth: selectedBirthMonth,
                    deathMonth: selectedDeathMonth,
                    century: selectedCentury
                ) { familyNameKey, storiesOnly, connectionScope, birthMonth, deathMonth, century in
                    selectedFamilyNameKey = familyNameKey
                    self.storiesOnly = storiesOnly
                    selectedConnectionScope = connectionScope
                    selectedBirthMonth = birthMonth
                    selectedDeathMonth = deathMonth
                    selectedCentury = century
                }
            }
            .onAppear {
                if let initialPersonID {
                    guard navigationPath.isEmpty else { return }
                    navigationPath.append(initialPersonID)
                } else {
                    // A normal launch should always land on the family list,
                    // even if SwiftUI restored a previously open profile route.
                    navigationPath = NavigationPath()
                }
            }
        }
    }

    private var filterControls: some View {
        Button {
            showingFilters = true
        } label: {
            filterControlLabel(
                title: activeFilterCount == 0
                    ? ArchiveCopy.text(english: "Filters", russian: "Фильтры")
                    : ArchiveCopy.text(english: "Filters · \(activeFilterCount)", russian: "Фильтры · \(activeFilterCount)"),
                systemImage: "line.3.horizontal.decrease.circle",
                isSelected: activeFilterCount > 0
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ArchiveCopy.text(english: "Open family filters", russian: "Открыть фильтры семьи"))
    }

    private func monthName(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: repository.appLanguage == .russian ? "ru_RU" : "en_US_POSIX")
        formatter.dateFormat = "LLLL"
        return formatter.string(from: Calendar(identifier: .gregorian).date(from: DateComponents(year: 2000, month: month, day: 1)) ?? Date())
    }

    private func monthFilterLabel(_ selection: DateFilterSelection, englishPrefix: String, russianPrefix: String) -> String {
        switch selection {
        case .any:
            return ArchiveCopy.text(english: "\(englishPrefix) month", russian: "Месяц: \(russianPrefix.lowercased())")
        case .unknown:
            return ArchiveCopy.text(english: "\(englishPrefix): unknown month", russian: "\(russianPrefix): месяц неизвестен")
        case .value(let month):
            return ArchiveCopy.text(english: "\(englishPrefix): \(monthName(month))", russian: "\(russianPrefix): \(monthName(month))")
        }
    }

    private var centuryFilterLabel: String {
        switch selectedCentury {
        case .any:
            ArchiveCopy.text(english: "Lived in century", russian: "Жил в веке")
        case .unknown:
            ArchiveCopy.text(english: "Lived in: unknown century", russian: "Жил в: век неизвестен")
        case .value(let century):
            ArchiveCopy.text(english: "Lived in: \(centuryName(century))", russian: "Жил в: \(centuryName(century))")
        }
    }

    private var activeFilterBubbles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let selectedFamilyNameKey,
                   let name = familyNameOptions.first(where: { $0.id == selectedFamilyNameKey })?.displayName {
                    FilterBubble(title: name) { self.selectedFamilyNameKey = nil }
                }
                if storiesOnly {
                    FilterBubble(title: ArchiveCopy.text(english: "Has stories", russian: "Есть истории")) {
                        storiesOnly = false
                    }
                }
                if selectedConnectionScope != .all {
                    FilterBubble(title: connectionFilterTitle) { selectedConnectionScope = .all }
                }
                if selectedBirthMonth != .any {
                    FilterBubble(title: monthFilterLabel(selectedBirthMonth, englishPrefix: "Birth", russianPrefix: "Рождение")) {
                        selectedBirthMonth = .any
                    }
                }
                if selectedDeathMonth != .any {
                    FilterBubble(title: monthFilterLabel(selectedDeathMonth, englishPrefix: "Death", russianPrefix: "Смерть")) {
                        selectedDeathMonth = .any
                    }
                }
                if selectedCentury != .any {
                    FilterBubble(title: centuryFilterLabel) { selectedCentury = .any }
                }
            }
        }
    }

    private var connectionFilterTitle: String {
        switch selectedConnectionScope {
        case .all: ArchiveCopy.text(english: "Everyone", russian: "Все")
        case .withinOne: ArchiveCopy.text(english: "Within 1 connection", russian: "До 1 связи")
        case .withinTwo: ArchiveCopy.text(english: "Within 2 connections", russian: "До 2 связей")
        case .withinThree: ArchiveCopy.text(english: "Within 3 connections", russian: "До 3 связей")
        }
    }

    private func centuryName(_ century: Int) -> String {
        let suffix = century == 1 ? "st" : century == 2 ? "nd" : century == 3 ? "rd" : "th"
        return ArchiveCopy.text(english: "\(century)\(suffix) century", russian: "\(century)-й век")
    }

    private func filterControlLabel(title: String, systemImage: String, isSelected: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(ArchiveTypography.metadataEmphasis)
        .foregroundStyle(isSelected ? .white : ArchiveTheme.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? ArchiveTheme.accent : ArchiveTheme.controlBackground)
        .clipShape(ArchiveShape.control)
        .overlay(
            ArchiveShape.control
                .stroke(isSelected ? ArchiveTheme.accent : ArchiveTheme.controlBorder, lineWidth: 1)
        )
    }

    private struct FilterBubble: View {
        let title: String
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 5) {
                    Text(title)
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .font(ArchiveTypography.metadata)
                .foregroundStyle(ArchiveTheme.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(ArchiveTheme.controlBackground)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(ArchiveTheme.controlBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private func filterMenuLabel(_ title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title)
            if isSelected {
                Spacer()
                Image(systemName: "checkmark")
            }
        }
    }

    private var archiveHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(ArchiveCopy.text(english: "FAMILY", russian: "СЕМЬЯ"))
                .font(ArchiveTypography.sectionTitle)
                .tracking(1.2)
                .foregroundStyle(ArchiveTheme.ink)

            Text("·")
                .font(ArchiveTypography.metadata)
                .foregroundStyle(ArchiveTheme.metadata)

            Text("\(repository.people.count)")
                .font(ArchiveTypography.metadataEmphasis)
                .foregroundStyle(ArchiveTheme.metadata)
        }
        .padding(.top, ArchiveLayout.pageTop)
    }
}

/// A persistent staging area for family filters. Changes stay local to the
/// sheet until the user taps Apply, so several filters can be chosen before
/// the list is recalculated. This avoids the old one-selection-at-a-time menu
/// behavior, where the menu dismissed after every choice.
private struct FamilyFilterSheet: View {
    @ObservedObject var repository: FamilyRepository
    let familyNameOptions: [FamilyNameFilterOption]
    let connectionScopeCounts: [ConnectionScope: Int]
    let availableCenturies: [Int]
    let onApply: (String?, Bool, ConnectionScope, DateFilterSelection, DateFilterSelection, DateFilterSelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var familyNameKey: String?
    @State private var storiesOnly: Bool
    @State private var connectionScope: ConnectionScope
    @State private var birthMonth: DateFilterSelection
    @State private var deathMonth: DateFilterSelection
    @State private var century: DateFilterSelection

    init(
        repository: FamilyRepository,
        familyNameOptions: [FamilyNameFilterOption],
        connectionScopeCounts: [ConnectionScope: Int],
        availableCenturies: [Int],
        familyNameKey: String?,
        storiesOnly: Bool,
        connectionScope: ConnectionScope,
        birthMonth: DateFilterSelection,
        deathMonth: DateFilterSelection,
        century: DateFilterSelection,
        onApply: @escaping (String?, Bool, ConnectionScope, DateFilterSelection, DateFilterSelection, DateFilterSelection) -> Void
    ) {
        self.repository = repository
        self.familyNameOptions = familyNameOptions
        self.connectionScopeCounts = connectionScopeCounts
        self.availableCenturies = availableCenturies
        self.onApply = onApply
        _familyNameKey = State(initialValue: familyNameKey)
        _storiesOnly = State(initialValue: storiesOnly)
        _connectionScope = State(initialValue: connectionScope)
        _birthMonth = State(initialValue: birthMonth)
        _deathMonth = State(initialValue: deathMonth)
        _century = State(initialValue: century)
    }

    private var isRussian: Bool { repository.appLanguage == .russian }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(ArchiveCopy.text(
                        english: "Choose any filters, then apply them together.",
                        russian: "Выберите фильтры и примените их вместе."
                    ))
                    .font(ArchiveTypography.body)
                    .foregroundStyle(ArchiveTheme.muted)

                    filterSection(
                        title: ArchiveCopy.text(english: "PEOPLE", russian: "ЛЮДИ")
                    ) {
                        filterMenuRow(
                            title: ArchiveCopy.text(english: "Last name", russian: "Фамилия"),
                            value: familyNameOptions.first(where: { $0.id == familyNameKey })?.displayName
                                ?? ArchiveCopy.text(english: "Everyone", russian: "Все фамилии")
                        ) {
                            Button {
                                familyNameKey = nil
                            } label: {
                                selectionLabel(ArchiveCopy.text(english: "All last names", russian: "Все фамилии"), isSelected: familyNameKey == nil)
                            }
                            Divider()
                            ForEach(familyNameOptions) { option in
                                Button {
                                    familyNameKey = option.id
                                } label: {
                                    selectionLabel(option.displayName, isSelected: familyNameKey == option.id)
                                }
                            }
                        }

                        filterToggleRow(
                            title: ArchiveCopy.text(english: "Has stories", russian: "Есть истории"),
                            isOn: $storiesOnly
                        )

                        filterMenuRow(
                            title: ArchiveCopy.text(english: "Relationship", russian: "Родственная связь"),
                            value: connectionScope.label(count: connectionScopeCounts[connectionScope] ?? 0)
                        ) {
                            ForEach(ConnectionScope.allCases) { scope in
                                Button {
                                    connectionScope = scope
                                } label: {
                                    selectionLabel(
                                        scope.label(count: connectionScopeCounts[scope] ?? 0),
                                        isSelected: connectionScope == scope
                                    )
                                }
                            }
                        }
                    }

                    filterSection(
                        title: ArchiveCopy.text(english: "DATES", russian: "ДАТЫ")
                    ) {
                        filterMenuRow(
                            title: ArchiveCopy.text(english: "Birth month", russian: "Месяц рождения"),
                            value: monthSelectionLabel(birthMonth, kind: .birth)
                        ) {
                            monthMenuItems(selection: $birthMonth)
                        }

                        filterMenuRow(
                            title: ArchiveCopy.text(english: "Death month", russian: "Месяц смерти"),
                            value: monthSelectionLabel(deathMonth, kind: .death)
                        ) {
                            monthMenuItems(selection: $deathMonth)
                        }

                        filterMenuRow(
                            title: ArchiveCopy.text(english: "Lived in century", russian: "Век жизни"),
                            value: centurySelectionLabel
                        ) {
                            Button {
                                century = .any
                            } label: {
                                selectionLabel(ArchiveCopy.text(english: "Any century", russian: "Любой век"), isSelected: century == .any)
                            }
                            Button {
                                century = .unknown
                            } label: {
                                selectionLabel(ArchiveCopy.text(english: "Unknown century", russian: "Век неизвестен"), isSelected: century == .unknown)
                            }
                            if !availableCenturies.isEmpty { Divider() }
                            ForEach(availableCenturies, id: \.self) { value in
                                Button {
                                    century = .value(value)
                                } label: {
                                    selectionLabel(centuryName(value), isSelected: century == .value(value))
                                }
                            }
                        }
                    }

                    Button {
                        clearAll()
                    } label: {
                        Text(ArchiveCopy.text(english: "Clear all filters", russian: "Очистить все фильтры"))
                            .font(ArchiveTypography.action)
                            .foregroundStyle(ArchiveTheme.action)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                .padding(.horizontal, ArchiveLayout.pageHorizontal)
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(ArchiveTheme.background)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(ArchiveTypography.icon)
                            .foregroundStyle(ArchiveTheme.ink)
                    }
                    .accessibilityLabel(ArchiveCopy.text(english: "Cancel", russian: "Отмена"))
                }
                ToolbarItem(placement: .principal) {
                    Text(ArchiveCopy.text(english: "Filters", russian: "Фильтры"))
                        .font(ArchiveTypography.navigationTitle)
                        .foregroundStyle(ArchiveTheme.ink)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onApply(familyNameKey, storiesOnly, connectionScope, birthMonth, deathMonth, century)
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(ArchiveTypography.icon)
                            .foregroundStyle(ArchiveTheme.ink)
                    }
                    .accessibilityLabel(ArchiveCopy.text(english: "Apply filters", russian: "Применить фильтры"))
                }
            }
            .toolbarBackground(ArchiveTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        // Filters are a focused task, so open the sheet at full height. The
        // half-height detent hid the date choices and made the panel feel
        // transient instead of like a standard settings screen.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(ArchiveTheme.background)
    }

    private enum MonthKind {
        case birth
        case death
    }

    @ViewBuilder
    private func filterSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ArchiveTypography.sectionTitle)
                .tracking(1.2)
                .foregroundStyle(ArchiveTheme.ink)

            VStack(spacing: 0) {
                content()
            }
            .background(ArchiveTheme.controlBackground)
            .clipShape(ArchiveShape.control)
            .overlay(ArchiveShape.control.stroke(ArchiveTheme.controlBorder, lineWidth: 1))
        }
    }

    @ViewBuilder
    private func filterMenuRow<MenuContent: View>(title: String, value: String, @ViewBuilder menu: @escaping () -> MenuContent) -> some View {
        Menu {
            menu()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(ArchiveTypography.metadataEmphasis)
                        .foregroundStyle(ArchiveTheme.ink)
                    Text(value)
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(ArchiveTypography.metadataEmphasis)
                    .foregroundStyle(ArchiveTheme.action)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(ArchiveTheme.controlBorder)
                    .frame(height: 1)
                    .padding(.leading, 14)
            }
        }
        .buttonStyle(.plain)
    }

    private func filterToggleRow(title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(ArchiveTypography.metadataEmphasis)
                .foregroundStyle(ArchiveTheme.ink)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(ArchiveTheme.action)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ArchiveTheme.controlBorder)
                .frame(height: 1)
                .padding(.leading, 14)
        }
    }

    private func selectionLabel(_ title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title)
            if isSelected {
                Spacer()
                Image(systemName: "checkmark")
            }
        }
    }

    @ViewBuilder
    private func monthMenuItems(selection: Binding<DateFilterSelection>) -> some View {
        Button {
            selection.wrappedValue = .any
        } label: {
            selectionLabel(ArchiveCopy.text(english: "Any month", russian: "Любой месяц"), isSelected: selection.wrappedValue == .any)
        }
        Button {
            selection.wrappedValue = .unknown
        } label: {
            selectionLabel(ArchiveCopy.text(english: "Unknown month", russian: "Месяц неизвестен"), isSelected: selection.wrappedValue == .unknown)
        }
        Divider()
        ForEach(1...12, id: \.self) { month in
            Button {
                selection.wrappedValue = .value(month)
            } label: {
                selectionLabel(monthName(month), isSelected: selection.wrappedValue == .value(month))
            }
        }
    }

    private func monthSelectionLabel(_ selection: DateFilterSelection, kind: MonthKind) -> String {
        let prefix = kind == .birth
            ? ArchiveCopy.text(english: "Birth", russian: "Рождение")
            : ArchiveCopy.text(english: "Death", russian: "Смерть")
        switch selection {
        case .any:
            return ArchiveCopy.text(english: "Any month", russian: "Любой месяц")
        case .unknown:
            return ArchiveCopy.text(english: "Unknown month", russian: "Месяц неизвестен")
        case .value(let month):
            return "\(prefix): \(monthName(month))"
        }
    }

    private var centurySelectionLabel: String {
        switch century {
        case .any:
            return ArchiveCopy.text(english: "Any century", russian: "Любой век")
        case .unknown:
            return ArchiveCopy.text(english: "Unknown century", russian: "Век неизвестен")
        case .value(let value):
            return centuryName(value)
        }
    }

    private func monthName(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: isRussian ? "ru_RU" : "en_US_POSIX")
        formatter.dateFormat = "LLLL"
        return formatter.string(from: Calendar(identifier: .gregorian).date(from: DateComponents(year: 2000, month: month, day: 1)) ?? Date())
    }

    private func centuryName(_ century: Int) -> String {
        let suffix = century == 1 ? "st" : century == 2 ? "nd" : century == 3 ? "rd" : "th"
        return ArchiveCopy.text(english: "\(century)\(suffix) century", russian: "\(century)-й век")
    }

    private func clearAll() {
        familyNameKey = nil
        storiesOnly = false
        connectionScope = .all
        birthMonth = .any
        deathMonth = .any
        century = .any
    }
}

struct FamilyMemberTile: View {
    let person: Person
    let repository: FamilyRepository?
    var isAccountHolder = false
    var relationshipDetail: String? = nil

    init(
        person: Person,
        repository: FamilyRepository? = nil,
        isAccountHolder: Bool = false,
        relationshipDetail: String? = nil
    ) {
        self.person = person
        self.repository = repository
        self.isAccountHolder = isAccountHolder
        self.relationshipDetail = relationshipDetail
    }

    private var isLiving: Bool {
        repository?.isLiving(person) ?? person.isLiving
    }

    private var hasUnknownDeathDate: Bool {
        repository?.hasUnknownDeathDate(person) ?? (!isLiving && person.deathFact == nil)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            FamilyMemberPhotoView(person: person, size: 40, repository: repository)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(NameLocalizationStore.shared.displayName(
                            for: person.id,
                            fallback: person.sourceDisplayName,
                            language: .current
                        ))
                        .font(ArchiveTypography.contentTitle)
                        .foregroundStyle(isLiving ? ArchiveTheme.ink : ArchiveTheme.metadata)

                    if isAccountHolder {
                        AccountHolderBadge()
                    }

                    Spacer(minLength: 6)

                    if person.hasStories {
                        ProfileContentBadge()
                    }

                    if photoCount > 1 {
                        PhotoContentBadge()
                    }
                }

                HStack(spacing: 5) {
                        Text(person.lifeDateLine(
                            language: .current,
                            includeUnknownDeathDate: hasUnknownDeathDate
                        ))
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.metadata)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .layoutPriority(1)
                }

                if let relationshipDetail, !relationshipDetail.isEmpty {
                    Text(relationshipDetail)
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.metadata)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var photoCount: Int {
        let media = repository?.media(for: person.id) ?? person.media
        return media.filter { $0.kind == .photo }.count
    }
}

struct AccountHolderBadge: View {
    var body: some View {
        Text(ArchiveCopy.text(english: "YOU", russian: "ВЫ"))
            .font(ArchiveTypography.sectionTitle)
            .tracking(0.8)
            .foregroundStyle(ArchiveTheme.action)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay {
                Rectangle()
                    .stroke(ArchiveTheme.action, lineWidth: 1)
            }
            .accessibilityLabel("You, account holder")
    }
}

private struct ProfileContentBadge: View {
    var body: some View {
        Image(systemName: "book.pages")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ArchiveTheme.muted)
            .accessibilityLabel(ArchiveCopy.text(english: "Stories available", russian: "Есть истории"))
    }
}

private struct PhotoContentBadge: View {
    var body: some View {
        Image(systemName: "photo")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ArchiveTheme.muted)
            .accessibilityLabel(ArchiveCopy.text(english: "More than one photo", russian: "Больше одной фотографии"))
    }
}

private struct FamilyMemberPhotoView: View {
    let person: Person
    let size: CGFloat
    let repository: FamilyRepository?

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(CGFloat(currentPerson.profileImageScale ?? 1))
                    .offset(
                        x: CGFloat(currentPerson.profileImageOffsetX ?? 0) * size / 300,
                        y: CGFloat(currentPerson.profileImageOffsetY ?? 0) * size / 300
                    )
                    .grayscale((repository?.isLiving(currentPerson) ?? currentPerson.isLiving) ? 0 : 1)
            } else {
                MonogramView(person: currentPerson, size: size, isLiving: repository?.isLiving(currentPerson) ?? currentPerson.isLiving)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel("Photo for \(person.displayName)")
    }

    private var loadedImage: UIImage? {
        let path = repository?.photoPath(for: currentPerson.id) ?? currentPerson.profileImagePath ?? currentPerson.media.first(where: { $0.kind == .photo })?.path
        guard let path else { return nil }
        return ArchiveFileResolver.image(for: path)
    }

    private var currentPerson: Person {
        repository?.person(id: person.id) ?? person
    }
}

private struct PersonRow: View {
    let person: Person
    let repository: FamilyRepository
    let isAccountHolder: Bool

    var body: some View {
        FamilyMemberTile(person: person, repository: repository, isAccountHolder: isAccountHolder)
    }
}

extension Person {
    var hasStories: Bool {
        !biography.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !structuredStories.isEmpty
    }

    var hasProfileContent: Bool {
        hasStories ||
            sources.contains { source in
                let kind = source.kind.lowercased()
                let locator = source.locator.lowercased()
                return kind.contains("html") || locator.hasSuffix(".html")
            }
    }

    var birthYear: Int? {
        if let birthValue = birthFact?.value {
            return birthValue
                .split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }
                .first(where: { (1000...2100).contains($0) })
        }

        // A lifespan such as "????–1889" contains only a death year. Do not
        // mistake that year for a birth year when ordering the family list.
        let trimmedLifespan = lifespan.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLifespan.hasPrefix("?") else { return nil }

        let value = trimmedLifespan
        return value
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
            .first(where: { (1000...2100).contains($0) })
    }

    var lifeDateLine: String {
        lifeDateLine(language: nil)
    }

    func lifeDateLine(
        language: ArchiveLanguage?,
        includeUnknownDeathDate: Bool = false
    ) -> String {
        let birth = birthFact?.value
        let death = deathFact?.value

        switch (birth, death) {
        case let (birth?, death?):
            let range = "\(localizedDate(birth, language: language)) - \(localizedDate(death, language: language))"
            return ArchiveDateFormatter.displayRange(range, language: language) ?? range
        case let (birth?, nil):
            let displayedBirth = localizedDate(birth, language: language)
            return includeUnknownDeathDate ? "\(displayedBirth) - ????" : displayedBirth
        case let (nil, death?):
            return "???? - \(localizedDate(death, language: language))"
        case (nil, nil):
            let normalized = lifespan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "unknown" || normalized == "????" || normalized.isEmpty {
                return includeUnknownDeathDate ? "???? - ????" : "????"
            }

            if let range = ArchiveDateFormatter.displayRange(lifespan, language: language), range.contains(" - ") {
                return range
            }

            // A few imported records use two whitespace-separated endpoints
            // (for example, "1858 ????"). Keep the list's range format stable.
            let endpoints = normalized.split(whereSeparator: { $0.isWhitespace })
            if endpoints.count == 2,
               endpoints.allSatisfy({ $0 == "????" || ($0.count == 4 && $0.allSatisfy(\.isNumber)) }) {
                let start = localizedDate(String(endpoints[0]), language: language)
                let end = localizedDate(String(endpoints[1]), language: language)
                return "\(start) - \(end)"
            }

            let displayed = localizedDate(normalized, language: language)
            return includeUnknownDeathDate ? "\(displayed) - ????" : displayed
        }
    }

    private func localizedDate(_ value: String, language: ArchiveLanguage?) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "unknown" || normalized == "????" || normalized.isEmpty {
            return "????"
        }
        // This is a single fact, not a range. Keeping the single-date path
        // explicit preserves a complete day/month/year whenever it exists.
        return ArchiveDateFormatter.display(value, language: language) ?? value
    }
}

private struct SearchField: View {
    @Binding var text: String
    let placeholder: String

    init(text: Binding<String>, placeholder: String) {
        _text = text
        self.placeholder = placeholder
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(ArchiveTypography.icon)
                .foregroundStyle(ArchiveTheme.muted)

            TextField(placeholder, text: $text)
                .font(ArchiveTypography.body)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(ArchiveTheme.controlBackground)
        .clipShape(ArchiveShape.control)
        .overlay(
            ArchiveShape.control
                .stroke(ArchiveTheme.controlBorder, lineWidth: 1)
        )
    }
}

struct MonogramView: View {
    let person: Person
    let size: CGFloat
    let isLiving: Bool

    init(person: Person, size: CGFloat, isLiving: Bool? = nil) {
        self.person = person
        self.size = size
        self.isLiving = isLiving ?? person.isLiving
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [ArchiveTheme.accent, ArchiveTheme.accentLight],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text(person.initials)
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .grayscale(isLiving ? 0 : 1)
        .accessibilityHidden(true)
    }
}

struct MainTabView: View {
    @ObservedObject var repository: FamilyRepository
    let initialPersonID: Person.ID?

    @State private var selectedTab: MainTab = .home
    @State private var familyResetID = UUID()
    @State private var shouldOpenInitialPerson = true
    @State private var personIDToOpen: Person.ID?
    @State private var homePerson: PresentedPerson?
    @State private var treePerson: PresentedPerson?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case .home:
                    HomeView(repository: repository) { personID in
                        // Present profiles from Home as a sheet so closing the
                        // profile returns to the same Home context.
                        homePerson = PresentedPerson(id: personID)
                    }
                    case .tree:
                        TopolaTreeView(repository: repository) { personID in
                            treePerson = PresentedPerson(id: personID)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .family:
                    PeopleListView(
                        repository: repository,
                        initialPersonID: personIDToOpen ?? (shouldOpenInitialPerson ? initialPersonID : nil)
                    )
                    .id(familyResetID)
                case .memories:
                    MemoriesView(repository: repository)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ArchiveBottomNavigation(selectedTab: $selectedTab) { tab in
                if tab == .family {
                    personIDToOpen = nil
                    shouldOpenInitialPerson = false
                    familyResetID = UUID()
                }
                selectedTab = tab
            }
        }
        .background(ArchiveTheme.background)
        .sheet(item: $homePerson) { presented in
            if let person = repository.person(id: presented.id) {
                NavigationStack {
                    PersonDetailView(person: person, repository: repository)
                }
            }
        }
        .sheet(item: $treePerson) { presented in
            if let person = repository.person(id: presented.id) {
                NavigationStack {
                    PersonDetailView(person: person, repository: repository)
                }
            }
        }
        .onAppear {
            // A fresh app launch is a welcoming Home experience. Selecting
            // Family from the bottom bar can still open the requested person.
            selectedTab = .home
        }
    }
}

private struct PresentedPerson: Identifiable {
    let id: Person.ID
}

private struct ArchiveBottomNavigation: View {
    @Binding var selectedTab: MainTab
    let onSelect: (MainTab) -> Void

    init(selectedTab: Binding<MainTab>, onSelect: @escaping (MainTab) -> Void = { _ in }) {
        _selectedTab = selectedTab
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases, id: \.self) { tab in
                Button {
                    onSelect(tab)
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.systemImage)
                            .font(ArchiveTypography.icon)

                        Text(tab.title)
                            .font(ArchiveTypography.metadataEmphasis)
                            .lineLimit(1)
                    }
                    .foregroundStyle(selectedTab == tab ? .white : Color.white.opacity(0.68))
                    .frame(maxWidth: .infinity)
                    .frame(height: 68)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                .accessibilityLabel(tab.title)
            }
        }
        .frame(height: 68)
        .background(ArchiveTheme.navigationBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ArchiveTheme.navigationBackground)
                .frame(height: 1)
        }
    }
}

enum MainTab: Hashable, CaseIterable {
    case home
    case tree
    case family
    case memories

    var title: String {
        switch self {
        case .home: ArchiveCopy.text(english: "Home", russian: "Главная")
        case .tree: ArchiveCopy.text(english: "Tree", russian: "Дерево")
        case .family: ArchiveCopy.text(english: "Family", russian: "Семья")
        case .memories: ArchiveCopy.text(english: "Archive", russian: "Архив")
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .tree: "point.3.connected.trianglepath.dotted"
        case .family: "person.2"
        case .memories: "photo.on.rectangle"
        }
    }
}

enum ArchiveTheme {
    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    // The night palette stays in the archive's gray-green family. In
    // particular, the old near-black ink color was unreadable against the
    // system dark background.
    static let background = adaptive(
        light: UIColor(red: 0.99, green: 1.00, blue: 0.99, alpha: 1),
        dark: UIColor(red: 0.08, green: 0.13, blue: 0.12, alpha: 1)
    )
    static let accent = adaptive(
        light: UIColor(red: 0.66, green: 0.24, blue: 0.08, alpha: 1),
        dark: UIColor(red: 0.96, green: 0.53, blue: 0.30, alpha: 1)
    )
    static let accentLight = adaptive(
        light: UIColor(red: 0.88, green: 0.43, blue: 0.16, alpha: 1),
        dark: UIColor(red: 1.00, green: 0.68, blue: 0.46, alpha: 1)
    )
    static let ink = adaptive(
        light: UIColor(red: 0.12, green: 0.18, blue: 0.17, alpha: 1),
        dark: UIColor(red: 0.88, green: 0.94, blue: 0.91, alpha: 1)
    )
    static let muted = adaptive(
        light: UIColor(red: 0.34, green: 0.39, blue: 0.37, alpha: 1),
        dark: UIColor(red: 0.68, green: 0.77, blue: 0.73, alpha: 1)
    )
    static let metadata = adaptive(
        light: UIColor(red: 0.46, green: 0.50, blue: 0.48, alpha: 1),
        dark: UIColor(red: 0.61, green: 0.71, blue: 0.67, alpha: 1)
    )
    static let controlBackground = adaptive(
        light: UIColor(red: 0.99, green: 1.00, blue: 0.99, alpha: 1),
        dark: UIColor(red: 0.13, green: 0.21, blue: 0.19, alpha: 1)
    )
    static let controlBorder = adaptive(
        light: UIColor.separator,
        dark: UIColor(red: 0.27, green: 0.39, blue: 0.35, alpha: 1)
    )
    static let actionBackground = adaptive(
        light: UIColor(red: 0.93, green: 0.95, blue: 0.94, alpha: 1),
        dark: UIColor(red: 0.16, green: 0.27, blue: 0.24, alpha: 1)
    )
    static let mention = adaptive(
        light: UIColor(red: 0.10, green: 0.30, blue: 0.25, alpha: 1),
        dark: UIColor(red: 0.46, green: 0.76, blue: 0.63, alpha: 1)
    )
    static let navigationBackground = adaptive(
        light: UIColor(red: 0.12, green: 0.18, blue: 0.17, alpha: 1),
        dark: UIColor(red: 0.05, green: 0.10, blue: 0.09, alpha: 1)
    )
    static let action = accent
}

enum ArchiveTypography {
    static let navigationTitle = Font.system(size: 17, weight: .semibold)
    static let pageTitle = Font.system(size: 34, weight: .bold)
    static let profileName = Font.system(size: 28, weight: .bold)
    /// SwiftUI aligns text using its line box. This is the distance from that
    /// line-box top to the capital-letter top for the profile-name font.
    static let profileNameOpticalTopInset: CGFloat = {
        let font = UIFont.systemFont(ofSize: 28, weight: .bold)
        return max(0, (font.lineHeight - font.capHeight) / 2)
    }()
    static let body = Font.system(size: 15, weight: .regular)
    static let paragraph = body
    static let bodyEmphasis = Font.system(size: 17, weight: .semibold)
    static let supporting = Font.system(size: 15, weight: .regular)
    static let supportingEmphasis = Font.system(size: 15, weight: .semibold)
    static let contentTitle = Font.system(size: 16, weight: .medium)
    static let metadata = Font.system(size: 13, weight: .regular)
    static let metadataEmphasis = Font.system(size: 13, weight: .semibold)
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static let action = Font.system(size: 14, weight: .semibold)
    static let icon = Font.system(size: 17, weight: .semibold)
}

enum ArchiveLayout {
    static let pageHorizontal: CGFloat = 20
    static let pageTop: CGFloat = 28
    static let pageBottom: CGFloat = 32
}

enum ArchiveShape {
    static let control = Rectangle()
    static let actionDiameter: CGFloat = 40
}

private struct HomeView: View {
    @ObservedObject var repository: FamilyRepository
    let onOpenPerson: (Person.ID) -> Void
    @State private var showingSettings = false

    private var accountHolder: Person? {
        repository.accountHolder
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(greeting)
                        .font(.system(.largeTitle).weight(.bold))

                    Text(ArchiveCopy.text(
                        english: "Your family, stories, and memories in one place.",
                        russian: "Ваша семья, истории и воспоминания — в одном месте."
                    ))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)

                    detailSection(ArchiveCopy.text(english: "Display", russian: "Отображение")) {
                        VStack(spacing: 12) {
                            HomePreferenceRow(
                                title: ArchiveCopy.text(english: "App language", russian: "Язык приложения")
                            ) {
                                Picker("App language", selection: $repository.appLanguage) {
                                    ForEach(ArchiveLanguage.allCases) { language in
                                        Text(language.label).tag(language)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 150)
                                .accessibilityLabel("App language")
                            }

                        }
                        .padding(.vertical, 12)
                    }
                    .padding(.top, 24)

                    detailSection(ArchiveCopy.text(english: "Upcoming dates to remember", russian: "Ближайшие важные даты")) {
                        ForEach(upcomingDates) { date in
                            Button {
                                onOpenPerson(date.personID)
                            } label: {
                                RememberedDateRow(date: date)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 28)

                    detailSection(ArchiveCopy.text(english: "Archive at a glance", russian: "Архив вкратце")) {
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                            spacing: 12
                        ) {
                            HomeStat(value: "\(repository.people.count)", label: ArchiveCopy.text(english: "People", russian: "Люди"))
                            HomeStat(value: "\(repository.people.filter { repository.isLiving($0) }.count)", label: ArchiveCopy.text(english: "Living", russian: "Живые"))
                            HomeStat(value: "\(repository.people.filter { !repository.isLiving($0) }.count)", label: ArchiveCopy.text(english: "Deceased", russian: "Ушедшие"))
                            HomeStat(value: "\(repository.people.reduce(0) { $0 + $1.media.count })", label: ArchiveCopy.text(english: "Memories", russian: "Воспоминания"))
                        }
                        .padding(.vertical, 14)
                        .background(ArchiveTheme.accent.opacity(0.06))
                    }
                    .padding(.top, 28)

                    detailSection(ArchiveCopy.text(english: "Family relationships", russian: "Родственные связи")) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(relationshipGroups) { group in
                                HomeRelationshipGroupView(
                                    group: group,
                                    repository: repository,
                                    onOpenPerson: onOpenPerson
                                )
                            }
                        }
                    }
                    .padding(.top, 28)
                }
                .padding(.horizontal, ArchiveLayout.pageHorizontal)
                .padding(.top, ArchiveLayout.pageTop)
                .padding(.bottom, ArchiveLayout.pageBottom)
            }
            .scrollIndicators(.hidden)
            .background(ArchiveTheme.background)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Button {
                        showingSettings = true
                    } label: {
                        UserProfilePhotoView(person: accountHolder, repository: repository, size: 40)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                    .accessibilityLabel("Open account settings")

                    Spacer()
                }
                .frame(height: 72)
                .padding(.horizontal, ArchiveLayout.pageHorizontal)
                .background(ArchiveTheme.actionBackground)
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView(person: accountHolder, repository: repository)
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = accountHolder?.displayGivenName ?? "Elena"
        switch hour {
        case 5..<12: return ArchiveCopy.text(english: "Good morning, \(name)", russian: "Доброе утро, \(name)")
        case 12..<18: return ArchiveCopy.text(english: "Good afternoon, \(name)", russian: "Добрый день, \(name)")
        default: return ArchiveCopy.text(english: "Good evening, \(name)", russian: "Добрый вечер, \(name)")
        }
    }

    private var upcomingDates: [RememberedDate] {
        var dates: [RememberedDate] = []

        for person in repository.people {
            if repository.isLiving(person) {
                if let birth = person.birthFact,
                   let parts = calendarParts(from: birth.value) {
                    let occurrence = upcomingOccurrence(month: parts.month, day: parts.day)
                    dates.append(RememberedDate(
                        id: "birthday-\(person.id)",
                        personID: person.id,
                        daysUntil: occurrence.daysUntil,
                        kind: .birthday,
                        eventLabel: ArchiveCopy.text(english: "Birthday", russian: "День рождения"),
                        personName: person.displayName,
                        detail: [fullDate(month: parts.month, day: parts.day, year: parts.year), birth.place.map(ArchiveCopy.place)].compactMap { $0 }.joined(separator: " · "),
                        occurrence: occurrence.date
                    ))
                }
            } else if let death = person.deathFact,
                      let parts = calendarParts(from: death.value) {
                let occurrence = upcomingOccurrence(month: parts.month, day: parts.day)
                dates.append(RememberedDate(
                    id: "remembrance-\(person.id)",
                    personID: person.id,
                    daysUntil: occurrence.daysUntil,
                    kind: .remembrance,
                    eventLabel: ArchiveCopy.text(english: "Remembrance day", russian: "День памяти"),
                    personName: person.displayName,
                    detail: [fullDate(month: parts.month, day: parts.day, year: parts.year), death.place.map(ArchiveCopy.place)].compactMap { $0 }.joined(separator: " · "),
                    occurrence: occurrence.date
                ))
            }
        }

        return dates.sorted { $0.occurrence < $1.occurrence }.prefix(5).map { $0 }
    }

    private func calendarParts(from value: String) -> (year: Int?, month: Int, day: Int)? {
        let formats = ["d MMMM yyyy", "d MMM yyyy", "MMMM d, yyyy", "MMM d, yyyy"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
                if let month = components.month, let day = components.day {
                    return (components.year, month, day)
                }
            }
        }
        return nil
    }

    private func fullDate(month: Int, day: Int, year: Int?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: repository.appLanguage == .russian ? "ru_RU" : "en_US_POSIX")
        formatter.dateFormat = year == nil
            ? (repository.appLanguage == .russian ? "d MMMM" : "MMMM d")
            : (repository.appLanguage == .russian ? "d MMMM yyyy" : "MMMM d, yyyy")
        return formatter.string(from: Calendar.current.date(from: DateComponents(year: year ?? 2000, month: month, day: day)) ?? Date())
    }

    private func upcomingOccurrence(month: Int, day: Int) -> (date: Date, daysUntil: Int) {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let year = calendar.component(.year, from: today)
        var candidate = calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? today
        if candidate < today {
            candidate = calendar.date(byAdding: .year, value: 1, to: candidate) ?? candidate
        }
        let daysUntil = max(0, calendar.dateComponents([.day], from: today, to: candidate).day ?? 0)
        return (candidate, daysUntil)
    }

    private var relationshipGroups: [HomeRelationshipGroup] {
        guard let accountHolder else { return [] }

        let graph = FamilyRelationshipGraph(repository: repository)
        let directParents = graph.parents(of: accountHolder.id)
        let directPartners = graph.partners(of: accountHolder.id)
        let directSiblings = graph.siblings(of: accountHolder.id)
        let directChildren = graph.children(of: accountHolder.id)
        let grandparents = Set(directParents.flatMap { graph.parents(of: $0.id) })
        let auntsAndUncles = Set(directParents.flatMap { graph.siblings(of: $0.id) })
        let cousins = Set(auntsAndUncles.flatMap { graph.children(of: $0.id) })
        // A niece or nephew is any descendant of a sibling, not only the
        // sibling's immediate children. Include grandnieces/nephews and
        // every later generation so the category does not silently stop at
        // the first level.
        let niecesAndNephews = Set(directSiblings.flatMap { graph.descendants(of: $0.id) })
        let grandchildren = Set(directChildren.flatMap { graph.children(of: $0.id) })
        let greatGrandparents = Set(grandparents.flatMap { graph.parents(of: $0.id) })
        let greatAuntsAndUncles = Set(grandparents.flatMap { graph.siblings(of: $0.id) })
        let olderGenerationCousinsOnceRemoved = Set(greatAuntsAndUncles.flatMap { graph.children(of: $0.id) })
        // Children (and later descendants) of the account holder's first
        // cousins are also first cousins once removed. The previous logic
        // only followed the great-aunt/uncle branch, which omitted people
        // such as Andrei Nosov's and Anna Fedotova's children.
        let cousinsOnceRemoved = Set(cousins.flatMap { graph.descendants(of: $0.id) })
        let firstCousinsOnceRemoved = olderGenerationCousinsOnceRemoved
            .union(cousinsOnceRemoved)
        // Keep the second-cousin calculation tied to the older-generation
        // branch; descendants of a first cousin are not second cousins.
        let secondCousins = Set(olderGenerationCousinsOnceRemoved.flatMap { graph.children(of: $0.id) })
        // In-laws are connected through the selected person's own marriage:
        // the partner's immediate family, plus partners of the selected
        // person's siblings and children. Parents' partners are not in-laws
        // of the selected person and must not be included here.
        let partnerFamily = directPartners.flatMap { partner in
            graph.parents(of: partner.id) +
                graph.siblings(of: partner.id) +
                graph.children(of: partner.id)
        }
        let siblingAndChildPartners = (directSiblings + directChildren).flatMap { graph.partners(of: $0.id) }
        let inLaws = Set((partnerFamily + siblingAndChildPartners).map(\.id))
            .subtracting(Set(directParents.map(\.id)))
            .subtracting(Set(directSiblings.map(\.id)))
            .subtracting(Set(directChildren.map(\.id)))
            .subtracting(Set(directPartners.map(\.id)))
            .subtracting([accountHolder.id])

        let groups: [(String, String, [Person])] = [
            ("parents", ArchiveCopy.text(english: "Parents", russian: "Родители"), directParents),
            ("grandparents", ArchiveCopy.text(english: "Grandparents", russian: "Бабушки и дедушки"), Array(grandparents)),
            ("siblings", ArchiveCopy.text(english: "Siblings", russian: "Братья и сёстры"), directSiblings),
            ("children", ArchiveCopy.text(english: "Children", russian: "Дети"), directChildren),
            ("partners", ArchiveCopy.text(english: "Spouse and partners", russian: "Супруги и партнёры"), directPartners),
            ("in-laws", ArchiveCopy.text(english: "In-laws", russian: "Связи через брак"), repository.people(ids: Array(inLaws))),
            ("aunts-uncles", ArchiveCopy.text(english: "Aunts and uncles", russian: "Тёти и дяди"), Array(auntsAndUncles)),
            ("first-cousins", ArchiveCopy.text(english: "First cousins", russian: "Двоюродные братья и сёстры"), Array(cousins)),
            ("nieces-nephews", ArchiveCopy.text(english: "Nieces and nephews", russian: "Племянники и племянницы"), Array(niecesAndNephews)),
            ("cousins-once-removed", ArchiveCopy.text(english: "First cousins once removed", russian: "Двоюродные родственники через поколение"), Array(firstCousinsOnceRemoved)),
            ("second-cousins", ArchiveCopy.text(english: "Second cousins", russian: "Троюродные братья и сёстры"), Array(secondCousins)),
            ("grandchildren", ArchiveCopy.text(english: "Grandchildren", russian: "Внуки"), Array(grandchildren)),
            ("great-grandparents", ArchiveCopy.text(english: "Great-grandparents", russian: "Прадедушки и прабабушки"), Array(greatGrandparents)),
            ("great-aunts-uncles", ArchiveCopy.text(english: "Great-aunts and great-uncles", russian: "Двоюродные бабушки и дедушки"), Array(greatAuntsAndUncles))
        ]

        return groups.compactMap { id, title, people in
            let uniquePeople = people
                .filter { $0.id != accountHolder.id }
                .reduce(into: [Person.ID: Person]()) { result, person in result[person.id] = person }
                .values
                .sorted { left, right in
                    left.displayName.localizedStandardCompare(right.displayName) == .orderedAscending
                }
            guard !uniquePeople.isEmpty else { return nil }
            return HomeRelationshipGroup(id: id, title: title, people: Array(uniquePeople))
        }
    }

    @ViewBuilder
    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(ArchiveTheme.accent)

            content()
        }
    }
}

private struct RememberedDate: Identifiable {
    let id: String
    let personID: Person.ID
    let daysUntil: Int
    let kind: Kind
    let eventLabel: String
    let personName: String
    let detail: String
    let occurrence: Date

    enum Kind {
        case birthday
        case remembrance

        var iconName: String {
            switch self {
            case .birthday: "birthday.cake.fill"
            case .remembrance: "flame.fill"
            }
        }

        var tint: Color {
            switch self {
            case .birthday: ArchiveTheme.accent
            case .remembrance: ArchiveTheme.accent.opacity(0.55)
            }
        }

    }
}

private struct RememberedDateRow: View {
    let date: RememberedDate

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 1) {
                Text(ArchiveCopy.countdown(days: date.daysUntil))
                    .font(ArchiveTypography.metadataEmphasis)
                    .foregroundStyle(ArchiveTheme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
            }
            .frame(width: 84, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: date.kind.iconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(date.kind.tint)
                        .accessibilityHidden(true)

                    Text(date.eventLabel)
                        .font(ArchiveTypography.metadataEmphasis)
                        .foregroundStyle(date.kind.tint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(date.personName)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(date.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.vertical, 11)
        // Explicit height keeps this separator horizontal. A SwiftUI Divider
        // attached to an HStack can otherwise be interpreted as vertical.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ArchiveTheme.controlBorder)
                .frame(height: 1)
        }
    }
}

private struct HomeRelationshipGroup: Identifiable {
    let id: String
    let title: String
    let people: [Person]
}

private struct HomeRelationshipGroupView: View {
    let group: HomeRelationshipGroup
    let repository: FamilyRepository
    let onOpenPerson: (Person.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.title)
                .font(ArchiveTypography.contentTitle)
                .foregroundStyle(ArchiveTheme.ink)
                .padding(.top, 12)

            ForEach(group.people) { person in
                Button {
                    onOpenPerson(person.id)
                } label: {
                    HStack(spacing: 10) {
                        UserProfilePhotoView(person: person, repository: repository, size: 34)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.displayName)
                                .font(ArchiveTypography.supportingEmphasis)
                                .foregroundStyle(repository.isLiving(person) ? ArchiveTheme.ink : ArchiveTheme.metadata)
                                .lineLimit(1)

                            if !person.lifeDateLine.isEmpty {
                                Text(person.lifeDateLine)
                                    .font(ArchiveTypography.metadata)
                                    .foregroundStyle(ArchiveTheme.metadata)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ArchiveTheme.metadata)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(person.displayName)")
            }
        }
    }
}

/// A small read-only relationship index used to build person-centered views.
/// It combines explicit links with their inverse links so one-sided GEDCOM
/// relationships still appear in the Home relationship hub.
private struct FamilyRelationshipGraph {
    private let repository: FamilyRepository
    private var parentsByChild: [Person.ID: Set<Person.ID>] = [:]
    private var childrenByParent: [Person.ID: Set<Person.ID>] = [:]
    private var partnersByPerson: [Person.ID: Set<Person.ID>] = [:]
    private var siblingsByPerson: [Person.ID: Set<Person.ID>] = [:]

    init(repository: FamilyRepository) {
        self.repository = repository

        for person in repository.people {
            let personID = person.id
            for parentID in person.immediateFamily.parents {
                parentsByChild[personID, default: []].insert(parentID)
                childrenByParent[parentID, default: []].insert(personID)
            }
            for childID in person.immediateFamily.children {
                childrenByParent[personID, default: []].insert(childID)
                parentsByChild[childID, default: []].insert(personID)
            }
            for partnerID in person.immediateFamily.partners {
                partnersByPerson[personID, default: []].insert(partnerID)
                partnersByPerson[partnerID, default: []].insert(personID)
            }
            for siblingID in person.immediateFamily.siblings {
                siblingsByPerson[personID, default: []].insert(siblingID)
                siblingsByPerson[siblingID, default: []].insert(personID)
            }
        }

        // Shared parents are also sibling evidence, even if the GEDCOM file
        // only recorded the parent links.
        for siblingGroup in parentsByChild.keys {
            let parents = parentsByChild[siblingGroup] ?? []
            for otherPerson in repository.people where otherPerson.id != siblingGroup {
                let otherParents = parentsByChild[otherPerson.id] ?? []
                if !parents.isDisjoint(with: otherParents) {
                    siblingsByPerson[siblingGroup, default: []].insert(otherPerson.id)
                    siblingsByPerson[otherPerson.id, default: []].insert(siblingGroup)
                }
            }
        }
    }

    func parents(of personID: Person.ID) -> [Person] {
        people(for: parentsByChild[personID] ?? [])
    }

    func children(of personID: Person.ID) -> [Person] {
        people(for: childrenByParent[personID] ?? [])
    }

    /// Returns every descendant, walking through all child generations.
    /// This is intentionally blood-line traversal only; spouses are not
    /// nieces/nephews and therefore are not added to this category.
    func descendants(of personID: Person.ID) -> [Person] {
        var result: [Person] = []
        var visited: Set<Person.ID> = []
        var pending = children(of: personID)

        while let next = pending.popLast() {
            guard visited.insert(next.id).inserted else { continue }
            result.append(next)
            pending.append(contentsOf: children(of: next.id))
        }

        return result
    }

    func partners(of personID: Person.ID) -> [Person] {
        people(for: partnersByPerson[personID] ?? [])
    }

    func siblings(of personID: Person.ID) -> [Person] {
        people(for: siblingsByPerson[personID] ?? [])
    }

    private func people(for ids: Set<Person.ID>) -> [Person] {
        repository.people(ids: Array(ids)).sorted { left, right in
            left.displayName.localizedStandardCompare(right.displayName) == .orderedAscending
        }
    }
}

private struct HomePreferenceRow<Control: View>: View {
    let title: String
    let control: () -> Control

    init(title: String, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.control = control
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(ArchiveTypography.supportingEmphasis)
                .foregroundStyle(ArchiveTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)

            control()
        }
    }
}

private struct UserProfilePhotoView: View {
    let person: Person?
    let repository: FamilyRepository?
    var size: CGFloat = 48

    init(person: Person? = nil, repository: FamilyRepository? = nil, size: CGFloat = 48) {
        self.person = person
        self.repository = repository
        self.size = size
    }

    var body: some View {
        ZStack {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(CGFloat(currentPerson?.profileImageScale ?? 1))
                    .offset(
                        x: CGFloat(currentPerson?.profileImageOffsetX ?? 0) * size / 300,
                        y: CGFloat(currentPerson?.profileImageOffsetY ?? 0) * size / 300
                    )
            } else {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [ArchiveTheme.accent, ArchiveTheme.accentLight],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    Text(currentPerson?.initials ?? "EL")
                    .font(.system(size: size * 0.35, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .clipShape(Circle())
        .grayscale(isLiving ? 0 : 1)
        .accessibilityLabel("Elena profile")
    }

    private var isLiving: Bool {
        guard let person = currentPerson else { return true }
        return repository?.isLiving(person) ?? person.isLiving
    }

    private var loadedImage: UIImage? {
        guard let person = currentPerson,
              let path = repository?.photoPath(for: person.id) ?? person.profileImagePath ?? person.media.first(where: { $0.kind == .photo })?.path else { return nil }
        return ArchiveFileResolver.image(for: path)
    }

    private var currentPerson: Person? {
        guard let person else { return nil }
        return repository?.person(id: person.id) ?? person
    }
}

private struct SettingsView: View {
    let person: Person?
    let repository: FamilyRepository?
    @Environment(\.dismiss) private var dismiss
    @State private var exportItem: ArchiveTransferItem?
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var importConfirmation: ImportConfirmation?
    @State private var transferMessage: TransferMessage?
    @State private var transferInProgress = false
    @State private var diagnosticRunning = false
    @State private var transferStatus: String?
    @State private var showingAccountChooser = false
    @State private var showingPreparationChooser = false
    @State private var preparedAccountID: Person.ID?
    @State private var preparedReadOnly = true
    @State private var exportFilename = "family-archive-private.familyarchive"
    @StateObject private var accountSession = AccountSessionStore()

    private var activeAccountPerson: Person? {
        repository?.accountHolder ?? person
    }

    private var canEdit: Bool {
        repository?.canEdit ?? true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    UserProfilePhotoView(person: activeAccountPerson, repository: repository)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activeAccountPerson?.displayName ?? "Elena")
                            .font(.title2.weight(.bold))
                        Text(ArchiveCopy.text(english: "Account profile", russian: "Профиль аккаунта"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 26)

                Text(ArchiveCopy.text(english: "ACCOUNT", russian: "АККАУНТ"))
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(ArchiveTheme.accent)

                if !canEdit {
                    AccountRow(
                        title: ArchiveCopy.text(english: "Read-only access", russian: "Доступ только для чтения"),
                        detail: ArchiveCopy.text(english: "Editing is managed by the family archive owner.", russian: "Изменения управляются владельцем семейного архива.")
                    )
                }

                if canEdit, repository != nil {
                    Button {
                        showingAccountChooser = true
                    } label: {
                        ArchiveTransferRow(
                            title: ArchiveCopy.text(english: "Account person", russian: "Профиль аккаунта"),
                            detail: activeAccountPerson?.displayName ?? ArchiveCopy.text(english: "Choose a person", russian: "Выберите человека"),
                            systemImage: "person.crop.circle"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(transferInProgress)
                }

                if accountSession.isSignedIn {
                    AccountRow(
                        title: ArchiveCopy.text(english: "Apple account", russian: "Учётная запись Apple"),
                        detail: ArchiveCopy.text(english: "Connected on this device", russian: "Подключена на этом устройстве")
                    )
                } else {
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        accountSession.handleAppleAuthorization(result)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 44)
                    .padding(.vertical, 10)
                }

                AccountRow(title: ArchiveCopy.text(english: "Profile photo", russian: "Фото профиля"), detail: ArchiveCopy.text(english: "Coming soon", russian: "Скоро будет доступно"))
                AccountRow(title: ArchiveCopy.text(english: "Your relationship view", russian: "Связи с родственниками"), detail: ArchiveCopy.text(english: "Coming soon", russian: "Скоро будет доступно"))
                AccountRow(title: ArchiveCopy.text(english: "Privacy", russian: "Приватность"), detail: ArchiveCopy.text(english: "Coming soon", russian: "Скоро будет доступно"))

                if canEdit, repository != nil {
                    Button {
                        showingPreparationChooser = true
                    } label: {
                        ArchiveTransferRow(
                            title: ArchiveCopy.text(english: "Prepare archive for another person", russian: "Подготовить архив для другого человека"),
                            detail: ArchiveCopy.text(english: "They will see themselves as YOU after import", russian: "После импорта человек увидит себя как ВЫ"),
                            systemImage: "person.badge.plus"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(transferInProgress)
                }

                if repository != nil {
                    Text(ArchiveCopy.text(english: "PRIVATE DATA", russian: "ПРИВАТНЫЕ ДАННЫЕ"))
                        .font(.caption.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(ArchiveTheme.accent)
                        .padding(.top, 28)

                    if canEdit {
                        Button {
                            exportPrivateArchive()
                        } label: {
                            ArchiveTransferRow(
                                title: ArchiveCopy.text(english: "Export private archive", russian: "Экспортировать приватный архив"),
                                detail: ArchiveCopy.text(english: "Save people, relationships, stories, and media", russian: "Сохранить людей, связи, истории и медиа"),
                                systemImage: "square.and.arrow.up"
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(transferInProgress)
                        .opacity(transferInProgress ? 0.5 : 1)
                    }

                    Button {
                        showingImporter = true
                    } label: {
                        ArchiveTransferRow(
                            title: ArchiveCopy.text(english: "Import private archive", russian: "Импортировать приватный архив"),
                            detail: ArchiveCopy.text(english: "Replace the current private data after review", russian: "Заменить текущие приватные данные после проверки"),
                            systemImage: "square.and.arrow.down"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(transferInProgress)
                    .opacity(transferInProgress ? 0.5 : 1)
                }

                if let transferStatus {
                    Text(transferStatus)
                        .font(.caption)
                        .foregroundStyle(ArchiveTheme.metadata)
                        .padding(.top, 8)
                }

                if let importConfirmation {
                    ImportReviewPanel(
                        personCount: importConfirmation.summary.personCount,
                        relationshipCount: importConfirmation.summary.relationshipCount,
                        preparedAccountName: importConfirmation.summary.preparedAccountName,
                        onReplace: { replaceImportedArchive(importConfirmation) },
                        onCancel: {
                            cleanupTemporaryImport(at: importConfirmation.url)
                            self.importConfirmation = nil
                            transferStatus = ArchiveCopy.text(english: "Import cancelled.", russian: "Импорт отменён.")
                        }
                    )
                    .padding(.top, 14)
                }

                #if DEBUG
                Text("IMPORT DIAGNOSTICS")
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(ArchiveTheme.accent)
                    .padding(.top, 28)

                Button {
                    runBuiltInImportDiagnostic()
                } label: {
                    ArchiveTransferRow(
                        title: "Test importer · build 4fc72d4",
                        detail: "Validate a synthetic archive without private data",
                        systemImage: "checkmark.seal"
                    )
                }
                .buttonStyle(.plain)
                .disabled(transferInProgress || diagnosticRunning)
                .opacity(diagnosticRunning ? 0.5 : 1)
                #endif
            }
            .padding(.horizontal, ArchiveLayout.pageHorizontal)
            .padding(.top, ArchiveLayout.pageTop)
            .padding(.bottom, ArchiveLayout.pageBottom)
        }
        .scrollIndicators(.hidden)
        .background(ArchiveTheme.background)
        .navigationTitle(ArchiveCopy.text(english: "Settings", russian: "Настройки"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                }
                .disabled(transferInProgress)
                .opacity(transferInProgress ? 0.35 : 1)
                .accessibilityLabel(ArchiveCopy.text(english: "Close settings", russian: "Закрыть настройки"))
            }
        }
        .interactiveDismissDisabled(transferInProgress)
        .sheet(isPresented: $showingAccountChooser) {
            AccountChooserView(
                title: ArchiveCopy.text(english: "Choose account person", russian: "Выберите профиль аккаунта"),
                repository: repository,
                selectedID: repository?.accountHolderID,
                onSelect: { selected in
                    repository?.setActiveAccountID(selected.id)
                    showingAccountChooser = false
                }
            )
        }
        .sheet(isPresented: $showingPreparationChooser) {
            AccountChooserView(
                title: ArchiveCopy.text(english: "Prepare archive for", russian: "Подготовить архив для"),
                repository: repository,
                selectedID: nil,
                readOnly: $preparedReadOnly,
                onSelect: { selected in
                    showingPreparationChooser = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        exportPrivateArchive(
                            preparedFor: selected.id,
                            displayName: selected.sourceDisplayName,
                            readOnly: preparedReadOnly
                        )
                    }
                }
            )
        }
        .fileExporter(
            isPresented: $showingExporter,
            item: exportItem,
            contentTypes: [.familyArchive],
            defaultFilename: exportFilename
        ) { result in
            cleanupPreparedExport()
            transferInProgress = false
            preparedAccountID = nil
            switch result {
            case .success:
                transferMessage = TransferMessage(message: ArchiveCopy.text(
                    english: "Private archive saved.",
                    russian: "Приватный архив сохранён."
                ))
            case .failure(let error):
                transferMessage = TransferMessage(message: error.localizedDescription)
            }
        } onCancellation: {
            cleanupPreparedExport()
            transferInProgress = false
            preparedAccountID = nil
            transferStatus = ArchiveCopy.text(english: "Export cancelled.", russian: "Экспорт отменён.")
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.familyArchive]
        ) { result in
            switch result {
            case .success(let url):
                importPrivateArchive(from: url)
            case .failure(let error):
                transferMessage = TransferMessage(message: error.localizedDescription)
            }
        }
        .alert(item: $transferMessage) { message in
            Alert(title: Text(message.message), dismissButton: .default(Text(ArchiveCopy.text(english: "OK", russian: "ОК"))))
        }
        .alert(
            ArchiveCopy.text(english: "Apple sign-in", russian: "Вход через Apple"),
            isPresented: Binding(
                get: { accountSession.errorMessage != nil },
                set: { if !$0 { accountSession.errorMessage = nil } }
            )
        ) {
            Button(ArchiveCopy.text(english: "OK", russian: "Хорошо")) {
                accountSession.errorMessage = nil
            }
        } message: {
            Text(accountSession.errorMessage ?? "")
        }
    }

    private func exportPrivateArchive(
        preparedFor personID: Person.ID? = nil,
        displayName: String? = nil,
        readOnly: Bool = true
    ) {
        guard let repository else { return }
        cleanupPreparedExport()
        preparedAccountID = personID
        preparedReadOnly = readOnly
        if let displayName {
            let safeName = displayName.replacingOccurrences(of: " ", with: "-")
            exportFilename = "family-archive-for-\(safeName).familyarchive"
        } else {
            exportFilename = "family-archive-private.familyarchive"
        }
        transferInProgress = true
        transferStatus = ArchiveCopy.text(
            english: "Preparing private archive… Keep the app open.",
            russian: "Подготовка приватного архива… Не закрывайте приложение."
        )
        let preparedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FamilyArchivePrepared-\(UUID().uuidString)")
            .appendingPathExtension("familyarchive")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try repository.exportPrivateArchiveFile(
                    to: preparedURL,
                    preparedForPersonID: personID,
                    readOnly: readOnly
                )
                DispatchQueue.main.async {
                    exportItem = ArchiveTransferItem(url: preparedURL)
                    transferStatus = ArchiveCopy.text(
                        english: "Archive ready. Choose where to save it.",
                        russian: "Архив готов. Выберите место сохранения."
                    )
                    showingExporter = true
                }
            } catch {
                try? FileManager.default.removeItem(at: preparedURL)
                DispatchQueue.main.async {
                    transferInProgress = false
                    transferMessage = TransferMessage(message: error.localizedDescription)
                }
            }
        }
    }

    private func cleanupPreparedExport() {
        guard let url = exportItem?.url else { return }
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        if candidate.hasPrefix(temporaryRoot + "/"),
           url.lastPathComponent.hasPrefix("FamilyArchivePrepared-") {
            try? FileManager.default.removeItem(at: url)
        }
        exportItem = nil
    }

    private func replaceImportedArchive(_ confirmation: ImportConfirmation) {
        guard let repository else { return }
        transferInProgress = true
        transferStatus = ArchiveCopy.text(english: "Importing private archive…", russian: "Импорт приватного архива…")
        let url = confirmation.url

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let summary = try repository.importPrivateArchive(at: url)
                let message = ArchiveCopy.text(
                    english: "Imported \(summary.personCount) people.",
                    russian: "Импортировано людей: \(summary.personCount)."
                )
                DispatchQueue.main.async {
                    transferInProgress = false
                    cleanupTemporaryImport(at: url)
                    importConfirmation = nil
                    transferStatus = message
                }
            } catch {
                DispatchQueue.main.async {
                    transferInProgress = false
                    cleanupTemporaryImport(at: url)
                    transferStatus = "Import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func importPrivateArchive(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        transferInProgress = true
        transferStatus = ArchiveCopy.text(english: "Reading selected archive…", russian: "Чтение выбранного архива…")
        DispatchQueue.global(qos: .userInitiated).async {
            let localURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("FamilyArchiveImport-\(UUID().uuidString)", isDirectory: false)
                .appendingPathExtension("familyarchive")
            do {
                guard let repository else { throw ArchivePackageError.documentsUnavailable }
                // Files/iCloud URLs can be virtual provider locations rather
                // than ordinary local files. Copy once while the security
                // scope is active, then do all parsing and extraction locally.
                try? FileManager.default.removeItem(at: localURL)
                try FileManager.default.copyItem(at: url, to: localURL)
                let summary = try repository.previewPrivateArchive(at: localURL)
                if accessed { url.stopAccessingSecurityScopedResource() }
                // Let the Files picker finish its dismissal before presenting
                // the review alert; otherwise SwiftUI can discard the alert.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    transferInProgress = false
                    transferStatus = ArchiveCopy.text(english: "Archive ready for review.", russian: "Архив готов к проверке.")
                    importConfirmation = ImportConfirmation(url: localURL, summary: summary)
                }
            } catch {
                if accessed { url.stopAccessingSecurityScopedResource() }
                try? FileManager.default.removeItem(at: localURL)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    transferInProgress = false
                    transferStatus = "Import failed: \(error.localizedDescription)"
                    transferMessage = TransferMessage(message: error.localizedDescription)
                }
            }
        }
    }

    private func cleanupTemporaryImport(at url: URL) {
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        guard candidate.hasPrefix(temporaryRoot + "/"),
              url.lastPathComponent.hasPrefix("FamilyArchiveImport-") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    #if DEBUG
    private func runBuiltInImportDiagnostic() {
        guard let repository else { return }
        diagnosticRunning = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let summary = try repository.validateBuiltInPrivateArchive()
                let summaryText = "\(summary.personCount) person, \(summary.fileCount) files."
                DispatchQueue.main.async {
                    diagnosticRunning = false
                    transferMessage = TransferMessage(message: "Importer test passed (build 4fc72d4): \(summaryText)")
                }
            } catch {
                DispatchQueue.main.async {
                    diagnosticRunning = false
                    transferMessage = TransferMessage(message: "Importer test failed (build 4fc72d4): \(error.localizedDescription)")
                }
            }
        }
    }
    #endif
}

private struct ArchiveTransferRow: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ArchiveTheme.action)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(ArchiveTheme.ink)
                Text(detail).font(.caption).foregroundStyle(ArchiveTheme.metadata)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ArchiveTheme.metadata)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct ImportConfirmation: Identifiable {
    let id = UUID()
    let url: URL
    let summary: ArchivePackageSummary
}

private struct ImportReviewPanel: View {
    let personCount: Int
    let relationshipCount: Int
    let preparedAccountName: String?
    let onReplace: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ArchiveCopy.text(english: "ARCHIVE READY FOR REVIEW", russian: "АРХИВ ГОТОВ К ПРОВЕРКЕ"))
                .font(.caption.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(ArchiveTheme.accent)

            Text(ArchiveCopy.text(
                english: "This package contains \(personCount) people and \(relationshipCount) relationship links.",
                russian: "В этом пакете \(personCount) людей и \(relationshipCount) родственных связей."
            ))
                .font(ArchiveTypography.body)
                .foregroundStyle(ArchiveTheme.ink)

            if let preparedAccountName {
                Text(ArchiveCopy.text(
                    english: "Prepared for \(preparedAccountName). After import, this person will be YOU on this device.",
                    russian: "Подготовлено для профиля «\(preparedAccountName)». После импорта этот человек будет ВАМИ на этом устройстве."
                ))
                    .font(ArchiveTypography.metadata)
                    .foregroundStyle(ArchiveTheme.metadata)
            }

            HStack(spacing: 10) {
                Button(ArchiveCopy.text(english: "Cancel", russian: "Отмена"), action: onCancel)
                    .font(ArchiveTypography.action)
                    .foregroundStyle(ArchiveTheme.muted)

                Spacer()

                Button(ArchiveCopy.text(english: "Replace private data", russian: "Заменить приватные данные"), action: onReplace)
                    .font(ArchiveTypography.action)
                    .foregroundStyle(ArchiveTheme.action)
            }
        }
        .padding(14)
        .background(ArchiveTheme.actionBackground)
        .overlay(Rectangle().stroke(ArchiveTheme.controlBorder, lineWidth: 1))
    }
}

private struct TransferMessage: Identifiable {
    let id = UUID()
    let message: String
}

private struct ArchiveTransferItem: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .familyArchive) { item in
            SentTransferredFile(item.url)
        }
    }
}

private struct AccountChooserView: View {
    let title: String
    let repository: FamilyRepository?
    let selectedID: Person.ID?
    let readOnly: Binding<Bool>?
    let onSelect: (Person) -> Void
    @Environment(\.dismiss) private var dismiss

    init(
        title: String,
        repository: FamilyRepository?,
        selectedID: Person.ID?,
        readOnly: Binding<Bool>? = nil,
        onSelect: @escaping (Person) -> Void
    ) {
        self.title = title
        self.repository = repository
        self.selectedID = selectedID
        self.readOnly = readOnly
        self.onSelect = onSelect
    }

    private var availableAccounts: [Person] {
        guard let repository else { return [] }

        if readOnly != nil {
            // Preparing an account is for another living family member, not
            // the current administrator. Keep this list focused on the
            // administrator's immediate family.
            guard let ownerID = repository.document.accountHolderID,
                  let account = repository.person(id: ownerID) else { return [] }
            let graph = FamilyRelationshipGraph(repository: repository)
            let relatives = graph.parents(of: account.id) +
                graph.partners(of: account.id) +
                graph.siblings(of: account.id) +
                graph.children(of: account.id)
            var seen = Set<Person.ID>()
            return relatives
                .filter { $0.id != account.id && repository.isLiving($0) }
                .filter { seen.insert($0.id).inserted }
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }

        // The account model is intentionally limited to the two people we
        // are onboarding in this prototype. Other people remain family
        // records, but are not yet selectable as app accounts.
        let accountIDs = [
            repository.people.first { person in
                let name = person.sourceDisplayName.lowercased()
                return name == "елена петрова" || name == "elena petrova"
            }?.id,
            repository.people.first { person in
                let name = person.sourceDisplayName.lowercased()
                return name == "михаил сапаров" || name == "mikhail saparov"
            }?.id,
            repository.document.accountHolderID
        ].compactMap { $0 }

        return accountIDs.reduce(into: [Person]()) { result, id in
            guard let person = repository.person(id: id), !result.contains(where: { $0.id == id }) else { return }
            result.append(person)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let readOnly {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(
                                ArchiveCopy.text(english: "Read-only access", russian: "Доступ только для чтения"),
                                isOn: readOnly
                            )
                            Text(ArchiveCopy.text(
                                english: "When enabled, the recipient can browse the archive but cannot edit or delete profiles, stories, events, captions, or media.",
                                russian: "При включении получатель сможет просматривать архив, но не сможет изменять или удалять профили, истории, события, подписи и медиа."
                            ))
                            .font(ArchiveTypography.metadata)
                            .foregroundStyle(ArchiveTheme.metadata)
                        }
                        .padding(.horizontal, ArchiveLayout.pageHorizontal)
                        .padding(.top, ArchiveLayout.pageTop)
                        .padding(.bottom, 14)

                        Divider()
                    }
                    if let repository {
                        ForEach(availableAccounts) { person in
                            Button {
                                onSelect(person)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    FamilyMemberPhotoView(person: person, size: 42, repository: repository)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(person.displayName)
                                            .font(ArchiveTypography.contentTitle)
                                            .foregroundStyle(ArchiveTheme.ink)
                                            .lineLimit(1)
                                        Text(person.lifeDateLine(language: .current))
                                            .font(ArchiveTypography.metadata)
                                            .foregroundStyle(ArchiveTheme.metadata)
                                            .lineLimit(1)
                                    }

                                    Spacer(minLength: 8)

                                    if selectedID == person.id {
                                        Image(systemName: "checkmark")
                                            .font(ArchiveTypography.icon)
                                            .foregroundStyle(ArchiveTheme.action)
                                    }
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 11)
                            }
                            .buttonStyle(.plain)

                            Divider()
                        }
                    }
                }
                .padding(.horizontal, ArchiveLayout.pageHorizontal)
                .padding(.top, ArchiveLayout.pageTop)
                .padding(.bottom, ArchiveLayout.pageBottom)
            }
            .scrollIndicators(.hidden)
            .background(ArchiveTheme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(ArchiveTypography.icon)
                    }
                    .accessibilityLabel(ArchiveCopy.text(english: "Close", russian: "Закрыть"))
                }
            }
        }
    }
}

extension UTType {
    static let familyArchive = UTType(filenameExtension: "familyarchive", conformingTo: .data) ?? .data
}

private struct AccountRow: View {
    let title: String
    let detail: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 15)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct HomeStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }
}

private struct PrimaryTreeView: View {
    @ObservedObject var repository: FamilyRepository

    private var graph: FamilyRelationshipGraph {
        FamilyRelationshipGraph(repository: repository)
    }

    private var account: Person? {
        repository.accountHolder
    }

    private var parents: [Person] {
        guard let account else { return [] }
        return graph.parents(of: account.id)
    }

    private var grandparents: [Person] {
        let parentIDs = Set(parents.map(\.id))
        return uniquePeople(parents.flatMap { graph.parents(of: $0.id) })
            .filter { !parentIDs.contains($0.id) }
    }

    private var siblings: [Person] {
        guard let account else { return [] }
        return graph.siblings(of: account.id)
    }

    private var partners: [Person] {
        guard let account else { return [] }
        return graph.partners(of: account.id)
    }

    private var children: [Person] {
        guard let account else { return [] }
        return graph.children(of: account.id)
    }

    private var grandchildren: [Person] {
        return uniquePeople(children.flatMap { graph.children(of: $0.id) })
    }

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                VStack(spacing: 0) {
                    treeHeader

                    if let account {
                        if !grandparents.isEmpty {
                            treeGeneration(
                                title: ArchiveCopy.text(english: "Grandparents", russian: "Бабушки и дедушки"),
                                people: grandparents
                            )
                            treeConnector
                        }

                        if !parents.isEmpty {
                            treeGeneration(
                                title: ArchiveCopy.text(english: "Parents", russian: "Родители"),
                                people: parents
                            )
                            treeConnector
                        }

                        treeGeneration(
                            title: ArchiveCopy.text(english: "You and your generation", russian: "Вы и ваше поколение"),
                            people: [account] + partners + siblings,
                            highlightedIDs: [account.id]
                        )

                        if !children.isEmpty {
                            treeConnector
                            treeGeneration(
                                title: ArchiveCopy.text(english: "Children", russian: "Дети"),
                                people: children
                            )
                        }

                        if !grandchildren.isEmpty {
                            treeConnector
                            treeGeneration(
                                title: ArchiveCopy.text(english: "Grandchildren", russian: "Внуки"),
                                people: grandchildren
                            )
                        }
                    } else {
                        Text(ArchiveCopy.text(
                            english: "Choose an account person to build the primary tree.",
                            russian: "Выберите человека аккаунта, чтобы построить основное дерево."
                        ))
                        .font(ArchiveTypography.paragraph)
                        .foregroundStyle(ArchiveTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 30)
                    }
                }
                .frame(minWidth: 340, alignment: .center)
                .padding(.horizontal, ArchiveLayout.pageHorizontal)
                .padding(.top, ArchiveLayout.pageTop)
                .padding(.bottom, ArchiveLayout.pageBottom)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var treeHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ArchiveCopy.text(english: "TREE", russian: "ДЕРЕВО"))
                .font(ArchiveTypography.sectionTitle)
                .tracking(1.2)
                .foregroundStyle(ArchiveTheme.ink)

            Text(ArchiveCopy.text(english: "Primary family tree", russian: "Основное семейное дерево"))
                .font(ArchiveTypography.pageTitle)
                .fixedSize(horizontal: false, vertical: true)

            if let account {
                Text(ArchiveCopy.text(
                    english: "Centered on \(account.displayName). Showing the connected family branch.",
                    russian: "В центре — \(account.displayName). Показана связанная семейная ветвь."
                ))
                .font(ArchiveTypography.paragraph)
                .foregroundStyle(ArchiveTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 24)
    }

    private var treeConnector: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(ArchiveTheme.controlBorder)
                .frame(width: 1, height: 18)
            Rectangle()
                .fill(ArchiveTheme.controlBorder)
                .frame(width: 1, height: 18)
        }
        .frame(maxWidth: .infinity)
    }

    private func treeGeneration(
        title: String,
        people: [Person],
        highlightedIDs: Set<Person.ID> = []
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(ArchiveTypography.metadataEmphasis)
                .tracking(0.8)
                .foregroundStyle(ArchiveTheme.metadata)

            HStack(alignment: .top, spacing: 10) {
                ForEach(uniquePeople(people)) { person in
                    NavigationLink {
                        PersonDetailView(person: person, repository: repository)
                    } label: {
                        TreePersonCard(
                            person: person,
                            repository: repository,
                            isHighlighted: highlightedIDs.contains(person.id)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func uniquePeople(_ people: [Person]) -> [Person] {
        var seen = Set<Person.ID>()
        return people.filter { seen.insert($0.id).inserted }
    }
}

private struct TreePersonCard: View {
    let person: Person
    let repository: FamilyRepository
    let isHighlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            FamilyMemberPhotoView(person: person, size: 54, repository: repository)

            Text(NameLocalizationStore.shared.displayName(
                for: person.id,
                fallback: person.sourceDisplayName,
                language: .current
            ))
            .font(ArchiveTypography.contentTitle)
            .foregroundStyle(isHighlighted ? ArchiveTheme.action : (repository.isLiving(person) ? ArchiveTheme.ink : ArchiveTheme.metadata))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)

            Text(person.lifeDateLine(
                language: .current,
                includeUnknownDeathDate: repository.hasUnknownDeathDate(person)
            ))
            .font(ArchiveTypography.metadata)
            .foregroundStyle(ArchiveTheme.metadata)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 136, alignment: .leading)
        .padding(10)
        .background(ArchiveTheme.controlBackground)
        .overlay(
            Rectangle()
                .stroke(isHighlighted ? ArchiveTheme.action : ArchiveTheme.controlBorder, lineWidth: isHighlighted ? 2 : 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(person.displayName)
    }
}

private struct MemoriesView: View {
    @ObservedObject var repository: FamilyRepository

    @State private var searchText = ""
    @State private var filter: MemoryFilter = .photo
    @State private var mediaSnapshot: [MemoryItem] = []
    @State private var selectedMemory: MemoryItem?
    @State private var showingMediaReview = false

    init(repository: FamilyRepository) {
        self.repository = repository
        _mediaSnapshot = State(initialValue: Self.makeMediaSnapshot(repository: repository))
    }

    private static func makeMediaSnapshot(repository: FamilyRepository) -> [MemoryItem] {
        // Build this once per document change. The previous implementation
        // called repository.media(for:) for every person on every SwiftUI
        // refresh; each call scanned every person's media collection again.
        // A single pass keeps archive navigation responsive while preserving
        // one gallery entry for a shared asset.
        var seen = Set<String>()
        var result: [MemoryItem] = []
        for person in repository.people {
            for item in person.media {
                let identity = item.path ?? item.id
                guard seen.insert(identity).inserted else { continue }
                guard !MediaMentionToken.personIDs(in: item.caption ?? "").isEmpty else { continue }
                result.append(MemoryItem(person: person, media: item))
            }
        }
        return result
    }

    private var visibleMemories: [MemoryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let people = repository.people
        let filtered = mediaSnapshot.filter { memory in
            let matchesType = filter.matches(memory)
            let searchableText = [
                memory.media.title,
                MediaMentionToken.visibleText(
                    NarrativeLocalizationStore.shared.mediaCaption(mediaID: memory.media.id, source: memory.media.caption ?? ""),
                    people: people
                ),
                memory.media.collection ?? "",
                memory.person.displayName,
                (memory.media.tags ?? []).joined(separator: " ")
            ]
            .joined(separator: " ")

            let matchesSearch = query.isEmpty || searchableText.localizedCaseInsensitiveContains(query)
            return matchesType && matchesSearch
        }

        return filtered
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    memoriesHeader

                    if repository.canEdit {
                        Button {
                            showingMediaReview = true
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "tray.and.arrow.down")
                                Text(ArchiveCopy.text(english: "Review media", russian: "Проверить медиа"))
                                let reviewCount = repository.stagedMediaItems().count + repository.mediaNeedingMentionReview().count
                                if reviewCount > 0 {
                                    Text("· \(reviewCount)")
                                        .font(ArchiveTypography.metadata)
                                }
                            }
                            .font(ArchiveTypography.action)
                            .foregroundStyle(ArchiveTheme.action)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 10)
                    }

                    SearchField(text: $searchText, placeholder: ArchiveCopy.text(english: "Search \(filter.searchPlaceholder)", russian: "Поиск: \(filter.searchPlaceholderRussian)"))
                        .padding(.top, 12)
                        .padding(.bottom, 20)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(MemoryFilter.allCases)) { option in
                                MemoryFilterButton(option: option, isSelected: filter == option) {
                                    filter = option
                                }
                            }
                        }
                    }
                    .padding(.vertical, 12)

                    Text("\(visibleMemories.count) \(filter.localizedCountLabel)")
                        .font(ArchiveTypography.metadataEmphasis)
                        .foregroundStyle(ArchiveTheme.metadata)
                    .padding(.bottom, 8)

                    if visibleMemories.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            ForEach(visibleMemories) { memory in
                                GalleryMemoryTile(memory: memory, people: repository.people)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedMemory = memory
                                    }
                            }
                        }
                    }
                }
                .padding(.horizontal, ArchiveLayout.pageHorizontal)
                .padding(.bottom, ArchiveLayout.pageBottom)
            }
            .scrollIndicators(.hidden)
            .background(ArchiveTheme.background)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Person.ID.self) { personID in
                if let person = repository.person(id: personID) {
                    PersonDetailView(person: person, repository: repository)
                }
            }
            .sheet(item: $selectedMemory) { memory in
                MemoriesPagerView(items: visibleMemories, initialID: memory.id, repository: repository)
            }
            .sheet(isPresented: $showingMediaReview) {
                MediaReviewView(repository: repository)
            }
            .task {
                if mediaSnapshot.isEmpty {
                    mediaSnapshot = Self.makeMediaSnapshot(repository: repository)
                }
            }
            .onReceive(repository.$document) { _ in
                mediaSnapshot = Self.makeMediaSnapshot(repository: repository)
            }
        }
    }

    private var memoriesHeader: some View {
        Text(ArchiveCopy.text(english: "MEMORIES", russian: "ВОСПОМИНАНИЯ"))
            .font(ArchiveTypography.sectionTitle)
            .tracking(1.2)
            .foregroundStyle(ArchiveTheme.ink)
        .padding(.top, ArchiveLayout.pageTop)
    }
}

private struct MediaReviewView: View {
    @ObservedObject var repository: FamilyRepository
    @Environment(\.dismiss) private var dismiss
    @State private var stagedItems: [StagedMediaItem] = []
    @State private var savedItems: [MediaMentionReviewItem] = []
    @State private var selectedItem: StagedMediaItem?
    @State private var selectedSavedItem: MediaMentionReviewItem?
    @State private var showingImporter = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(ArchiveCopy.text(
                        english: "New files stay private until you review and save them.",
                        russian: "Новые файлы остаются приватными, пока вы не проверите и не сохраните их."
                    ))
                    .font(ArchiveTypography.body)
                    .foregroundStyle(ArchiveTheme.metadata)

                    if stagedItems.isEmpty && savedItems.isEmpty {
                        ContentUnavailableView(
                            ArchiveCopy.text(english: "No media to review", russian: "Нет медиа для проверки"),
                            systemImage: "tray",
                            description: Text(ArchiveCopy.text(
                                english: "Add photos or documents from Files to begin.",
                                russian: "Добавьте фотографии или документы из приложения «Файлы»."
                            ))
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                    } else {
                        if !savedItems.isEmpty {
                            Text(ArchiveCopy.text(
                                english: "SAVED MEDIA NEEDING MENTIONS",
                                russian: "СОХРАНЁННЫЕ МЕДИА БЕЗ УПОМИНАНИЙ"
                            ))
                            .font(ArchiveTypography.metadataEmphasis)
                            .foregroundStyle(ArchiveTheme.metadata)

                            VStack(spacing: 0) {
                                ForEach(savedItems) { reviewItem in
                                    Button {
                                        selectedSavedItem = reviewItem
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: reviewItem.media.kind.systemImage)
                                                .foregroundStyle(ArchiveTheme.action)
                                                .frame(width: 28)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(reviewItem.media.title)
                                                    .font(ArchiveTypography.contentTitle)
                                                    .foregroundStyle(ArchiveTheme.ink)
                                                    .lineLimit(1)
                                                Text(ArchiveCopy.text(
                                                    english: "Add an @name_year mention",
                                                    russian: "Добавьте упоминание @имя_год"
                                                ))
                                                .font(ArchiveTypography.metadata)
                                                .foregroundStyle(ArchiveTheme.metadata)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .foregroundStyle(ArchiveTheme.metadata)
                                        }
                                        .padding(12)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .overlay(Rectangle().stroke(ArchiveTheme.controlBorder, lineWidth: 1))
                        }

                        if !stagedItems.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(stagedItems) { item in
                                Button {
                                    selectedItem = item
                                } label: {
                                    StagedMediaRow(item: item)
                                }
                                .buttonStyle(.plain)

                                if item.id != stagedItems.last?.id {
                                    Rectangle()
                                        .fill(ArchiveTheme.controlBorder)
                                        .frame(height: 1)
                                }
                            }
                        }
                        .overlay(Rectangle().stroke(ArchiveTheme.controlBorder, lineWidth: 1))
                        }
                    }
                }
                .padding(.horizontal, ArchiveLayout.pageHorizontal)
                .padding(.top, ArchiveLayout.pageTop)
                .padding(.bottom, ArchiveLayout.pageBottom)
            }
            .scrollIndicators(.hidden)
            .background(ArchiveTheme.background)
            .navigationTitle(ArchiveCopy.text(english: "Review media", russian: "Проверка медиа"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(ArchiveCopy.text(english: "Close", russian: "Закрыть"))
                }
                if repository.canEdit {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingImporter = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(ArchiveCopy.text(english: "Add media", russian: "Добавить медиа"))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        PhotosPicker(
                            selection: $selectedPhotoItems,
                            maxSelectionCount: 50,
                            matching: .images,
                            photoLibrary: .shared()
                        ) {
                            Image(systemName: "photo.badge.plus")
                        }
                        .accessibilityLabel(ArchiveCopy.text(english: "Choose from Photos", russian: "Выбрать из Фото"))
                    }
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.image, .movie, .audio, .pdf],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    do {
                        _ = try repository.importMediaFilesToStaging(urls)
                        reloadItems()
                    } catch {
                        importError = error.localizedDescription
                    }
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }
            .sheet(item: $selectedItem) { item in
                StagedMediaEditor(item: item, repository: repository) {
                    reloadItems()
                }
            }
            .sheet(item: $selectedSavedItem) { reviewItem in
                MediaMetadataEditor(item: reviewItem.media, ownerID: reviewItem.ownerID, repository: repository)
                    .onDisappear { reloadItems() }
            }
            .alert(
                ArchiveCopy.text(english: "Could not add media", russian: "Не удалось добавить медиа"),
                isPresented: Binding(
                    get: { importError != nil },
                    set: { if !$0 { importError = nil } }
                )
            ) {
                Button(ArchiveCopy.text(english: "OK", russian: "Хорошо")) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .onChange(of: selectedPhotoItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    await importPhotos(items)
                    selectedPhotoItems = []
                }
            }
            .onAppear { reloadItems() }
        }
    }

    private func reloadItems() {
        stagedItems = repository.stagedMediaItems()
        savedItems = repository.mediaNeedingMentionReview()
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        do {
            for item in items {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let extensionName = item.supportedContentTypes
                    .first(where: { $0.conforms(to: .image) })?
                    .preferredFilenameExtension ?? "jpg"
                _ = try repository.importPhotoDataToStaging(
                    data,
                    filename: "photo-\(UUID().uuidString).\(extensionName)"
                )
            }
            reloadItems()
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct StagedMediaRow: View {
    let item: StagedMediaItem

    var body: some View {
        HStack(spacing: 12) {
            StagedMediaThumbnail(item: item)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename)
                    .font(ArchiveTypography.contentTitle)
                    .foregroundStyle(ArchiveTheme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(ArchiveCopy.text(english: "Needs review", russian: "Требует проверки"))
                    .font(ArchiveTypography.metadata)
                    .foregroundStyle(ArchiveTheme.metadata)
            }

            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(ArchiveTypography.metadataEmphasis)
                .foregroundStyle(ArchiveTheme.action)
        }
        .padding(12)
        .contentShape(Rectangle())
    }
}

private struct StagedMediaThumbnail: View {
    let item: StagedMediaItem
    @StateObject private var loader = ArchiveImageLoader()

    var body: some View {
        Group {
            if item.kind == .photo, let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: item.kind.systemImage)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(ArchiveTheme.action)
            }
        }
        .frame(width: 72, height: 72)
        .background(ArchiveTheme.controlBackground)
        .clipped()
        .onAppear {
            if item.kind == .photo {
                loader.load(path: item.url.path, maxPixelSize: 240)
            }
        }
    }
}

private struct StagedMediaEditor: View {
    let item: StagedMediaItem
    @ObservedObject var repository: FamilyRepository
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var caption = ""
    @State private var date = ""
    @State private var seededOriginalDate: String?
    @State private var seededOriginalLocation: String?
    @State private var mentionSuggestions: [Person] = []
    @State private var selectedMentionIDs: Set<Person.ID> = []
    @State private var selectedEditorMentionID: Person.ID?
    @State private var errorMessage: String?
    @StateObject private var imageLoader = ArchiveImageLoader()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    stagedPreview

                    Text(ArchiveCopy.text(english: "EDIT CAPTION", russian: "ИЗМЕНЕНИЕ ПОДПИСИ"))
                        .font(ArchiveTypography.sectionTitle)
                        .tracking(1.2)
                        .foregroundStyle(ArchiveTheme.ink)

                    MentionTextEditor(text: $caption, people: repository.people) { personID in
                        selectedEditorMentionID = personID
                        if let personID,
                           let person = repository.people.first(where: { $0.id == personID }) {
                            mentionSuggestions = [person]
                        } else {
                            mentionSuggestions = []
                        }
                    }
                        // UITextView does not provide a reliable intrinsic
                        // height when hosted by SwiftUI. Without an explicit
                        // height the editor collapses and only the helper
                        // text below it remains visible.
                        .frame(minHeight: 104, maxHeight: 180)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(ArchiveTheme.controlBackground)
                        .overlay(Rectangle().stroke(ArchiveTheme.controlBorder, lineWidth: 1))
                        .onChange(of: caption) { _, _ in
                            updateMentionSuggestions()
                        }

                    if !mentionSuggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(mentionSuggestions) { person in
                                    Button {
                                        insertMention(for: person)
                                    } label: {
                                        Text("@\(MediaMentionToken.displayLabel(for: person, people: repository.people, language: repository.appLanguage))")
                                            .font(ArchiveTypography.metadataEmphasis)
                                            .foregroundStyle(ArchiveTheme.ink)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(ArchiveTheme.actionBackground)
                                        .clipShape(ArchiveShape.control)
                                        .overlay(ArchiveShape.control.stroke(ArchiveTheme.controlBorder, lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    Text(ArchiveCopy.text(
                        english: "Type @ followed by a family member’s name. The mention becomes a profile link and adds the image to that person’s media.",
                        russian: "Введите @ и имя родственника. Упоминание станет ссылкой на профиль, а изображение появится в его медиа."
                    ))
                    .font(ArchiveTypography.metadata)
                    .foregroundStyle(ArchiveTheme.metadata)

                    HStack {
                        Button(ArchiveCopy.text(english: "Cancel", russian: "Отмена")) {
                            dismiss()
                        }
                        .buttonStyle(.plain)
                        .font(ArchiveTypography.action)
                        .foregroundStyle(ArchiveTheme.metadata)

                        Spacer()

                        Button(ArchiveCopy.text(english: "Save", russian: "Сохранить")) {
                            save()
                        }
                        .buttonStyle(.plain)
                        .font(ArchiveTypography.action)
                        .foregroundStyle(ArchiveTheme.action)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, ArchiveLayout.pageHorizontal)
                .padding(.top, ArchiveLayout.pageTop)
                .padding(.bottom, ArchiveLayout.pageBottom)
            }
            .scrollIndicators(.hidden)
            .background(ArchiveTheme.background)
            .navigationTitle(ArchiveCopy.text(english: "Review media", russian: "Проверка медиа"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
            .alert(
                ArchiveCopy.text(english: "Could not save media", russian: "Не удалось сохранить медиа"),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button(ArchiveCopy.text(english: "OK", russian: "Хорошо")) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                if item.kind == .photo {
                    imageLoader.load(path: item.url.path, maxPixelSize: 1400)
                }
                if caption.isEmpty, let originalDate = repository.originalMediaDate(for: item) {
                    seededOriginalDate = originalDate
                    date = originalDate
                    caption = originalDate
                }
                Task {
                    guard let originalLocation = await repository.originalMediaLocation(for: item) else { return }
                    guard caption.isEmpty || caption == seededOriginalDate else { return }
                    seededOriginalLocation = originalLocation
                    if let seededOriginalDate {
                        caption = "\(seededOriginalDate) · \(originalLocation)"
                    } else {
                        caption = originalLocation
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var stagedPreview: some View {
        if item.kind == .photo, let image = imageLoader.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipped()
        } else {
            VStack(spacing: 10) {
                Image(systemName: item.kind.systemImage)
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(ArchiveTheme.action)
                Text(item.filename)
                    .font(ArchiveTypography.metadata)
                    .foregroundStyle(ArchiveTheme.metadata)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
            .background(ArchiveTheme.controlBackground)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(ArchiveTypography.metadataEmphasis)
            .foregroundStyle(ArchiveTheme.ink)
    }

    private func save() {
        guard repository.canEdit else {
            errorMessage = ArchiveCopy.text(
                english: "This account can view the archive but cannot add or edit media.",
                russian: "Эта учётная запись может просматривать архив, но не может добавлять или изменять медиа."
            )
            return
        }
        guard !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = ArchiveCopy.text(english: "Add a caption before saving.", russian: "Добавьте подпись перед сохранением.")
            return
        }
        do {
            let recordDate = dateFromCaption(caption)
            let canonicalCaption = MediaMentionToken.canonicalize(
                caption,
                people: repository.people,
                preferredPersonIDs: selectedMentionIDs
            )
            let linkedIDs = Set(MediaMentionToken.personIDs(in: canonicalCaption))
            guard !linkedIDs.isEmpty else {
                errorMessage = ArchiveCopy.text(english: "Type @ and choose at least one family member.", russian: "Введите @ и выберите хотя бы одного родственника.")
                return
            }
            let mediaID = try repository.reviewStagedMedia(
                item,
                caption: canonicalCaption,
                date: recordDate,
                personIDs: Array(linkedIDs),
                isApproximate: false,
                captionLanguage: repository.appLanguage
            )
            let sourceLanguage = repository.appLanguage
            #if !os(tvOS)
            if #available(iOS 26.0, *) {
                Task { @MainActor in
                    await repository.autoTranslateMediaCaption(
                        canonicalCaption,
                        mediaID: mediaID,
                        personIDs: Array(linkedIDs),
                        from: sourceLanguage
                    )
                }
            }
            #endif
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }


    private func updateMentionSuggestions() {
        selectedEditorMentionID = nil
        guard let query = mentionQuery(in: caption) else {
            mentionSuggestions = []
            return
        }

        let labels = MediaMentionToken.displayLabels(for: repository.people, language: repository.appLanguage)
        mentionSuggestions = Array(repository.people.filter { person in
            personNameVariants(person, mentionLabels: labels).contains { name in
                query.isEmpty || name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
            }
        }.prefix(8))
    }

    private func insertMention(for person: Person) {
        if selectedEditorMentionID == person.id {
            selectedMentionIDs.insert(person.id)
            selectedEditorMentionID = nil
            mentionSuggestions = []
            return
        }
        guard let atIndex = caption.lastIndex(of: "@") else { return }
        let label = MediaMentionToken.displayLabel(for: person, people: repository.people, language: repository.appLanguage)
        let tokenRange = mentionReplacementRange(in: caption, at: atIndex, displayName: label)
        caption.replaceSubrange(tokenRange, with: "@\(label) ")
        let labels = MediaMentionToken.displayLabels(for: repository.people, language: repository.appLanguage)
        let selectedVariants = personNameVariants(person, mentionLabels: labels)
        let duplicateIDs = repository.people
            .filter { personNameVariants($0, mentionLabels: labels).contains { lhs in selectedVariants.contains { rhs in lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame } } }
            .map(\.id)
        selectedMentionIDs.subtract(duplicateIDs)
        selectedMentionIDs.insert(person.id)
        mentionSuggestions = []
    }

    private func personNameVariants(
        _ person: Person,
        mentionLabels: [Person.ID: String]? = nil
    ) -> [String] {
        [
            person.displayName,
            person.sourceDisplayName,
            person.originalDisplayName,
            mentionLabels?[person.id] ?? MediaMentionToken.displayLabel(for: person, people: repository.people, language: repository.appLanguage)
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func mentionedPersonIDs(in text: String) -> Set<Person.ID> {
        let storedIDs = Set(MediaMentionToken.personIDs(in: text))
        if !storedIDs.isEmpty { return storedIDs }
        let candidates = repository.people.flatMap { person in
            personNameVariants(person).map { ($0, person.id) }
        }
        .sorted { $0.0.count > $1.0.count }

        var found = Set<Person.ID>()
        for (name, personID) in candidates {
            let token = "@\(name)"
            var searchRange = text.startIndex..<text.endIndex
            while let range = text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
                found.insert(personID)
                guard range.upperBound < text.endIndex else { break }
                searchRange = range.upperBound..<text.endIndex
            }
        }
        return found
    }

    private func dateFromCaption(_ value: String) -> String? {
        if let seededOriginalDate,
           value.localizedCaseInsensitiveContains(seededOriginalDate) {
            return seededOriginalDate
        }

        guard let range = value.range(of: "\\b(19|20)\\d{2}\\b", options: .regularExpression) else {
            return nil
        }
        return String(value[range])
    }
}

struct MemoryItem: Identifiable {
    let person: Person
    let media: MediaReference

    var id: String { "\(person.id)-\(media.id)" }

    var year: Int {
        Int(media.date?.prefix(4) ?? "") ?? 0
    }
}

private struct MemoryFilterButton: View {
    let option: MemoryFilter
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(option.localizedTitle)
                .font(ArchiveTypography.metadataEmphasis)
                .foregroundStyle(isSelected ? .white : ArchiveTheme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(isSelected ? ArchiveTheme.accent : Color(uiColor: .secondarySystemBackground))
                .clipShape(ArchiveShape.control)
                .overlay(
                    ArchiveShape.control
                        .stroke(Color(uiColor: .separator), lineWidth: isSelected ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private enum MemoryFilter: String, CaseIterable, Identifiable {
    case photo
    case document
    case audio
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo: ArchiveCopy.text(english: "Photos", russian: "Фото")
        case .document: ArchiveCopy.text(english: "Documents", russian: "Документы")
        case .audio: ArchiveCopy.text(english: "Audio", russian: "Аудио")
        case .video: ArchiveCopy.text(english: "Video", russian: "Видео")
        }
    }

    var localizedTitle: String { title }

    var countLabel: String {
        switch self {
        case .photo: "photos"
        case .document: "documents"
        case .audio: "audio recordings"
        case .video: "videos"
        }
    }

    var localizedCountLabel: String {
        switch self {
        case .photo: ArchiveCopy.text(english: "photos", russian: "фото")
        case .document: ArchiveCopy.text(english: "documents", russian: "документов")
        case .audio: ArchiveCopy.text(english: "audio recordings", russian: "аудиозаписей")
        case .video: ArchiveCopy.text(english: "videos", russian: "видео")
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .photo: "photos"
        case .document: "documents"
        case .audio: "audio recordings"
        case .video: "videos"
        }
    }

    var searchPlaceholderRussian: String {
        switch self {
        case .photo: "фото"
        case .document: "документам"
        case .audio: "аудиозаписям"
        case .video: "видео"
        }
    }

    func matches(_ memory: MemoryItem) -> Bool {
        rawValue == memory.media.kind.rawValue
    }
}

private struct GalleryMemoryTile: View {
    let memory: MemoryItem
    let people: [Person]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Gallery cells are small previews; decoding a 900px thumbnail
            // for each cell wastes memory and delays the first screen.
            GalleryMediaVisual(memory: memory, maxPixelSize: 540)

            Group {
                let caption = NarrativeLocalizationStore.shared.mediaCaption(mediaID: memory.media.id, source: memory.media.caption ?? "")
                if !caption.isEmpty {
                    Text(MediaMentionToken.visibleText(
                        memoryCaptionWithDate(caption, date: memory.media.date),
                        people: people
                    ))
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.metadata)
                        .lineLimit(2)
                } else if let date = memory.media.date {
                    Text(ArchiveDateFormatter.displayRange(date) ?? date)
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.metadata)
                        .lineLimit(2)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func memoryCaptionWithDate(_ caption: String, date: String?) -> String {
    let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let date, !date.isEmpty else { return trimmedCaption }
    let displayedDate = ArchiveDateFormatter.displayRange(date) ?? date
    guard !displayedDate.isEmpty else { return trimmedCaption }

    // Captions edited in newer builds already contain the year. Avoid adding
    // the same date a second time when rendering those records.
    let year = date
        .split(whereSeparator: { !$0.isNumber })
        .first(where: { $0.count == 4 })
        .map(String.init)
    if let year, trimmedCaption.range(of: year) != nil {
        return trimmedCaption
    }

    guard !trimmedCaption.isEmpty else { return displayedDate }
    return "\(trimmedCaption) · \(displayedDate)"
}

private struct GalleryMediaVisual: View {
    let memory: MemoryItem
    let isActive: Bool
    let maxPixelSize: Int
    @StateObject private var imageLoader = ArchiveImageLoader()

    init(memory: MemoryItem, isActive: Bool = true, maxPixelSize: Int = 900) {
        self.memory = memory
        self.isActive = isActive
        self.maxPixelSize = maxPixelSize
    }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack(alignment: .bottomLeading) {
                    if let image = imageLoader.image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [ArchiveTheme.accent, ArchiveTheme.accentLight],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )

                        Image(systemName: memory.media.kind.systemImage)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if memory.media.kind != .photo {
                        HStack(spacing: 5) {
                            Image(systemName: memory.media.kind.systemImage)
                            Text(memory.media.kind.rawValue.capitalized)
                        }
                        .font(ArchiveTypography.metadataEmphasis)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.55))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .task(id: "\(memory.media.path ?? "")|\(isActive)") {
                guard isActive else { return }
                imageLoader.load(
                    path: memory.media.kind == .photo ? memory.media.path : nil,
                    maxPixelSize: maxPixelSize
                )
            }
        .clipped()
    }
}

/// Renders names found in a caption as links to the matching family profile.
/// The caption itself remains the source text; only the recognized names are
/// interactive and styled with the app accent color.
///
/// TextEditor on iOS 17 only supports a plain String binding. This small
/// UITextView wrapper gives the editor the standard token behavior users
/// expect from mention fields: recognized @names are highlighted as one unit,
/// tapping a token selects the whole token, and backspace removes it as a
/// whole rather than leaving a half-name behind.
struct MentionTextEditor: UIViewRepresentable {
    @Binding var text: String
    let people: [Person]
    let onMentionSelected: (Person.ID?) -> Void

    init(
        text: Binding<String>,
        people: [Person],
        onMentionSelected: @escaping (Person.ID?) -> Void = { _ in }
    ) {
        _text = text
        self.people = people
        self.onMentionSelected = onMentionSelected
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, people: people, onMentionSelected: onMentionSelected)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.isEditable = true
        view.isScrollEnabled = true
        view.backgroundColor = .clear
        view.font = UIFont.systemFont(ofSize: 15)
        view.textColor = UIColor.archiveInk
        view.tintColor = UIColor.archiveInk
        view.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.applyAttributes(to: view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onMentionSelected = onMentionSelected
        guard view.text != text else { return }
        let selectedRange = view.selectedRange
        context.coordinator.applyAttributes(to: view, text: text)
        view.selectedRange = NSRange(
            location: min(selectedRange.location, view.text.utf16.count),
            length: 0
        )
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private struct MentionDescriptor {
            let name: String
            let personID: Person.ID
        }

        private struct MentionMatch {
            let range: NSRange
            let personID: Person.ID
        }

        private let mentionDescriptors: [MentionDescriptor]
        private var binding: Binding<String>
        private var isApplyingAttributes = false
        var onMentionSelected: (Person.ID?) -> Void

        init(
            text: Binding<String>,
            people: [Person],
            onMentionSelected: @escaping (Person.ID?) -> Void
        ) {
            self.binding = text
            self.onMentionSelected = onMentionSelected
            let currentLabels = MediaMentionToken.displayLabels(for: people, language: .current)
            self.mentionDescriptors = people.compactMap { person in
                let label = (currentLabels[person.id] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { return nil }
                return MentionDescriptor(name: label, personID: person.id)
            }
            .sorted { $0.name.utf16.count > $1.name.utf16.count }
        }

        func applyAttributes(to view: UITextView, text: String? = nil) {
            isApplyingAttributes = true
            defer { isApplyingAttributes = false }
            let value = text ?? binding.wrappedValue
            let selection = view.selectedRange
            let attributed = NSMutableAttributedString(string: value, attributes: [
                .font: UIFont.systemFont(ofSize: 15),
                .foregroundColor: UIColor.archiveInk
            ])
            for match in mentionMatches(in: value) {
                attributed.addAttributes([
                    .foregroundColor: UIColor.archiveMention,
                    .backgroundColor: UIColor.archiveMentionBackground,
                    .link: URL(string: "family-mention://token") as Any,
                    .underlineStyle: 0
                ], range: match.range)
            }
            view.attributedText = attributed
            view.typingAttributes = [
                .font: UIFont.systemFont(ofSize: 15),
                .foregroundColor: UIColor.archiveInk
            ]
            view.selectedRange = NSRange(
                location: min(selection.location, attributed.length),
                length: min(selection.length, max(0, attributed.length - min(selection.location, attributed.length)))
            )
        }

        func textViewDidChange(_ textView: UITextView) {
            binding.wrappedValue = textView.text
            applyAttributes(to: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingAttributes else { return }
            let selection = textView.selectedRange
            guard let mention = mentionMatches(in: textView.text).first(where: { match in
                if selection.length == 0 {
                    // A caret at either token boundary is outside the token.
                    // This lets a tap immediately before or after a mention
                    // place the insertion point and remain ready for typing.
                    return selection.location > match.range.location
                        && selection.location < NSMaxRange(match.range)
                }
                return NSIntersectionRange(match.range, selection).length > 0
            }) else {
                onMentionSelected(nil)
                return
            }
            if selection != mention.range {
                textView.selectedRange = mention.range
            }
            onMentionSelected(mention.personID)
        }

        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange) -> Bool {
            // Mention tokens are editable tokens here, not outbound links.
            // Selecting the full range makes their special behavior visible
            // and lets a single backspace remove the complete token.
            textView.selectedRange = characterRange
            if let mention = mentionMatches(in: textView.text).first(where: { $0.range == characterRange }) {
                onMentionSelected(mention.personID)
            }
            return false
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            let mentions = mentionMatches(in: textView.text)
            guard let token = mentions.first(where: { NSIntersectionRange($0.range, range).length > 0 })?.range else {
                return true
            }

            if replacement.isEmpty {
                let value = textView.text as NSString
                textView.text = value.replacingCharacters(in: token, with: "")
                textView.selectedRange = NSRange(location: token.location, length: 0)
                textViewDidChange(textView)
            } else {
                textView.selectedRange = NSRange(location: NSMaxRange(token), length: 0)
            }
            return false
        }

        private func mentionMatches(in text: String) -> [MentionMatch] {
            var matches: [MentionMatch] = []
            for descriptor in mentionDescriptors {
                let token = "@\(descriptor.name)"
                var search = NSRange(location: 0, length: (text as NSString).length)
                while search.length > 0 {
                    let found = (text as NSString).range(of: token, options: [.caseInsensitive, .diacriticInsensitive], range: search)
                    guard found.location != NSNotFound else { break }
                    let beforeOK = found.location == 0 || mentionBoundary((text as NSString).character(at: found.location - 1))
                    let end = found.location + found.length
                    let afterOK = end == (text as NSString).length || mentionBoundary((text as NSString).character(at: end))
                    if beforeOK && afterOK && !matches.contains(where: { NSIntersectionRange($0.range, found).length > 0 }) {
                        matches.append(MentionMatch(range: found, personID: descriptor.personID))
                    }
                    let next = found.location + max(found.length, 1)
                    search = NSRange(location: next, length: (text as NSString).length - next)
                }
            }
            return matches.sorted { $0.range.location < $1.range.location }
        }

        private func mentionBoundary(_ value: unichar) -> Bool {
            guard let scalar = UnicodeScalar(value) else { return true }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
        }
    }
}

/// The single caption-editing component used everywhere media captions are
/// edited. It owns mention selection, suggestions, insertion, and the
/// gesture-safe Save/Cancel controls so entry points cannot drift apart.
struct MediaCaptionEditor: View {
    /// The exact media being described. Keeping it in the shared editor means
    /// caption editing is never detached from the image in either entry path.
    let preview: MemoryItem?
    /// The pager hosts Save/Cancel outside its swipeable content. Other
    /// callers use the same controls inline.
    let showsActions: Bool
    @Binding var caption: String
    @Binding var selectedMentionIDs: Set<Person.ID>
    @ObservedObject var repository: FamilyRepository
    let onCancel: () -> Void
    let onSave: () throws -> Void

    @State private var mentionSuggestions: [Person] = []
    @State private var selectedEditorMentionID: Person.ID?
    @State private var saveError: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let preview {
                GalleryMediaVisual(memory: preview, maxPixelSize: 900)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 320)
                    .clipShape(ArchiveShape.control)
                    .accessibilityLabel(ArchiveCopy.text(english: "Image being captioned", russian: "Изображение, для которого редактируется подпись"))
            }

            Text(ArchiveCopy.text(english: "EDIT CAPTION", russian: "ИЗМЕНЕНИЕ ПОДПИСИ"))
                .font(ArchiveTypography.sectionTitle)
                .tracking(1.2)
                .foregroundStyle(ArchiveTheme.ink)

            MentionTextEditor(text: $caption, people: repository.people) { personID in
                selectedEditorMentionID = personID
                if let personID,
                   let person = repository.people.first(where: { $0.id == personID }) {
                    mentionSuggestions = [person]
                } else {
                    mentionSuggestions = []
                }
            }
            .frame(minHeight: 104, maxHeight: 180)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(ArchiveTheme.controlBackground)
            .overlay(Rectangle().stroke(ArchiveTheme.controlBorder, lineWidth: 1))
            .onChange(of: caption) { _, _ in
                updateMentionSuggestions()
            }

            if !mentionSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(mentionSuggestions) { person in
                            Button {
                                insertMention(for: person)
                            } label: {
                                Text("@\(MediaMentionToken.displayLabel(for: person, people: repository.people, language: repository.appLanguage))")
                                    .font(ArchiveTypography.metadataEmphasis)
                                    .foregroundStyle(ArchiveTheme.ink)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(ArchiveTheme.actionBackground)
                                    .clipShape(ArchiveShape.control)
                                    .overlay(ArchiveShape.control.stroke(ArchiveTheme.controlBorder, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Text(ArchiveCopy.text(
                english: "Type @ and choose a family member. The suggested mention is inserted exactly as shown, becomes a profile link, and adds the photo to that person’s media.",
                russian: "Введите @ и выберите родственника. Упоминание будет вставлено точно в показанном виде, станет ссылкой на профиль, а фото появится в его медиа."
            ))
            .font(ArchiveTypography.metadata)
            .foregroundStyle(ArchiveTheme.metadata)

            if showsActions {
                CaptionEditorActionBar(
                    isSaving: isSaving,
                    onCancel: onCancel,
                    onSave: save
                )
                .padding(.top, 4)
            }

            if let saveError {
                Text(saveError)
                    .font(ArchiveTypography.metadata)
                    .foregroundStyle(.red)
                    .accessibilityLabel(ArchiveCopy.text(
                        english: "Could not save caption: \(saveError)",
                        russian: "Не удалось сохранить подпись: \(saveError)"
                    ))
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        do {
            try onSave()
        } catch {
            saveError = error.localizedDescription
            isSaving = false
        }
    }

    private func updateMentionSuggestions() {
        selectedEditorMentionID = nil
        guard let query = mentionQuery(in: caption) else {
            mentionSuggestions = []
            return
        }
        let labels = MediaMentionToken.displayLabels(
            for: repository.people,
            language: repository.appLanguage
        )
        mentionSuggestions = Array(repository.people.filter { person in
            let variants = personNameVariants(person, mentionLabels: labels)
            return query.isEmpty || variants.contains { value in
                value.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
            }
        }.prefix(8))
    }

    private func insertMention(for person: Person) {
        if selectedEditorMentionID == person.id {
            selectedMentionIDs.insert(person.id)
            selectedEditorMentionID = nil
            mentionSuggestions = []
            return
        }
        guard let atIndex = caption.lastIndex(of: "@") else { return }
        let label = MediaMentionToken.displayLabel(
            for: person,
            people: repository.people,
            language: repository.appLanguage
        )
        let range = mentionReplacementRange(in: caption, at: atIndex, displayName: label)
        caption.replaceSubrange(range, with: "@\(label) ")

        let labels = MediaMentionToken.displayLabels(
            for: repository.people,
            language: repository.appLanguage
        )
        let selectedVariants = personNameVariants(person, mentionLabels: labels)
        let duplicateIDs = repository.people
            .filter { candidate in
                personNameVariants(candidate, mentionLabels: labels).contains { lhs in
                    selectedVariants.contains { rhs in
                        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                    }
                }
            }
            .map(\.id)
        selectedMentionIDs.subtract(duplicateIDs)
        selectedMentionIDs.insert(person.id)
        mentionSuggestions = []
    }

    private func personNameVariants(
        _ person: Person,
        mentionLabels: [Person.ID: String]
    ) -> [String] {
        [
            person.displayName,
            person.sourceDisplayName,
            person.originalDisplayName,
            mentionLabels[person.id] ?? person.sourceDisplayName
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }
}

/// The one Save/Cancel control used by every caption editor. The pager places
/// this bar beside (rather than inside) its swipeable image page.
private struct CaptionEditorActionBar: View {
    let isSaving: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack {
            Button(action: onCancel) {
                Text(ArchiveCopy.text(english: "Cancel", russian: "Отмена"))
                    .font(ArchiveTypography.action)
                    .frame(minWidth: 96, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ArchiveTheme.metadata)
            .disabled(isSaving)

            Spacer()

            Button(action: onSave) {
                Text(isSaving
                    ? ArchiveCopy.text(english: "Saving…", russian: "Сохранение…")
                    : ArchiveCopy.text(english: "Save", russian: "Сохранить"))
                    .font(ArchiveTypography.action)
                    .frame(minWidth: 96, minHeight: 44, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ArchiveTheme.action)
            .disabled(isSaving)
        }
    }
}

private extension UIColor {
    static let archiveInk = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.88, green: 0.94, blue: 0.91, alpha: 1)
            : UIColor(red: 0.12, green: 0.18, blue: 0.17, alpha: 1)
    }

    static let archiveMention = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.46, green: 0.76, blue: 0.63, alpha: 1)
            : UIColor(red: 0.10, green: 0.30, blue: 0.25, alpha: 1)
    }

    static let archiveMentionBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.16, green: 0.27, blue: 0.24, alpha: 1)
            : UIColor(red: 0.93, green: 0.95, blue: 0.94, alpha: 1)
    }
}

private struct CaptionPeopleText: View {
    let text: String
    let people: [Person]
    let preferredPersonIDs: Set<Person.ID>
    let onSelect: (Person) -> Void

    init(
        text: String,
        people: [Person],
        preferredPersonIDs: Set<Person.ID> = [],
        onSelect: @escaping (Person) -> Void
    ) {
        self.text = text
        self.people = people
        self.preferredPersonIDs = preferredPersonIDs
        self.onSelect = onSelect
    }

    var body: some View {
        Text(linkedCaption)
            .font(ArchiveTypography.metadata)
            .foregroundStyle(ArchiveTheme.metadata)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "family-person",
                      let id = url.host,
                      let person = people.first(where: { $0.id == id }) else {
                    return .discarded
                }
                onSelect(person)
                return .handled
            })
    }

    private var linkedCaption: AttributedString {
        let canonical = MediaMentionToken.canonicalize(
            text,
            people: people,
            preferredPersonIDs: preferredPersonIDs
        )
        var result = AttributedString()
        var cursor = canonical.startIndex
        while cursor < canonical.endIndex {
            guard let start = canonical.range(of: MediaMentionToken.prefix, range: cursor..<canonical.endIndex),
                  let end = canonical.range(of: MediaMentionToken.suffix, range: start.upperBound..<canonical.endIndex) else {
                result += AttributedString(String(canonical[cursor...]))
                break
            }
            result += AttributedString(String(canonical[cursor..<start.lowerBound]))
            let personID = String(canonical[start.upperBound..<end.lowerBound])
            if let person = people.first(where: { $0.id == personID }) {
                let label = MediaMentionToken.displayLabel(for: person, people: people, language: .current)
                var linked = AttributedString("@\(label)")
                linked.link = URL(string: "family-person://\(person.id)")
                linked.foregroundColor = ArchiveTheme.mention
                linked.backgroundColor = ArchiveTheme.actionBackground
                linked.inlinePresentationIntent = .stronglyEmphasized
                result += linked
            } else {
                result += AttributedString("@\(personID)")
            }
            cursor = end.upperBound
        }
        return result
    }
}

/// Returns the current @mention token without consuming the text that follows
/// it. This matches the behavior of standard mention fields: choosing a
/// suggestion replaces only the active token, not the rest of the caption.
func mentionTokenRange(in text: String, at atIndex: String.Index) -> Range<String.Index> {
    var end = text.index(after: atIndex)
    // The current visible mention format uses underscores, so `_` must remain
    // part of the active token. Whitespace and ordinary prose punctuation end
    // the query and protect any caption text that follows it.
    while end < text.endIndex {
        let character = text[end]
        let isMentionCharacter = character.isLetter || character.isNumber ||
            character == "_" || character == "-" || character == "'" || character == "’"
        if !isMentionCharacter {
            break
        }
        end = text.index(after: end)
    }
    return atIndex..<end
}

func mentionReplacementRange(
    in text: String,
    at atIndex: String.Index,
    displayName _: String
) -> Range<String.Index> {
    // Replace the complete active query. Prefix-only replacement left suffixes
    // behind when the selected person differed from the typed year/name, e.g.
    // selecting `@Ivan_Petrov_1912` from `@Ivan_1890` produced a stray `890`.
    mentionTokenRange(in: text, at: atIndex)
}

func mentionQuery(in text: String) -> String? {
    guard let atIndex = text.lastIndex(of: "@") else { return nil }
    if atIndex != text.startIndex {
        let previous = text[text.index(before: atIndex)]
        let isPunctuation = previous.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
        guard previous.isWhitespace || isPunctuation else { return nil }
    }

    let tokenRange = mentionTokenRange(in: text, at: atIndex)
    // A space or punctuation commits the mention/query. Do not reopen the
    // suggestion row for a completed mention elsewhere in the caption.
    if tokenRange.upperBound < text.endIndex {
        return nil
    }
    let queryStart = text.index(after: atIndex)
    return String(text[queryStart..<tokenRange.upperBound])
}

private enum CaptionEditorCommand: Equatable {
    case save(mediaID: MediaReference.ID)
    case cancel(mediaID: MediaReference.ID)

    var mediaID: MediaReference.ID {
        switch self {
        case let .save(mediaID), let .cancel(mediaID): mediaID
        }
    }
}

private struct MemoryDetailView: View {
    let memory: MemoryItem
    @ObservedObject var repository: FamilyRepository
    let isActive: Bool
    @Binding var captionCommand: CaptionEditorCommand?
    let onCaptionEditingChanged: (Bool) -> Void
    let onCaptionSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPerson: Person?
    @State private var isEditingCaption = false
    @State private var draftCaption = ""
    /// Keeps an unambiguous ID for a person selected from the @mention picker.
    /// The visible caption remains human-readable; the IDs are written to the
    /// media record's personIDs field when the caption is saved.
    @State private var selectedMentionIDs: Set<Person.ID> = []
    @State private var languageError: String?
    @State private var saveError: String?
    @State private var showingRemoveConfirmation = false

    init(
        memory: MemoryItem,
        repository: FamilyRepository,
        isActive: Bool = true,
        captionCommand: Binding<CaptionEditorCommand?>,
        onCaptionEditingChanged: @escaping (Bool) -> Void = { _ in },
        onCaptionSaved: @escaping () -> Void = { }
    ) {
        self.memory = memory
        self.repository = repository
        self.isActive = isActive
        self._captionCommand = captionCommand
        self.onCaptionEditingChanged = onCaptionEditingChanged
        self.onCaptionSaved = onCaptionSaved
    }

    private var currentMedia: MediaReference {
        repository.mediaItem(withID: memory.media.id, preferredPersonID: memory.person.id) ?? memory.media
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                    GalleryMediaVisual(
                        memory: MemoryItem(person: memory.person, media: currentMedia),
                        isActive: isActive
                    )
                        .overlay(alignment: .bottomTrailing) {
                        if repository.canEdit {
                            Button(role: .destructive) {
                                showingRemoveConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                                    .font(ArchiveTypography.icon)
                                    .foregroundStyle(ArchiveTheme.ink)
                                    .frame(width: ArchiveShape.actionDiameter, height: ArchiveShape.actionDiameter)
                                    .background(ArchiveTheme.actionBackground)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .padding(10)
                            .accessibilityLabel(ArchiveCopy.text(english: "Remove image", russian: "Удалить изображение"))
                        }
                    }

                if isEditingCaption {
                    captionEditor
                } else {
                    let caption = NarrativeLocalizationStore.shared.mediaCaption(mediaID: currentMedia.id, source: currentMedia.caption ?? "")
                    let captionWithDate = memoryCaptionWithDate(caption, date: currentMedia.date)
                    VStack(alignment: .leading, spacing: 10) {
                        if !captionWithDate.isEmpty {
                            CaptionPeopleText(
                                text: captionWithDate,
                                people: repository.people,
                                preferredPersonIDs: Set(MediaMentionToken.personIDs(in: currentMedia.caption ?? "")),
                                onSelect: { selectedPerson = $0 }
                            )
                        } else {
                            Text(ArchiveCopy.text(english: "Add a caption", russian: "Добавить подпись"))
                                .font(ArchiveTypography.metadata)
                                .foregroundStyle(ArchiveTheme.metadata)
                        }

                        if repository.canEdit {
                            VStack(alignment: .leading, spacing: 14) {
                                Button {
                                    beginCaptionEditing()
                                } label: {
                                    Text(ArchiveCopy.text(english: "Edit caption", russian: "Изменить подпись"))
                                        .font(ArchiveTypography.metadataEmphasis)
                                        .foregroundStyle(ArchiveTheme.action)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(ArchiveCopy.text(english: "Edit caption", russian: "Изменить подпись"))
                            }
                        }
                    }
                }

                if currentMedia.isApproximate == true {
                    MemoryDetailRow(
                        label: ArchiveCopy.text(english: "Date", russian: "Дата"),
                        value: ArchiveCopy.text(english: "Approximate", russian: "Примерно")
                    )
                }

            }
            .padding(.horizontal, ArchiveLayout.pageHorizontal)
            .padding(.top, ArchiveLayout.pageTop)
            .padding(.bottom, ArchiveLayout.pageBottom)
        }
        .scrollIndicators(.hidden)
        .background(ArchiveTheme.background)
        .navigationTitle(ArchiveCopy.text(english: "Memory", russian: "Воспоминание"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: isEditingCaption) { _, editing in
            onCaptionEditingChanged(editing)
        }
        .onChange(of: captionCommand) { _, command in
            handleCaptionCommand(command)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: ArchiveShape.actionDiameter, height: ArchiveShape.actionDiameter)
                        .background(ArchiveTheme.actionBackground)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ArchiveCopy.text(english: "Close", russian: "Закрыть"))
            }

            if repository.canEdit {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            beginCaptionEditing()
                        } label: {
                            Label(
                                ArchiveCopy.text(english: "Edit caption", russian: "Изменить подпись"),
                                systemImage: "pencil"
                            )
                        }

                        Button(role: .destructive) {
                            showingRemoveConfirmation = true
                        } label: {
                            Label(
                                ArchiveCopy.text(english: "Remove image", russian: "Удалить изображение"),
                                systemImage: "trash"
                            )
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .frame(width: ArchiveShape.actionDiameter, height: ArchiveShape.actionDiameter)
                            .background(ArchiveTheme.actionBackground)
                            .clipShape(Circle())
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel(ArchiveCopy.text(english: "Media actions", russian: "Действия с медиа"))
                }
            }
        }
        .sheet(item: $selectedPerson) { person in
            PersonDetailView(person: person, repository: repository)
        }
        .alert(
            ArchiveCopy.text(english: "Language check", russian: "Проверка языка"),
            isPresented: Binding(
                get: { languageError != nil },
                set: { if !$0 { languageError = nil } }
            )
        ) {
            Button(ArchiveCopy.text(english: "OK", russian: "Хорошо")) { languageError = nil }
        } message: {
            Text(languageError ?? "")
        }
        .alert(
            ArchiveCopy.text(english: "Could not save media", russian: "Не удалось сохранить медиа"),
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )
        ) {
            Button(ArchiveCopy.text(english: "OK", russian: "Хорошо")) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .confirmationDialog(
            ArchiveCopy.text(english: "Remove this image?", russian: "Удалить это изображение?"),
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(ArchiveCopy.text(english: "Remove image", russian: "Удалить изображение"), role: .destructive) {
                guard repository.canEdit else { return }
                repository.removeMedia(currentMedia, from: memory.person.id)
                dismiss()
            }
            Button(ArchiveCopy.text(english: "Cancel", russian: "Отмена"), role: .cancel) { }
        } message: {
            Text(ArchiveCopy.text(
                english: "This permanently removes the image from the app’s private normalized store and linked profiles. The original archive is not changed.",
                russian: "Изображение будет навсегда удалено из приватного нормализованного хранилища приложения и связанных профилей. Исходный архив не изменится."
            ))
        }
    }

    @ViewBuilder
    private var captionEditor: some View {
        MediaCaptionEditor(
            preview: nil,
            showsActions: false,
            caption: $draftCaption,
            selectedMentionIDs: $selectedMentionIDs,
            repository: repository,
            onCancel: { },
            onSave: { }
        )
    }

    private func beginCaptionEditing() {
        guard repository.canEdit else { return }
        let source = currentMedia.caption ?? ""
        let localizedCaption = repository.appLanguage == .english
            ? (NarrativeLocalizationStore.shared.storedMediaCaption(mediaID: currentMedia.id)
                ?? (source.range(of: "[А-Яа-яЁё]", options: .regularExpression) == nil ? source : ""))
            : source
        // The year is part of the user-facing caption. The media date remains
        // a separate field for sorting and filtering, but is included here so
        // it is visible and editable with the rest of the caption text.
        draftCaption = MediaMentionToken.visibleText(
            memoryCaptionWithDate(localizedCaption, date: currentMedia.date),
            people: repository.people,
            language: repository.appLanguage
        )
        selectedMentionIDs = Set(MediaMentionToken.personIDs(in: localizedCaption))
        isEditingCaption = true
    }

    private func handleCaptionCommand(_ command: CaptionEditorCommand?) {
        guard let command else { return }
        defer { captionCommand = nil }
        guard command.mediaID == currentMedia.id, isEditingCaption else { return }

        switch command {
        case .cancel:
            isEditingCaption = false
        case .save:
            do {
                try saveCaptionEditing()
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    private func saveCaptionEditing() throws {
        guard repository.canEdit else { throw MediaUpdateError.editingUnavailable }
        let ownerID = repository.mediaOwnerID(for: currentMedia, preferredID: memory.person.id) ?? memory.person.id
        let saved = try repository.saveMediaCaption(
            draftCaption,
            for: currentMedia,
            ownerID: ownerID,
            preferredPersonIDs: selectedMentionIDs,
            date: currentMedia.date,
            language: repository.appLanguage
        )
        let sourceLanguage = repository.appLanguage
        if #available(iOS 26.0, *) {
            Task { @MainActor in
                await repository.autoTranslateMediaCaption(
                    saved.canonicalCaption,
                    mediaID: saved.media.id,
                    personIDs: Array(saved.personIDs),
                    from: sourceLanguage
                )
            }
        }
        isEditingCaption = false
        onCaptionSaved()
    }

    private func mentionedPersonIDs(in text: String) -> Set<Person.ID> {
        let storedIDs = Set(MediaMentionToken.personIDs(in: text))
        if !storedIDs.isEmpty { return storedIDs }
        let candidates = repository.people.flatMap { person in
            [person.displayName, person.sourceDisplayName, person.originalDisplayName]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { ($0, person.id) }
        }
        .sorted { $0.0.count > $1.0.count }

        var found = Set<Person.ID>()
        for (name, personID) in candidates {
            let token = "@\(name)"
            var searchRange = text.startIndex..<text.endIndex
            while let range = text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
                found.insert(personID)
                guard range.upperBound < text.endIndex else { break }
                searchRange = range.upperBound..<text.endIndex
            }
        }
        return found
    }
}

struct MemoriesPagerView: View {
    let items: [MemoryItem]
    let initialID: String
    let repository: FamilyRepository

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: Int
    @State private var selectedSlot = 1
    @State private var isCaptionEditing = false
    @State private var captionCommand: CaptionEditorCommand?

    init(items: [MemoryItem], initialID: String, repository: FamilyRepository) {
        self.items = items
        self.initialID = initialID
        self.repository = repository
        _selectedIndex = State(initialValue: items.firstIndex { $0.id == initialID } ?? 0)
        _selectedSlot = State(initialValue: items.count > 1 ? 1 : 0)
    }

    /// Keep the pager's view tree bounded. The archive can contain hundreds
    /// of memories; constructing one full page for every item made opening a
    /// single image wait on all of them. Only the previous, current, and next
    /// records are kept in the SwiftUI pager.
    private var visibleMemoryIndices: [Int] {
        guard !items.isEmpty else { return [] }
        guard items.count > 1 else { return [0] }
        let previous = (selectedIndex + items.count - 1) % items.count
        let next = (selectedIndex + 1) % items.count
        return [previous, selectedIndex, next]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                memoriesTopBar

                TabView(selection: $selectedSlot) {
                    ForEach(Array(visibleMemoryIndices.enumerated()), id: \.offset) { slot, index in
                        MemoryDetailView(
                            memory: items[index],
                            repository: repository,
                            // A single-item pager has only slot 0; treating
                            // it as inactive prevents its image loader from
                            // ever starting and leaves an orange placeholder
                            // beside an otherwise valid caption.
                            isActive: items.count == 1 ? true : slot == 1,
                            captionCommand: $captionCommand,
                            onCaptionEditingChanged: { editing in
                                isCaptionEditing = editing
                                resetPagerToCurrentSlot()
                            },
                            onCaptionSaved: {
                                // Saving is an action on this media, not pager
                                // navigation. Keep the exact image selected.
                                selectedIndex = index
                                resetPagerToCurrentSlot()
                            }
                        )
                            .id(items[index].id)
                            .tag(slot)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                .scrollDisabled(isCaptionEditing)
                .onChange(of: selectedSlot) { _, newSlot in
                    guard !isCaptionEditing else {
                        resetPagerToCurrentSlot()
                        return
                    }
                    guard items.count > 1 else { return }
                    switch newSlot {
                    case 0:
                        selectedIndex = (selectedIndex + items.count - 1) % items.count
                    case 2:
                        selectedIndex = (selectedIndex + 1) % items.count
                    default:
                        return
                    }
                    DispatchQueue.main.async {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { selectedSlot = 1 }
                    }
                }

                if isCaptionEditing {
                    CaptionEditorActionBar(
                        isSaving: false,
                        onCancel: {
                            guard let mediaID = currentMemoryID else { return }
                            captionCommand = .cancel(mediaID: mediaID)
                        },
                        onSave: {
                            guard let mediaID = currentMemoryID else { return }
                            captionCommand = .save(mediaID: mediaID)
                        }
                    )
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(ArchiveTheme.background)
                } else {
                    HStack {
                    Button {
                        guard !items.isEmpty else { return }
                        selectedIndex = (selectedIndex + items.count - 1) % items.count
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(ArchiveTypography.icon)
                            .foregroundStyle(ArchiveTheme.ink)
                            .frame(width: ArchiveShape.actionDiameter, height: ArchiveShape.actionDiameter)
                            .background(ArchiveTheme.actionBackground)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isCaptionEditing)
                    .accessibilityLabel("Previous memory")

                    Spacer()

                    Text("\(selectedIndex + 1) of \(items.count)")
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.metadata)

                    Spacer()

                    Button {
                        guard !items.isEmpty else { return }
                        selectedIndex = (selectedIndex + 1) % items.count
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(ArchiveTypography.icon)
                            .foregroundStyle(ArchiveTheme.ink)
                            .frame(width: ArchiveShape.actionDiameter, height: ArchiveShape.actionDiameter)
                            .background(ArchiveTheme.actionBackground)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isCaptionEditing)
                    .accessibilityLabel("Next memory")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(ArchiveTheme.background)
                }
            }
            .foregroundStyle(ArchiveTheme.ink)
            .background(ArchiveTheme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func resetPagerToCurrentSlot() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedSlot = items.count > 1 ? 1 : 0
        }
    }

    private var currentMemoryID: MediaReference.ID? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex].media.id
    }

    private var memoriesTopBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(ArchiveTypography.icon)
                    .foregroundStyle(ArchiveTheme.ink)
                    .frame(width: ArchiveShape.actionDiameter, height: ArchiveShape.actionDiameter)
                    .background(ArchiveTheme.actionBackground)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close memories")

            Spacer()

            Text(ArchiveCopy.text(english: "Memories", russian: "Воспоминания"))
                .font(ArchiveTypography.navigationTitle)
                .lineLimit(1)

            Spacer()

            Color.clear
                .frame(width: ArchiveShape.actionDiameter, height: ArchiveShape.actionDiameter)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}

private struct MemoryDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(ArchiveTypography.sectionTitle)
                .tracking(1.1)
                .foregroundStyle(ArchiveTheme.ink)
            Text(value)
                .font(ArchiveTypography.supporting)
        }
    }
}
