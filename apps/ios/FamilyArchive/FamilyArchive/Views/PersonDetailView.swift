import SwiftUI
import UIKit

struct PersonDetailView: View {
    let person: Person
    let repository: FamilyRepository

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: DetailTab = .overview
    @State private var showingActions = false

    var body: some View {
        VStack(spacing: 0) {
            detailTopBar
            profileHeader
            profileMediaPreview
            tabBar

            ScrollView {
                tabContent
                    .padding(.horizontal, 20)
                    .padding(.top, 22)
                    .padding(.bottom, 32)
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
    }

    private var detailTopBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .background(Color(uiColor: .secondarySystemBackground))
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
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .background(Color(uiColor: .secondarySystemBackground))
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

                VStack(alignment: .leading, spacing: 2) {
                    Text(person.displayName)
                        .font(ArchiveTypography.profileName)
                        .fixedSize(horizontal: false, vertical: true)

                    if !person.alternateNames.isEmpty {
                        (
                            Text("Also known as ")
                            + Text(person.alternateNames.joined(separator: " · "))
                        )
                            .font(.caption)
                            .foregroundStyle(ArchiveTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 6)
                    }

                    if let lifeSummary = profileLifeSummary {
                        Text(lifeSummary)
                            .font(.caption)
                            .foregroundStyle(ArchiveTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: -6)
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
                Text(person.summary)
                    .font(.subheadline)
                    .foregroundStyle(ArchiveTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
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
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.date(from: value)
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
                            .font(.subheadline.weight(.semibold))

                        Text(tab.title)
                            .font(.caption.weight(.medium))
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
        if !person.media.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("MEDIA")
                        .font(ArchiveTypography.sectionTitle)
                        .tracking(1.2)
                        .foregroundStyle(ArchiveTheme.ink)
                }

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                    spacing: 8
                ) {
                    ForEach(person.media.prefix(4)) { item in
                        ProfileMediaPreviewTile(item: item)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
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
                            .font(.subheadline)
                            .foregroundStyle(ArchiveTheme.muted)
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
                    detailSection(chapter.title) {
                        if let dateRange = chapter.dateRange {
                            Text(dateRange)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(ArchiveTheme.muted)
                        }
                        if let summary = chapter.summary {
                            Text(summary)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(ArchiveTheme.muted)
                                .padding(.top, 4)
                        }
                        Text(chapter.body)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    }
                }
            } else {
                detailSection("Life story") {
                    Text(person.biography)
                        .font(.body)
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
                    Text("No immediate family connections are recorded for this profile yet.")
                        .font(.body)
                        .foregroundStyle(ArchiveTheme.muted)
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
                .font(.subheadline.weight(.semibold))
                .padding(.top, 10)

            ForEach(repository.people(ids: ids)) { relative in
                NavigationLink(value: relative.id) {
                    HStack(spacing: 12) {
                        MonogramView(person: relative, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(relative.displayName)
                            Text(relative.lifespan)
                                .font(.caption)
                                .foregroundStyle(ArchiveTheme.muted)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ArchiveTheme.muted)
                    }
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                Divider()
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
    }
}

private struct ProfileDateLine: View {
    let label: String
    let fact: PersonFact

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(label):")
                .font(.caption.weight(.bold))
                .foregroundStyle(ArchiveTheme.ink)
                .frame(width: 54, alignment: .leading)
            Text(dateAndPlace)
                .font(.caption)
                .foregroundStyle(ArchiveTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dateAndPlace: String {
        guard let place = fact.place, !place.isEmpty else { return fact.value }
        return "\(fact.value), \(place)"
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
            } else {
                ZStack(alignment: .bottomLeading) {
                    MonogramView(person: person, size: size)
                    Image(systemName: "photo")
                        .font(.caption.weight(.semibold))
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
        return UIImage(contentsOfFile: path) ?? UIImage(named: path)
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
                .font(.subheadline)
                .foregroundStyle(ArchiveTheme.muted)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(fact.value)
                if let place = fact.place {
                    Text(place)
                        .font(.caption)
                        .foregroundStyle(ArchiveTheme.muted)
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

            VStack(alignment: .leading, spacing: 3) {
                Text(fact.label)
                    .font(.subheadline.weight(.semibold))
                Text(fact.value)
                if let place = fact.place {
                    Text(place)
                        .font(.caption)
                        .foregroundStyle(ArchiveTheme.muted)
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
                HStack(alignment: .firstTextBaseline) {
                    Text(event.date)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ArchiveTheme.muted)
                    Spacer()
                    if event.isApproximate == true {
                        Text("Approximate")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(ArchiveTheme.muted)
                    }
                }
                Text(event.title)
                    .font(.subheadline.weight(.semibold))
                Text(event.summary)
                    .font(.subheadline)
                if let place = event.place {
                    Text(place)
                        .font(.caption)
                        .foregroundStyle(ArchiveTheme.muted)
                }
            }
            .padding(.vertical, 11)
        }
    }
}

private struct ProfileMediaPreviewTile: View {
    let item: MediaReference

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

            Image(systemName: item.kind.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
        }
        .aspectRatio(1, contentMode: .fit)
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
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(12)
            }
            .frame(height: 106)

            Text(item.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)

            if let date = item.date {
                Text(date)
                    .font(.caption)
                    .foregroundStyle(ArchiveTheme.muted)
            }

            if let caption = item.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(ArchiveTheme.muted)
                    .lineLimit(2)
            }

            if let collection = item.collection, !collection.isEmpty {
                Text(collection)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(ArchiveTheme.muted)
                    .lineLimit(1)
            }

            if let tags = item.tags, !tags.isEmpty {
                Text(tags.map { "#\($0)" }.joined(separator: "  "))
                    .font(.caption2)
                    .foregroundStyle(ArchiveTheme.muted)
                    .lineLimit(1)
            }

            if item.isApproximate == true {
                Text("Date approximate")
                    .font(.caption2)
                    .foregroundStyle(ArchiveTheme.muted)
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
                .font(.subheadline.weight(.semibold))
            Text(source.locator)
                .font(.caption)
                .foregroundStyle(ArchiveTheme.muted)
                .textSelection(.enabled)
            if let notes = source.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(ArchiveTheme.muted)
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
                .font(.title3.weight(.semibold))
            Text(label)
                .font(.caption)
                    .foregroundStyle(ArchiveTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }
}
