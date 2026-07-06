# GitHub Workflows

- `node.js.yml`: install, lint, build, unit test, and run the reduced
  Playwright suite.
- `deploy-gh-pages.yml`: optional static deployment. Set the
  `FAMILY_TREE_URL` repository secret to the GEDCOM or GDZ URL that should be
  baked into the static build.
- `codeql-analysis.yml`: CodeQL security analysis.
