import SwiftUI
import UIKit

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
                person.summary.localizedCaseInsensitiveContains(query)
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
        let cyrillicVariant = variants.first { variant in
            cyrillicAlias(for: variant).unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
        }
        let source = cyrillicVariant ?? variants.first ?? key
        return masculineFamilyName(source)
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

                    SearchField(text: $searchText, placeholder: "Search family")
                        .padding(.top, 12)
                        .padding(.bottom, 10)

                    filterControls
                        .padding(.bottom, 16)

                    if filteredPeople.isEmpty {
                        ContentUnavailableView(
                            searchText.isEmpty ? "No matching people" : "No results",
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
                    filterMenuLabel("All last names", isSelected: selectedFamilyNameKey == nil)
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
                    title: familyNameOptions.first(where: { $0.id == selectedFamilyNameKey })?.displayName ?? "Last name",
                    systemImage: "textformat"
                )
            }
            .accessibilityLabel("Filter by last name")

            Button {
                storiesOnly.toggle()
            } label: {
                filterControlLabel(
                    title: "Stories",
                    systemImage: storiesOnly ? "book.pages.fill" : "book.pages",
                    isSelected: storiesOnly
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(storiesOnly ? "Showing people with stories" : "Show only people with stories")

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
            Text("FAMILY")
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
                        Text("Living")
                            .font(ArchiveTypography.metadata)
                            .foregroundStyle(ArchiveTheme.accent)
                            .lineLimit(1)
                    } else if repository?.hasUnknownDeathDate(person) == true {
                        Text("Death date unknown")
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
        Text("YOU")
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
            Text("PROFILE")
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
            return "\(ArchiveDateFormatter.display(birth) ?? birth) – \(ArchiveDateFormatter.display(death) ?? death)"
        case let (birth?, nil):
            return ArchiveDateFormatter.display(birth) ?? birth
        case (nil, _):
            return lifespan
        }
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

    @State private var selectedTab: MainTab = .family
    @State private var familyResetID = UUID()
    @State private var shouldOpenInitialPerson = true
    @State private var personIDToOpen: Person.ID?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case .home:
                    HomeView(repository: repository) { personID in
                        // Profiles belong to Family, even when discovered from
                        // the Home reminders. This keeps the selected tab and
                        // the navigation stack consistent.
                        personIDToOpen = personID
                        shouldOpenInitialPerson = false
                        familyResetID = UUID()
                        selectedTab = .family
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
        .onAppear {
            if initialPersonID != nil {
                selectedTab = .family
            }
        }
    }
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
        case .home: "Home"
        case .tree: "Tree"
        case .family: "Family"
        case .memories: "Memories"
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

                    Text("Your family, stories, and memories in one place.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)

                    detailSection("Upcoming dates to remember") {
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

                    detailSection("Archive at a glance") {
                        HStack(spacing: 0) {
                            HomeStat(value: "\(repository.people.count)", label: "People")
                            HomeStat(value: "\(repository.people.filter { repository.isLiving($0) }.count)", label: "Living")
                            HomeStat(value: "\(repository.people.filter { !repository.isLiving($0) }.count)", label: "Deceased")
                            HomeStat(value: "\(repository.people.reduce(0) { $0 + $1.media.count })", label: "Memories")
                        }
                        .padding(.vertical, 14)
                        .background(ArchiveTheme.accent.opacity(0.06))
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
        let name = accountHolder?.givenName ?? "Elena"
        switch hour {
        case 5..<12: return "Good morning, \(name)"
        case 12..<18: return "Good afternoon, \(name)"
        default: return "Good evening, \(name)"
        }
    }

    private var upcomingDates: [RememberedDate] {
        var dates: [RememberedDate] = []

        for person in repository.people {
            if let birth = person.birthFact,
               let parts = calendarParts(from: birth.value) {
                dates.append(RememberedDate(
                    id: "birthday-\(person.id)",
                    personID: person.id,
                    date: shortMonthDay(month: parts.month, day: parts.day),
                    title: "\(person.displayName)’s birthday",
                    detail: [parts.year.map(String.init), birth.place].compactMap { $0 }.joined(separator: " · "),
                    sortKey: upcomingSortKey(month: parts.month, day: parts.day)
                ))
            }

            if let death = person.deathFact,
               let parts = calendarParts(from: death.value) {
                dates.append(RememberedDate(
                    id: "remembrance-\(person.id)",
                    personID: person.id,
                    date: shortMonthDay(month: parts.month, day: parts.day),
                    title: "\(person.displayName)’s remembrance day",
                    detail: [parts.year.map(String.init), death.place].compactMap { $0 }.joined(separator: " · "),
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
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: Calendar.current.date(from: DateComponents(year: 2000, month: month, day: day)) ?? Date())
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
            .frame(width: 54, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(date.title)
                    .font(.subheadline.weight(.medium))
                Text(date.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Divider() }
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    UserProfilePhotoView(person: person, repository: repository)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(person?.displayName ?? "Elena")
                            .font(.title2.weight(.bold))
                        Text("Account profile")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 26)

                Text("ACCOUNT")
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(ArchiveTheme.accent)

                AccountRow(title: "Profile photo", detail: "Add or change your photo")
                AccountRow(title: "Your relationship view", detail: "Choose how family relationships are described")
                AccountRow(title: "Privacy", detail: "Control what is visible to other family members")
            }
            .padding(.horizontal, ArchiveLayout.pageHorizontal)
            .padding(.top, ArchiveLayout.pageTop)
            .padding(.bottom, ArchiveLayout.pageBottom)
        }
        .scrollIndicators(.hidden)
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                }
                .accessibilityLabel("Close settings")
            }
        }
    }
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
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }
}

private struct TreePlaceholderView: View {
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("TREE")
                    .font(ArchiveTypography.sectionTitle)
                    .tracking(1.2)
                    .foregroundStyle(ArchiveTheme.ink)
                Text("Family tree")
                    .font(ArchiveTypography.pageTitle)
                Text("The tree viewer is coming soon. Profiles and family links are available from the Family tab.")
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
                memory.media.caption ?? "",
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

                    SearchField(text: $searchText, placeholder: "Search \(filter.searchPlaceholder)")
                        .padding(.top, 12)
                        .padding(.bottom, 20)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(MemoryFilter.allCases) { option in
                                Button {
                                    filter = option
                                } label: {
                                    Text(option.title)
                                        .font(ArchiveTypography.metadataEmphasis)
                                        .foregroundStyle(filter == option ? .white : ArchiveTheme.ink)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 9)
                                        .background(filter == option ? ArchiveTheme.accent : Color(uiColor: .secondarySystemBackground))
                                        .clipShape(ArchiveShape.control)
                                        .overlay(
                                            ArchiveShape.control
                                                .stroke(Color(uiColor: .separator), lineWidth: filter == option ? 0 : 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 12)

                    HStack {
                        Text("\(visibleMemories.count) \(filter.countLabel)")
                            .font(ArchiveTypography.metadataEmphasis)
                            .foregroundStyle(ArchiveTheme.metadata)

                        Spacer()

                        Menu {
                            ForEach(MemorySort.allCases) { option in
                                Button {
                                    sort = option
                                } label: {
                                    HStack {
                                        Text(option.title)
                                        if sort == option {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.up.arrow.down")
                                Text(sort.title)
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
        Text("MEMORIES")
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

private enum MemoryFilter: String, CaseIterable, Identifiable {
    case photo
    case document
    case audio
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo: "Photos"
        case .document: "Documents"
        case .audio: "Audio"
        case .video: "Video"
        }
    }

    var countLabel: String {
        switch self {
        case .photo: "photos"
        case .document: "documents"
        case .audio: "audio recordings"
        case .video: "videos"
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
}

private struct GalleryMemoryTile: View {
    let memory: MemoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GalleryMediaVisual(memory: memory)

            Group {
                if let caption = memory.media.caption, !caption.isEmpty {
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

                if let caption = memory.media.caption, !caption.isEmpty {
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
                    MemoryDetailRow(label: "Collection", value: collection)
                }

                if let tags = memory.media.tags, !tags.isEmpty {
                    MemoryDetailRow(label: "Tags", value: tags.joined(separator: " · "))
                }

                if memory.media.isApproximate == true {
                    MemoryDetailRow(label: "Date", value: "Approximate")
                }

                NavigationLink {
                    PersonDetailView(person: memory.person, repository: repository)
                } label: {
                    HStack {
                        Text("Open \(memory.person.displayName)’s profile")
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
        .navigationTitle("Memory")
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

            Text("Memories")
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
