import {test} from '@playwright/test';

import {runProber} from './helpers';

/**
 * Prober: WikiTree GEDCOM + CORS proxy
 *
 * Loads a GEDCOM file from a raw GitHub URL through the app deployed on
 * apps.wikitree.com. Even though the app is on the WikiTree domain,
 * GEDCOM-from-URL always uses the CORS proxy by default. This confirms
 * the CORS proxy is reachable from the WikiTree deployment.
 */
test('WikiTree CORS proxy prober', async ({page}) => {
  await runProber(page, {
    url: 'https://apps.wikitree.com/apps/wiech13/topola-viewer/#/view?url=https://raw.githubusercontent.com/PeWu/topola-viewer/master/src/datasource/testdata/test.ged&indi=I1',
    expectedName: 'Bonifacy',
  });
});
