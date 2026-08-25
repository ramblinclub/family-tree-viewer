import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ArchiveFileResolver {
    static func image(for path: String) -> UIImage? {
        if let image = UIImage(contentsOfFile: path) {
            return image
        }

        if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let localURL = documentsURL.appendingPathComponent(path)
            if let image = UIImage(contentsOfFile: localURL.path) {
                return image
            }
        }

        return UIImage(named: path)
    }
}

private struct FamilyNameFilterOption: Identifiable {
    let id: String
    let displayName: String
    let variants: [String]
}

struct PeopleListView: View {
    @ObservedObject var repository: FamilyRepository
    let initialPersonID: Person.ID?

    @State private var searchText = ""
    @State private var selectedFamilyNameKey: String?
    @State private var storiesOnly = false
    @State private var navigationPath = NavigationPath()

    private var filteredPeople: [Person] {
        let people = repository.people.sorted(by: birthYearOrder)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return people.filter { person in
            let matchesSearch = query.isEmpty ||
                person.displayName.localizedCaseInsensitiveContains(query) ||
                person.alternateNames.contains { $0.localizedCaseInsensitiveContains(query) } ||
                person.localizedSummary.localizedCaseInsensitiveContains(query)
            let matchesFamilyName = selectedFamilyNameKey == nil ||
                normalizedFamilyNameKey(person.familyName) == selectedFamilyNameKey
            let matchesStories = !storiesOnly || person.hasStories
            return matchesSearch && matchesFamilyName && matchesStories
        }
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
                                        isAccountHolder: repository.document.accountHolderID == person.id
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
            .background(Color(uiColor: .systemBackground))
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
        HStack(spacing: 8) {
            Menu {
                Button {
                    selectedFamilyNameKey = nil
                } label: {
                    filterMenuLabel(ArchiveCopy.text(english: "All last names", russian: "Все фамилии"), isSelected: selectedFamilyNameKey == nil)
                }

                Divider()

                ForEach(familyNameOptions) { option in
                    Button {
                        selectedFamilyNameKey = option.id
                    } label: {
                        filterMenuLabel(option.displayName, isSelected: selectedFamilyNameKey == option.id)
                    }
                }
            } label: {
                filterControlLabel(
                    title: familyNameOptions.first(where: { $0.id == selectedFamilyNameKey })?.displayName ?? ArchiveCopy.text(english: "Last name", russian: "Фамилия"),
                    systemImage: "textformat"
                )
            }
            .accessibilityLabel(ArchiveCopy.text(english: "Filter by last name", russian: "Фильтр по фамилии"))

            Button {
                storiesOnly.toggle()
            } label: {
                filterControlLabel(
                    title: ArchiveCopy.text(english: "Stories", russian: "Истории"),
                    systemImage: storiesOnly ? "book.pages.fill" : "book.pages",
                    isSelected: storiesOnly
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(storiesOnly ? ArchiveCopy.text(english: "Showing people with stories", russian: "Показаны люди с историями") : ArchiveCopy.text(english: "Show only people with stories", russian: "Показать только людей с историями"))

            Spacer(minLength: 0)
        }
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

struct FamilyMemberTile: View {
    let person: Person
    let repository: FamilyRepository?
    var isAccountHolder = false

    init(person: Person, repository: FamilyRepository? = nil, isAccountHolder: Bool = false) {
        self.person = person
        self.repository = repository
        self.isAccountHolder = isAccountHolder
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            FamilyMemberPhotoView(person: person, size: 40, repository: repository)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(person.displayName)
                        .font(ArchiveTypography.contentTitle)

                    if isAccountHolder {
                        AccountHolderBadge()
                    }

                    if person.hasProfileContent {
                        ProfileContentBadge()
                    }
                }

                HStack(spacing: 5) {
                    Text(person.lifeDateLine)
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.metadata)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .layoutPriority(1)
                    if repository?.isLiving(person) ?? person.isLiving {
                        Circle()
                            .fill(ArchiveTheme.accent)
                            .frame(width: 5, height: 5)
                            .accessibilityLabel("Living")
                        Text(ArchiveCopy.text(english: "Living", russian: "Жив"))
                            .font(ArchiveTypography.metadata)
                            .foregroundStyle(ArchiveTheme.accent)
                            .lineLimit(1)
                    } else if repository?.hasUnknownDeathDate(person) == true {
                        Text(ArchiveCopy.text(english: "Death date unknown", russian: "Дата смерти неизвестна"))
                            .font(ArchiveTypography.metadata)
                            .foregroundStyle(ArchiveTheme.metadata)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
        HStack(spacing: 3) {
            Image(systemName: "book.pages")
                .font(.system(size: 10, weight: .semibold))
                Text(ArchiveCopy.text(english: "PROFILE", russian: "ПРОФИЛЬ"))
                .font(ArchiveTypography.sectionTitle)
                .tracking(0.5)
        }
        .foregroundStyle(ArchiveTheme.action)
        .accessibilityLabel("Profile story available")
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
                    .grayscale((repository?.isLiving(person) ?? person.isLiving) ? 0 : 1)
            } else {
                MonogramView(person: person, size: size, isLiving: repository?.isLiving(person) ?? person.isLiving)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel("Photo for \(person.displayName)")
    }

    private var loadedImage: UIImage? {
        let path = repository?.photoPath(for: person.id) ?? person.profileImagePath ?? person.media.first(where: { $0.kind == .photo })?.path
        guard let path else { return nil }
        return ArchiveFileResolver.image(for: path)
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
        let birth = birthFact?.value
        let death = deathFact?.value

        switch (birth, death) {
        case let (birth?, death?):
            return "\(localizedDate(birth)) – \(localizedDate(death))"
        case let (birth?, nil):
            return localizedDate(birth)
        case (nil, _):
            let normalized = lifespan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "unknown" || normalized == "????" || normalized.isEmpty {
                return ArchiveCopy.text(english: "Unknown", russian: "Неизвестно")
            }
            return lifespan
        }
    }

    private func localizedDate(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "unknown" || normalized == "????" || normalized.isEmpty {
            return ArchiveCopy.text(english: "Unknown", russian: "Неизвестно")
        }
        return ArchiveDateFormatter.display(value) ?? value
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
                    TreePlaceholderView()
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
        .background(Color(uiColor: .systemBackground))
        .sheet(item: $homePerson) { presented in
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
        .background(ArchiveTheme.ink)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ArchiveTheme.ink)
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
    static let accent = Color(red: 0.66, green: 0.24, blue: 0.08)
    static let accentLight = Color(red: 0.88, green: 0.43, blue: 0.16)
    static let ink = Color(red: 0.12, green: 0.18, blue: 0.17)
    static let muted = Color(red: 0.34, green: 0.39, blue: 0.37)
    static let metadata = Color(red: 0.46, green: 0.50, blue: 0.48)
    static let controlBackground = Color(uiColor: .systemBackground)
    static let controlBorder = Color(uiColor: .separator)
    static let actionBackground = Color(red: 0.93, green: 0.95, blue: 0.94)
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
        guard let id = repository.document.accountHolderID else { return nil }
        return repository.person(id: id)
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
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        UserProfilePhotoView(person: accountHolder, repository: repository, size: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open account settings")
                }
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
                    dates.append(RememberedDate(
                        id: "birthday-\(person.id)",
                        personID: person.id,
                        date: shortMonthDay(month: parts.month, day: parts.day),
                        title: ArchiveCopy.text(english: "\(person.displayName)’s birthday", russian: "День рождения: \(person.displayName)"),
                        detail: [fullDate(month: parts.month, day: parts.day, year: parts.year), birth.place.map(ArchiveCopy.place)].compactMap { $0 }.joined(separator: " · "),
                        sortKey: upcomingSortKey(month: parts.month, day: parts.day)
                    ))
                }
            } else if let death = person.deathFact,
                      let parts = calendarParts(from: death.value) {
                dates.append(RememberedDate(
                    id: "remembrance-\(person.id)",
                    personID: person.id,
                    date: shortMonthDay(month: parts.month, day: parts.day),
                    title: ArchiveCopy.text(english: "\(person.displayName)’s remembrance day", russian: "День памяти: \(person.displayName)"),
                    detail: [fullDate(month: parts.month, day: parts.day, year: parts.year), death.place.map(ArchiveCopy.place)].compactMap { $0 }.joined(separator: " · "),
                    sortKey: upcomingSortKey(month: parts.month, day: parts.day)
                ))
            }
        }

        return dates.sorted { $0.sortKey < $1.sortKey }.prefix(5).map { $0 }
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

    private func shortMonthDay(month: Int, day: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: repository.appLanguage == .russian ? "ru_RU" : "en_US_POSIX")
        formatter.dateFormat = repository.appLanguage == .russian ? "d MMM" : "MMM d"
        return formatter.string(from: Calendar.current.date(from: DateComponents(year: 2000, month: month, day: day)) ?? Date())
    }

    private func fullDate(month: Int, day: Int, year: Int?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: repository.appLanguage == .russian ? "ru_RU" : "en_US_POSIX")
        formatter.dateFormat = year == nil
            ? (repository.appLanguage == .russian ? "d MMMM" : "MMMM d")
            : (repository.appLanguage == .russian ? "d MMMM yyyy" : "MMMM d, yyyy")
        return formatter.string(from: Calendar.current.date(from: DateComponents(year: year ?? 2000, month: month, day: day)) ?? Date())
    }

    private func upcomingSortKey(month: Int, day: Int) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let year = calendar.component(.year, from: now)
        let candidate = calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? now
        let offset = candidate < today ? 10_000 : 0
        return offset + month * 100 + day
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
        let niecesAndNephews = Set(directSiblings.flatMap { graph.children(of: $0.id) })
        let grandchildren = Set(directChildren.flatMap { graph.children(of: $0.id) })
        let greatGrandparents = Set(grandparents.flatMap { graph.parents(of: $0.id) })
        let greatAuntsAndUncles = Set(grandparents.flatMap { graph.siblings(of: $0.id) })
        let firstCousinsOnceRemoved = Set(greatAuntsAndUncles.flatMap { graph.children(of: $0.id) })
        let secondCousins = Set(firstCousinsOnceRemoved.flatMap { graph.children(of: $0.id) })
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
            ("cousins-once-removed", ArchiveCopy.text(english: "First cousins once removed", russian: "Двоюродные родственники через поколение"), Array(firstCousinsOnceRemoved)),
            ("second-cousins", ArchiveCopy.text(english: "Second cousins", russian: "Троюродные братья и сёстры"), Array(secondCousins)),
            ("nieces-nephews", ArchiveCopy.text(english: "Nieces and nephews", russian: "Племянники и племянницы"), Array(niecesAndNephews)),
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
    let date: String
    let title: String
    let detail: String
    let sortKey: Int
}

private struct RememberedDateRow: View {
    let date: RememberedDate

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 1) {
                Text(date.date)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(ArchiveTheme.accent)
            }
            .frame(width: 70, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(date.title)
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
        .overlay(alignment: .bottom) { Divider() }
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
                                .foregroundStyle(ArchiveTheme.ink)
                                .lineLimit(1)

                            if !person.lifespan.isEmpty {
                                Text(person.lifespan)
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
            } else {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [ArchiveTheme.accent, ArchiveTheme.accentLight],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text(person?.initials ?? "EL")
                    .font(.system(size: size * 0.35, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .clipShape(Circle())
        .accessibilityLabel("Elena profile")
    }

    private var loadedImage: UIImage? {
        guard let person,
              let path = repository?.photoPath(for: person.id) ?? person.profileImagePath ?? person.media.first(where: { $0.kind == .photo })?.path else { return nil }
        return ArchiveFileResolver.image(for: path)
    }
}

private struct SettingsView: View {
    let person: Person?
    let repository: FamilyRepository?
    @Environment(\.dismiss) private var dismiss
    @State private var transferDocument = ArchiveTransferDocument(data: Data())
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var importConfirmation: ImportConfirmation?
    @State private var transferMessage: TransferMessage?
    @State private var transferInProgress = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    UserProfilePhotoView(person: person, repository: repository)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(person?.displayName ?? "Elena")
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

                // These account controls are intentionally read-only until their
                // editors are implemented. They must not look like tappable rows.
                AccountRow(title: ArchiveCopy.text(english: "Profile photo", russian: "Фото профиля"), detail: ArchiveCopy.text(english: "Coming soon", russian: "Скоро будет доступно"))
                AccountRow(title: ArchiveCopy.text(english: "Your relationship view", russian: "Связи с родственниками"), detail: ArchiveCopy.text(english: "Coming soon", russian: "Скоро будет доступно"))
                AccountRow(title: ArchiveCopy.text(english: "Privacy", russian: "Приватность"), detail: ArchiveCopy.text(english: "Coming soon", russian: "Скоро будет доступно"))

                Text(ArchiveCopy.text(english: "PRIVATE DATA", russian: "ПРИВАТНЫЕ ДАННЫЕ"))
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(ArchiveTheme.accent)
                    .padding(.top, 28)

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
            .padding(.horizontal, ArchiveLayout.pageHorizontal)
            .padding(.top, ArchiveLayout.pageTop)
            .padding(.bottom, ArchiveLayout.pageBottom)
        }
        .scrollIndicators(.hidden)
        .background(Color(uiColor: .systemBackground))
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
        .fileExporter(
            isPresented: $showingExporter,
            document: transferDocument,
            contentType: .familyArchive,
            defaultFilename: "family-archive-private.familyarchive"
        ) { result in
            switch result {
            case .success(let url):
                finishExport(to: url)
            case .failure(let error):
                transferMessage = TransferMessage(message: error.localizedDescription)
            }
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
        .alert(item: $importConfirmation) { confirmation in
            Alert(
                title: Text(ArchiveCopy.text(english: "Replace private archive?", russian: "Заменить приватный архив?")),
                message: Text(ArchiveCopy.text(
                    english: "This package contains \(confirmation.summary.personCount) people and \(confirmation.summary.relationshipCount) relationship links.",
                    russian: "В этом пакете \(confirmation.summary.personCount) людей и \(confirmation.summary.relationshipCount) родственных связей."
                )),
                primaryButton: .destructive(Text(ArchiveCopy.text(english: "Replace", russian: "Заменить"))) {
                    guard let repository else { return }
                    transferInProgress = true
                    let url = confirmation.url
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            _ = try repository.importPrivateArchive(at: url)
                            DispatchQueue.main.async {
                                transferInProgress = false
                                cleanupTemporaryImport(at: url)
                                transferMessage = TransferMessage(message: ArchiveCopy.text(english: "Private archive imported.", russian: "Приватный архив импортирован."))
                            }
                        } catch {
                            DispatchQueue.main.async {
                                transferInProgress = false
                                cleanupTemporaryImport(at: url)
                                transferMessage = TransferMessage(message: error.localizedDescription)
                            }
                        }
                    }
                },
                secondaryButton: .cancel(Text(ArchiveCopy.text(english: "Cancel", russian: "Отмена"))) {
                    cleanupTemporaryImport(at: confirmation.url)
                }
            )
        }
        .alert(item: $transferMessage) { message in
            Alert(title: Text(message.message), dismissButton: .default(Text(ArchiveCopy.text(english: "OK", russian: "ОК"))))
        }
    }

    private func exportPrivateArchive() {
        guard let repository else { return }
        do {
            // This is intentionally synchronous and limited to resolving the
            // already-persistent store URL. No media scan, copy, or state
            // transition occurs before the picker is presented.
            _ = try repository.exportPrivateStoreURL()
            transferDocument = ArchiveTransferDocument(data: Data("Family Archive private export".utf8))
            showingExporter = true
        } catch {
            transferMessage = TransferMessage(message: error.localizedDescription)
        }
    }

    private func finishExport(to destinationURL: URL) {
        guard let repository else { return }
        transferInProgress = true
        let accessed = destinationURL.startAccessingSecurityScopedResource()

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                if accessed { destinationURL.stopAccessingSecurityScopedResource() }
            }

            do {
                // The system picker wrote only the tiny placeholder. Replace
                // it at the chosen location with the streaming archive file.
                try? FileManager.default.removeItem(at: destinationURL)
                try repository.exportPrivateArchiveFile(to: destinationURL)
                DispatchQueue.main.async {
                    transferInProgress = false
                    transferMessage = TransferMessage(message: ArchiveCopy.text(
                        english: "Private archive saved.",
                        russian: "Приватный архив сохранён."
                    ))
                }
            } catch {
                DispatchQueue.main.async {
                    transferInProgress = false
                    transferMessage = TransferMessage(message: error.localizedDescription)
                }
            }
        }
    }

    private func importPrivateArchive(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        transferInProgress = true
        DispatchQueue.global(qos: .userInitiated).async {
            let localURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("FamilyArchiveImport-(UUID().uuidString)", isDirectory: false)
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
                DispatchQueue.main.async {
                    transferInProgress = false
                    importConfirmation = ImportConfirmation(url: localURL, summary: summary)
                }
            } catch {
                if accessed { url.stopAccessingSecurityScopedResource() }
                try? FileManager.default.removeItem(at: localURL)
                DispatchQueue.main.async {
                    transferInProgress = false
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

private struct TransferMessage: Identifiable {
    let id = UUID()
    let message: String
}

private struct ArchiveTransferDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.familyArchive] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
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

private struct TreePlaceholderView: View {
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(ArchiveCopy.text(english: "TREE", russian: "ДЕРЕВО"))
                    .font(ArchiveTypography.sectionTitle)
                    .tracking(1.2)
                    .foregroundStyle(ArchiveTheme.ink)
                Text(ArchiveCopy.text(english: "Family tree", russian: "Семейное дерево"))
                    .font(ArchiveTypography.pageTitle)
                Text(ArchiveCopy.text(english: "The tree viewer is coming soon. Profiles and family links are available from the Family tab.", russian: "Просмотр дерева скоро появится. Профили и семейные связи доступны на вкладке «Семья»."))
                    .font(ArchiveTypography.paragraph)
                    .foregroundStyle(ArchiveTheme.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, ArchiveLayout.pageHorizontal)
            .padding(.top, ArchiveLayout.pageTop)
            .padding(.bottom, ArchiveLayout.pageBottom)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct MemoriesView: View {
    @ObservedObject var repository: FamilyRepository

    @State private var searchText = ""
    @State private var filter: MemoryFilter = .photo
    @State private var sort: MemorySort = .newest
    @State private var selectedMemory: MemoryItem?

    private var allMemories: [MemoryItem] {
        repository.people.flatMap { person in
            person.media.map { MemoryItem(person: person, media: $0) }
        }
    }

    private var visibleMemories: [MemoryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = allMemories.filter { memory in
            let matchesType = filter.matches(memory.media.kind)
            let searchableText = [
                memory.media.title,
                NarrativeLocalizationStore.shared.mediaCaption(memory.person.id, mediaID: memory.media.id, source: memory.media.caption ?? ""),
                memory.media.collection ?? "",
                memory.person.displayName,
                (memory.media.tags ?? []).joined(separator: " ")
            ]
            .joined(separator: " ")

            let matchesSearch = query.isEmpty || searchableText.localizedCaseInsensitiveContains(query)
            return matchesType && matchesSearch
        }

        return filtered.sorted { left, right in
            switch sort {
            case .newest:
                return left.year > right.year
            case .oldest:
                return left.year < right.year
            case .title:
                return left.media.title.localizedStandardCompare(right.media.title) == .orderedAscending
            case .person:
                return left.person.displayName.localizedStandardCompare(right.person.displayName) == .orderedAscending
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    memoriesHeader

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

                    HStack {
                        Text("\(visibleMemories.count) \(filter.localizedCountLabel)")
                            .font(ArchiveTypography.metadataEmphasis)
                            .foregroundStyle(ArchiveTheme.metadata)

                        Spacer()

                        Menu {
                            ForEach(MemorySort.allCases) { option in
                                Button {
                                    sort = option
                                } label: {
                                    HStack {
                                        Text(option.localizedTitle)
                                        if sort == option {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.up.arrow.down")
                                Text(sort.localizedTitle)
                            }
                            .font(ArchiveTypography.metadataEmphasis)
                            .foregroundStyle(ArchiveTheme.accent)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .clipShape(ArchiveShape.control)
                            .overlay(ArchiveShape.control.stroke(ArchiveTheme.accent, lineWidth: 1))
                        }
                    }
                    .padding(.bottom, 8)

                    if visibleMemories.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            ForEach(visibleMemories) { memory in
                                GalleryMemoryTile(memory: memory)
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
            .background(Color(uiColor: .systemBackground))
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

private struct MemoryItem: Identifiable {
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

    func matches(_ kind: MediaKind) -> Bool {
        rawValue == kind.rawValue
    }
}

private enum MemorySort: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case title
    case person

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .title: "Title"
        case .person: "Person"
        }
    }

    var localizedTitle: String {
        switch self {
        case .newest: ArchiveCopy.text(english: "Newest", russian: "Сначала новые")
        case .oldest: ArchiveCopy.text(english: "Oldest", russian: "Сначала старые")
        case .title: ArchiveCopy.text(english: "Title", russian: "Название")
        case .person: ArchiveCopy.text(english: "Person", russian: "Человек")
        }
    }
}

private struct GalleryMemoryTile: View {
    let memory: MemoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GalleryMediaVisual(memory: memory)

            Group {
                let caption = NarrativeLocalizationStore.shared.mediaCaption(memory.person.id, mediaID: memory.media.id, source: memory.media.caption ?? "")
                if !caption.isEmpty {
                    Text(memoryCaptionWithDate(caption, date: memory.media.date))
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.metadata)
                        .lineLimit(2)
                } else if let date = memory.media.date {
                    Text(ArchiveDateFormatter.display(date) ?? date)
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

private struct GalleryMediaVisual: View {
    let memory: MemoryItem

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack(alignment: .bottomLeading) {
                    if let image = loadedImage {
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
        .clipped()
    }

    private var loadedImage: UIImage? {
        guard memory.media.kind == .photo, let path = memory.media.path else { return nil }
        return ArchiveFileResolver.image(for: path)
    }
}

private struct MemoryDetailView: View {
    let memory: MemoryItem
    let repository: FamilyRepository

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GalleryMediaVisual(memory: memory)

                let caption = NarrativeLocalizationStore.shared.mediaCaption(memory.person.id, mediaID: memory.media.id, source: memory.media.caption ?? "")
                if !caption.isEmpty {
                    Text(memoryCaptionWithDate(caption, date: memory.media.date))
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.metadata)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let date = memory.media.date {
                    Text(ArchiveDateFormatter.display(date) ?? date)
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.metadata)
                }

                Text(memory.person.displayName)
                    .font(ArchiveTypography.metadata)
                    .foregroundStyle(ArchiveTheme.metadata)

                if let collection = memory.media.collection, !collection.isEmpty {
                    MemoryDetailRow(label: ArchiveCopy.text(english: "Collection", russian: "Коллекция"), value: collection)
                }

                if let tags = memory.media.tags, !tags.isEmpty {
                    MemoryDetailRow(label: ArchiveCopy.text(english: "Tags", russian: "Метки"), value: tags.joined(separator: " · "))
                }

                if memory.media.isApproximate == true {
                    MemoryDetailRow(
                        label: ArchiveCopy.text(english: "Date", russian: "Дата"),
                        value: ArchiveCopy.text(english: "Approximate", russian: "Примерно")
                    )
                }

                NavigationLink {
                    PersonDetailView(person: memory.person, repository: repository)
                } label: {
                    HStack {
                        Text(ArchiveCopy.text(
                            english: "Open \(memory.person.displayName)’s profile",
                            russian: "Открыть профиль: \(memory.person.displayName)"
                        ))
                            .font(ArchiveTypography.action)
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .foregroundStyle(ArchiveTheme.accent)
                    .padding(.vertical, 13)
                    .overlay(alignment: .bottom) { Divider() }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, ArchiveLayout.pageHorizontal)
            .padding(.top, ArchiveLayout.pageTop)
            .padding(.bottom, ArchiveLayout.pageBottom)
        }
        .scrollIndicators(.hidden)
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(ArchiveCopy.text(english: "Memory", russian: "Воспоминание"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private func memoryCaptionWithDate(_ caption: String, date: String?) -> String {
    guard let date, !date.isEmpty else { return caption }
    return "\(caption) · \(ArchiveDateFormatter.display(date) ?? date)"
}

private struct MemoriesPagerView: View {
    let items: [MemoryItem]
    let initialID: String
    let repository: FamilyRepository

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: Int

    init(items: [MemoryItem], initialID: String, repository: FamilyRepository) {
        self.items = items
        self.initialID = initialID
        self.repository = repository
        _selectedIndex = State(initialValue: items.firstIndex { $0.id == initialID } ?? 0)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                memoriesTopBar

                TabView(selection: $selectedIndex) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, memory in
                        MemoryDetailView(memory: memory, repository: repository)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))

                HStack {
                    Button {
                        selectedIndex = max(0, selectedIndex - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(ArchiveTypography.icon)
                            .foregroundStyle(ArchiveTheme.ink)
                            .frame(width: ArchiveShape.actionDiameter, height: ArchiveShape.actionDiameter)
                            .background(ArchiveTheme.actionBackground)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedIndex == 0)
                    .opacity(selectedIndex == 0 ? 0.35 : 1)
                    .accessibilityLabel("Previous memory")

                    Spacer()

                    Text("\(selectedIndex + 1) of \(items.count)")
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.metadata)

                    Spacer()

                    Button {
                        selectedIndex = min(items.count - 1, selectedIndex + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(ArchiveTypography.icon)
                            .foregroundStyle(ArchiveTheme.ink)
                            .frame(width: ArchiveShape.actionDiameter, height: ArchiveShape.actionDiameter)
                            .background(ArchiveTheme.actionBackground)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedIndex == items.count - 1)
                    .opacity(selectedIndex == items.count - 1 ? 0.35 : 1)
                    .accessibilityLabel("Next memory")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color(uiColor: .systemBackground))
            }
            .foregroundStyle(ArchiveTheme.ink)
            .background(Color(uiColor: .systemBackground))
            .toolbar(.hidden, for: .navigationBar)
        }
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
