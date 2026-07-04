import {test} from '@playwright/test';

import {runProber} from './helpers';

/**
 * Prober: Docker container
 *
 * Pulls the Docker image published to GHCR, runs it locally with the test
 * GEDCOM file mounted via STATIC_URL, and verifies that the containerized
 * application starts and renders data. This exercises the Docker build path
 * (multi-stage Dockerfile, Caddy server configuration, static URL template
 * injection) and confirms the published container image is functional.
 *
 * The workflow starts the container externally (via `docker run`) before
 * this test runs, so Playwright connects to localhost:8080 directly.
 *
 * If the Docker container is not running (e.g., when running probers locally
 * without Docker), this test is skipped with a clear message rather than
 * failing with a confusing connection error.
 */
test('Docker container prober', async ({page}) => {
  // Guard: verify the Docker container is reachable before running the
  // prober. When running locally without Docker, this produces a clear
  // skip message instead of a confusing ECONNREFUSED failure.
  // page.request.get throws on connection refused (rather than returning a
  // non-OK response), so we catch the error and skip.
  let containerReachable = false;
  try {
    const response = await page.request.get('http://localhost:8080/', {
      timeout: 5_000,
    });
    containerReachable = response.ok();
  } catch {
    containerReachable = false;
  }
  test.skip(
    !containerReachable,
    'Docker container is not reachable on localhost:8080 — start it with: ' +
      'docker run -d -p 8080:8080 -e STATIC_URL=test.ged ' +
      '-v $(pwd)/src/datasource/testdata/test.ged:/app/public/test.ged ' +
      'ghcr.io/pewu/topola-viewer:latest',
  );

  await runProber(page, {
    url: 'http://localhost:8080/',
    expectedName: 'Bonifacy',
  });
});
