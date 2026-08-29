# Edit Data Translation and Review Plan

**Status:** Planned
**Created:** August 28, 2026

## Purpose

FamSpam stores private, user-authored content in both English and Russian. An
edit made in either language must not leave the other language stale, silently
replace it with an unreviewed translation, or cause mixed-language
content to appear on a screen.

This plan applies to:

- Profile fields
- Media captions
- Life events
- Notes
- Profile summaries when summary editing is added

It does not apply to app labels or controlled values such as “Photo,” “Born,”
and “Died.” Those belong to the app's normal interface localization.

## Core Rule

The language in which the user edits is the source version for that revision.
After the user saves the edit, FamSpam adds the other-language version to the
separate **To review** list. The user writes that counterpart manually.

The user can then:

1. **Save the translation** — save the source and the reviewed counterpart
   together and clear the translation-review issue for those fields.
2. **Review later** — preserve the source edit and create a precise review
   issue without changing the stored source.

The selected-language screen uses the complete source text as a fallback while
the counterpart is missing, and the affected record remains marked for review.
The app must never show “translation pending” in place of the user's content.

## Edit Workflow

### 1. Edit the selected language

- The editor opens in the currently selected app language.
- Only user-authored fields are editable and sent for translation.
- Existing content in the other language remains available until a replacement
  has been entered and reviewed.

### 2. Save the source revision

- Validate required fields and record-specific rules.
- Assign a revision identifier or content hash to the edit.
- Preserve the source edit before the counterpart is reviewed so leaving the
  review screen cannot discard the user's work.

### 3. Queue the counterpart for review

- Queue only changed translatable fields.
- Preserve structured tokens such as person mentions, links, dates,
  identifiers, and other language-neutral metadata in the review editor.
- Never translate on screen load or during save. Both language versions are
  stored only after a person supplies and saves the counterpart.

### 4. Present translation review

Show the source and an editable counterpart field together. The user supplies
the counterpart before saving it.

The review screen offers two clear actions:

- **Save translation**
- **Review later**

Closing the review is treated as **Review later** after the source edit has
been preserved. Cancelling before the original edit is saved continues to
discard the entire edit normally.

### 5. Store the outcome

For a saved counterpart:

- Store both language versions.
- Mark the translated fields as reviewed for the current revision.
- Remove the corresponding review issue.

For review later:

- Store the source version.
- Record the source language, record type, record ID, field, revision, and
  reason requiring review.
- Flag the affected profile or profiles until the issue is resolved.

## Review Status and Queue

Translation status belongs to the edited record and field, not merely to the
profile. A profile-level warning is derived from its unresolved record issues.
This makes the warning actionable and prevents every profile from being marked
because of harmless controlled labels.

The separate translation-review view should show:

- Person or people affected
- Record type: Profile, Caption, Event, Note, or Summary
- Exact field requiring attention
- Source language and source text
- Source text and an editable counterpart field
- Date and author of the edit

The family list must display a visible warning on affected people and support
filtering to **Needs translation review**.

Existing accepted English and Russian data remains accepted. A migration or
audit must not mark all profiles merely because old records lack new review
metadata.

## Record-Specific Rules

### Profile

- Translate and review genuinely user-authored fields, including custom
  biography text and future summaries.
- Names use their stored English and Russian/transliterated values and follow
  the same review workflow when edited.
- A failed or deferred translation flags that profile.

### Media captions

- Mentions in every language must resolve to exactly the same person IDs.
- Translate the prose around mentions, but protect canonical mention tokens.
- Caption dates remain derived metadata and are not appended as separate text
  by the editor.
- A caption issue flags every mentioned profile. Unmentioned media remains in
  the media translation-review queue without inventing a profile association.

### Life events

- Translate custom titles and descriptions, not localized category labels.
- A canonical shared event is edited once; its translations remain attached to
  that event rather than copied into separate per-person events.
- An unresolved shared event flags every participating profile.

### Notes

- Translate and review the Note text while preserving links and structured
  mentions.
- Only the account that originally recorded a Note may edit it unless a later
  permissions design explicitly expands that rule.
- An unresolved Note flags its subject profile.

### Summary

- When summary editing is introduced, use this workflow from the first release.
- Do not add a separate summary-only translation mechanism.

## Display Rules

- Display only the selected-language approved version when it exists.
- Never combine English and Russian fragments to construct one field.
- When the selected-language version is unavailable or awaiting review, display
  the complete source-language field as a fallback and show a visible review
  warning.
- Dates, URLs, IDs, and other language-neutral values may be shared.

## Validation Before Approval

Before **Save both languages** succeeds, validate that:

- Both required language versions are present.
- The entered counterpart belongs to the current source revision.
- Captions contain the same resolved mention set in both languages.
- Links and protected tokens survived translation.
- The translation does not contain unexpected mixed-language fragments, while
  allowing names, places, quotations, and other intentional exceptions.

Validation should explain the exact problem and keep the review editor open.
The user can correct the translation or choose **Review later**.

## Implementation Order

1. Define shared bilingual field, revision, draft, and review-issue storage.
2. Build one reusable translation review screen and save coordinator.
3. Adopt it in Profile editing.
4. Adopt it in Caption editing, including strict mention validation.
5. Adopt it in Event editing, including shared-event ownership.
6. Adopt it in Note editing and enforce author permissions.
7. Use it for Summary editing when that editor is added.
8. Add the profile warning, family-list filter, and separate review queue.
9. Migrate existing records as accepted and test EN/RU editing end to end.

## Acceptance Criteria

- Editing in English or Russian never leaves the other stored version silently
  stale.
- No automatic translation is created during editing or screen loading.
- Choosing **Review later** never loses the source edit.
- Approved edits store both languages and clear only the relevant issue.
- Deferred issues identify the exact record and field to review.
- The same workflow is used by Profile, Caption, Event, Note, and Summary
  editors.
- Captions cannot save conflicting person mentions across languages.
- Shared events cannot acquire inconsistent per-person translations.
- The selected-language screen never mixes languages unintentionally.
- No translation request is performed merely because a profile or screen was
  opened.
