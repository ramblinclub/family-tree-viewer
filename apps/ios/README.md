# Family Archive for iPhone

This directory contains the first-pass native SwiftUI application for the
family archive. It is intentionally separate from the existing web viewer but
uses a portable JSON model that can later be shared by the website, import and
export tools, and the tree viewer.

## First-pass scope

- Searchable alphabetical list of people
- Profile pages with life facts and biography
- Tappable links to parents, partners, siblings, and children
- Media-reference cards for photographs and documents
- Offline bundled sample data
- iPhone and iPad support

The tree viewer, editing, synchronization, authentication, and real archive
data are deliberately outside this milestone.

## Privacy boundary

The bundled `sample-family.json` contains synthetic people. Real names, family
facts, photographs, documents, GEDCOM files, and generated private JSON must
not be committed to this repository.

The original archive at the following location is a read-only source and must
never be modified by this project:

```text
/Users/wwwelena/SHOEBOX/PERSONAL/PROJECTS/ANCESTRY/FAMILY_ARCHIVE
```

When private-data work begins, selected source files should be copied by the
archive owner into a separate folder outside this Git repository. Local files
named `*.private.json` and any `PrivateData/` directory under the iOS project
are ignored as an additional safeguard.

## Open and run

Open:

```text
apps/ios/FamilyArchive/FamilyArchive.xcodeproj
```

Choose an iPhone or iPad simulator and run the `FamilyArchive` scheme.

## Portable data contract

`sample-family.json` is versioned with `schemaVersion`. Each person has a
stable opaque ID, names, life facts, biography, media references, provenance,
privacy classification, and immediate-family IDs. Relationship links are
resolved by ID rather than by a person's name or filename.

Future converters can merge:

- GEDCOM for structured people, events, and relationships
- Curated HTML pages for biographies and editorial corrections
- Photo indexes and gallery folders for media metadata

When sources disagree, the converter should preserve provenance and report the
conflict instead of silently overwriting either value.
