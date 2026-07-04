import {test} from '@playwright/test';

import {runProber} from './helpers';

/**
 * Prober: WikiTree direct API
 *
 * Loads a known WikiTree profile (Skłodowska-2) from the app deployed on
 * apps.wikitree.com. Because the app is on the apps.wikitree.com domain,
 * WikiTree API calls go direct (no CORS proxy). This exercises the WikiTree
 * direct API path and confirms the WikiTree deployment is healthy.
 */
test('WikiTree direct API prober', async ({page}) => {
  await runProber(page, {
    url: 'https://apps.wikitree.com/apps/wiech13/topola-viewer/#/view?source=wikitree&indi=Sk%C5%82odowska-2',
    expectedName: 'Skłodowska',
  });
});
