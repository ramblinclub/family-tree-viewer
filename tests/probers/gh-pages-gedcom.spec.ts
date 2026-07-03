import {expect, test} from '@playwright/test';

/**
 * Prober: GitHub Pages GEDCOM via CORS proxy
 *
 * Loads a GEDCOM file from a raw GitHub URL through the app deployed on
 * pewu.github.io. Because the app is not on the apps.wikitree.com domain,
 * GEDCOM URL requests are routed through the CORS proxy
 * (topolaproxy.bieda.it) by default. This exercises the GitHub Pages
 * deployment, the CORS proxy, and GEDCOM-from-URL loading.
 */
test('GitHub Pages GEDCOM prober', async ({page}) => {
  await page.goto(
    'https://pewu.github.io/topola-viewer/#/view?url=https://raw.githubusercontent.com/PeWu/topola-viewer/master/src/datasource/testdata/test.ged&indi=I1',
  );

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
