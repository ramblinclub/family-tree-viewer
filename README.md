# Family Tree Viewer

This is a static family-tree website forked from
[Topola Genealogy Viewer](https://github.com/PeWu/topola-viewer). It keeps the
GEDCOM/GDZ loading pipeline and chart renderers, but removes the general-purpose
viewer shell in favor of one preconfigured family site.

## What This Fork Keeps

- Static GEDCOM or GDZ loading through `VITE_STATIC_URL`
- Existing chart modes: hourglass, all relatives, Donatso, and fancy tree
- Search within the loaded family tree
- Selected-person URL state
- Info-only details side panel
- Print and SVG/PNG/PDF export for chart modes that support it
- GEDZIP media plumbing for a later photo milestone

## What This Fork Disables

- Visitor file upload
- Arbitrary "load from URL" UI
- WikiTree integration
- Google Drive integration
- Embedded/WebMCP runtime integration
- User-facing chart configuration side panel
- Docker/Caddy packaging

## Development

Install dependencies and run the app with a static GEDCOM or GDZ URL:

```bash
npm install
VITE_STATIC_URL=https://example.org/family.ged npm start
```

For local testing, `VITE_STATIC_URL` may point to any GEDCOM or GDZ file served
by your dev server, test route, S3 bucket, or CDN.

## Static Build

Build the static site with the same URL configured:

```bash
VITE_STATIC_URL=https://cdn.example.org/family.gdz npm run build
```

Upload the generated `dist/` directory to S3, CloudFront, or any static hosting
provider. There is no server-side application code.

## Tests

```bash
npm test
npm run test:e2e
npm run test:visual
```

The Playwright suite is reduced to the static-family-site behavior. Legacy
integration flows are excluded from the default projects.

## Photo Roadmap

Photo support is intentionally deferred. The existing pipeline already preserves
GEDCOM media references and can resolve files from GDZ archives. The next step
is to choose one production packaging model:

- GDZ bundle containing the GEDCOM and referenced photo files
- Static photo URLs referenced directly by the GEDCOM and hosted on S3/CDN

## License

This fork remains available under the Apache License 2.0. See
[LICENSE](LICENSE).
