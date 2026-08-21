import SwiftUI
import UIKit

struct PeopleListView: View {
    let repository: FamilyRepository
    let initialPersonID: Person.ID?

    @State private var searchText = ""
    @State private var navigationPath = NavigationPath()

    private var filteredPeople: [Person] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return repository.people
        }

        return repository.people.filter { person in
            person.displayName.localizedCaseInsensitiveContains(searchText) ||
                person.alternateNames.contains { $0.localizedCaseInsensitiveContains(searchText) } ||
                person.summary.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    archiveHeader

                    SearchField(text: $searchText, placeholder: "Search family")
                        .padding(.top, 12)
                        .padding(.bottom, 20)

                    if filteredPeople.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredPeople) { person in
                                NavigationLink(value: person.id) {
                                    PersonRow(person: person)
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
                guard navigationPath.isEmpty, let initialPersonID else { return }
                navigationPath.append(initialPersonID)
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

    var body: some View {
        HStack(spacing: 14) {
            MonogramView(person: person, size: 40)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(person.displayName)
                    .font(ArchiveTypography.contentTitle)

                HStack(spacing: 5) {
                    Text(person.lifeDateLine)
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.metadata)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .layoutPriority(1)
                    if person.isLiving {
                        Circle()
                            .fill(ArchiveTheme.accent)
                            .frame(width: 5, height: 5)
                            .accessibilityLabel("Living")
                        Text("Living")
                            .font(ArchiveTypography.metadata)
                            .foregroundStyle(ArchiveTheme.accent)
                            .lineLimit(1)
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

private struct PersonRow: View {
    let person: Person

    var body: some View {
        FamilyMemberTile(person: person)
    }
}

extension Person {
    var lifeDateLine: String {
        let birth = birthFact?.value
        let death = deathFact?.value

        switch (birth, death) {
        case let (birth?, death?):
            return "\(birth) – \(death)"
        case let (birth?, nil):
            return birth
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
        .grayscale(person.isLiving ? 0 : 1)
        .accessibilityHidden(true)
    }
}

struct MainTabView: View {
    let repository: FamilyRepository
    let initialPersonID: Person.ID?

    @State private var selectedTab: MainTab = .home

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case .home:
                    HomeView(repository: repository, selectedTab: $selectedTab)
                case .tree:
                    TreePlaceholderView()
                case .family:
                    PeopleListView(repository: repository, initialPersonID: initialPersonID)
                case .memories:
                    MemoriesView(repository: repository)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ArchiveBottomNavigation(selectedTab: $selectedTab)
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

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
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
    let repository: FamilyRepository
    @Binding var selectedTab: MainTab
    @State private var showingSettings = false

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
                            RememberedDateRow(date: date)
                        }
                    }
                    .padding(.top, 28)

                    detailSection("Archive at a glance") {
                        HStack(spacing: 0) {
                            HomeStat(value: "\(repository.people.count)", label: "People")
                            HomeStat(value: "\(repository.people.filter(\.isLiving).count)", label: "Living")
                            HomeStat(value: "\(repository.people.filter { !$0.isLiving }.count)", label: "Deceased")
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
                        UserProfilePhotoView(size: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open account settings")
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning, Elena"
        case 12..<18: return "Good afternoon, Elena"
        default: return "Good evening, Elena"
        }
    }

    private var upcomingDates: [RememberedDate] {
        [
            RememberedDate(id: "eleanor-memorial", date: "4 Sep", title: "Eleanor’s remembrance day", detail: "2018 · Lakeview"),
            RememberedDate(id: "morgan-birthday", date: "23 Oct", title: "Morgan Bennett’s birthday", detail: "1958 · Lakeview"),
            RememberedDate(id: "anton-birthday", date: "14 Feb", title: "Anton Orlov’s birthday", detail: "1923 · North Harbor"),
            RememberedDate(id: "eleanor-birthday", date: "12 May", title: "Eleanor Hart’s birthday", detail: "1931 · Lakeview")
        ]
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
    let date: String
    let title: String
    let detail: String
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
    var size: CGFloat = 48

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
            Text("EL")
                .font(.system(size: size * 0.35, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Elena profile")
    }
}

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    UserProfilePhotoView()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Elena")
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
    let repository: FamilyRepository

    @State private var searchText = ""
    @State private var filter: MemoryFilter = .all
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
                    Text("MEMORIES")
                        .font(ArchiveTypography.sectionTitle)
                        .tracking(1.2)
                        .foregroundStyle(ArchiveTheme.ink)
                    Text("Photos, documents & recordings")
                        .font(ArchiveTypography.pageTitle)
                        .padding(.top, 6)

                    Text("Every photo, document, recording, and film in one searchable view.")
                        .font(ArchiveTypography.paragraph)
                        .foregroundStyle(ArchiveTheme.muted)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                        .padding(.bottom, 18)

                    SearchField(text: $searchText, placeholder: "Search memories")

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
                        Text("\(visibleMemories.count) memories")
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
                                Button {
                                    selectedMemory = memory
                                } label: {
                                    GalleryMemoryTile(memory: memory)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, ArchiveLayout.pageHorizontal)
                .padding(.top, ArchiveLayout.pageTop)
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
                NavigationStack {
                    MemoryDetailView(memory: memory, repository: repository)
                }
            }
        }
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
    case all
    case photo
    case document
    case audio
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .photo: "Photos"
        case .document: "Documents"
        case .audio: "Audio"
        case .video: "Video"
        }
    }

    func matches(_ kind: MediaKind) -> Bool {
        self == .all || rawValue == kind.rawValue
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

            VStack(alignment: .leading, spacing: 4) {
                Text(memory.media.title)
                    .font(ArchiveTypography.contentTitle)
                    .lineLimit(2)

                HStack(spacing: 4) {
                    Text(memory.person.displayName)
                    if let date = memory.media.date {
                        Text("·")
                        Text(date)
                    }
                }
                .font(ArchiveTypography.metadata)
                .foregroundStyle(ArchiveTheme.metadata)
            }
        }
    }
}

private struct GalleryMediaVisual: View {
    let memory: MemoryItem

    var body: some View {
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
        .aspectRatio(1, contentMode: .fit)
        .clipped()
    }

    private var loadedImage: UIImage? {
        guard memory.media.kind == .photo, let path = memory.media.path else { return nil }
        return UIImage(contentsOfFile: path) ?? UIImage(named: path)
    }
}

private struct MemoryDetailView: View {
    let memory: MemoryItem
    let repository: FamilyRepository

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GalleryMediaVisual(memory: memory)

                Text(memory.media.title)
                    .font(ArchiveTypography.contentTitle)

                HStack(spacing: 6) {
                    Text(memory.person.displayName)
                    if let date = memory.media.date {
                        Text("·")
                        Text(date)
                    }
                }
                .font(ArchiveTypography.metadata)
                .foregroundStyle(ArchiveTheme.metadata)

                if let caption = memory.media.caption, !caption.isEmpty {
                    Text(caption)
                        .font(ArchiveTypography.paragraph)
                        .foregroundStyle(ArchiveTheme.muted)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

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
