# Complete GEDCOM Event Export Plan

**Status:** Deferred for later implementation
**Created:** August 28, 2026

## Purpose

The FamSpam private `.familyarchive` package is the authoritative, lossless
backup. It preserves complete person records, canonical family unions, life
events, narrative descriptions, translations, sources, stories, media, and
documents.

GEDCOM is currently a simplified derivative used primarily for Topola and
interoperability with genealogy tools. The existing exporter writes names,
relationships, birth, death, marriage, notes, and places, but it does not
preserve every FamSpam event field. GEDCOM must not be described or treated as
a complete FamSpam backup until the work in this plan is implemented and
verified.

## Current Behavior

- Canonical birth events are exported as `BIRT` records.
- Canonical death events are exported as `DEAT` records.
- Canonical marriage dates are exported through family `MARR` records.
- Divorce status and dates are exported through family `DIV` records.
- Topola consumes the derived birth, death, and family structure correctly.
- Other life events may be omitted entirely.
- Event descriptions, translations, FamSpam event IDs, source references, and
  some approximate-date metadata are not guaranteed to survive a GEDCOM
  export/import round trip.
- Stories, media, documents, and private localization sidecars remain features
  of the private archive rather than plain GEDCOM.

## Goal

Extend the GEDCOM derivative so supported structured life events can be shared
with other genealogy tools without silently losing their essential meaning.
The private archive remains the only complete restoration format.

The exporter should preserve, where GEDCOM permits:

- Event type or category
- Date or date range
- Approximate-date status
- Place
- Title
- Description or summary
- Source citations
- Stable FamSpam event identity for round-trip matching

## Proposed Event Mapping

Use standard GEDCOM tags whenever an event has a direct equivalent:

| FamSpam event | GEDCOM representation |
| --- | --- |
| Birth | `BIRT` |
| Death | `DEAT` |
| Marriage | Family `MARR` |
| Divorce | Family `DIV` |
| Burial | `BURI` |
| Residence | `RESI` |
| Education | `EDUC` |
| Occupation or career | `OCCU` |
| Immigration | `IMMI` |
| Emigration | `EMIG` |
| Military service | `EVEN` with a typed description |
| Other life event | `EVEN` with `TYPE` |

For each supported event, write subordinate values when available:

```text
1 EVEN
2 TYPE Military service
2 DATE ABT 1943
2 PLAC St Petersburg, Russia
2 NOTE Event description
2 _FAMSPAM_EVENT_ID event-identifier
```

The exact custom-tag naming must be finalized before implementation. Custom
tags should be limited to data that has no standard GEDCOM representation.

## Sources and Provenance

FamSpam event `sourceIDs` currently refer to source records stored with each
person. A complete exporter should:

1. Build one GEDCOM `SOUR` record for every referenced FamSpam source.
2. Attach source citations to the corresponding event with `SOUR` pointers.
3. Preserve source titles, repository details, URLs, notes, and available
   citation text using standard GEDCOM fields where possible.
4. Retain the original FamSpam source ID in a custom field only when required
   for round-trip identity.
5. Never invent a source association that is absent from the private data.

## Translations

Plain GEDCOM does not provide a dependable cross-application representation
for FamSpam's complete English/Russian localization sidecars.

The initial implementation should export the currently selected display
language and identify that language in the GEDCOM header or documented custom
metadata. A later optional extension may include alternate-language values in
custom tags, but importers outside FamSpam may ignore them.

The private archive must remain the authoritative source for complete bilingual
content.

## Import Considerations

If GEDCOM import is expanded to restore events, it must:

- Map standard event tags to controlled FamSpam event categories.
- Use the preserved FamSpam event ID when present.
- Otherwise match conservatively using event type, normalized date, and place.
- Avoid creating a second birth, death, marriage, or divorce event when the
  same canonical event already exists.
- Preserve unknown GEDCOM event types as `other` events rather than dropping
  them.
- Report unsupported or partially imported fields instead of failing silently.

## Compatibility and Limitations

- GEDCOM applications vary substantially in their support for `EVEN`, `TYPE`,
  custom tags, rich notes, and source citations.
- A valid export may still lose custom data when opened and re-exported by
  another genealogy application.
- Media portability requires GEDZIP or another bundle format; paths in a plain
  GEDCOM file are not a complete media backup.
- Stories and bilingual narrative content may need GEDZIP sidecars or a
  documented FamSpam extension rather than increasingly complex custom tags.
- The UI should continue labeling `.familyarchive` as the complete private
  backup and GEDCOM as a compatibility export.

## Delivery Phases

### Phase 1: Event inventory and mapping

- Inventory every event category in the normalized private store.
- Approve one standard or custom GEDCOM mapping for each category.
- Define the rules for dates, approximate values, places, and descriptions.
- Document fields that will remain private-archive-only.

### Phase 2: Export standard structured events

- Add burial, residence, education, occupation, immigration, and emigration.
- Add generic `EVEN` plus `TYPE` output for other supported events.
- Preserve stable FamSpam event IDs where needed for round trips.

### Phase 3: Sources and diagnostics

- Export source records and event citations.
- Produce an export report listing any omitted or downgraded data.
- Add checks for duplicate identifiers and invalid GEDCOM line values.

### Phase 4: Round-trip import

- Import the supported event mappings back into canonical FamSpam events.
- Merge conservatively with existing birth, death, and family events.
- Test exports through the genealogy applications that family members are
  expected to use.

## Acceptance Criteria

- Birth and death appear exactly once after a FamSpam → GEDCOM → FamSpam round
  trip.
- Supported non-core events retain their type, date, place, description, and
  sources.
- Unsupported fields are listed in an explicit export/import diagnostic.
- Topola continues to render the same 147-person relationship graph.
- GEDCOM validates against the selected GEDCOM version.
- Importing an exported GEDCOM never replaces or damages the existing private
  archive without review.
- The product clearly states that `.familyarchive`, not GEDCOM, is the complete
  backup and restoration format.

## Open Decisions

- Select GEDCOM 5.5.1, GEDCOM 7, or dual-version export as the target.
- Decide whether the default export language follows the app language or is an
  explicit export option.
- Define custom tag names for FamSpam event and source identities.
- Decide whether bilingual event content belongs in custom GEDCOM tags or only
  in a GEDZIP sidecar.
- Select third-party genealogy applications for compatibility testing.
