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

                    SearchField(text: $searchText)
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
            .padding(.horizontal, 20)
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
        VStack(alignment: .leading, spacing: 6) {
            Text("FAMILY")
                .font(.caption.weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(ArchiveTheme.accent)

            HStack(alignment: .firstTextBaseline) {
                Text(repository.document.title)
                    .font(.system(.largeTitle, design: .serif).weight(.bold))

                Spacer()

                Text("\(repository.people.count)")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text("People and their immediate family connections")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)
        }
        .padding(.top, 14)
    }
}

private struct PersonRow: View {
    let person: Person

    var body: some View {
        HStack(spacing: 14) {
            MonogramView(person: person, size: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(person.displayName)
                    .font(.headline)

                Text(person.lifespan)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Rectangle()
                        .fill(person.isLiving ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(person.lifeStatusLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(person.isLiving ? .green : .secondary)
                }

                if !person.summary.isEmpty {
                    Text(person.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 16)
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search people", text: $text)
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
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Color(uiColor: .secondarySystemBackground))
        .overlay(Rectangle().stroke(Color(uiColor: .separator), lineWidth: 1))
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
                .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct MainTabView: View {
    let repository: FamilyRepository
    let initialPersonID: Person.ID?

    @State private var selectedTab: MainTab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(repository: repository, selectedTab: $selectedTab)
                .tabItem {
                    Label("Home", systemImage: "house")
                }
                .tag(MainTab.home)

            TreePlaceholderView()
                .tabItem {
                    Label("Tree", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .tag(MainTab.tree)

            PeopleListView(repository: repository, initialPersonID: initialPersonID)
                .tabItem {
                    Label("Family", systemImage: "person.2")
                }
                .tag(MainTab.family)

            MemoriesView(repository: repository)
                .tabItem {
                    Label("Memories", systemImage: "photo.on.rectangle")
                }
                .tag(MainTab.memories)
        }
        .tint(ArchiveTheme.accent)
        .onAppear {
            if initialPersonID != nil {
                selectedTab = .family
            }
        }
    }
}

enum MainTab: Hashable {
    case home
    case tree
    case family
    case memories
}

enum ArchiveTheme {
    static let accent = Color(red: 0.66, green: 0.24, blue: 0.08)
    static let accentLight = Color(red: 0.88, green: 0.43, blue: 0.16)
    static let ink = Color(red: 0.12, green: 0.18, blue: 0.17)
    static let muted = Color(red: 0.34, green: 0.39, blue: 0.37)
    static let action = accent
}

enum ArchiveTypography {
    static let navigationTitle = Font.system(size: 17, weight: .semibold)
    static let profileName = Font.system(size: 28, weight: .bold, design: .serif)
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static let action = Font.system(size: 14, weight: .semibold)
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
                        .font(.system(.largeTitle, design: .serif).weight(.bold))

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
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 32)
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
                .font(.system(size: size * 0.35, weight: .semibold, design: .rounded))
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
            .padding(20)
            .padding(.top, 24)
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
                    .font(.caption.weight(.semibold))
                    .tracking(1.5)
                    .foregroundStyle(ArchiveTheme.accent)
                Text("Family tree")
                    .font(.system(.largeTitle, design: .serif).weight(.bold))
                Text("The tree viewer is coming soon. Profiles and family links are available from the Family tab.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(20)
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
                        .font(.caption.weight(.semibold))
                        .tracking(1.5)
                        .foregroundStyle(ArchiveTheme.accent)
                    Text("Photos, documents & recordings")
                        .font(.system(.largeTitle, design: .serif).weight(.bold))
                        .padding(.top, 6)

                    Text("Every photo, document, recording, and film in one searchable view.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                        .padding(.bottom, 18)

                    SearchField(text: $searchText)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(MemoryFilter.allCases) { option in
                                Button {
                                    filter = option
                                } label: {
                                    Text(option.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(filter == option ? .white : .primary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 9)
                        .background(filter == option ? ArchiveTheme.accent : Color(uiColor: .secondarySystemBackground))
                                        .overlay(Rectangle().stroke(Color(uiColor: .separator), lineWidth: filter == option ? 0 : 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 12)

                    HStack {
                        Text("\(visibleMemories.count) memories")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

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
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ArchiveTheme.accent)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .overlay(Rectangle().stroke(ArchiveTheme.accent, lineWidth: 1))
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
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 32)
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
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                HStack(spacing: 4) {
                    Text(memory.person.displayName)
                    if let date = memory.media.date {
                        Text("·")
                        Text(date)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
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
            .font(.caption2.weight(.semibold))
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
                    .font(.system(.title2, design: .serif).weight(.bold))

                HStack(spacing: 6) {
                    Text(memory.person.displayName)
                    if let date = memory.media.date {
                        Text("·")
                        Text(date)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if let caption = memory.media.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.body)
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
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .foregroundStyle(ArchiveTheme.accent)
                    .padding(.vertical, 13)
                    .overlay(alignment: .bottom) { Divider() }
                }
                .buttonStyle(.plain)
            }
            .padding(20)
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
                .font(.caption.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(ArchiveTheme.accent)
            Text(value)
                .font(.subheadline)
        }
    }
}
