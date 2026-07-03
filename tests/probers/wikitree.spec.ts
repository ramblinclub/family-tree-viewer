import {expect, test} from '@playwright/test';

/**
 * Prober: WikiTree direct API
 *
 * Loads a known WikiTree profile (Skłodowska-2) from the app deployed on
 * apps.wikitree.com. Because the app is on the apps.wikitree.com domain,
 * WikiTree API calls go direct (no CORS proxy). This exercises the WikiTree
 * direct API path and confirms the WikiTree deployment is healthy.
 */
test('WikiTree direct API prober', async ({page}) => {
  await page.goto(
    'https://apps.wikitree.com/apps/wiech13/topola-viewer/#/view?source=wikitree&indi=Sk%C5%82odowska-2',
  );

  // Wait for the app to reach SHOWING_CHART state.
  await expect(page.locator('#content')).toBeVisible();

  // Assert the expected person's name appears in the chart SVG.
  await expect(page.locator('#chart')).toContainText('Skłodowska');

  // Assert the expected person's name appears in the side panel.
  // Scoped to div.details to avoid matching <text class="details sex"> SVG
  // elements in the chart that also carry the "details" class.
  await expect(page.locator('div.details')).toContainText('Skłodowska');

  // Assert no fatal error is displayed (replaces chart when state is ERROR).
  await expect(page.locator('.ui.error.message')).not.toBeVisible();

  // Assert no popup error is displayed.
  // ErrorPopup uses Semantic UI React's <Portal>, which renders at
  // document.body level, not inside #content.
  await expect(page.locator('.ui.errorPopup.message')).not.toBeVisible();
});
