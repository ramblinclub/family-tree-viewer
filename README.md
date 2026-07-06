# Family Tree Viewer

This is a static family-tree website forked from
[Topola Genealogy Viewer](https://github.com/PeWu/topola-viewer). It keeps the
GEDCOM/GDZ loading pipeline and chart renderers, but replaces the
general-purpose viewer shell with one preconfigured family site.

The app is built with React, TypeScript, Vite, Semantic UI React, and the
existing Topola/family-chart renderers.

## Project Scope

This fork is designed for a static website hosted from S3, CloudFront, GitHub
Pages, or another static host. It loads one configured family dataset at startup
and does not provide visitor upload or third-party integration flows.

Kept:

- Static GEDCOM or GDZ loading through `VITE_STATIC_URL`
- Existing chart modes: hourglass, all relatives, Donatso, and fancy tree
- Search within the loaded family tree
- Selected-person and chart-view URL state
- Info-only details side panel
- Print and SVG/PNG/PDF export for chart modes that support it
- GEDZIP media plumbing for a later photo milestone

Removed or disabled:

- Visitor file upload
- Arbitrary "load from URL" UI
- WikiTree integration
- Google Drive integration
- Embedded/WebMCP runtime integration
- User-facing chart configuration side panel
- Docker/Caddy packaging

## Requirements

- Node.js 24.x is used by CI
- npm
- Playwright Chromium for end-to-end and visual tests

Install dependencies:

```bash
npm install
```

Install Playwright's Chromium browser if it is not already installed:

```bash
npx playwright install chromium
```

## Static Data Configuration

The site reads the family data URL from `VITE_STATIC_URL` at build or dev-server
startup.

Examples:

```bash
VITE_STATIC_URL=/family.ged npm start
VITE_STATIC_URL=https://cdn.example.org/family.gdz npm run build
```

Supported inputs:

- `.ged` GEDCOM files
- `.gdz` / GEDZIP bundles
- Any same-origin or CORS-accessible URL that the browser can fetch

For local development, put private GEDCOM/GDZ files under `public/`. Files such
as `public/*.ged`, `public/*.gdz`, and `public/photos/` are gitignored so local
family data is not committed.

## Run Locally With Your GEDCOM

Copy your GEDCOM into Vite's `public/` folder:

```bash
cp "$HOME/Downloads/Big_Family2026.ged" public/Big_Family2026.ged
```

Start the dev server using that file:

```bash
VITE_STATIC_URL=/Big_Family2026.ged npm start
```

Open the local URL printed by Vite, usually:

```text
http://localhost:5173/
```

The app redirects to `/view` and loads the configured GEDCOM automatically.

Useful URL parameters while testing:

- `?view=hourglass`
- `?view=relatives`
- `?view=donatso`
- `?view=fancy`
- `?indi=@I123@` to select a person if you know the GEDCOM individual ID
- `?sidePanel=false` to hide the details side panel on desktop

Example:

```text
http://localhost:5173/view?view=relatives&sidePanel=false
```

## Build And Preview Locally

Build the production static files with the same data URL you plan to deploy:

```bash
VITE_STATIC_URL=/Big_Family2026.ged npm run build
```

Preview the built site locally:

```bash
npm run preview
```

For CDN/S3 production, build with the final hosted URL:

```bash
VITE_STATIC_URL=https://cdn.example.org/family/Big_Family2026.ged npm run build
```

Then upload `dist/` to your static host.

## Development Commands

```bash
npm start
npm run build
npm run preview
npm test
npm run lint
npm run test:e2e
npm run test:visual
npm run check:all
```

Notes:

- `npm start` runs Vite's development server.
- `npm run build` runs TypeScript and creates `dist/`.
- `npm run preview` serves the already-built `dist/` output.
- `npm test` runs Jest unit tests.
- `npm run test:e2e` runs the reduced Playwright static-site suite.
- `npm run test:visual` runs visual regression tests.
- `npm run check:all` runs formatting check, lint, build, unit tests, TypeScript
  test compilation, e2e tests, and visual tests.

## Deployment

The repository includes a GitHub Pages workflow at
`.github/workflows/deploy-gh-pages.yml`. It expects a repository or organization
secret named `FAMILY_TREE_URL`; that value is passed to the build as
`VITE_STATIC_URL`.

For S3/CloudFront, use the same build command locally or in CI, then upload
`dist/`:

```bash
VITE_STATIC_URL=https://cdn.example.org/family/Big_Family2026.ged npm run build
```

The deployed site is fully static. There is no server-side application runtime.

## Customization

Static app defaults live in `src/app_config.ts`:

- `SITE_TITLE` controls the title shown in the top bar.
- `STATIC_CHART_CONFIG` controls fixed chart display options.

The current UX shell lives mainly in:

- `src/menu/top_bar.tsx`
- `src/pages/view_page.tsx`
- `src/sidepanel/side-panel.tsx`
- `src/index.css`

Photo support is intentionally deferred. The existing data pipeline preserves
GEDCOM media references and can resolve files from GDZ archives. The next
production decision is whether photos should ship inside a GDZ bundle or be
referenced as static S3/CDN URLs from the GEDCOM.

## License

This fork remains available under the Apache License 2.0. See
[LICENSE](LICENSE).
