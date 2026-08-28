import SwiftUI
import UIKit

struct PersonDetailView: View {
    private let initialPerson: Person
    private let personID: Person.ID
    @ObservedObject var repository: FamilyRepository

    private var person: Person {
        repository.person(id: personID) ?? initialPerson
    }

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: DetailTab = .overview
    @State private var showingActions = false
    @State private var showingAllMedia = false
    @State private var showingEditor = false
    @State private var showingMediaEditor = false
    @State private var showingProfilePhotoEditor = false
    @State private var showingEventsManager = false
    @State private var showingStoriesManager = false
    @State private var selectedMedia: MediaReference?
    @State private var selectedFamilyPerson: PresentedFamilyPerson?

    init(person: Person, repository: FamilyRepository) {
        initialPerson = person
        personID = person.id
        _repository = ObservedObject(wrappedValue: repository)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                detailTopBar
                ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        profileHeader
                        profileMediaPreview

                        Section {
                            tabContent
                                .id(repository.appLanguage)
                                .padding(.horizontal, 20)
                                .padding(.top, 22)
                                .padding(.bottom, 32)
                        } header: {
                            tabBar
                                .background(ArchiveTheme.background)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            if showingActions {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { showingActions = false }

                profileActionsMenu
                    .padding(.top, 58)
                    .padding(.trailing, 20)
                    .zIndex(2)
            }
        }
        .foregroundStyle(ArchiveTheme.ink)
        .background(ArchiveTheme.background)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingAllMedia) {
            PersonMediaGalleryView(person: person, items: browsableMedia, repository: repository)
        }
        .sheet(item: $selectedMedia) { item in
            MemoriesPagerView(
                items: browsableMedia.map { MemoryItem(person: person, media: $0) },
                initialID: "\(person.id)-\(item.id)",
                repository: repository
            )
        }
        .sheet(isPresented: $showingEditor) {
            ProfileEditorView(person: person, repository: repository)
        }
        .sheet(isPresented: $showingMediaEditor) {
            PersonMediaEditorView(person: person, repository: repository)
        }
        .sheet(isPresented: $showingProfilePhotoEditor) {
            ProfilePhotoSelectionView(person: person, repository: repository)
        }
        .sheet(isPresented: $showingEventsManager) {
            LifeEventsManagerView(person: person, repository: repository)
        }
        .sheet(isPresented: $showingStoriesManager) {
            StoriesManagerView(person: person, repository: repository)
        }
        .sheet(item: $selectedFamilyPerson) { presented in
            if let familyPerson = repository.person(id: presented.id) {
                NavigationStack {
                    PersonDetailView(person: familyPerson, repository: repository)
                }
            }
        }
    }

    private var profileActionsMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            if repository.canEdit {
                profileAction(ArchiveCopy.text(english: "Edit profile", russian: "Изменить профиль"), systemImage: "person.crop.circle") {
                    showingActions = false
                    showingEditor = true
                }
                profileAction(ArchiveCopy.text(english: "Change profile image", russian: "Изменить фото профиля"), systemImage: "person.crop.square") {
                    showingActions = false
                    showingProfilePhotoEditor = true
                }
                profileAction(ArchiveCopy.text(english: "Edit media", russian: "Изменить медиа"), systemImage: "photo") {
                    showingActions = false
                    showingMediaEditor = true
                }
            }
            profileAction(ArchiveCopy.text(english: "Share profile", russian: "Поделиться профилем"), systemImage: "square.and.arrow.up") {
                showingActions = false
            }
        }
        .frame(width: 188, alignment: .leading)
        .background(ArchiveTheme.background)
        .overlay(Rectangle().stroke(ArchiveTheme.controlBorder, lineWidth: 1))
        .shadow(color: ArchiveTheme.ink.opacity(0.14), radius: 8, y: 3)
    }

    private func profileAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(ArchiveTypography.icon)
                    .frame(width: 18)
                Text(title)
                    .font(ArchiveTypography.body)
                Spacer()
            }
            .foregroundStyle(ArchiveTheme.ink)
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var detailTopBar: some View {
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
            .accessibilityLabel(ArchiveCopy.text(english: "Close profile", russian: "Закрыть профиль"))

            Spacer()

            HStack(spacing: 7) {
                Text(person.relationshipToMe.map { ArchiveCopy.relationshipLabel($0, gender: person.archiveGender) } ?? ArchiveCopy.text(english: "Family member", russian: "Член семьи"))
                    .font(ArchiveTypography.navigationTitle)
                    .lineLimit(1)

                Button {
                    repository.appLanguage = repository.appLanguage == .english ? .russian : .english
                } label: {
                    Text(repository.appLanguage == .english ? "EN" : "RU")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(ArchiveTheme.ink)
                        .background(ArchiveTheme.actionBackground)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(repository.appLanguage == .english
                    ? "Switch profile language to Russian"
                    : "Переключить язык профиля на английский")
            }

            Spacer()

            Button {
                showingActions = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(ArchiveTypography.icon)
                    .foregroundStyle(ArchiveTheme.ink)
                    .frame(width: ArchiveShape.actionDiameter, height: ArchiveShape.actionDiameter)
                    .background(ArchiveTheme.actionBackground)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ArchiveCopy.text(english: "Profile actions", russian: "Действия профиля"))
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                Button {
                    guard let profileMediaItem else { return }
                    selectedMedia = profileMediaItem
                } label: {
                    ProfilePhotoView(person: person, size: 72, repository: repository)
                    // Align the photo with the visible cap-height of the name,
                    // not the font's invisible line-box top.
                    .padding(.top, ArchiveTypography.profileNameOpticalTopInset)
                }
                .buttonStyle(.plain)
                .disabled(profileMediaItem == nil)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .center, spacing: 10) {
                        Text(person.displayName)
                            .font(ArchiveTypography.profileName)
                            .fixedSize(horizontal: false, vertical: true)

                        if repository.accountHolderID == person.id {
                            AccountHolderBadge()
                        }
                    }

                    if let lifeSummary = profileLifeSummary {
                        Text(lifeSummary)
                            .font(ArchiveTypography.body)
                            .foregroundStyle(ArchiveTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: 2) {
                if let birth = person.birthFact {
                    ProfileDateLine(label: ArchiveCopy.text(english: "Birth", russian: "Рождение"), fact: birth)
                }

                if let death = person.deathFact {
                    ProfileDateLine(label: ArchiveCopy.text(english: "Death", russian: "Смерть"), fact: death)
                }

            }

            if !profileSummaryText.isEmpty {
                ArchiveParagraph(profileSummaryText)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var profileSummaryText: String {
        let summary = person.localizedSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliases = person.alternateNames
            .map { NameLocalizationStore.shared.localizeEmbeddedNames(in: $0) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let aliasText = aliases.isEmpty
            ? ""
            : ArchiveCopy.text(
                english: "Also known as " + aliases.joined(separator: " · ") + ".",
                russian: "Также известен как " + aliases.joined(separator: " · ") + "."
            )
        return [summary, aliasText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private var profileLifeSummary: String? {
        if repository.hasUnknownDeathDate(person) {
            return "????"
        }

        let lifespanYears = years(in: person.lifespan)
        let birthValue = person.birthFact?.value
        let deathValue = person.deathFact?.value
        let birthYear = years(in: birthValue).first ?? lifespanYears.first
        guard let birthYear else { return nil }

        let birthDate = date(from: birthValue)
        let deathDate = date(from: deathValue)
        let deathYear = years(in: deathValue).first ?? (lifespanYears.count > 1 ? lifespanYears.last : nil)
        let calendar = Calendar.current

        if let deathYear {
            let age = age(from: birthDate, birthYear: birthYear, to: deathDate, endYear: deathYear)
            let yearsAgo = yearsAgo(from: deathDate, year: deathYear, calendar: calendar)
            if ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? "en") == .russian {
                let unit = yearsAgo == 1 ? "год" : yearsAgo < 5 ? "года" : "лет"
                switch person.archiveGender {
                case .female:
                    return "Умерла в возрасте \(age) · \(yearsAgo) \(unit) назад"
                case .male:
                    return "Умер в возрасте \(age) · \(yearsAgo) \(unit) назад"
                case .unknown:
                    return "Смерть в возрасте \(age) · \(yearsAgo) \(unit) назад"
                }
            }
            return "Died at age \(age) · \(yearsAgo) \(yearsAgo == 1 ? "year" : "years") ago"
        }

        let age = age(from: birthDate, birthYear: birthYear, to: Date(), endYear: calendar.component(.year, from: Date()))
        return ArchiveCopy.text(english: "Age \(age)", russian: "Возраст \(age)")
    }

    private func date(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["d MMMM yyyy", "d MMM yyyy", "MMMM d, yyyy", "MMM d, yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    private func years(in value: String?) -> [Int] {
        guard let value else { return [] }
        return value
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
            .filter { (1000...2100).contains($0) }
    }

    private func age(from birthDate: Date?, birthYear: Int, to endDate: Date?, endYear: Int) -> Int {
        if let birthDate, let endDate {
            return max(0, Calendar.current.dateComponents([.year], from: birthDate, to: endDate).year ?? endYear - birthYear)
        }
        return max(0, endYear - birthYear)
    }

    private func yearsAgo(from date: Date?, year: Int, calendar: Calendar) -> Int {
        if let date {
            return max(0, calendar.dateComponents([.year], from: date, to: Date()).year ?? calendar.component(.year, from: Date()) - year)
        }
        return max(0, calendar.component(.year, from: Date()) - year)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(DetailTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: tab.systemImage)
                            .font(ArchiveTypography.icon)

                        Text(tab.title)
                            .font(ArchiveTypography.metadataEmphasis)
                            .lineLimit(1)
                    }
                    .foregroundStyle(selectedTab == tab ? ArchiveTheme.action : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(selectedTab == tab ? ArchiveTheme.action : Color.clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var profileMediaPreview: some View {
        // Media is shared by person ID, not by whichever person's JSON file
        // happens to own the record. Use the repository lookup here so a
        // newly selected @mention appears on the target profile immediately.
        let previewMedia = repository.media(for: person.id).filter { $0.path != profileMediaPath }

        if !previewMedia.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    ArchiveSectionHeading(ArchiveCopy.text(english: "MEDIA", russian: "МЕДИА"))

                    Spacer()

                    Button(ArchiveCopy.text(english: "View all", russian: "Показать всё")) {
                        showingAllMedia = true
                    }
                    .font(ArchiveTypography.action)
                    .foregroundStyle(ArchiveTheme.action)
                    .buttonStyle(.plain)
                }

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5),
                    spacing: 6
                ) {
                    ForEach(previewMedia.prefix(5)) { item in
                        Button {
                            selectedMedia = item
                        } label: {
                            ProfileMediaPreviewTile(item: item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(ArchiveCopy.text(english: "Open media", russian: "Открыть медиа"))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
    }

    private var profileMediaPath: String? {
        repository.photoPath(for: person.id)
    }

    private var profileMediaItem: MediaReference? {
        guard let path = profileMediaPath else { return nil }
        if let existing = repository.media(for: person.id).first(where: { $0.path == path }) {
            return existing
        }
        return MediaReference(
            id: "profile-\(person.id)",
            kind: .photo,
            title: "",
            date: nil,
            path: path,
            caption: nil,
            tags: nil,
            collection: nil,
            isApproximate: nil,
            personIDs: [person.id]
        )
    }

    private var browsableMedia: [MediaReference] {
        let relatedMedia = repository.media(for: person.id)
        guard let profileMediaItem,
              !relatedMedia.contains(where: { $0.path == profileMediaItem.path }) else {
            return relatedMedia
        }
        return [profileMediaItem] + relatedMedia
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .overview:
            overviewContent
        case .timeline:
            timelineContent
        case .stories:
            storiesContent
        case .family:
            familyContent
        }
    }

    @ViewBuilder
    private var overviewContent: some View {
        if let connectionPreview {
            ConnectionPathPreview(preview: connectionPreview, repository: repository)
        } else {
            EmptyView()
        }
    }

    private var connectionPreview: ConnectionPathPreviewModel? {
        // Build the relationship tree for every profile that can be reached
        // from the account holder through the recorded family connections.
        // Profiles without a discoverable path simply omit this section.
        guard let accountID = repository.accountHolderID,
              let account = repository.person(id: accountID),
              let path = connectionPath(from: account.id, to: person.id) else {
            return nil
        }

        if account.id == person.id {
            let step = ConnectionPathStepModel(
                person: account,
                relationship: nil,
                contextPeople: [],
                isAccount: true,
                isTarget: true
            )
            return ConnectionPathPreviewModel(
                accountName: account.displayName,
                targetName: person.displayName,
                relationshipSummary: ArchiveCopy.text(
                    english: "This is your account profile.",
                    russian: "Это ваш профиль."
                ),
                distanceSummary: ArchiveCopy.text(
                    english: "Account holder",
                    russian: "Владелец аккаунта"
                ),
                steps: [step]
            )
        }

        let pathIDs = Set(path.map(\.id))
        let steps = path.compactMap { node -> ConnectionPathStepModel? in
            guard let pathPerson = repository.person(id: node.id) else { return nil }

            let relationship: String?
            if let relationshipKind = node.kindFromPrevious,
               let index = path.firstIndex(where: { $0.id == node.id }),
               index > 0,
               let previousPerson = repository.person(id: path[index - 1].id) {
                relationship = connectionLabel(from: previousPerson, to: pathPerson, kind: relationshipKind)
            } else {
                relationship = nil
            }

            return ConnectionPathStepModel(
                person: pathPerson,
                relationship: relationship,
                contextPeople: repository.people(ids: pathPerson.immediateFamily.partners.filter { !pathIDs.contains($0) }),
                isAccount: pathPerson.id == account.id,
                isTarget: pathPerson.id == person.id
            )
        }

        guard steps.count == path.count,
              let summary = connectionSummary(for: person, path: path) else { return nil }

        return ConnectionPathPreviewModel(
            accountName: account.displayName,
            targetName: person.displayName,
            relationshipSummary: summary.text,
            distanceSummary: summary.distance,
            steps: steps
        )
    }

    private func connectionPath(from startID: Person.ID, to targetID: Person.ID) -> [ConnectionPathNode]? {
        guard startID != targetID else {
            return [ConnectionPathNode(id: startID, kindFromPrevious: nil)]
        }

        var queue = [startID]
        var queueIndex = 0
        var previous: [Person.ID: (id: Person.ID, kind: ConnectionEdgeKind)] = [:]
        var visited: Set<Person.ID> = [startID]

        while queueIndex < queue.count {
            let currentID = queue[queueIndex]
            queueIndex += 1

            for neighbor in connectionNeighbors(for: currentID) where !visited.contains(neighbor.id) {
                visited.insert(neighbor.id)
                previous[neighbor.id] = (currentID, neighbor.kind)
                queue.append(neighbor.id)
                if neighbor.id == targetID { break }
            }

            if visited.contains(targetID) { break }
        }

        guard visited.contains(targetID) else { return nil }

        var ids: [Person.ID] = []
        var currentID = targetID
        while true {
            ids.append(currentID)
            if currentID == startID { break }
            guard let previousID = previous[currentID]?.id else { return nil }
            currentID = previousID
        }

        return ids.reversed().enumerated().map { index, id in
            ConnectionPathNode(
                id: id,
                kindFromPrevious: index == 0 ? nil : previous[id]?.kind
            )
        }
    }

    private func connectionNeighbors(for personID: Person.ID) -> [ConnectionNeighbor] {
        guard let person = repository.person(id: personID) else { return [] }

        var neighbors: [ConnectionNeighbor] = []
        var seen = Set<Person.ID>()

        func add(_ id: Person.ID, kind: ConnectionEdgeKind) {
            guard id != personID, repository.person(id: id) != nil, seen.insert(id).inserted else { return }
            neighbors.append(ConnectionNeighbor(id: id, kind: kind))
        }

        person.immediateFamily.parents.forEach { add($0, kind: .parent) }
        person.immediateFamily.children.forEach { add($0, kind: .child) }
        person.immediateFamily.partners.forEach { add($0, kind: .partner) }
        person.immediateFamily.siblings.forEach { add($0, kind: .sibling) }

        // Some GEDCOM migrations omit sibling links. Infer them when two
        // people share at least one recorded parent.
        let parentIDs = Set(person.immediateFamily.parents)
        if !parentIDs.isEmpty {
            for candidate in repository.people where candidate.id != personID {
                if !parentIDs.isDisjoint(with: candidate.immediateFamily.parents) {
                    add(candidate.id, kind: .sibling)
                }
            }
        }

        return neighbors
    }

    private func connectionLabel(from source: Person, to destination: Person, kind: ConnectionEdgeKind) -> String {
        let relationship = connectionWord(for: destination, kind: kind)
        if ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? "en") == .russian {
            return "\(relationship) \(russianGenitiveName(of: source))"
        }

        let sourceName = source.givenName.isEmpty ? source.displayName : source.displayGivenName
        return "\(sourceName)’s \(relationship)"
    }

    private func connectionWord(for person: Person, kind: ConnectionEdgeKind) -> String {
        switch kind {
        case .parent:
            switch connectionGender(of: person) {
            case .female: ArchiveCopy.text(english: "mother", russian: "мать")
            case .male: ArchiveCopy.text(english: "father", russian: "отец")
            case .unknown: ArchiveCopy.text(english: "parent", russian: "родитель")
            }
        case .child:
            switch connectionGender(of: person) {
            case .female: ArchiveCopy.text(english: "daughter", russian: "дочь")
            case .male: ArchiveCopy.text(english: "son", russian: "сын")
            case .unknown: ArchiveCopy.text(english: "child", russian: "ребёнок")
            }
        case .partner:
            switch connectionGender(of: person) {
            case .female: ArchiveCopy.text(english: "wife", russian: "жена")
            case .male: ArchiveCopy.text(english: "husband", russian: "муж")
            case .unknown: ArchiveCopy.text(english: "spouse", russian: "партнёр")
            }
        case .sibling:
            switch connectionGender(of: person) {
            case .female: ArchiveCopy.text(english: "sister", russian: "сестра")
            case .male: ArchiveCopy.text(english: "brother", russian: "брат")
            case .unknown: ArchiveCopy.text(english: "sibling", russian: "брат или сестра")
            }
        }
    }

    private func connectionSummary(for target: Person, path: [ConnectionPathNode]) -> (text: String, distance: String)? {
        let kinds = path.dropFirst().compactMap(\.kindFromPrevious)
        guard !kinds.isEmpty else { return nil }

        if kinds.allSatisfy({ $0 == .parent }) {
            let ancestor: String
            switch connectionGender(of: target) {
            case .female:
                ancestor = ancestorTerm(for: kinds.count, feminine: true)
            case .male:
                ancestor = ancestorTerm(for: kinds.count, feminine: false)
            case .unknown:
                ancestor = ancestorTerm(for: kinds.count, feminine: nil)
            }
            if ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? "en") == .russian {
                let possessive: String
                switch connectionGender(of: target) {
                case .female: possessive = "ваша"
                case .male, .unknown: possessive = "ваш"
                }
                return ("\(target.displayName) — \(possessive) \(ancestor).", "\(kinds.count) поколений назад")
            }
            return ("\(target.displayName) is your \(ancestor).", "\(kinds.count) generations away")
        }

        let destinations = path.dropFirst().compactMap { repository.person(id: $0.id) }
        let words = zip(kinds, destinations).map { connectionWord(for: $0.1, kind: $0.0) }
        guard let first = words.first else { return nil }

        if ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? "en") == .russian {
            var relation = "\(first) \(russianGenitiveName(of: repository.person(id: path[0].id) ?? person))"
            for index in 1..<destinations.count {
                let previous = repository.person(id: path[index].id)
                relation = "\(words[index]) \(previous.map { russianGenitiveName(of: $0) } ?? "")"
            }
            let summary = "\(target.displayName) — \(relation)."
            return (summary, "Связей: \(kinds.count)")
        }

        let firstGender = destinations.first.map(connectionGender(of:)) ?? .unknown
        let russianPossessive: String
        switch firstGender {
        case .female: russianPossessive = "ваша"
        case .male: russianPossessive = "ваш"
        case .unknown: russianPossessive = "ваш родственник"
        }
        var phrase = ArchiveCopy.text(english: "your \(first)", russian: "\(russianPossessive) \(first)")
        for word in words.dropFirst() {
            phrase += ArchiveCopy.text(english: "’s \(word)", russian: " — \(word)")
        }
        let summary = ArchiveCopy.text(english: "\(target.displayName) is \(phrase).", russian: "\(target.displayName) — \(phrase).")
        let distance = ArchiveCopy.text(english: "\(kinds.count) connections away", russian: "Связей: \(kinds.count)")
        return (summary, distance)
    }

    private func russianGenitiveName(of person: Person) -> String {
        let name = person.displayGivenName
        let normalized = name.lowercased().replacingOccurrences(of: "ё", with: "е")
        let explicit: [String: String] = [
            "иван": "Ивана", "владимир": "Владимира", "михаил": "Михаила", "константин": "Константина",
            "сергей": "Сергея", "александр": "Александра", "яков": "Якова", "антон": "Антона",
            "виктор": "Виктора", "степан": "Степана", "петр": "Петра", "евгений": "Евгения",
            "илья": "Ильи", "юрий": "Юрия", "андрей": "Андрея", "аркадий": "Аркадия",
            "елена": "Елены", "галина": "Галины", "ирина": "Ирины", "анна": "Анны",
            "антонина": "Антонины", "ольга": "Ольги", "александра": "Александры", "мария": "Марии",
            "татьяна": "Татьяны", "людмила": "Людмилы", "юлия": "Юлии", "евгения": "Евгении",
            "надежда": "Надежды", "римма": "Риммы", "ариадна": "Ариадны", "раиса": "Раисы"
        ]
        if let result = explicit[normalized] { return result }
        if normalized.hasSuffix("ия") { return String(name.dropLast(1)) + "и" }
        if normalized.hasSuffix("а") || normalized.hasSuffix("я") || normalized.hasSuffix("ь") {
            return String(name.dropLast()) + (normalized.hasSuffix("я") ? "и" : "ы")
        }
        if normalized.hasSuffix("й") { return String(name.dropLast()) + "я" }
        return name + "а"
    }

    private func ancestorTerm(for generations: Int, feminine: Bool?) -> String {
        let base: String
        switch feminine {
        case true:
            base = ArchiveCopy.text(english: generations == 1 ? "mother" : "grandmother", russian: generations == 1 ? "мать" : "бабушка")
        case false:
            base = ArchiveCopy.text(english: generations == 1 ? "father" : "grandfather", russian: generations == 1 ? "отец" : "дедушка")
        case nil:
            base = ArchiveCopy.text(english: generations == 1 ? "parent" : "grandparent", russian: generations == 1 ? "родитель" : "бабушка или дедушка")
        }

        guard generations > 2 else { return base }
        if ArchiveLanguage(rawValue: UserDefaults.standard.string(forKey: NameLocalizationStore.appLanguageKey) ?? "en") == .russian {
            return String(repeating: "пра", count: generations - 2) + base
        }
        let greatPrefix = String(repeating: "great-", count: generations - 2)
        return greatPrefix + base
    }

    private func connectionGender(of person: Person) -> ConnectionGender {
        switch person.archiveGender {
        case .female: return .female
        case .male: return .male
        case .unknown: return .unknown
        }
    }

    private var timelineContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    ArchiveSectionHeading(ArchiveCopy.text(english: "LIFE EVENTS & RECORDS", russian: "СОБЫТИЯ И ЗАПИСИ"))
                    Spacer()
                    if repository.canEdit {
                        Button(ArchiveCopy.text(english: "Manage", russian: "Управлять")) { showingEventsManager = true }
                            .font(ArchiveTypography.action)
                            .foregroundStyle(ArchiveTheme.action)
                            .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    if !timelineEntries.isEmpty {
                        ForEach(Array(timelineEntries.enumerated()), id: \.element.id) { index, entry in
                            LifeEventRow(timelineEvent: entry, isLast: index == timelineEntries.count - 1)
                        }
                    } else {
                        Text(ArchiveCopy.text(english: "No additional dated events recorded.", russian: "Дополнительные события с датами не записаны."))
                            .font(ArchiveTypography.paragraph)
                            .foregroundStyle(ArchiveTheme.muted)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 12)
                    }
                }
            }
        }
    }

    private var storiesContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .firstTextBaseline) {
                ArchiveSectionHeading(ArchiveCopy.text(english: "STORIES", russian: "ИСТОРИИ"))
                Spacer()
                if repository.canEdit {
                    Button(ArchiveCopy.text(english: "Manage", russian: "Управлять")) { showingStoriesManager = true }
                        .font(ArchiveTypography.action)
                        .foregroundStyle(ArchiveTheme.action)
                        .buttonStyle(.plain)
                }
            }

            if !person.structuredStories.isEmpty {
                ForEach(person.structuredStories) { chapter in
                    VStack(alignment: .leading, spacing: 10) {
                        ArchiveSectionHeading(
                            NarrativeLocalizationStore.shared.storyTitle(person.id, storyID: chapter.id, source: chapter.title)
                        )

                        if let dateRange = chapter.dateRange, let summary = chapter.summary {
                            StoryDatedContentBlock(
                                date: dateRange,
                                title: NarrativeLocalizationStore.shared.storySummary(person.id, storyID: chapter.id, source: summary),
                                body: NarrativeLocalizationStore.shared.storyBody(person.id, storyID: chapter.id, source: chapter.body)
                            )
                        } else {
                            if let dateRange = chapter.dateRange {
                                ArchiveContentDate(dateRange)
                            }
                            if let summary = chapter.summary {
                                StoryIntroParagraph(NarrativeLocalizationStore.shared.storySummary(person.id, storyID: chapter.id, source: summary))
                            }
                        }
                        if chapter.dateRange == nil || chapter.summary == nil {
                            ArchiveParagraph(NarrativeLocalizationStore.shared.storyBody(person.id, storyID: chapter.id, source: chapter.body))
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                detailSection(ArchiveCopy.text(english: "Life story", russian: "История жизни")) {
                    ArchiveParagraph(person.localizedBiography)
                        .textSelection(.enabled)
                }
            }

        }
    }

    private var mediaContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            detailSection(ArchiveCopy.text(english: "Media & documents", russian: "Медиа и документы")) {
                mediaStats
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 1) {
                    ForEach(person.media) { item in
                        MediaTile(item: item, people: repository.people)
                    }
                }
                .padding(.top, 10)
            }

        }
    }

    private var familyContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            if hasFamily {
                familySection
            } else {
                detailSection(ArchiveCopy.text(english: "Immediate family", russian: "Ближайшие родственники")) {
                    ArchiveParagraph(ArchiveCopy.text(english: "No immediate family connections are recorded for this profile yet.", russian: "Для этого профиля пока не записаны близкие родственники."))
                }
            }
        }
    }

    private var mediaStats: some View {
        HStack(spacing: 0) {
            MediaStat(value: mediaCount(.photo), label: ArchiveCopy.text(english: "Photos", russian: "Фото"))
            MediaStat(value: mediaCount(.document), label: ArchiveCopy.text(english: "Documents", russian: "Документы"))
            MediaStat(value: mediaCount(.audio), label: ArchiveCopy.text(english: "Audio", russian: "Аудио"))
            MediaStat(value: mediaCount(.video), label: ArchiveCopy.text(english: "Video", russian: "Видео"))
        }
        .padding(.vertical, 12)
        .background(ArchiveTheme.ink.opacity(0.05))
    }

    private func mediaCount(_ kind: MediaKind) -> String {
        "\(person.media.filter { $0.kind == kind }.count)"
    }

    private var timelineEvents: [FamilyTimelineEvent] {
        repository.timelineEvents(for: person.id)
    }

    private var timelineEntries: [FamilyTimelineEvent] {
        timelineEvents
    }

    private var hasFamily: Bool {
        !person.immediateFamily.parents.isEmpty ||
            !person.immediateFamily.partners.isEmpty ||
            !person.immediateFamily.siblings.isEmpty ||
            !person.immediateFamily.children.isEmpty
    }

    private var familySection: some View {
        detailSection(ArchiveCopy.text(english: "Family", russian: "Семья")) {
            parentsGroup
            spousesGroup
            familyGroup(title: ArchiveCopy.text(english: "Children", russian: "Дети"), ids: person.immediateFamily.children)
            siblingGroups
        }
    }

    @ViewBuilder
    private var parentsGroup: some View {
        if !person.immediateFamily.parents.isEmpty {
            Text(ArchiveCopy.text(english: "Parents", russian: "Родители"))
                .font(ArchiveTypography.contentTitle)
                .padding(.top, 10)

            if let parentsUnionNote {
                Text(parentsUnionNote)
                    .font(ArchiveTypography.metadata)
                    .foregroundStyle(ArchiveTheme.metadata)
                    .padding(.bottom, 2)
            }

            ForEach(repository.people(ids: person.immediateFamily.parents)) { relative in
                FamilyMemberTile(person: relative, repository: repository)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedFamilyPerson = PresentedFamilyPerson(id: relative.id)
                    }
                    .accessibilityAddTraits(.isButton)
                    .padding(.bottom, 6)
            }
        }
    }

    private var parentsUnionNote: String? {
        guard person.immediateFamily.parentsUnionStatus?.lowercased() == "divorced" else { return nil }

        let status = ArchiveCopy.text(english: "Parents divorced", russian: "Родители в разводе")
        guard let date = person.immediateFamily.parentsUnionDate?.trimmed,
              !date.isEmpty else {
            return status
        }

        let suffix = person.immediateFamily.parentsUnionDateIsApproximate == true
            ? ArchiveCopy.text(english: "approx.", russian: "примерно")
            : nil
        return [status, date, suffix].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var siblingGroups: some View {
        let parentIDs = Set(person.immediateFamily.parents)
        let siblings = repository.people(ids: person.immediateFamily.siblings)
        let fullSiblingIDs = siblings
            .filter { parentIDs.intersection($0.immediateFamily.parents).count >= 2 }
            .map(\.id)
        let halfSiblingIDs = siblings
            .filter { parentIDs.intersection($0.immediateFamily.parents).count == 1 }
            .map(\.id)
        let otherSiblingIDs = siblings
            .filter { parentIDs.intersection($0.immediateFamily.parents).isEmpty }
            .map(\.id)

        if !fullSiblingIDs.isEmpty {
            familyGroup(
                title: ArchiveCopy.text(english: "Siblings", russian: "Братья и сёстры"),
                ids: fullSiblingIDs
            )
        }
        if !halfSiblingIDs.isEmpty {
            familyGroup(
                title: halfSiblingGroupTitle(for: halfSiblingIDs),
                ids: halfSiblingIDs
            )
        }
        if !otherSiblingIDs.isEmpty {
            familyGroup(
                title: ArchiveCopy.text(english: "Siblings (relationship to parent unclear)", russian: "Братья и сёстры (связь с родителем не уточнена)"),
                ids: otherSiblingIDs
            )
        }
    }

    private func halfSiblingGroupTitle(for siblingIDs: [Person.ID]) -> String {
        let parentIDs = Set(person.immediateFamily.parents)
        var sharedParentIDs = parentIDs
        for sibling in repository.people(ids: siblingIDs) {
            sharedParentIDs.formIntersection(sibling.immediateFamily.parents)
        }

        guard sharedParentIDs.count == 1,
              let sharedParentID = sharedParentIDs.first,
              let sharedParent = repository.person(id: sharedParentID) else {
            return ArchiveCopy.text(english: "Half-siblings", russian: "Неполнородные братья и сёстры")
        }

        let through: String
        switch sharedParent.archiveGender {
        case .female:
            through = ArchiveCopy.text(english: "through mother", russian: "по матери")
        case .male:
            through = ArchiveCopy.text(english: "through father", russian: "по отцу")
        case .unknown:
            through = ArchiveCopy.text(english: "through shared parent", russian: "по общему родителю")
        }
        return "\(ArchiveCopy.text(english: "Half-siblings", russian: "Неполнородные братья и сёстры")) · \(through)"
    }

    private var spouseGroupTitle: String {
        let partners = repository.partnerRelationships(for: person.id).map(\.partner)
        guard partners.count == 1, let partner = partners.first else {
            return ArchiveCopy.spouseLabel(gender: .unknown)
        }
        return ArchiveCopy.spouseLabel(gender: partner.archiveGender)
    }

    @ViewBuilder
    private var spousesGroup: some View {
        let relationships = repository.partnerRelationships(for: person.id)
        if !relationships.isEmpty {
            Text(spouseGroupTitle)
                .font(ArchiveTypography.contentTitle)
                .padding(.top, 10)

            ForEach(relationships) { relationship in
                FamilyMemberTile(
                    person: relationship.partner,
                    repository: repository,
                    relationshipDetail: spouseRelationshipDetail(relationship)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedFamilyPerson = PresentedFamilyPerson(id: relationship.partner.id)
                }
                .accessibilityAddTraits(.isButton)
                .padding(.bottom, 6)
            }
        }
    }

    private func spouseRelationshipDetail(_ relationship: FamilyPartnerRelationship) -> String? {
        var parts: [String] = []
        if let sequence = relationship.sequence {
            parts.append(orderedSpouseLabel(sequence, gender: relationship.partner.archiveGender))
        }
        if let date = relationship.union.marriageDate?.trimmed, !date.isEmpty {
            parts.append(ArchiveCopy.text(english: "Married \(date)", russian: "Брак · \(date)"))
        }
        if let status = relationship.union.relationshipStatus?.trimmed,
           !status.isEmpty,
           status.lowercased() != "married" {
            let statusLabel = ArchiveCopy.text(english: status.capitalized, russian: ArchiveCopy.relationshipStatus(status))
            if let statusDate = relationship.union.statusDate?.trimmed, !statusDate.isEmpty {
                parts.append("\(statusLabel) · \(statusDate)")
            } else {
                parts.append(statusLabel)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func orderedSpouseLabel(_ sequence: Int, gender: ArchiveGender) -> String {
        let englishOrdinal: String
        let russianOrdinal: String
        switch sequence {
        case 1: (englishOrdinal, russianOrdinal) = ("First", gender == .male ? "Первый" : "Первая")
        case 2: (englishOrdinal, russianOrdinal) = ("Second", gender == .male ? "Второй" : "Вторая")
        case 3: (englishOrdinal, russianOrdinal) = ("Third", gender == .male ? "Третий" : "Третья")
        default: (englishOrdinal, russianOrdinal) = ("Spouse #\(sequence)", "Супруг(а) №\(sequence)")
        }

        let englishRole: String
        let russianRole: String
        switch gender {
        case .male: (englishRole, russianRole) = ("husband", "муж")
        case .female: (englishRole, russianRole) = ("wife", "жена")
        case .unknown: (englishRole, russianRole) = ("spouse", "супруг(а)")
        }
        if sequence > 3 {
            return ArchiveCopy.text(english: englishOrdinal, russian: russianOrdinal)
        }
        return ArchiveCopy.text(
            english: "\(englishOrdinal) \(englishRole)",
            russian: "\(russianOrdinal) \(russianRole)"
        )
    }

    @ViewBuilder
    private func familyGroup(title: String, ids: [Person.ID]) -> some View {
        if !ids.isEmpty {
            Text(title)
                .font(ArchiveTypography.contentTitle)
                .padding(.top, 10)

            ForEach(repository.people(ids: ids)) { relative in
                FamilyMemberTile(person: relative, repository: repository)
                    .contentShape(Rectangle())
                    .onTapGesture {
                    selectedFamilyPerson = PresentedFamilyPerson(id: relative.id)
                    }
                    .accessibilityAddTraits(.isButton)
                .padding(.bottom, 6)
            }
        }
    }

    private func tabLink(_ title: String, tab: DetailTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack {
                Text(title)
                    .font(ArchiveTypography.action)
                    .underline()
                Spacer()
                Image(systemName: "arrow.right")
            }
            .foregroundStyle(ArchiveTheme.action)
            .padding(.vertical, 13)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ArchiveSectionHeading(title)

            VStack(alignment: .leading, spacing: 0, content: content)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shared visual treatment for section headings inside a person profile.
/// Keeping the casing, tracking, font, and ink color in one component prevents
/// the Overview relationship heading from drifting from the other tabs.
private struct ArchiveSectionHeading: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(ArchiveTypography.sectionTitle)
            .tracking(1.2)
            .foregroundStyle(ArchiveTheme.ink)
    }
}

private struct ArchiveParagraph: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(ArchiveTypography.paragraph)
            .foregroundStyle(ArchiveTheme.muted)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ArchiveContentDate: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        Text(ArchiveDateFormatter.displayRange(value) ?? value)
            .font(ArchiveTypography.metadataEmphasis)
            .foregroundStyle(ArchiveTheme.metadata)
    }
}

private struct ArchiveContentTitle: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        Text(value)
            .font(ArchiveTypography.contentTitle)
            .foregroundStyle(ArchiveTheme.ink)
    }
}

private struct StoryIntroParagraph: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(ArchiveTheme.accent)
                .frame(width: 3)

            Text(value)
                .font(ArchiveTypography.paragraph)
                .foregroundStyle(ArchiveTheme.ink)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ArchiveDatedContentTitle: View {
    let date: String
    let title: String
    let note: String?

    init(date: String, title: String, note: String? = nil) {
        self.date = date
        self.title = title
        self.note = note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                ArchiveContentDate(date)
                Spacer()
                if let note {
                    Text(note)
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.metadata)
                }
            }
            ArchiveContentTitle(title)
        }
    }
}

private struct ArchiveDatedContentBlock: View {
    let date: String
    let title: String
    let bodyText: String
    let note: String?

    init(date: String, title: String, body: String, note: String? = nil) {
        self.date = date
        self.title = title
        self.bodyText = body
        self.note = note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ArchiveDatedContentTitle(date: date, title: title, note: note)
            ArchiveParagraph(bodyText)
                .textSelection(.enabled)
        }
    }
}

private struct StoryDatedContentBlock: View {
    let date: String
    let title: String
    let bodyText: String

    init(date: String, title: String, body: String) {
        self.date = date
        self.title = title
        self.bodyText = body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(ArchiveTheme.accent)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 3) {
                    ArchiveContentDate(date)
                    Text(title)
                        .font(ArchiveTypography.paragraph)
                        .foregroundStyle(ArchiveTheme.ink)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
                .padding(.bottom, 9)

            ArchiveParagraph(bodyText)
                .textSelection(.enabled)
        }
    }
}

private struct ProfileDateLine: View {
    let label: String
    let fact: PersonFact

    var body: some View {
        (
            Text("\(label): ")
                .font(ArchiveTypography.metadataEmphasis)
                .foregroundStyle(ArchiveTheme.ink)
            + Text(dateAndPlace)
                .font(ArchiveTypography.metadata)
                .foregroundStyle(ArchiveTheme.metadata)
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private var dateAndPlace: String {
        let rawDate = fact.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = ArchiveDateFormatter.displayRange(rawDate) ?? (rawDate.isEmpty ? "????" : rawDate)
        guard let place = fact.place, !place.isEmpty else { return date }
        return "\(date), \(ArchiveCopy.place(place))"
    }
}

private struct ProfilePhotoView: View {
    let person: Person
    let size: CGFloat
    let repository: FamilyRepository?

    init(person: Person, size: CGFloat, repository: FamilyRepository? = nil) {
        self.person = person
        self.size = size
        self.repository = repository
    }

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(CGFloat(currentPerson.profileImageScale ?? 1))
                        // Crop offsets are authored in the 300-point editor;
                        // scale them for the actual avatar size so a saved
                        // adjustment remains visible in every context.
                        .offset(
                            x: CGFloat(currentPerson.profileImageOffsetX ?? 0) * size / 300,
                            y: CGFloat(currentPerson.profileImageOffsetY ?? 0) * size / 300
                        )
                    .grayscale((repository?.isLiving(currentPerson) ?? currentPerson.isLiving) ? 0 : 1)
            } else {
                ZStack(alignment: .bottomLeading) {
                    MonogramView(
                        person: currentPerson,
                        size: size,
                        isLiving: repository?.isLiving(currentPerson) ?? currentPerson.isLiving
                    )
                    Image(systemName: "photo")
                        .font(ArchiveTypography.metadataEmphasis)
                        .foregroundStyle(.white)
                        .padding(8)
                }
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .accessibilityLabel("Photo for \(person.displayName)")
    }

    private var loadedImage: UIImage? {
        let path: String?
        if let repository {
            // The repository resolver enforces that the path belongs to this
            // person's tagged media collection. Do not fall back to a stale
            // profileImagePath when that check rejects it.
            path = repository.photoPath(for: currentPerson.id)
        } else {
            path = currentPerson.profileImagePath ?? currentPerson.media.first(where: { $0.kind == .photo })?.path
        }
        guard let path else { return nil }
        return ArchiveFileResolver.image(for: path)
    }

    private var currentPerson: Person {
        repository?.person(id: person.id) ?? person
    }
}

private struct PresentedFamilyPerson: Identifiable {
    let id: Person.ID
}

private enum DetailTab: String, CaseIterable, Identifiable {
    case overview
    case timeline
    case stories
    case family

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: ArchiveCopy.text(english: "Overview", russian: "Обзор")
        case .timeline: ArchiveCopy.text(english: "Life events", russian: "События")
        case .stories: ArchiveCopy.text(english: "Stories", russian: "Истории")
        case .family: ArchiveCopy.text(english: "Family", russian: "Семья")
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "person.text.rectangle"
        case .timeline: "point.topleft.down.curvedto.point.bottomright.up"
        case .stories: "text.book.closed"
        case .family: "person.2"
        }
    }
}

private struct ConnectionPathPreviewModel {
    let accountName: String
    let targetName: String
    let relationshipSummary: String
    let distanceSummary: String
    let steps: [ConnectionPathStepModel]
}

private enum ConnectionEdgeKind {
    case parent
    case child
    case partner
    case sibling
}

private enum ConnectionGender {
    case female
    case male
    case unknown
}

private struct ConnectionNeighbor {
    let id: Person.ID
    let kind: ConnectionEdgeKind
}

private struct ConnectionPathNode {
    let id: Person.ID
    let kindFromPrevious: ConnectionEdgeKind?
}

private struct ConnectionPathStepModel: Identifiable {
    let person: Person
    let relationship: String?
    let contextPeople: [Person]
    let isAccount: Bool
    let isTarget: Bool

    var id: Person.ID { person.id }
}

private struct ConnectionPathPreview: View {
    let preview: ConnectionPathPreviewModel
    let repository: FamilyRepository

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                ArchiveSectionHeading(ArchiveCopy.text(english: "YOUR RELATIONSHIP", russian: "ВАША СВЯЗЬ"))

                Text(preview.relationshipSummary)
                    .font(ArchiveTypography.paragraph)
                    .foregroundStyle(ArchiveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(preview.distanceSummary)
                    .font(ArchiveTypography.metadata)
                    .foregroundStyle(ArchiveTheme.metadata)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(preview.steps.enumerated()), id: \.element.id) { index, step in
                    connectionStep(step, isLast: index == preview.steps.count - 1)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func connectionStep(_ step: ConnectionPathStepModel, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(step.isTarget || step.isAccount ? ArchiveTheme.action : ArchiveTheme.controlBorder)
                    .frame(width: 10, height: 10)
                    .padding(.top, 3)

                if !isLast {
                    Rectangle()
                        .fill(ArchiveTheme.controlBorder)
                        .frame(width: 1, height: 56)
                }
            }
            .frame(width: 10)

            VStack(alignment: .leading, spacing: 4) {
                if step.isAccount {
                    Text(ArchiveCopy.text(english: "YOU", russian: "ВЫ"))
                        .font(ArchiveTypography.metadata)
                        .tracking(0.7)
                        .foregroundStyle(ArchiveTheme.metadata)
                } else if let relationship = step.relationship {
                    Text(relationship.uppercased())
                        .font(ArchiveTypography.metadata)
                        .tracking(0.7)
                        .foregroundStyle(ArchiveTheme.metadata)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    NavigationLink {
                        PersonDetailView(person: step.person, repository: repository)
                    } label: {
                        Text(step.person.displayName)
                            .font(ArchiveTypography.contentTitle)
                            .foregroundStyle(step.isTarget || step.isAccount ? ArchiveTheme.action : ArchiveTheme.ink)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 8)

                if !step.contextPeople.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(ArchiveCopy.text(english: "with", russian: "с"))
                            .font(ArchiveTypography.metadata)
                            .foregroundStyle(ArchiveTheme.metadata)

                        ForEach(Array(step.contextPeople.enumerated()), id: \.element.id) { index, contextPerson in
                            if index > 0 {
                                Text("&")
                                    .font(ArchiveTypography.metadata)
                                    .foregroundStyle(ArchiveTheme.metadata)
                            }

                            NavigationLink {
                                PersonDetailView(person: contextPerson, repository: repository)
                            } label: {
                                Text(contextPerson.displayName)
                                    .font(ArchiveTypography.metadata)
                                    .foregroundStyle(ArchiveTheme.metadata)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                        .padding(.leading, 8)
                }
            }
            .padding(.bottom, 14)
        }
    }
}

private struct FactRow: View {
    let fact: PersonFact

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Text(fact.localizedLabel)
                .font(ArchiveTypography.supporting)
                .foregroundStyle(ArchiveTheme.muted)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(fact.localizedValue)
                if let place = fact.place {
                Text(ArchiveCopy.place(place))
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.metadata)
                }
            }
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct LifeEventRow: View {
    let timelineEvent: FamilyTimelineEvent
    let isLast: Bool

    private var event: LifeEvent { timelineEvent.event }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(ArchiveTheme.ink)
                    .frame(width: 10, height: 10)
                    .padding(.top, 15)

                if !isLast {
                    Rectangle()
                        .fill(ArchiveTheme.ink.opacity(0.25))
                        .frame(width: 1)
                }
            }
            .frame(width: 10)

            VStack(alignment: .leading, spacing: 4) {
                ArchiveDatedContentBlock(
                    date: event.date,
                    title: timelineEvent.isFamilyProjection
                        ? event.localizedTitle
                        : NarrativeLocalizationStore.shared.eventTitle(
                            timelineEvent.sourcePersonID,
                            eventID: timelineEvent.sourceEventID,
                            source: event.localizedTitle
                        ),
                    body: NarrativeLocalizationStore.shared.eventSummary(
                        timelineEvent.sourcePersonID,
                        eventID: timelineEvent.sourceEventID,
                        source: event.localizedSummary
                    ),
                    note: event.isApproximate == true ? ArchiveCopy.text(english: "Approximate", russian: "Примерно") : nil
                )
                if let place = event.place {
                    Text(ArchiveCopy.place(place))
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.metadata)
                }
            }
            .padding(.vertical, 11)
        }
    }
}

private struct ProfileMediaPreviewTile: View {
    let item: MediaReference

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack {
                    if let path = item.path, let image = ArchiveFileResolver.image(for: path) {
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

                        Image(systemName: item.kind.systemImage)
                            .font(ArchiveTypography.icon)
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        .clipped()
    }
}

private struct PersonMediaGalleryView: View {
    let person: Person
    let items: [MediaReference]
    let repository: FamilyRepository?
    let selectionMode: Bool
    let onSelect: ((MediaReference) -> Void)?
    let onCancel: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedMedia: MediaReference?

    init(person: Person, items: [MediaReference]? = nil, repository: FamilyRepository? = nil, selectionMode: Bool = false, onSelect: ((MediaReference) -> Void)? = nil, onCancel: (() -> Void)? = nil) {
        self.person = person
        self.items = items ?? person.media
        self.repository = repository
        self.selectionMode = selectionMode
        self.onSelect = onSelect
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            mediaTopBar

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 14
                ) {
                    ForEach(items) { item in
                        PersonMediaGalleryTile(
                            personID: person.id,
                            item: item,
                            people: repository?.people ?? [person]
                        )
                            .contentShape(Rectangle())
                            .onTapGesture {
                            if selectionMode {
                                onSelect?(item)
                            } else {
                                selectedMedia = item
                            }
                        }
                    }
                }
                .padding(.horizontal, ArchiveLayout.pageHorizontal)
                .padding(.top, ArchiveLayout.pageTop)
                .padding(.bottom, ArchiveLayout.pageBottom)
            }
            .scrollIndicators(.hidden)
            .background(ArchiveTheme.background)
        }
        .foregroundStyle(ArchiveTheme.ink)
        .background(ArchiveTheme.background)
        .sheet(item: $selectedMedia) { item in
            if let repository {
                MemoriesPagerView(
                    items: items.map { MemoryItem(person: person, media: $0) },
                    initialID: "\(person.id)-\(item.id)",
                    repository: repository
                )
            } else {
                PersonMediaPagerView(personID: person.id, items: items, initialID: item.id, repository: repository)
            }
        }
    }

    private var mediaTopBar: some View {
        HStack {
            Button {
                if let onCancel {
                    onCancel()
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(ArchiveTypography.icon)
                    .foregroundStyle(ArchiveTheme.ink)
                    .frame(width: ArchiveShape.actionDiameter, height: ArchiveShape.actionDiameter)
                    .background(ArchiveTheme.actionBackground)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ArchiveCopy.text(english: "Close media gallery", russian: "Закрыть галерею медиа"))

            Spacer()

            Text(selectionMode
                ? ArchiveCopy.text(english: "Choose profile image", russian: "Выберите фото профиля")
                : ArchiveCopy.text(english: "Media", russian: "Медиа"))
                .font(ArchiveTypography.navigationTitle)
                .lineLimit(1)

            Spacer()

            // Balance the title against the leading close control.
            Color.clear
                .frame(width: ArchiveShape.actionDiameter, height: ArchiveShape.actionDiameter)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}

private struct PersonMediaGalleryTile: View {
    let personID: Person.ID
    let item: MediaReference
    let people: [Person]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            PersonMediaVisual(item: item)

            Group {
                let caption = NarrativeLocalizationStore.shared.mediaCaption(mediaID: item.id, source: item.caption ?? "")
                if !caption.isEmpty {
                    Text(MediaMentionToken.visibleText(
                        caption,
                        people: people
                    ))
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

private struct PersonMediaVisual: View {
    let item: MediaReference
    @StateObject private var imageLoader = ArchiveImageLoader()

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

                        Image(systemName: item.kind.systemImage)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if item.kind != .photo {
                        Text(item.kind.rawValue.capitalized)
                            .font(ArchiveTypography.metadataEmphasis)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.55))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .task(id: item.path) {
                imageLoader.load(
                    path: item.kind == .photo ? item.path : nil,
                    maxPixelSize: 700
                )
            }
            .clipped()
    }
}

private struct PersonMediaPagerView: View {
    let personID: Person.ID
    let items: [MediaReference]
    let initialID: String
    let repository: FamilyRepository?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: Int
    @State private var showingMediaEditor = false
    @State private var showingRemoveConfirmation = false

    init(personID: Person.ID, items: [MediaReference], initialID: String, repository: FamilyRepository? = nil) {
        self.personID = personID
        self.items = items
        self.initialID = initialID
        self.repository = repository
        // The first and last pages are duplicated as invisible wrap points,
        // so a swipe can continue from the end back to the beginning.
        let initialPage = items.firstIndex { $0.id == initialID } ?? 0
        _selectedIndex = State(initialValue: items.count > 1 ? initialPage + 1 : 0)
    }

    private var pageItems: [MediaReference] {
        guard let first = items.first, let last = items.last, items.count > 1 else { return items }
        return [last] + items + [first]
    }

    private var displayIndex: Int {
        guard !items.isEmpty else { return 0 }
        if items.count == 1 { return 1 }
        return min(max(selectedIndex, 1), items.count)
    }

    private var currentItem: MediaReference? {
        guard !items.isEmpty else { return nil }
        let pageIndex = min(max(selectedIndex, 0), pageItems.count - 1)
        return pageItems[pageIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            mediaTopBar

            VStack(spacing: 0) {
                TabView(selection: $selectedIndex) {
                    ForEach(Array(pageItems.enumerated()), id: \.offset) { index, item in
                        PersonMediaDetailContent(
                            personID: personID,
                            item: item,
                            isActive: index == selectedIndex,
                            repository: repository
                        )
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                .onChange(of: selectedIndex) { _, newValue in
                    guard items.count > 1 else { return }
                    if newValue == 0 {
                        DispatchQueue.main.async {
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { selectedIndex = items.count }
                        }
                    } else if newValue == items.count + 1 {
                        DispatchQueue.main.async {
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { selectedIndex = 1 }
                        }
                    }
                }

                HStack {
                    Button {
                        guard items.count > 1 else { return }
                        selectedIndex = selectedIndex == 1 ? items.count : selectedIndex - 1
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(ArchiveTypography.icon)
                            .foregroundStyle(ArchiveTheme.ink)
                            .frame(width: ArchiveShape.actionDiameter, height: ArchiveShape.actionDiameter)
                            .background(ArchiveTheme.actionBackground)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(items.count < 2)
                    .opacity(items.count < 2 ? 0.35 : 1)
                    .accessibilityLabel("Previous photo")

                    Spacer()

                    Text("\(displayIndex) of \(items.count)")
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.metadata)

                    Spacer()

                    Button {
                        guard items.count > 1 else { return }
                        selectedIndex = selectedIndex == items.count ? 1 : selectedIndex + 1
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(ArchiveTypography.icon)
                            .foregroundStyle(ArchiveTheme.ink)
                            .frame(width: ArchiveShape.actionDiameter, height: ArchiveShape.actionDiameter)
                            .background(ArchiveTheme.actionBackground)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(items.count < 2)
                    .opacity(items.count < 2 ? 0.35 : 1)
                    .accessibilityLabel("Next photo")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(ArchiveTheme.background)
            }
            .background(ArchiveTheme.background)
        }
        .foregroundStyle(ArchiveTheme.ink)
        .background(ArchiveTheme.background)
        .sheet(isPresented: $showingMediaEditor) {
            if let currentItem, let repository {
                MediaMetadataEditor(item: currentItem, ownerID: personID, repository: repository)
            }
        }
        .confirmationDialog(
            ArchiveCopy.text(english: "Remove this image?", russian: "Удалить это изображение?"),
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(ArchiveCopy.text(english: "Remove image", russian: "Удалить изображение"), role: .destructive) {
                guard let currentItem, let repository, repository.canEdit else { return }
                repository.removeMedia(currentItem, from: personID)
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

    private var mediaTopBar: some View {
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
            .accessibilityLabel(ArchiveCopy.text(english: "Close media", russian: "Закрыть медиа"))

            Spacer()

            Text(ArchiveCopy.text(english: "Media", russian: "Медиа"))
                .font(ArchiveTypography.navigationTitle)
                .lineLimit(1)

            Spacer()

            if let repository, repository.canEdit {
                Menu {
                    Button {
                        showingMediaEditor = true
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
                        .font(ArchiveTypography.icon)
                        .foregroundStyle(ArchiveTheme.ink)
                        .frame(width: ArchiveShape.actionDiameter, height: ArchiveShape.actionDiameter)
                        .background(ArchiveTheme.actionBackground)
                        .clipShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel(ArchiveCopy.text(english: "Media actions", russian: "Действия с медиа"))
            } else {
                Color.clear
                    .frame(width: ArchiveShape.actionDiameter, height: ArchiveShape.actionDiameter)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}

private struct PersonMediaDetailContent: View {
    let personID: Person.ID
    let item: MediaReference
    let isActive: Bool
    let repository: FamilyRepository?

    @State private var showingMediaEditor = false
    @State private var showingRemoveConfirmation = false

    init(personID: Person.ID, item: MediaReference, isActive: Bool = true, repository: FamilyRepository? = nil) {
        self.personID = personID
        self.item = item
        self.isActive = isActive
        self.repository = repository
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PersonMediaLargeVisual(item: item, isActive: isActive)

                let caption = NarrativeLocalizationStore.shared.mediaCaption(mediaID: item.id, source: item.caption ?? "")
                if !caption.isEmpty {
                    Text(MediaMentionToken.visibleText(
                        caption,
                        people: repository?.people ?? []
                    ))
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.metadata)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let repository, repository.canEdit {
                    HStack(spacing: 18) {
                        Button {
                            showingMediaEditor = true
                        } label: {
                            Text(ArchiveCopy.text(english: "Edit caption", russian: "Изменить подпись"))
                                .font(ArchiveTypography.action)
                                .foregroundStyle(ArchiveTheme.action)
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            showingRemoveConfirmation = true
                        } label: {
                            Label(
                                ArchiveCopy.text(english: "Remove image", russian: "Удалить изображение"),
                                systemImage: "trash"
                            )
                            .font(ArchiveTypography.action)
                            .foregroundStyle(ArchiveTheme.action)
                        }
                        .buttonStyle(.plain)
                    }
                }

            }
            .padding(.horizontal, ArchiveLayout.pageHorizontal)
            .padding(.top, ArchiveLayout.pageTop)
            .padding(.bottom, ArchiveLayout.pageBottom)
        }
        .background(ArchiveTheme.background)
        .sheet(isPresented: $showingMediaEditor) {
            if let repository {
                MediaMetadataEditor(item: item, ownerID: personID, repository: repository)
            }
        }
        .confirmationDialog(
            ArchiveCopy.text(english: "Remove this image?", russian: "Удалить это изображение?"),
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(ArchiveCopy.text(english: "Remove image", russian: "Удалить изображение"), role: .destructive) {
                guard let repository, repository.canEdit else { return }
                repository.removeMedia(item, from: personID)
            }
            Button(ArchiveCopy.text(english: "Cancel", russian: "Отмена"), role: .cancel) { }
        } message: {
            Text(ArchiveCopy.text(
                english: "This permanently removes the image from the app’s private normalized store and linked profiles. The original archive is not changed.",
                russian: "Изображение будет навсегда удалено из приватного нормализованного хранилища приложения и связанных профилей. Исходный архив не изменится."
            ))
        }
    }
}

private struct PersonMediaLargeVisual: View {
    let item: MediaReference
    let isActive: Bool
    @StateObject private var imageLoader = ArchiveImageLoader()

    init(item: MediaReference, isActive: Bool = true) {
        self.item = item
        self.isActive = isActive
    }

    var body: some View {
        Group {
            if let image = imageLoader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .background(ArchiveTheme.ink.opacity(0.05))
            } else {
                ZStack {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [ArchiveTheme.accent, ArchiveTheme.accentLight],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: item.kind.systemImage)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
            }
        }
        .task(id: "\(item.path ?? "")|\(isActive)") {
            guard isActive else { return }
            imageLoader.load(
                path: item.kind == .photo ? item.path : nil,
                // The viewer is screen-sized; decoding a multi-thousand-pixel
                // original adds latency without improving the on-device view.
                maxPixelSize: 1400
            )
        }
    }
}

private struct GalleryMetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(ArchiveTypography.metadataEmphasis)
                .foregroundStyle(ArchiveTheme.metadata)
            Text(value)
                .font(ArchiveTypography.metadata)
                .foregroundStyle(ArchiveTheme.ink)
        }
    }
}

private struct MediaTile: View {
    let item: MediaReference
    let people: [Person]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [ArchiveTheme.accent, ArchiveTheme.accentLight],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Image(systemName: item.kind.systemImage)
                    .font(ArchiveTypography.bodyEmphasis)
                    .foregroundStyle(.white)
                    .padding(12)
            }
            .frame(height: 106)

            Text(item.title)
                .font(ArchiveTypography.supportingEmphasis)
                .lineLimit(2)

            if let caption = item.caption, !caption.isEmpty {
                Text(MediaMentionToken.visibleText(caption, people: people))
                    .font(ArchiveTypography.metadata)
                    .foregroundStyle(ArchiveTheme.metadata)
                    .lineLimit(2)
            }

            if let collection = item.collection, !collection.isEmpty {
                Text(collection)
                    .font(ArchiveTypography.metadata)
                    .foregroundStyle(ArchiveTheme.metadata)
                    .lineLimit(1)
            }

            if let tags = item.tags, !tags.isEmpty {
                Text(tags.map { "#\($0)" }.joined(separator: "  "))
                    .font(ArchiveTypography.metadata)
                    .foregroundStyle(ArchiveTheme.metadata)
                    .lineLimit(1)
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 14)
    }
}

private struct SourceRow: View {
    let source: SourceReference

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(source.title ?? source.kind)
                .font(ArchiveTypography.supportingEmphasis)
            Text(source.locator)
                .font(ArchiveTypography.metadata)
                .foregroundStyle(ArchiveTheme.metadata)
                .textSelection(.enabled)
            if let notes = source.notes, !notes.isEmpty {
                Text(notes)
                    .font(ArchiveTypography.metadata)
                    .foregroundStyle(ArchiveTheme.metadata)
            }
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct MediaStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(ArchiveTypography.supportingEmphasis)
            Text(label)
                .font(ArchiveTypography.metadata)
                    .foregroundStyle(ArchiveTheme.metadata)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }
}

// MARK: - Private editors

private struct ProfileEditorField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(ArchiveTypography.metadataEmphasis)
                    .foregroundStyle(ArchiveTheme.muted)

                TextField("", text: $text, axis: .vertical)
                    .font(ArchiveTypography.body)
                    .foregroundStyle(ArchiveTheme.ink)
                    .lineLimit(1...4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 5)
        }
    }
}

private struct ProfileEditorView: View {
    private struct EditorValues {
        var givenName: String
        var familyName: String
    }

    let repository: FamilyRepository
    let initialPerson: Person
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Person
    @State private var editedGivenName: String
    @State private var editedFamilyName: String
    @State private var languageError: String?
    @State private var showingLanguageReviewConfirmation = false
    @State private var valuesByLanguage: [ArchiveLanguage: EditorValues] = [:]

    init(person: Person, repository: FamilyRepository) {
        self.repository = repository
        self.initialPerson = person
        _draft = State(initialValue: person)
        let displayParts = person.displayName.split(separator: " ", maxSplits: 1).map(String.init)
        _editedGivenName = State(initialValue: displayParts.first ?? person.givenName)
        _editedFamilyName = State(initialValue: displayParts.count > 1 ? displayParts[1] : person.familyName)
        _languageError = State(initialValue: nil)
    }

    private func copy(_ english: String, _ russian: String) -> String {
        repository.appLanguage == .russian ? russian : english
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                editorTopBar

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        editorSection(copy("PROFILE", "ПРОФИЛЬ")) {
                            ProfileEditorField(label: copy("First name", "Имя"), text: $editedGivenName)
                            ProfileEditorField(label: copy("Last name", "Фамилия"), text: $editedFamilyName)
                        }
                    }
                    .padding(.horizontal, ArchiveLayout.pageHorizontal)
                    .padding(.top, 12)
                    .padding(.bottom, ArchiveLayout.pageBottom)
                }
                .scrollIndicators(.hidden)
            }
            .background(ArchiveTheme.background)
            .toolbar(.hidden, for: .navigationBar)
            .alert(copy("Language check", "Проверка языка"), isPresented: Binding(
                get: { languageError != nil },
                set: { if !$0 { languageError = nil } }
            )) {
                Button(copy("OK", "Хорошо")) { languageError = nil }
            } message: {
                Text(languageError ?? "")
            }
            .alert(copy("Check other language", "Проверьте другой язык"), isPresented: $showingLanguageReviewConfirmation) {
                Button(copy("Review other language", "Проверить другой язык")) {
                    switchEditorLanguage()
                }
                Button(copy("I checked — save", "Я проверил(а) — сохранить")) {
                    persistSave(counterpart: suggestedCounterpartForCurrentName())
                }
                Button(copy("Cancel", "Отмена"), role: .cancel) { }
            } message: {
                Text(copy(
                    "Please review the other language before saving this change.",
                    "Перед сохранением проверьте изменения на другом языке."
                ))
            }
        }
    }

    private var editorTopBar: some View {
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
            .accessibilityLabel(copy("Cancel", "Отмена"))

            Spacer()

            HStack(spacing: 7) {
                Text(copy("Edit profile", "Изменить профиль"))
                    .font(ArchiveTypography.navigationTitle)
                    .foregroundStyle(ArchiveTheme.ink)
                    .lineLimit(1)

                Button {
                    switchEditorLanguage()
                } label: {
                    Text(repository.appLanguage == .english ? "EN" : "RU")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(ArchiveTheme.ink)
                        .background(ArchiveTheme.actionBackground)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(repository.appLanguage == .english
                    ? "Switch edit language to Russian"
                    : "Переключить язык редактирования на английский")
            }

            Spacer()

            Button {
                save()
            } label: {
                Image(systemName: "checkmark")
                    .font(ArchiveTypography.icon)
                    .foregroundStyle(ArchiveTheme.ink)
                    .frame(width: ArchiveShape.actionDiameter, height: ArchiveShape.actionDiameter)
                    .background(ArchiveTheme.actionBackground)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copy("Save", "Сохранить"))
        }
        .padding(.horizontal, ArchiveLayout.pageHorizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(ArchiveTheme.background)
    }

    private func switchEditorLanguage() {
        if let issue = currentLanguageIssue() {
            languageError = issue
            return
        }

        let currentLanguage = repository.appLanguage
        valuesByLanguage[currentLanguage] = EditorValues(
            givenName: editedGivenName,
            familyName: editedFamilyName
        )

        if hasEditorChanges {
            persistSave(counterpart: suggestedCounterpartForCurrentName(), dismissAfterSave: false)
        }

        let nextLanguage: ArchiveLanguage = currentLanguage == .english ? .russian : .english
        repository.appLanguage = nextLanguage

        if let values = valuesByLanguage[nextLanguage] {
            apply(values)
        } else {
            applyValues(for: nextLanguage)
        }
    }

    private func apply(_ values: EditorValues) {
        editedGivenName = values.givenName
        editedFamilyName = values.familyName
    }

    private func applyValues(for language: ArchiveLanguage) {
        let localizedName = NameLocalizationStore.shared.displayName(
            for: initialPerson.id,
            fallback: draft.sourceDisplayName,
            language: language
        )
        let displayParts = localizedName.split(separator: " ", maxSplits: 1).map(String.init)
        editedGivenName = displayParts.first ?? draft.givenName
        editedFamilyName = displayParts.count > 1 ? displayParts[1] : draft.familyName
    }

    @ViewBuilder
    private func editorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(ArchiveTypography.sectionTitle)
                .tracking(1.2)
                .foregroundStyle(ArchiveTheme.ink)

            VStack(alignment: .leading, spacing: 6) {
                content()
            }
        }
    }

    private func save() {
        if let issue = currentLanguageIssue() {
            languageError = issue
            return
        }

        if hasEditorChanges {
            showingLanguageReviewConfirmation = true
            return
        }

        persistSave(counterpart: nil)
    }

    private var hasEditorChanges: Bool {
        let localizedName = NameLocalizationStore.shared.displayName(
            for: initialPerson.id,
            fallback: draft.sourceDisplayName,
            language: repository.appLanguage
        )
        let originalDisplayParts = localizedName.split(separator: " ", maxSplits: 1).map(String.init)
        let originalGivenName = originalDisplayParts.first ?? draft.givenName
        let originalFamilyName = originalDisplayParts.count > 1 ? originalDisplayParts[1] : draft.familyName

        return editedGivenName.trimmed != originalGivenName.trimmed ||
            editedFamilyName.trimmed != originalFamilyName.trimmed
    }

    private func currentLanguageIssue() -> String? {
        let originalDisplayParts = initialPerson.displayName.split(separator: " ", maxSplits: 1).map(String.init)
        let originalFields: [String: String] = [
            "First name": originalDisplayParts.first ?? initialPerson.givenName,
            "Last name": originalDisplayParts.count > 1 ? originalDisplayParts[1] : draft.familyName
        ]
        if let issue = ArchiveLanguageValidator.issue(
            language: repository.appLanguage,
            fields: [
                ("First name", editedGivenName),
                ("Last name", editedFamilyName)
            ],
            unchanged: originalFields
        ) {
            return issue
        }
        return nil
    }

    private func suggestedCounterpartForCurrentName() -> String? {
        let localizedName = [editedGivenName.trimmed, editedFamilyName.trimmed]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let suggestedCounterpart = NameLocalizationStore.shared.suggestedCounterpart(
            for: localizedName,
            language: repository.appLanguage
        )
        return suggestedCounterpart.isEmpty ? nil : suggestedCounterpart
    }

    private func persistSave(counterpart: String?, dismissAfterSave: Bool = true) {
        var updated = draft
        if repository.appLanguage == .russian {
            // Russian is the source/original locale in the private archive.
            updated.givenName = editedGivenName.trimmed
            updated.familyName = editedFamilyName.trimmed
        }
        let localizedName = [editedGivenName.trimmed, editedFamilyName.trimmed]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        do {
            try NameLocalizationStore.shared.update(
                personID: initialPerson.id,
                original: updated.sourceDisplayName,
                localizedName: localizedName,
                language: repository.appLanguage,
                counterpart: counterpart
            )
        } catch {
            languageError = copy(
                "The name could not be saved to the private name data.",
                "Не удалось сохранить имя в личных данных."
            )
            return
        }
        repository.updatePerson(updated)
        draft = updated
        if dismissAfterSave {
            dismiss()
        }
    }
}

private struct ProfilePhotoChoiceRow: View {
    let paths: [String]
    let onSelect: (String) -> Void
    @Binding var selectedPath: String
    @Binding var scale: Double
    @Binding var offsetX: Double
    @Binding var offsetY: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ArchiveCopy.text(english: "Choose an image", russian: "Выберите изображение"))
                .font(ArchiveTypography.supportingEmphasis)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    Button {
                        selectedPath = ""
                        resetAdjustment()
                    } label: {
                        Rectangle()
                            .fill(ArchiveTheme.controlBackground)
                            .overlay(Image(systemName: "person.crop.circle")
                                .font(.system(size: 24))
                                .foregroundStyle(ArchiveTheme.metadata))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(Rectangle().stroke(selectedPath.isEmpty ? ArchiveTheme.accent : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use initials")

                    ForEach(paths, id: \.self) { path in
                        Button {
                            selectedPath = path
                            resetAdjustment()
                            onSelect(path)
                        } label: {
                            Group {
                                if let image = ArchiveFileResolver.image(for: path) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    Rectangle()
                                        .fill(ArchiveTheme.controlBackground)
                                        .overlay(Image(systemName: "photo"))
                                }
                            }
                            .aspectRatio(1, contentMode: .fit)
                            .clipped()
                            .overlay(Rectangle().stroke(selectedPath == path ? ArchiveTheme.accent : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Photo")
                    }
            }

            if paths.isEmpty {
                Text(ArchiveCopy.text(
                    english: "No photo media is available for this profile yet.",
                    russian: "Для этого профиля пока нет фотографий."
                ))
                    .font(ArchiveTypography.metadata)
                    .foregroundStyle(ArchiveTheme.metadata)
            }
        }
    }

    private func resetAdjustment() {
        scale = 1
        offsetX = 0
        offsetY = 0
    }
}

private struct ProfilePhotoAdjustmentView: View {
    let path: String
    var previewSize: CGFloat = 220
    @Binding var scale: Double
    @Binding var offsetX: Double
    @Binding var offsetY: Double

    @State private var dragOrigin: CGSize = .zero
    @State private var magnificationOrigin: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ArchiveCopy.text(english: "Adjust display", russian: "Настройте отображение"))
                .font(ArchiveTypography.supportingEmphasis)

            ZStack {
                Rectangle()
                    .fill(ArchiveTheme.ink.opacity(0.08))

                if let image = ArchiveFileResolver.image(for: path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: previewSize, height: previewSize)
                        .scaleEffect(scale)
                        .offset(x: offsetX, y: offsetY)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 30))
                        .foregroundStyle(ArchiveTheme.metadata)
                }
            }
            .frame(width: previewSize, height: previewSize)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        offsetX = dragOrigin.width + value.translation.width
                        offsetY = dragOrigin.height + value.translation.height
                    }
                    .onEnded { _ in
                        dragOrigin = CGSize(width: offsetX, height: offsetY)
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = min(max(magnificationOrigin * value, 1), 3)
                    }
                    .onEnded { _ in
                        magnificationOrigin = scale
                    }
            )

            Slider(value: $scale, in: 1...3, step: 0.05) {
                Text(ArchiveCopy.text(english: "Zoom", russian: "Масштаб"))
            }

            HStack {
                Text(ArchiveCopy.text(
                    english: "Drag to reposition · pinch or use the slider to zoom",
                    russian: "Перетаскивайте изображение · масштабируйте жестом или ползунком"
                ))
                    .font(ArchiveTypography.metadata)
                    .foregroundStyle(ArchiveTheme.metadata)
                Spacer()
                Button(ArchiveCopy.text(english: "Reset", russian: "Сбросить")) {
                    scale = 1
                    offsetX = 0
                    offsetY = 0
                    dragOrigin = .zero
                    magnificationOrigin = 1
                }
                .font(ArchiveTypography.action)
                .foregroundStyle(ArchiveTheme.action)
            }
        }
    }
}

private struct ProfilePhotoAdjustmentScreen: View {
    let path: String
    let onSave: () -> Void
    let onCancel: () -> Void
    let onChooseDifferent: () -> Void
    @Binding var scale: Double
    @Binding var offsetX: Double
    @Binding var offsetY: Double
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                ProfilePhotoAdjustmentView(
                    path: path,
                    previewSize: 300,
                    scale: $scale,
                    offsetX: $offsetX,
                    offsetY: $offsetY
                )
                .padding(20)

                Button {
                    onChooseDifferent()
                } label: {
                    HStack {
                        Image(systemName: "photo.on.rectangle")
                        Text(ArchiveCopy.text(
                            english: "Choose a different image",
                            russian: "Выбрать другое изображение"
                        ))
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .font(ArchiveTypography.action)
                    .foregroundStyle(ArchiveTheme.action)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
                .buttonStyle(.plain)
            }
            .background(ArchiveTheme.background)
            .navigationTitle(ArchiveCopy.text(english: "Adjust image", russian: "Настроить изображение"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onCancel()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(ArchiveTypography.icon)
                    }
                    .accessibilityLabel(ArchiveCopy.text(english: "Cancel", russian: "Отмена"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSave()
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(ArchiveTypography.icon)
                    }
                    .accessibilityLabel(ArchiveCopy.text(english: "Save", russian: "Сохранить"))
                }
            }
        }
    }
}

private struct ProfilePhotoSelectionView: View {
    let initialPerson: Person
    @ObservedObject var repository: FamilyRepository
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPath: String
    @State private var scale: Double
    @State private var offsetX: Double
    @State private var offsetY: Double
    @State private var selectedPhotoForAdjustment: MediaReference?
    @State private var returnToAdjustmentPhoto: MediaReference?

    init(person: Person, repository: FamilyRepository) {
        initialPerson = person
        _repository = ObservedObject(wrappedValue: repository)
        _selectedPath = State(initialValue: person.profileImagePath ?? "")
        _scale = State(initialValue: person.profileImageScale ?? 1)
        _offsetX = State(initialValue: person.profileImageOffsetX ?? 0)
        _offsetY = State(initialValue: person.profileImageOffsetY ?? 0)

        let currentPath = person.profileImagePath?.trimmed ?? ""
        let existing = repository.media(for: person.id).first {
            $0.kind == .photo && $0.path?.trimmed == currentPath
        }
        if !currentPath.isEmpty, let existing {
            _selectedPhotoForAdjustment = State(initialValue: existing)
            _returnToAdjustmentPhoto = State(initialValue: existing)
        } else {
            // If there is exactly one available photo, there is no useful
            // choice to make: open it directly in the adjustment screen.
            // Multiple photos still open the chooser as before.
            let onlyPhoto = repository.media(for: person.id)
                .first { $0.kind == .photo && $0.path?.trimmed.isEmpty == false }
            let photoCount = repository.media(for: person.id)
                .filter { $0.kind == .photo && $0.path?.trimmed.isEmpty == false }
                .count
            if photoCount == 1, let onlyPhoto, let path = onlyPhoto.path?.trimmed {
                _selectedPath = State(initialValue: path)
                _selectedPhotoForAdjustment = State(initialValue: onlyPhoto)
                _returnToAdjustmentPhoto = State(initialValue: onlyPhoto)
            } else {
                _selectedPhotoForAdjustment = State(initialValue: nil)
                _returnToAdjustmentPhoto = State(initialValue: nil)
            }
        }
    }

    private var person: Person { repository.person(id: initialPerson.id) ?? initialPerson }

    private var photoOptions: [MediaReference] {
        repository.media(for: person.id)
            .filter { $0.kind == .photo }
            .filter { $0.path?.trimmed.isEmpty == false }
    }

    var body: some View {
        Group {
            if let item = selectedPhotoForAdjustment {
                ProfilePhotoAdjustmentScreen(
                    path: item.path?.trimmed ?? selectedPath,
                    onSave: {
                        save()
                    },
                    onCancel: {
                    },
                    onChooseDifferent: {
                        returnToAdjustmentPhoto = selectedPhotoForAdjustment
                        selectedPhotoForAdjustment = nil
                    },
                    scale: $scale,
                    offsetX: $offsetX,
                    offsetY: $offsetY
                )
            } else {
                PersonMediaGalleryView(
                    person: person,
                    items: photoOptions,
                    selectionMode: true,
                    onSelect: { item in
                        selectedPath = item.path?.trimmed ?? ""
                        scale = 1
                        offsetX = 0
                        offsetY = 0
                        returnToAdjustmentPhoto = item
                        selectedPhotoForAdjustment = item
                    },
                    onCancel: {
                        if let returnToAdjustmentPhoto {
                            selectedPhotoForAdjustment = returnToAdjustmentPhoto
                        } else {
                            dismiss()
                        }
                    }
                )
            }
        }
    }

    private func save() {
        // Keep the currently displayed photo path when only the crop/zoom was
        // changed. This also covers the synthetic adjustment item used for an
        // existing profile photo.
        let path = selectedPath.trimmed.isEmpty
            ? (selectedPhotoForAdjustment?.path?.trimmed ?? person.profileImagePath?.trimmed ?? "")
            : selectedPath.trimmed
        guard !path.isEmpty,
              repository.media(for: person.id).contains(where: { $0.kind == .photo && $0.path?.trimmed == path }) else {
            return
        }

        var updated = person
        updated.profileImagePath = path
        updated.profileImageScale = min(max(scale, 1), 3)
        updated.profileImageOffsetX = offsetX
        updated.profileImageOffsetY = offsetY
        selectedPath = path
        repository.updatePerson(updated)
    }
}

private struct LifeEventsManagerView: View {
    private let initialPerson: Person
    private let personID: Person.ID
    @ObservedObject var repository: FamilyRepository
    @Environment(\.dismiss) private var dismiss
    @State private var addingEvent = false
    @State private var editingEvent: ManagedLifeEvent?

    init(person: Person, repository: FamilyRepository) {
        initialPerson = person
        personID = person.id
        _repository = ObservedObject(wrappedValue: repository)
    }

    private var person: Person { repository.person(id: personID) ?? initialPerson }
    private var managedEvents: [ManagedLifeEvent] { repository.managedEvents(for: personID) }

    private func copy(_ english: String, _ russian: String) -> String {
        repository.appLanguage == .russian ? russian : english
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                managerTopBar

                HStack(alignment: .firstTextBaseline) {
                    Text(copy("LIFE EVENTS", "СОБЫТИЯ ЖИЗНИ"))
                        .font(ArchiveTypography.sectionTitle)
                        .tracking(1.2)
                        .foregroundStyle(ArchiveTheme.ink)
                    Spacer()
                    Text(eventCountText)
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.metadata)
                }
                .padding(.horizontal, ArchiveLayout.pageHorizontal)
                .padding(.top, 14)
                .padding(.bottom, 6)

                if managedEvents.isEmpty {
                    emptyState
                } else {
                    eventsList
                }
            }
            .foregroundStyle(ArchiveTheme.ink)
            .background(ArchiveTheme.background)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $addingEvent) {
                EventEditorView(event: nil, language: repository.appLanguage) { event in
                    save(event)
                }
            }
            .sheet(item: $editingEvent) { event in
                EventEditorView(event: event.event, language: repository.appLanguage) { updatedEvent in
                    save(updatedEvent, scope: event.scope)
                    editingEvent = nil
                }
            }
        }
    }

    private var managerTopBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(ArchiveTypography.icon)
                    .foregroundStyle(ArchiveTheme.ink)
                    .frame(width: ArchiveShape.actionDiameter, height: ArchiveShape.actionDiameter)
                    .background(ArchiveTheme.actionBackground)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copy("Close", "Закрыть"))

            Spacer()

            VStack(spacing: 1) {
                Text(copy("Manage events", "Управление событиями"))
                    .font(ArchiveTypography.navigationTitle)
                    .foregroundStyle(ArchiveTheme.ink)
                    .lineLimit(1)
                Text(person.displayName)
                    .font(ArchiveTypography.metadata)
                    .foregroundStyle(ArchiveTheme.metadata)
                    .lineLimit(1)
            }

            Spacer()

            if repository.canEdit {
                Button { addingEvent = true } label: {
                    Image(systemName: "plus")
                        .font(ArchiveTypography.icon)
                        .foregroundStyle(ArchiveTheme.ink)
                        .frame(width: ArchiveShape.actionDiameter, height: ArchiveShape.actionDiameter)
                        .background(ArchiveTheme.actionBackground)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copy("Add life event", "Добавить событие"))
            } else {
                Color.clear
                    .frame(width: ArchiveShape.actionDiameter, height: ArchiveShape.actionDiameter)
            }
        }
        .padding(.horizontal, ArchiveLayout.pageHorizontal)
        .padding(.vertical, 8)
        .background(ArchiveTheme.background)
    }

    private var eventsList: some View {
        List {
            ForEach(managedEvents) { managedEvent in
                Button { editingEvent = managedEvent } label: {
                    LifeEventManagerRow(personID: person.id, event: managedEvent.event)
                }
                .buttonStyle(.plain)
                .disabled(!repository.canEdit)
                .listRowInsets(EdgeInsets(top: 6, leading: ArchiveLayout.pageHorizontal, bottom: 6, trailing: ArchiveLayout.pageHorizontal))
                .listRowSeparator(.hidden)
                .listRowBackground(ArchiveTheme.background)
                .swipeActions {
                    if repository.canEdit {
                        Button(role: .destructive) { delete(managedEvent) } label: {
                            Label(copy("Delete", "Удалить"), systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .background(ArchiveTheme.background)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(ArchiveTheme.accent)
                    .frame(width: 56, height: 56)
                    .background(ArchiveTheme.background)
                    .clipShape(Circle())

                VStack(spacing: 5) {
                    Text(copy("No life events yet", "Событий пока нет"))
                        .font(ArchiveTypography.contentTitle)
                        .foregroundStyle(ArchiveTheme.ink)
                    Text(copy(
                        "Add a date, place, and story to begin this timeline.",
                        "Добавьте дату, место и описание, чтобы начать хронологию."
                    ))
                    .font(ArchiveTypography.body)
                    .foregroundStyle(ArchiveTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if repository.canEdit {
                    Button { addingEvent = true } label: {
                        Label(copy("Add event", "Добавить событие"), systemImage: "plus")
                            .font(ArchiveTypography.action)
                            .foregroundStyle(ArchiveTheme.background)
                            .padding(.horizontal, 18)
                            .frame(height: 42)
                            .background(ArchiveTheme.accent)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 36)
            .background(ArchiveTheme.actionBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, ArchiveLayout.pageHorizontal)
            .padding(.top, 12)

            Spacer()
        }
    }

    private var eventCountText: String {
        let count = managedEvents.count
        guard repository.appLanguage == .russian else {
            return count == 1 ? "1 event" : "\(count) events"
        }
        let lastTwo = count % 100
        let last = count % 10
        let noun: String
        if (11...14).contains(lastTwo) {
            noun = "событий"
        } else if last == 1 {
            noun = "событие"
        } else if (2...4).contains(last) {
            noun = "события"
        } else {
            noun = "событий"
        }
        return "\(count) \(noun)"
    }

    private func delete(_ managedEvent: ManagedLifeEvent) {
        guard repository.canEdit else { return }
        if case .familyUnion(let unionID, let recordID) = managedEvent.scope {
            repository.deleteSharedEvent(unionID: unionID, recordID: recordID, editorID: personID)
            return
        }
        var updated = person
        updated.events?.removeAll { $0.id == managedEvent.event.id }
        repository.updatePerson(updated)
    }

    private func save(_ event: LifeEvent, scope: ManagedLifeEvent.Scope = .person) {
        guard repository.canEdit else { return }
        if case .familyUnion(let unionID, let recordID) = scope {
            repository.updateSharedEvent(event, unionID: unionID, recordID: recordID, editorID: personID)
            return
        }
        var updated = person
        var events = updated.events ?? []

        // Birth and death are single canonical events. Saving either replaces
        // another record of the same kind instead of creating a second copy.
        if let coreCategory = event.coreCategory {
            events.removeAll { $0.id != event.id && $0.coreCategory == coreCategory }
        }
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            events[index] = event
        } else {
            events.append(event)
        }
        updated.events = events
        repository.updatePerson(updated)
    }
}

private struct LifeEventManagerRow: View {
    let personID: Person.ID
    let event: LifeEvent

    private var category: LifeEventCategory {
        LifeEventCategory.category(for: event.category) ?? event.coreCategory ?? .life
    }

    private var title: String {
        let localized = NarrativeLocalizationStore.shared.eventTitle(
            personID,
            eventID: event.id,
            source: event.localizedTitle
        )
        return localized.isEmpty
            ? ArchiveCopy.text(english: "Untitled event", russian: "Событие без названия")
            : localized
    }

    private var summary: String {
        NarrativeLocalizationStore.shared.eventSummary(
            personID,
            eventID: event.id,
            source: event.localizedSummary
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            LifeEventCategoryIcon(category: category, size: 16)
                .foregroundStyle(ArchiveTheme.accent)
                .frame(width: 38, height: 38)
                .background(ArchiveTheme.background)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(category.localizedLabel.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(ArchiveTheme.accent)

                Text(title)
                    .font(ArchiveTypography.contentTitle)
                    .foregroundStyle(ArchiveTheme.ink)
                    .multilineTextAlignment(.leading)

                VStack(alignment: .leading, spacing: 4) {
                    if !event.date.trimmed.isEmpty {
                        Label(ArchiveDateFormatter.displayRange(event.date) ?? event.date, systemImage: "calendar")
                    }
                    if let place = event.place?.trimmed, !place.isEmpty {
                        Label(place, systemImage: "mappin.and.ellipse")
                    }
                }
                .font(ArchiveTypography.metadata)
                .foregroundStyle(ArchiveTheme.metadata)
                .lineLimit(2)

                if !summary.isEmpty {
                    Text(summary)
                        .font(ArchiveTypography.body)
                        .foregroundStyle(ArchiveTheme.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ArchiveTheme.metadata)
                .padding(.top, 13)
        }
        .padding(14)
        .background(ArchiveTheme.actionBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private extension LifeEventCategory {
    var archiveIcon: String {
        switch self {
        case .birth: "sparkles"
        case .death: "leaf"
        case .marriage: "heart"
        case .partnership: "person.2"
        case .family: "person.3"
        case .health: "cross.case"
        case .residence: "house"
        case .education: "graduationcap"
        case .career: "briefcase"
        case .military: "shield"
        case .migration: "arrow.right"
        case .burial: "cross"
        case .life: "ellipsis"
        }
    }
}

private struct LifeEventCategoryIcon: View {
    let category: LifeEventCategory
    let size: CGFloat

    var body: some View {
        if category == .burial {
            GraveMarkerShape()
                .fill(.foreground)
                .frame(width: size * 0.9, height: size)
        } else {
            Image(systemName: category.archiveIcon)
                .font(.system(size: size, weight: .semibold))
        }
    }
}

private struct GraveMarkerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let stemWidth = rect.width * 0.19
        let stemX = rect.midX - stemWidth / 2
        path.addRoundedRect(
            in: CGRect(x: stemX, y: rect.minY, width: stemWidth, height: rect.height * 0.84),
            cornerSize: CGSize(width: stemWidth / 2, height: stemWidth / 2)
        )

        let armHeight = rect.height * 0.17
        path.addRoundedRect(
            in: CGRect(
                x: rect.minX + rect.width * 0.14,
                y: rect.minY + rect.height * 0.24,
                width: rect.width * 0.72,
                height: armHeight
            ),
            cornerSize: CGSize(width: armHeight / 2, height: armHeight / 2)
        )

        let groundHeight = rect.height * 0.11
        path.addRoundedRect(
            in: CGRect(
                x: rect.minX + rect.width * 0.05,
                y: rect.maxY - groundHeight,
                width: rect.width * 0.9,
                height: groundHeight
            ),
            cornerSize: CGSize(width: groundHeight / 2, height: groundHeight / 2)
        )
        return path
    }
}

private struct StoriesManagerView: View {
    private let initialPerson: Person
    private let personID: Person.ID
    @ObservedObject var repository: FamilyRepository
    @Environment(\.dismiss) private var dismiss
    @State private var addingStory = false
    @State private var editingStory: StoryChapter?

    init(person: Person, repository: FamilyRepository) {
        initialPerson = person
        personID = person.id
        _repository = ObservedObject(wrappedValue: repository)
    }

    private var person: Person { repository.person(id: personID) ?? initialPerson }

    var body: some View {
        NavigationStack {
            List {
                if person.structuredStories.isEmpty {
                    Text("No stories yet.")
                        .foregroundStyle(ArchiveTheme.metadata)
                } else {
                    ForEach(person.structuredStories) { story in
                        Button { editingStory = story } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(story.title.isEmpty ? "Untitled story" : NarrativeLocalizationStore.shared.storyTitle(person.id, storyID: story.id, source: story.title))
                                        .font(ArchiveTypography.contentTitle)
                                        .foregroundStyle(ArchiveTheme.ink)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(ArchiveTypography.metadata)
                                        .foregroundStyle(ArchiveTheme.metadata)
                                }
                                if let dateRange = story.dateRange, !dateRange.isEmpty {
                                    Text(ArchiveDateFormatter.displayRange(dateRange) ?? dateRange)
                                        .font(ArchiveTypography.metadata)
                                        .foregroundStyle(ArchiveTheme.metadata)
                                }
                                Text(NarrativeLocalizationStore.shared.storySummary(person.id, storyID: story.id, source: story.summary ?? story.body))
                                    .font(ArchiveTypography.metadata)
                                    .foregroundStyle(ArchiveTheme.muted)
                                    .lineLimit(2)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!repository.canEdit)
                        .swipeActions {
                            if repository.canEdit {
                                Button(role: .destructive) { delete(story) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Stories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if repository.canEdit {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            addingStory = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add story")
                    }
                }
            }
            .sheet(isPresented: $addingStory) {
                StoryEditorView(story: nil, language: repository.appLanguage) { story in
                    var updated = person
                    updated.storyChapters = (updated.storyChapters ?? []) + [story]
                    repository.updatePerson(updated)
                }
            }
            .sheet(item: $editingStory) { story in
                StoryEditorView(story: story, language: repository.appLanguage) { updatedStory in
                    var updated = person
                    var stories = updated.storyChapters ?? []
                    if let index = stories.firstIndex(where: { $0.id == updatedStory.id }) {
                        stories[index] = updatedStory
                    }
                    updated.storyChapters = stories
                    repository.updatePerson(updated)
                    editingStory = nil
                }
            }
        }
    }

    private func delete(_ story: StoryChapter) {
        guard repository.canEdit else { return }
        var updated = person
        updated.storyChapters?.removeAll { $0.id == story.id }
        repository.updatePerson(updated)
    }
}

private struct EventEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LifeEvent
    @State private var languageError: String?
    @State private var showingCategoryPicker = false
    private let isNewEvent: Bool
    let language: ArchiveLanguage
    let onSave: (LifeEvent) -> Void

    init(event: LifeEvent?, language: ArchiveLanguage, onSave: @escaping (LifeEvent) -> Void) {
        isNewEvent = event == nil
        self.language = language
        self.onSave = onSave
        _draft = State(initialValue: event ?? LifeEvent(
            id: UUID().uuidString,
            date: "",
            sortKey: nil,
            title: "",
            summary: "",
            place: nil,
            category: LifeEventCategory.life.rawValue,
            isApproximate: nil,
            sourceIDs: nil
        ))
        _languageError = State(initialValue: nil)
    }

    private func copy(_ english: String, _ russian: String) -> String {
        language == .russian ? russian : english
    }

    private var selectedCategory: LifeEventCategory {
        LifeEventCategory.category(for: draft.category) ?? draft.coreCategory ?? .life
    }

    private var canSave: Bool {
        !draft.title.trimmed.isEmpty || !draft.summary.trimmed.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                editorTopBar

                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        editorSection(copy("EVENT DETAILS", "СВЕДЕНИЯ О СОБЫТИИ")) {
                            EventEditorTextField(
                                label: copy("Title", "Название"),
                                prompt: copy("What happened?", "Что произошло?"),
                                text: $draft.title
                            )

                            EventEditorTextField(
                                label: copy("Date", "Дата"),
                                prompt: copy("For example, 1945 or 12 May 1945", "Например, 1945 или 12 мая 1945"),
                                text: $draft.date
                            )

                            EventEditorTextField(
                                label: copy("Place", "Место"),
                                prompt: copy("City, region, or country", "Город, область или страна"),
                                text: Binding(
                                    get: { draft.place ?? "" },
                                    set: { draft.place = $0.trimmed.isEmpty ? nil : $0 }
                                )
                            )

                            VStack(alignment: .leading, spacing: 7) {
                                Text(copy("Category", "Категория"))
                                    .font(ArchiveTypography.metadataEmphasis)
                                    .foregroundStyle(ArchiveTheme.muted)

                                Button {
                                    showingCategoryPicker = true
                                } label: {
                                    HStack(spacing: 12) {
                                        LifeEventCategoryIcon(category: selectedCategory, size: 15)
                                            .foregroundStyle(ArchiveTheme.accent)
                                            .frame(width: 32, height: 32)
                                            .background(ArchiveTheme.background)
                                            .clipShape(Circle())
                                        Text(selectedCategory.localizedLabel)
                                            .font(ArchiveTypography.bodyEmphasis)
                                            .foregroundStyle(ArchiveTheme.ink)
                                            .lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(ArchiveTheme.metadata)
                                    }
                                    .padding(.horizontal, 12)
                                    .frame(height: 48)
                                    .background(ArchiveTheme.actionBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(copy("Category", "Категория"))
                                .accessibilityValue(selectedCategory.localizedLabel)
                                .popover(
                                    isPresented: $showingCategoryPicker,
                                    attachmentAnchor: .rect(.bounds),
                                    arrowEdge: .top
                                ) {
                                    EventCategoryPicker(selectedCategory: selectedCategory) { category in
                                        draft.category = category.rawValue
                                        showingCategoryPicker = false
                                    }
                                    .presentationCompactAdaptation(.popover)
                                    .presentationBackground(ArchiveTheme.background)
                                }
                            }

                            Toggle(isOn: Binding(
                                get: { draft.isApproximate ?? false },
                                set: { draft.isApproximate = $0 }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(copy("Approximate date", "Приблизительная дата"))
                                        .font(ArchiveTypography.bodyEmphasis)
                                        .foregroundStyle(ArchiveTheme.ink)
                                    Text(copy(
                                        "Use when the exact date is uncertain.",
                                        "Включите, если точная дата неизвестна."
                                    ))
                                    .font(ArchiveTypography.metadata)
                                    .foregroundStyle(ArchiveTheme.metadata)
                                }
                            }
                            .tint(ArchiveTheme.accent)
                            .padding(.vertical, 4)
                        }

                        editorSection(copy("STORY", "ОПИСАНИЕ")) {
                            EventEditorTextArea(
                                label: copy("Description", "Описание"),
                                prompt: copy(
                                    "Add context, memories, or details about this event.",
                                    "Добавьте обстоятельства, воспоминания или подробности события."
                                ),
                                text: $draft.summary
                            )
                        }
                    }
                    .padding(.horizontal, ArchiveLayout.pageHorizontal)
                    .padding(.top, 14)
                    .padding(.bottom, ArchiveLayout.pageBottom)
                }
                .scrollIndicators(.hidden)
            }
            .foregroundStyle(ArchiveTheme.ink)
            .background(ArchiveTheme.background)
            .toolbar(.hidden, for: .navigationBar)
            .alert(language == .russian ? "Проверка языка" : "Language check", isPresented: Binding(
                get: { languageError != nil },
                set: { if !$0 { languageError = nil } }
            )) {
                Button(language == .russian ? "Хорошо" : "OK") { languageError = nil }
            } message: {
                Text(languageError ?? "")
            }
        }
    }

    private var editorTopBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(ArchiveTypography.icon)
                    .foregroundStyle(ArchiveTheme.ink)
                    .frame(width: ArchiveShape.actionDiameter, height: ArchiveShape.actionDiameter)
                    .background(ArchiveTheme.actionBackground)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copy("Cancel", "Отмена"))

            Spacer()

            Text(isNewEvent ? copy("Add event", "Новое событие") : copy("Edit event", "Изменить событие"))
                .font(ArchiveTypography.navigationTitle)
                .foregroundStyle(ArchiveTheme.ink)
                .lineLimit(1)

            Spacer()

            Button { save() } label: {
                Image(systemName: "checkmark")
                    .font(ArchiveTypography.icon)
                    .foregroundStyle(canSave ? ArchiveTheme.ink : ArchiveTheme.metadata)
                    .frame(width: ArchiveShape.actionDiameter, height: ArchiveShape.actionDiameter)
                    .background(ArchiveTheme.actionBackground)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .accessibilityLabel(copy("Save", "Сохранить"))
        }
        .padding(.horizontal, ArchiveLayout.pageHorizontal)
        .padding(.vertical, 8)
        .background(ArchiveTheme.background)
    }

    @ViewBuilder
    private func editorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(ArchiveTypography.sectionTitle)
                .tracking(1.2)
                .foregroundStyle(ArchiveTheme.ink)

            VStack(alignment: .leading, spacing: 18) {
                content()
            }
        }
    }

    private func save() {
        if let issue = ArchiveLanguageValidator.issue(
            language: language,
            fields: [("Title", draft.title), ("Description", draft.summary), ("Place", draft.place ?? "")]
        ) {
            languageError = issue
            return
        }
        var saved = draft
        saved.sortKey = editorSortKey(saved.date)
        onSave(saved)
        dismiss()
    }
}

private struct EventCategoryPicker: View {
    let selectedCategory: LifeEventCategory
    let onSelect: (LifeEventCategory) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(LifeEventCategory.allCases) { category in
                    Button {
                        onSelect(category)
                    } label: {
                        HStack(spacing: 10) {
                            LifeEventCategoryIcon(category: category, size: 13)
                                .foregroundStyle(ArchiveTheme.accent)
                                .frame(width: 20)

                            Text(category.localizedLabel)
                                .font(ArchiveTypography.body)
                                .foregroundStyle(ArchiveTheme.ink)
                                .lineLimit(1)

                            Spacer(minLength: 8)

                            if category == selectedCategory {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(ArchiveTheme.accent)
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(
                            category == selectedCategory
                                ? ArchiveTheme.actionBackground
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .scrollIndicators(.hidden)
        .frame(width: 270, height: 358)
        .background(ArchiveTheme.background)
        .accessibilityElement(children: .contain)
    }
}

private struct EventEditorTextField: View {
    let label: String
    let prompt: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(ArchiveTypography.metadataEmphasis)
                .foregroundStyle(ArchiveTheme.muted)

            TextField(prompt, text: $text, axis: .vertical)
                .font(ArchiveTypography.body)
                .foregroundStyle(ArchiveTheme.ink)
                .lineLimit(1...3)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(ArchiveTheme.actionBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct EventEditorTextArea: View {
    let label: String
    let prompt: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(ArchiveTypography.metadataEmphasis)
                .foregroundStyle(ArchiveTheme.muted)

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(prompt)
                        .font(ArchiveTypography.body)
                        .foregroundStyle(ArchiveTheme.metadata)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $text)
                    .font(ArchiveTypography.body)
                    .foregroundStyle(ArchiveTheme.ink)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 132)
            }
            .background(ArchiveTheme.actionBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct StoryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: StoryChapter
    @State private var languageError: String?
    let language: ArchiveLanguage
    let onSave: (StoryChapter) -> Void

    init(story: StoryChapter?, language: ArchiveLanguage, onSave: @escaping (StoryChapter) -> Void) {
        self.language = language
        self.onSave = onSave
        _draft = State(initialValue: story ?? StoryChapter(
            id: UUID().uuidString,
            title: "",
            dateRange: nil,
            summary: nil,
            body: ""
        ))
        _languageError = State(initialValue: nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Story") {
                    TextField("Title", text: $draft.title)
                    TextField("Date or range", text: Binding(
                        get: { draft.dateRange ?? "" },
                        set: { draft.dateRange = $0.trimmed.isEmpty ? nil : $0 }
                    ))
                    TextField("Highlighted introduction", text: Binding(
                        get: { draft.summary ?? "" },
                        set: { draft.summary = $0.trimmed.isEmpty ? nil : $0 }
                    ), axis: .vertical)
                        .lineLimit(2...5)
                    TextField("Story", text: $draft.body, axis: .vertical)
                        .lineLimit(8...20)
                }
            }
            .navigationTitle("Edit story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let issue = ArchiveLanguageValidator.issue(
                            language: language,
                            fields: [("Title", draft.title), ("Highlighted introduction", draft.summary ?? ""), ("Story", draft.body)]
                        ) {
                            languageError = issue
                            return
                        }
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(draft.title.trimmed.isEmpty && draft.body.trimmed.isEmpty)
                }
            }
            .alert(language == .russian ? "Проверка языка" : "Language check", isPresented: Binding(
                get: { languageError != nil },
                set: { if !$0 { languageError = nil } }
            )) {
                Button(language == .russian ? "Хорошо" : "OK") { languageError = nil }
            } message: {
                Text(languageError ?? "")
            }
        }
    }
}

private struct PersonMediaEditorView: View {
    private let initialPerson: Person
    private let personID: Person.ID
    @ObservedObject var repository: FamilyRepository
    @Environment(\.dismiss) private var dismiss
    @State private var editingMedia: MediaReference?

    init(person: Person, repository: FamilyRepository) {
        initialPerson = person
        personID = person.id
        _repository = ObservedObject(wrappedValue: repository)
    }

    private var person: Person { repository.person(id: personID) ?? initialPerson }

    var body: some View {
        NavigationStack {
            List {
                if person.media.isEmpty {
                    Text("No media has been added yet.")
                        .foregroundStyle(ArchiveTheme.metadata)
                } else {
                    ForEach(person.media) { item in
                        Button { editingMedia = item } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.kind.systemImage)
                                    .foregroundStyle(ArchiveTheme.action)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.caption?.trimmed.isEmpty == false
                                        ? MediaMentionToken.visibleText(item.caption!, people: repository.people)
                                        : item.kind.rawValue.capitalized)
                                        .foregroundStyle(ArchiveTheme.ink)
                                    Text("Related to \(MediaMentionToken.personIDs(in: item.caption ?? "").count) people")
                                        .font(ArchiveTypography.metadata)
                                        .foregroundStyle(ArchiveTheme.metadata)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(ArchiveTypography.metadata)
                                    .foregroundStyle(ArchiveTheme.metadata)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            if repository.canEdit {
                                Button(role: .destructive) {
                                    repository.removeMedia(item, from: person.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Edit media")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editingMedia) { item in
                MediaMetadataEditor(item: item, ownerID: person.id, repository: repository)
            }
        }
    }
}

struct MediaMetadataEditor: View {
    let item: MediaReference
    let ownerID: Person.ID
    @ObservedObject var repository: FamilyRepository
    @Environment(\.dismiss) private var dismiss
    @State private var caption: String
    @State private var selectedMentionIDs: Set<Person.ID>
    @State private var saveError: String?

    init(item: MediaReference, ownerID: Person.ID, repository: FamilyRepository) {
        self.item = item
        self.ownerID = ownerID
        _repository = ObservedObject(wrappedValue: repository)
        let sourceCaption = item.caption ?? ""
        let englishCaption = NarrativeLocalizationStore.shared.storedMediaCaption(
            mediaID: item.id,
            source: sourceCaption
        ) ?? (sourceCaption.range(of: "[А-Яа-яЁё]", options: .regularExpression) == nil ? sourceCaption : "")
        let localizedCaption = repository.appLanguage == .english ? englishCaption : sourceCaption
        _caption = State(initialValue: MediaMentionToken.visibleText(
            localizedCaption,
            people: repository.people,
            language: repository.appLanguage
        ))
        _selectedMentionIDs = State(initialValue: Set(MediaMentionToken.personIDs(in: localizedCaption)))
        _saveError = State(initialValue: nil)
    }

    private var captionLabel: String {
        ArchiveCopy.text(english: "Caption", russian: "Подпись")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MediaCaptionEditor(
                        preview: repository.people.first(where: { $0.id == ownerID }).map {
                            MemoryItem(person: $0, media: item)
                        },
                        showsActions: true,
                        caption: $caption,
                        selectedMentionIDs: $selectedMentionIDs,
                        repository: repository,
                        onCancel: { dismiss() },
                        onSave: save
                    )
                }
                .padding(.horizontal, ArchiveLayout.pageHorizontal)
                .padding(.top, ArchiveLayout.pageTop)
                .padding(.bottom, ArchiveLayout.pageBottom)
            }
            .scrollIndicators(.hidden)
            .background(ArchiveTheme.background)
            .navigationTitle(ArchiveCopy.text(english: "Edit media", russian: "Изменить медиа"))
            .navigationBarTitleDisplayMode(.inline)
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
        }
    }

    private func save() throws {
        let saved = try repository.saveMediaCaption(
            caption,
            for: item,
            ownerID: ownerID,
            preferredPersonIDs: selectedMentionIDs,
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
        dismiss()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

private func editorSortKey(_ value: String) -> Int? {
    LifeEvent.sortKey(for: value)
}
