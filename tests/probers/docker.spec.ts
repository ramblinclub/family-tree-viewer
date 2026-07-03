import {expect, test} from '@playwright/test';

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
 */
test('Docker container prober', async ({page}) => {
  await page.goto('http://localhost:8080/');

  // Wait for the app to reach SHOWING_CHART state.
  await expect(page.locator('#content')).toBeVisible();

  // Assert the expected person's name appears in the chart SVG.
  await expect(page.locator('#chart')).toContainText('Bonifacy');

  // Assert the expected person's name appears in the side panel.
  // Scoped to div.details to avoid matching <text class="details sex"> SVG
  // elements in the chart that also carry the "details" class.
  await expect(page.locator('div.details')).toContainText('Bonifacy');

  // Assert no fatal error is displayed (replaces chart when state is ERROR).
  await expect(page.locator('.ui.error.message')).not.toBeVisible();

  // Assert no popup error is displayed.
  // ErrorPopup uses Semantic UI React's <Portal>, which renders at
  // document.body level, not inside #content.
  await expect(page.locator('.ui.errorPopup.message')).not.toBeVisible();
});
