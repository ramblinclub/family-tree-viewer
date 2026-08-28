import SwiftUI
import WebKit

/// Hosts the existing Topola renderer in a local, offline WebView. The native
/// app supplies only the focused account-centered branch from its private store.
struct TopolaTreeView: UIViewRepresentable {
    @ObservedObject var repository: FamilyRepository
    let onPersonSelected: (Person.ID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPersonSelected: onPersonSelected)
    }

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "personSelected")
        contentController.add(context.coordinator, name: "topolaReady")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.scrollView.bounces = true

        if let stylesheetURL = Bundle.main.url(forResource: "topola-tree", withExtension: "css", subdirectory: "TopolaTree"),
           let stylesheet = try? String(contentsOf: stylesheetURL, encoding: .utf8) {
            let document = "<html><head><style>\(stylesheet)</style></head><body><div id=\"status\">Loading tree…</div><div id=\"svgContainer\"><svg id=\"treeSvg\"><g id=\"chart\"></g></svg></div></body></html>"
            webView.loadHTMLString(document, baseURL: nil)
        }

        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onPersonSelected = onPersonSelected
        context.coordinator.send(payload: TopolaTreePayloadBuilder(repository: repository).makePayload())
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        var onPersonSelected: (Person.ID) -> Void
        private var pendingPayload: TopolaTreePayload?

        init(onPersonSelected: @escaping (Person.ID) -> Void) {
            self.onPersonSelected = onPersonSelected
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "personSelected", let personID = message.body as? String {
                onPersonSelected(personID)
            } else if message.name == "topolaReady", let pendingPayload {
                send(payload: pendingPayload)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let pendingPayload {
                send(payload: pendingPayload)
            }
            webView.evaluateJavaScript("typeof window.setTreePayload + '|' + document.body.innerHTML.length") { value, error in
                if let error {
                    NSLog("Topola web view diagnostics failed: %@", error.localizedDescription)
                } else {
                    NSLog("Topola web view diagnostics: %@", String(describing: value))
                }
            }
        }

        fileprivate func send(payload: TopolaTreePayload?) {
            pendingPayload = payload
            guard let payload,
                  let data = try? JSONEncoder().encode(payload),
                  let json = String(data: data, encoding: .utf8) else { return }

            let javascript = "window.setTreePayload(\(json));"
            if webView?.isLoading == false {
                webView?.evaluateJavaScript(javascript) { _, error in
                    if let error {
                        NSLog("Topola payload evaluation failed: %@", error.localizedDescription)
                    }
                }
            }
        }
    }
}

private struct TopolaTreePayload: Codable {
    let data: TopolaGedcomData
    let selectionID: String
    let locale: String
}

private struct TopolaGedcomData: Codable {
    let indis: [TopolaIndividual]
    let fams: [TopolaFamily]
}

private struct TopolaIndividual: Codable {
    let id: String
    let firstName: String
    let lastName: String
    let famc: String?
    let fams: [String]
    let birth: TopolaEvent?
    let death: TopolaEvent?
    let sex: String?
}

private struct TopolaFamily: Codable {
    let id: String
    let children: [String]
    let wife: String?
    let husb: String?
}

private struct TopolaEvent: Codable {
    let date: TopolaDate?
    let place: String?
    let confirmed: Bool?
}

private struct TopolaDate: Codable {
    let text: String?
}

private struct TopolaTreePayloadBuilder {
    let repository: FamilyRepository

    func makePayload() -> TopolaTreePayload? {
        guard let account = repository.accountHolder else { return nil }
        let index = TreeRelationshipIndex(document: repository.document)
        let people = primaryPeople(account: account, index: index)
        guard !people.isEmpty else { return nil }

        let data = makeGedcomData(people: people)
        return TopolaTreePayload(
            data: data,
            selectionID: account.id,
            locale: repository.appLanguage.rawValue
        )
    }

    private func primaryPeople(account: Person, index: TreeRelationshipIndex) -> [Person] {
        var ids = Set<Person.ID>()
        func add(_ people: [Person]) {
            people.forEach { ids.insert($0.id) }
        }

        ids.insert(account.id)
        let parents = index.parents(of: account.id)
        add(parents)
        add(parents.flatMap { index.parents(of: $0.id) })
        add(index.partners(of: account.id))
        add(index.siblings(of: account.id))

        let children = index.children(of: account.id)
        add(children)
        add(children.flatMap { index.children(of: $0.id) })

        return repository.people(ids: Array(ids)).sorted { left, right in
            left.birthYear ?? Int.max < right.birthYear ?? Int.max
        }
    }

    private func makeGedcomData(people: [Person]) -> TopolaGedcomData {
        let peopleByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        let includedIDs = Set(peopleByID.keys)
        var famcByChild: [Person.ID: String] = [:]
        var famsByPerson: [Person.ID: Set<String>] = [:]
        var familyBuilders: [FamilyBuilder] = []

        for union in repository.familyUnions.sorted(by: { $0.id < $1.id }) {
            let partners = union.partnerIDs.compactMap { peopleByID[$0] }
            let children = union.childIDs.filter { includedIDs.contains($0) }
            guard !partners.isEmpty, !children.isEmpty || partners.count > 1 else { continue }

            var family = FamilyBuilder(id: union.id)
            family.children.formUnion(children)
            partners.forEach { family.assign(parent: $0) }
            familyBuilders.append(family)

            for partner in partners {
                famsByPerson[partner.id, default: []].insert(union.id)
            }
            for childID in children where famcByChild[childID] == nil {
                famcByChild[childID] = union.id
            }
        }

        let individuals = people.map { person in
            let names = localizedNameParts(person)
            return TopolaIndividual(
                id: person.id,
                firstName: names.first,
                lastName: names.last,
                famc: famcByChild[person.id],
                fams: famsByPerson[person.id, default: []].sorted(),
                birth: topolaEvent(person.birthFact),
                death: topolaEvent(person.deathFact),
                sex: topolaSex(person.archiveGender)
            )
        }

        let families = familyBuilders.sorted { $0.id < $1.id }.map {
            TopolaFamily(id: $0.id, children: $0.children.sorted(), wife: $0.wife, husb: $0.husb)
        }
        return TopolaGedcomData(indis: individuals, fams: families)
    }

    private func localizedNameParts(_ person: Person) -> (first: String, last: String) {
        let localized = NameLocalizationStore.shared.displayName(
            for: person.id,
            fallback: person.sourceDisplayName,
            language: repository.appLanguage
        )
        let parts = localized.split(separator: " ", maxSplits: 1).map(String.init)
        return (parts.first ?? person.givenName, parts.count > 1 ? parts[1] : person.familyName)
    }

    private func topolaEvent(_ fact: PersonFact?) -> TopolaEvent? {
        guard let fact else { return nil }
        let text = fact.localizedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = fact.place.map(ArchiveCopy.place)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !(place ?? "").isEmpty else { return nil }
        return TopolaEvent(
            date: text.isEmpty ? nil : TopolaDate(text: text),
            place: place?.isEmpty == true ? nil : place,
            confirmed: true
        )
    }

    private func topolaSex(_ gender: ArchiveGender) -> String? {
        switch gender {
        case .female: "F"
        case .male: "M"
        case .unknown: nil
        }
    }

    private struct FamilyBuilder {
        let id: String
        var children = Set<Person.ID>()
        var wife: Person.ID?
        var husb: Person.ID?

        mutating func assign(parent: Person) {
            switch parent.archiveGender {
            case .female:
                wife = wife ?? parent.id
            case .male:
                husb = husb ?? parent.id
            case .unknown:
                if husb == nil { husb = parent.id } else if wife == nil { wife = parent.id }
            }
        }
    }
}

private struct TreeRelationshipIndex {
    private let peopleByID: [Person.ID: Person]
    private var parentsByChild: [Person.ID: Set<Person.ID>] = [:]
    private var childrenByParent: [Person.ID: Set<Person.ID>] = [:]
    private var partnersByPerson: [Person.ID: Set<Person.ID>] = [:]
    private var siblingsByPerson: [Person.ID: Set<Person.ID>] = [:]

    init(document: FamilyArchiveDocument) {
        let people = document.people
        peopleByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })

        for union in document.resolvedFamilyUnions {
            let partners = union.partnerIDs.filter { peopleByID[$0] != nil }
            let children = union.childIDs.filter { peopleByID[$0] != nil }
            for childID in children {
                parentsByChild[childID, default: []].formUnion(partners)
                for parentID in partners {
                    childrenByParent[parentID, default: []].insert(childID)
                }
            }
            for partnerID in partners {
                partnersByPerson[partnerID, default: []].formUnion(partners.filter { $0 != partnerID })
            }
        }

        // Preserve explicit sibling evidence for legacy/partial records while
        // also deriving full and half siblings from canonical parent unions.
        for person in people {
            for siblingID in person.immediateFamily.siblings where peopleByID[siblingID] != nil {
                siblingsByPerson[person.id, default: []].insert(siblingID)
                siblingsByPerson[siblingID, default: []].insert(person.id)
            }
        }

        for person in people {
            let parents = parentsByChild[person.id] ?? []
            guard !parents.isEmpty else { continue }
            for other in people where other.id != person.id {
                if !parents.isDisjoint(with: parentsByChild[other.id] ?? []) {
                    siblingsByPerson[person.id, default: []].insert(other.id)
                    siblingsByPerson[other.id, default: []].insert(person.id)
                }
            }
        }
    }

    func parents(of id: Person.ID) -> [Person] { people(for: parentsByChild[id] ?? []) }
    func children(of id: Person.ID) -> [Person] { people(for: childrenByParent[id] ?? []) }
    func partners(of id: Person.ID) -> [Person] { people(for: partnersByPerson[id] ?? []) }
    func siblings(of id: Person.ID) -> [Person] { people(for: siblingsByPerson[id] ?? []) }

    private func people(for ids: Set<Person.ID>) -> [Person] {
        ids.compactMap { peopleByID[$0] }.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
}
