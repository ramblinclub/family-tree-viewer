import {expect, type Page} from '@playwright/test';

/**
 * Registers console, page-error, and network-failure listeners on the given
 * page. Playwright captures these in trace files, but also printing them to
 * stdout makes them visible in the GitHub Actions log — essential for
 * debugging live-URL prober failures where the failure is hard to reproduce.
 *
 * Listeners are registered once per page and remain active for the test's
 * lifetime.
 */
export function captureDiagnostics(page: Page): void {
  page.on('console', (msg) => {
    const type = msg.type();
    if (type === 'error' || type === 'warning') {
      console.log(`[browser ${type}] ${msg.text()}`);
    }
  });
  page.on('pageerror', (err) => {
    console.log(`[page error] ${err.message}`);
  });
  page.on('requestfailed', (req) => {
    const failure = req.failure();
    console.log(
      `[request failed] ${req.url()} — ${failure?.errorText ?? 'unknown'}`,
    );
  });
}

export interface ProberOptions {
  /** Full URL to navigate to. */
  url: string;
  /** Expected person name to assert appears in the chart and side panel. */
  expectedName: string;
  /**
   * Optional navigation timeout in milliseconds. Defaults to 60s — separate
   * from the test-level timeout so a hung navigation doesn't eat the entire
   * test budget before assertions even begin.
   */
  navigationTimeout?: number;
}

/**
 * Runs the standard prober flow against a live URL:
 *
 * 1. Navigate to the target URL.
 * 2. Wait for #content (data-testid="content") to be visible — indicates the
 *    app reached SHOWING_CHART state.
 * 3. Assert the expected person's name appears in the chart SVG.
 * 4. Assert the expected person's name appears in the side panel details.
 * 5. Assert no fatal error message is displayed.
 * 6. Assert no popup error is displayed.
 *
 * All selectors use `data-testid` attributes for stability — they survive
 * CSS class refactors and Semantic UI React internal changes.
 */
export async function runProber(
  page: Page,
  options: ProberOptions,
): Promise<void> {
  const {url, expectedName, navigationTimeout = 60_000} = options;

  captureDiagnostics(page);

  // Use 'domcontentloaded' instead of the default 'load' so we don't wait
  // for analytics scripts and third-party resources that are irrelevant to
  // the prober's assertions.
  await page.goto(url, {
    waitUntil: 'domcontentloaded',
    timeout: navigationTimeout,
  });

  // Wait for the app to reach SHOWING_CHART state. #content becomes visible
  // before the D3 chart SVG is populated — the subsequent #chart text
  // assertion relies on Playwright's auto-wait to bridge this gap.
  //
  // Selectors use a union of data-testid and legacy CSS/ID selectors so the
  // prober works against both the currently deployed app (which predates
  // data-testid) and future deployments that include the attributes.
  const content = page.locator('[data-testid="content"], #content');
  const chart = page.locator('[data-testid="chart"], #chart');
  const details = page.locator('[data-testid="details"], div.details');
  const errorMessage = page.locator(
    '[data-testid="error-message"], .ui.error.message',
  );
  const errorPopup = page.locator(
    '[data-testid="error-popup"], .ui.errorPopup.message',
  );

  await expect(content).toBeVisible();

  // Assert the expected person's name appears in the chart SVG.
  await expect(chart).toContainText(expectedName);

  // Assert the expected person's name appears in the side panel.
  await expect(details).toContainText(expectedName);

  // Assert no fatal error is displayed (replaces chart when state is ERROR).
  await expect(errorMessage).not.toBeVisible();

  // Assert no popup error is displayed. ErrorPopup uses Semantic UI React's
  // <Portal>, which renders at document.body level — these locators search
  // the entire document, so this works regardless of DOM nesting.
  await expect(errorPopup).not.toBeVisible();
}
