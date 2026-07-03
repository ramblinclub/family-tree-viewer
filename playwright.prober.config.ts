import {defineConfig, devices} from '@playwright/test';

/**
 * Playwright configuration for prober (live smoke) tests.
 *
 * Unlike the main playwright.config.ts, this config:
 * - Does not start a local dev server (specs navigate to absolute URLs).
 * - Runs tests sequentially to avoid rate-limiting external APIs.
 * - Enforces forbidOnly unconditionally (probers always run in CI).
 * - Captures screenshots, video, and traces for debugging live failures.
 */
export default defineConfig({
  testDir: './tests/probers',
  fullyParallel: false,
  forbidOnly: true,
  retries: 2,
  timeout: 120000,
  reporter: [['html', {open: 'never'}], ['list']],
  use: {
    locale: 'en-US',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'on-first-retry',
  },
  projects: [
    {
      name: 'prober',
      use: {
        ...devices['Desktop Chrome'],
      },
    },
  ],
});
