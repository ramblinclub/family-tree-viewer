import {test} from '@playwright/test';

import {runProber} from './helpers';

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
  await runProber(page, {
    url: 'https://pewu.github.io/topola-viewer/#/view?url=https://raw.githubusercontent.com/PeWu/topola-viewer/master/src/datasource/testdata/test.ged&indi=I1',
    expectedName: 'Bonifacy',
  });
});
