import SwiftUI
import UIKit

struct PersonDetailView: View {
    let person: Person
    let repository: FamilyRepository

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: DetailTab = .overview
    @State private var showingActions = false
    @State private var showingAllMedia = false

    var body: some View {
        VStack(spacing: 0) {
            detailTopBar
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    profileHeader
                    profileMediaPreview

                    Section {
                        tabContent
                            .padding(.horizontal, 20)
                            .padding(.top, 22)
                            .padding(.bottom, 32)
                    } header: {
                        tabBar
                            .background(Color(uiColor: .systemBackground))
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(ArchiveTheme.ink)
        .background(Color(uiColor: .systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog("Profile actions", isPresented: $showingActions, titleVisibility: .visible) {
            Button("Edit profile") {}
            Button("Add memory") {}
            Button("Share profile") {}
            Button("Report an issue", role: .destructive) {}
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingAllMedia) {
            PersonMediaGalleryView(person: person)
        }
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
            .accessibilityLabel("Close profile")

            Spacer()

            Text(person.relationshipToMe ?? "Family member")
                .font(ArchiveTypography.navigationTitle)
                .lineLimit(1)

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
            .accessibilityLabel("Profile actions")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                ProfilePhotoView(person: person, size: 72)
                    // Align the photo with the visible cap-height of the name,
                    // not the font's invisible line-box top.
                    .padding(.top, ArchiveTypography.profileNameOpticalTopInset)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(person.displayName)
                            .font(ArchiveTypography.profileName)
                            .fixedSize(horizontal: false, vertical: true)

                        if repository.document.accountHolderID == person.id {
                            AccountHolderBadge()
                        }
                    }

                    if !person.alternateNames.isEmpty {
                        (
                            Text("Also known as ")
                            + Text(person.alternateNames.joined(separator: " · "))
                        )
                            .font(ArchiveTypography.metadata)
                            .foregroundStyle(ArchiveTheme.metadata)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 6)
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
                    ProfileDateLine(label: "Birth", fact: birth)
                }

                if let death = person.deathFact {
                    ProfileDateLine(label: "Death", fact: death)
                }
            }

            if !person.summary.isEmpty {
                ArchiveParagraph(person.summary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var profileLifeSummary: String? {
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
            return "Died at age \(age) · \(yearsAgo) \(yearsAgo == 1 ? "year" : "years") ago"
        }

        let age = age(from: birthDate, birthYear: birthYear, to: Date(), endYear: calendar.component(.year, from: Date()))
        return "Age \(age)"
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
        let previewMedia = person.media.filter { $0.path != profileMediaPath }

        if !previewMedia.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("MEDIA")
                        .font(ArchiveTypography.sectionTitle)
                        .tracking(1.2)
                        .foregroundStyle(ArchiveTheme.ink)

                    Spacer()

                    Button("View all") {
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
                        ProfileMediaPreviewTile(item: item)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
    }

    private var profileMediaPath: String? {
        person.profileImagePath ?? person.media.first(where: { $0.kind == .photo })?.path
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

    private var overviewContent: some View {
        EmptyView()
    }

    private var timelineContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            detailSection("Life events & records") {
                VStack(alignment: .leading, spacing: 0) {
                    if !timelineEvents.isEmpty {
                        ForEach(Array(timelineEvents.enumerated()), id: \.element.id) { index, event in
                            LifeEventRow(event: event, isLast: index == timelineEvents.count - 1)
                        }
                    } else if !supportingFacts.isEmpty {
                        ForEach(Array(supportingFacts.enumerated()), id: \.element.id) { index, fact in
                            TimelineRow(fact: fact, isLast: index == supportingFacts.count - 1)
                        }
                    } else {
                        Text("No additional dated events recorded.")
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
            if !person.structuredStories.isEmpty {
                ForEach(person.structuredStories) { chapter in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(chapter.title.uppercased())
                            .font(ArchiveTypography.sectionTitle)
                            .tracking(1.2)
                            .foregroundStyle(ArchiveTheme.ink)

                        if let dateRange = chapter.dateRange, let summary = chapter.summary {
                            StoryDatedContentBlock(
                                date: dateRange,
                                title: summary,
                                body: chapter.body
                            )
                        } else {
                            if let dateRange = chapter.dateRange {
                                ArchiveContentDate(dateRange)
                            }
                            if let summary = chapter.summary {
                                StoryIntroParagraph(summary)
                            }
                        }
                        if chapter.dateRange == nil || chapter.summary == nil {
                            ArchiveParagraph(chapter.body)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                detailSection("Life story") {
                    ArchiveParagraph(person.biography)
                        .textSelection(.enabled)
                }
            }

        }
    }

    private var mediaContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            detailSection("Media & documents") {
                mediaStats
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 1) {
                    ForEach(person.media) { item in
                        MediaTile(item: item)
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
                detailSection("Immediate family") {
                    ArchiveParagraph("No immediate family connections are recorded for this profile yet.")
                }
            }
        }
    }

    private var mediaStats: some View {
        HStack(spacing: 0) {
            MediaStat(value: mediaCount(.photo), label: "Photos")
            MediaStat(value: mediaCount(.document), label: "Documents")
            MediaStat(value: mediaCount(.audio), label: "Audio")
            MediaStat(value: mediaCount(.video), label: "Video")
        }
        .padding(.vertical, 12)
        .background(ArchiveTheme.ink.opacity(0.05))
    }

    private func mediaCount(_ kind: MediaKind) -> String {
        "\(person.media.filter { $0.kind == kind }.count)"
    }

    private var supportingFacts: [PersonFact] {
        person.facts.filter {
            !$0.label.localizedCaseInsensitiveContains("born") &&
                !$0.label.localizedCaseInsensitiveContains("birth") &&
                !$0.label.localizedCaseInsensitiveContains("died") &&
                !$0.label.localizedCaseInsensitiveContains("death")
        }
    }

    private var timelineEvents: [LifeEvent] {
        person.orderedEvents.filter { $0.category != "birth" && $0.category != "death" }
    }

    private var hasFamily: Bool {
        !person.immediateFamily.parents.isEmpty ||
            !person.immediateFamily.partners.isEmpty ||
            !person.immediateFamily.siblings.isEmpty ||
            !person.immediateFamily.children.isEmpty
    }

    private var familySection: some View {
        detailSection("Family") {
            familyGroup(title: "Parents", ids: person.immediateFamily.parents)
            familyGroup(title: "Spouse", ids: person.immediateFamily.partners)
            familyGroup(title: "Children", ids: person.immediateFamily.children)
            familyGroup(title: "Siblings", ids: person.immediateFamily.siblings)
        }
    }

    @ViewBuilder
    private func familyGroup(title: String, ids: [Person.ID]) -> some View {
        if !ids.isEmpty {
            Text(title)
                .font(ArchiveTypography.contentTitle)
                .padding(.top, 10)

            ForEach(repository.people(ids: ids)) { relative in
                NavigationLink(value: relative.id) {
                    FamilyMemberTile(person: relative)
                }
                .buttonStyle(.plain)
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
            Text(title.uppercased())
                .font(ArchiveTypography.sectionTitle)
                .tracking(1.2)
                .foregroundStyle(ArchiveTheme.ink)

            VStack(alignment: .leading, spacing: 0, content: content)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        Text(ArchiveDateFormatter.display(value) ?? value)
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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(label):")
                .font(ArchiveTypography.metadataEmphasis)
                .foregroundStyle(ArchiveTheme.ink)
                .frame(width: 54, alignment: .leading)
            Text(dateAndPlace)
                .font(ArchiveTypography.metadata)
                .foregroundStyle(ArchiveTheme.metadata)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dateAndPlace: String {
        let date = ArchiveDateFormatter.display(fact.value) ?? fact.value
        guard let place = fact.place, !place.isEmpty else { return date }
        return "\(date), \(place)"
    }
}

private struct ProfilePhotoView: View {
    let person: Person
    let size: CGFloat

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .grayscale(person.isLiving ? 0 : 1)
            } else {
                ZStack(alignment: .bottomLeading) {
                    MonogramView(person: person, size: size)
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
        let path = person.profileImagePath ?? person.media.first(where: { $0.kind == .photo })?.path
        guard let path else { return nil }
        return ArchiveFileResolver.image(for: path)
    }
}

private enum DetailTab: String, CaseIterable, Identifiable {
    case overview
    case timeline
    case stories
    case family

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .timeline: "Life events"
        case .stories: "Stories"
        case .family: "Family"
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

private struct FactRow: View {
    let fact: PersonFact

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Text(fact.label)
                .font(ArchiveTypography.supporting)
                .foregroundStyle(ArchiveTheme.muted)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(fact.value)
                if let place = fact.place {
                Text(place)
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.metadata)
                }
            }
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct TimelineRow: View {
    let fact: PersonFact
    let isLast: Bool

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
                ArchiveContentTitle(fact.label)
                ArchiveParagraph(fact.value)
                if let place = fact.place {
                    Text(place)
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.metadata)
                }
            }
            .padding(.vertical, 11)
        }
    }
}

private struct LifeEventRow: View {
    let event: LifeEvent
    let isLast: Bool

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
                    title: event.title,
                    body: event.summary,
                    note: event.isApproximate == true ? "Approximate" : nil
                )
                if let place = event.place {
                    Text(place)
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

    @Environment(\.dismiss) private var dismiss
    @State private var selectedMedia: MediaReference?

    var body: some View {
        VStack(spacing: 0) {
            mediaTopBar

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 14
                ) {
                    ForEach(person.media) { item in
                        PersonMediaGalleryTile(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture {
                            selectedMedia = item
                        }
                    }
                }
                .padding(.horizontal, ArchiveLayout.pageHorizontal)
                .padding(.top, ArchiveLayout.pageTop)
                .padding(.bottom, ArchiveLayout.pageBottom)
            }
            .scrollIndicators(.hidden)
            .background(Color(uiColor: .systemBackground))
        }
        .foregroundStyle(ArchiveTheme.ink)
        .background(Color(uiColor: .systemBackground))
        .sheet(item: $selectedMedia) { item in
            PersonMediaPagerView(items: person.media, initialID: item.id)
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
            .accessibilityLabel("Close media gallery")

            Spacer()

            Text("Media")
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
    let item: MediaReference

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            PersonMediaVisual(item: item)

            Group {
                if let caption = item.caption, !caption.isEmpty {
                    Text(captionWithDate(caption))
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.metadata)
                        .lineLimit(2)
                } else if let date = item.date {
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

    private func captionWithDate(_ caption: String) -> String {
        guard let date = item.date, !date.isEmpty else { return caption }
        return "\(caption) · \(ArchiveDateFormatter.display(date) ?? date)"
    }
}

private struct PersonMediaVisual: View {
    let item: MediaReference

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack(alignment: .bottomLeading) {
                    if item.kind == .photo,
                       let path = item.path,
                       let image = ArchiveFileResolver.image(for: path) {
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
            .clipped()
    }
}

private struct PersonMediaPagerView: View {
    let items: [MediaReference]
    let initialID: String

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: Int

    init(items: [MediaReference], initialID: String) {
        self.items = items
        self.initialID = initialID
        _selectedIndex = State(initialValue: items.firstIndex { $0.id == initialID } ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            mediaTopBar

            VStack(spacing: 0) {
                TabView(selection: $selectedIndex) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        PersonMediaDetailContent(item: item)
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
                    .accessibilityLabel("Previous photo")

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
                    .accessibilityLabel("Next photo")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color(uiColor: .systemBackground))
            }
            .background(Color(uiColor: .systemBackground))
        }
        .foregroundStyle(ArchiveTheme.ink)
        .background(Color(uiColor: .systemBackground))
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
            .accessibilityLabel("Close media")

            Spacer()

            Text("Media")
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

private struct PersonMediaDetailContent: View {
    let item: MediaReference

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PersonMediaLargeVisual(item: item)

                if let caption = item.caption, !caption.isEmpty {
                    Text(mediaCaptionWithDate(caption, date: item.date))
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.metadata)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let date = item.date {
                    Text(ArchiveDateFormatter.display(date) ?? date)
                        .font(ArchiveTypography.metadata)
                        .foregroundStyle(ArchiveTheme.metadata)
                }

                if let collection = item.collection, !collection.isEmpty {
                    GalleryMetadataRow(label: "Collection", value: collection)
                }

                if let tags = item.tags, !tags.isEmpty {
                    GalleryMetadataRow(label: "Tags", value: tags.joined(separator: " · "))
                }
            }
            .padding(.horizontal, ArchiveLayout.pageHorizontal)
            .padding(.top, ArchiveLayout.pageTop)
            .padding(.bottom, ArchiveLayout.pageBottom)
        }
        .background(Color(uiColor: .systemBackground))
    }
}

private func mediaCaptionWithDate(_ caption: String, date: String?) -> String {
    guard let date, !date.isEmpty else { return caption }
    return "\(caption) · \(ArchiveDateFormatter.display(date) ?? date)"
}

private struct PersonMediaLargeVisual: View {
    let item: MediaReference

    var body: some View {
        Group {
            if item.kind == .photo,
               let path = item.path,
               let image = ArchiveFileResolver.image(for: path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .background(ArchiveTheme.ink.opacity(0.05))
            } else {
                PersonMediaVisual(item: item)
            }
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

            if let date = item.date {
                Text(ArchiveDateFormatter.display(date) ?? date)
                    .font(ArchiveTypography.metadata)
                    .foregroundStyle(ArchiveTheme.metadata)
            }

            if let caption = item.caption, !caption.isEmpty {
                Text(caption)
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

            if item.isApproximate == true {
                Text("Date approximate")
                    .font(ArchiveTypography.metadata)
                    .foregroundStyle(ArchiveTheme.metadata)
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
