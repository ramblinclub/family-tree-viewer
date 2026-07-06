# Tests

This suite now targets the static family-tree site behavior.

## Functional E2E

- `chart_view.spec.ts`: verifies the configured static GEDCOM loads, renders,
  and responds to person selection.
- `search.spec.ts`: verifies search and the global `/` shortcut.

## Visual Regression

- `charts_visual.spec.ts`: captures the retained chart modes.
- `details_visual.spec.ts`: captures the info-only details panel, including
  media rendering/fallback behavior.

## Helpers

- `helpers.ts`: mocks `family.ged`, blocks analytics, and injects stable fonts
  for visual tests.

## Commands

```bash
npm run test:e2e
npm run test:visual
npm run test:visual:update
```
