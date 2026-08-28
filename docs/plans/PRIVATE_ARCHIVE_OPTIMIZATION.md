# Private Archive Size and Performance Plan

**Status:** Deferred for later implementation  
**Baseline measured:** August 28, 2026

## Objective

Make routine FamSpam private archive exports substantially smaller and make
export and import faster, while preserving a full-fidelity backup option. The
canonical people, family relationships, stories, and other structured data must
remain lossless in every archive mode.

## Current Baseline

The measured private store is approximately 645 MB:

| Content | Approximate size | Share |
| --- | ---: | ---: |
| Photos and other images | 508 MB | 79% |
| Documents | 132 MB | 20% |
| People, relationships, stories, GEDCOM, and manifests | 4 MB | <1% |

Additional findings:

- 53 files are exact duplicates, wasting approximately 49.6 MB.
- Editable `.pages` documents use approximately 98.3 MB.
- PDF documents use approximately 33.9 MB.
- Most photos, PDFs, and Pages files are already compressed, so wrapping the
  existing payload in ZIP or another general-purpose compressor will not
  produce the main reduction.
- The current FAR1 archive is uncompressed and is first written to a temporary
  file. iOS then copies that completed file to the location selected in Files.
  Import also performs multiple full-file/storage passes. These copies increase
  elapsed time and temporary free-space requirements.

## Proposed Export Modes

### Data only

Expected size: approximately 4–5 MB.

Include all people, explicit family unions and parent-child relationships,
stories, metadata, and GEDCOM-compatible tree data. Exclude binary media and
documents. This mode is intended for fast tree transfer and diagnostics.

### Portable archive (recommended default)

Expected size: approximately 150–300 MB with the current collection. The exact
result must be measured after implementation.

Include all structured data, optimized display copies of images, and portable
documents. Preserve the original media in the app's private store; optimization
must occur only while constructing the export.

Suggested policy:

- Limit exported images to a 2048–2560 pixel longest edge.
- Encode photo copies as HEIC or JPEG at roughly 0.80–0.85 quality after visual
  quality testing.
- Preserve PNG only when transparency or lossless image content requires it.
- Prefer PDF when an equivalent `.pages` and PDF document both exist.
- Allow editable Pages originals to be included through an explicit option.
- Store identical content once and reference it from every person or story that
  uses it.

### Full-fidelity backup

Expected size: approximately the current 645 MB before deduplication.

Include every original asset and document without resizing or transcoding. Use
content deduplication where it can preserve all logical references exactly.
This remains the disaster-recovery and archival option.

## Archive Format Changes

Introduce a content-addressed asset index:

1. Calculate a SHA-256 digest for each binary asset.
2. Write each unique binary payload once, keyed by its digest.
3. Record logical references from people, stories, and documents to the digest.
4. Store size, media type, original filename, and integrity information in the
   archive manifest.
5. On import, retain shared assets in a common asset store or safely reconstruct
   the expected logical references.

The measured collection would save about 49.6 MB from exact deduplication
alone. The format must remain versioned, and the importer must continue to read
existing FAR1 archives.

Compression should be selected per entry:

- Compress JSON, GEDCOM, and other text metadata.
- Store JPEG, HEIC, PNG, PDF, Pages, video, and audio without an additional
  compression pass unless measurement shows a worthwhile benefit.
- Include checksums so truncated or corrupted archives fail with a specific
  diagnostic.

## Export and Import Performance

### Export

- Avoid constructing and then copying a second complete archive when iOS APIs
  permit direct streaming to the destination selected by the user.
- Stream files and transformations incrementally instead of loading whole media
  files or the archive into memory.
- Cache asset hashes so unchanged files are not repeatedly hashed for every
  export.
- Show byte-based progress, the current phase, cancellation, and an estimated
  output size before export begins.
- Check available temporary and destination space before starting.

### Import

- Validate the manifest and entry checksums while streaming.
- Import into a staging store and atomically replace the active store only after
  validation succeeds.
- Avoid retaining both an unnecessary local archive copy and a complete
  extracted copy longer than required.
- Report progress by bytes and distinguish validation, metadata import, media
  import, and finalization.
- Preserve the current store after any cancellation, malformed archive, missing
  asset, checksum failure, or insufficient-space error.

## Delivery Phases

### Phase 1: User-visible archive choices

- Add Data only, Portable archive, and Full-fidelity backup choices.
- Make Portable archive the normal default and clearly label Full backup.
- Calculate and display an estimated size before export.
- Add progress, cancellation, and free-space preflight checks.

### Phase 2: Portable media and document policy

- Generate non-destructive resized image copies during portable export.
- Detect equivalent Pages/PDF documents and prefer PDF by default.
- Add visual quality and metadata round-trip tests.

### Phase 3: Deduplicated, versioned archive format

- Add the content-addressed asset index and per-entry checksums.
- Keep backward-compatible FAR1 importing.
- Verify that shared photos and documents still appear for every associated
  person after a complete export/import round trip.

### Phase 4: Streaming and incremental backups

- Reduce temporary copies by streaming directly when supported by the selected
  Files provider.
- Add incremental backups that contain only structured-data changes and new or
  changed assets since a chosen full backup.
- Define restore behavior when an incremental archive's required base backup is
  missing or does not match.

## Acceptance Criteria

- Every export mode contains all 147 people and the canonical family unions.
- Importing any supported archive produces the same relationship graph and
  structured details as the source store.
- Portable export never modifies or replaces original assets in the app.
- Full-fidelity export retains every original byte, aside from deduplicated
  storage of identical content.
- Repeated logical references to a deduplicated asset survive export and import.
- Old FAR1 archives remain importable.
- Failed or cancelled imports leave the existing private store unchanged.
- Tests cover empty stores, duplicate assets, large individual files, corrupt
  entries, interrupted operations, and insufficient storage.
- Final device measurements record output size, export duration, import
  duration, peak memory, and temporary disk usage for each mode.

## Open Decisions for Implementation

- Choose HEIC versus JPEG for portable image copies based on compatibility and
  measured quality/size on supported iOS versions.
- Decide whether portable archives include documents without a PDF equivalent
  in their original format or require conversion.
- Determine which iOS document-provider APIs can reliably support direct
  streaming across iCloud Drive and third-party Files providers.
- Decide whether asset deduplication exists only inside archives or also becomes
  the on-device private-store representation.
- Define the incremental-backup base identity, retention policy, and user-facing
  restore workflow.
