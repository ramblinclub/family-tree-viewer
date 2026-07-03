# Prober Tests

These are **live smoke tests** that run against deployed URLs and external
services. They are NOT hermetic — they make real network requests to the
WikiTree API, CORS proxy, and GitHub raw URLs.

## Running

```bash
npm run test:probers
```

This uses the separate `playwright.prober.config.ts` configuration, which
does not start a local dev server. Each spec navigates to a full absolute
URL (or `localhost:8080` for the Docker prober).

## What They Test

| Spec | Target | Exercises |
| --- | --- | --- |
| `gh-pages-gedcom.spec.ts` | `pewu.github.io` | GitHub Pages deployment, CORS proxy, GEDCOM-from-URL |
| `wikitree.spec.ts` | `apps.wikitree.com` | WikiTree direct API, WikiTree deployment |
| `wikitree-cors-gedcom.spec.ts` | `apps.wikitree.com` | WikiTree deployment, CORS proxy via GEDCOM-from-URL |
| `docker.spec.ts` | `localhost:8080` | Published Docker image from GHCR |

## Notes

- Probers run sequentially (`fullyParallel: false`) to avoid rate-limiting.
- Each prober has its own GitHub Actions workflow for independent triggering.
- Probers do not block Google Analytics, so live runs generate real analytics events.
