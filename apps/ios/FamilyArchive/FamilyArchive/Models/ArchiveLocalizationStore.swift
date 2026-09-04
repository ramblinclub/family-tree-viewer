import Foundation

/// Bundled, non-private localization data for archive place names. Adding
/// another locale means adding a locale object to `Resources/archive-locales.json`.
private struct ArchiveLocaleResource: Decodable {
    let places: [String: String]
    let placeFragments: [String: String]
}

private struct ArchiveLocalizationResource: Decodable {
    let locales: [String: ArchiveLocaleResource]
}

final class ArchiveLocalizationStore {
    nonisolated(unsafe) static let shared = ArchiveLocalizationStore()

    private var locales: [String: ArchiveLocaleResource] = [:]

    private init() {
        reload()
    }

    func reload(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "archive-locales", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let resource = try? JSONDecoder().decode(ArchiveLocalizationResource.self, from: data) else {
            locales = [:]
            return
        }
        locales = resource.locales
    }

    func place(_ value: String, language: ArchiveLanguage) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mappings = locales[language.rawValue]?.places else { return nil }
        if let exact = mappings[trimmed] {
            return exact
        }
        return mappings.first {
            $0.key.caseInsensitiveCompare(trimmed) == .orderedSame
        }?.value
    }

    func replacePlaceFragments(in value: String, language: ArchiveLanguage) -> String {
        guard let fragments = locales[language.rawValue]?.placeFragments,
              !fragments.isEmpty else {
            return value
        }

        return fragments
            .sorted { $0.key.count > $1.key.count }
            .reduce(value) { partial, fragment in
                partial.replacingOccurrences(of: fragment.key, with: fragment.value)
            }
    }
}
