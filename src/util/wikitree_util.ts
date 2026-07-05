/**
 * Base URL for Topola Viewer hosted on apps.wikitree.com.
 * WikiTree API calls only work when the app is served from this domain.
 */
export const WIKITREE_TOPOLA_URL =
  'https://apps.wikitree.com/apps/wiech13/topola-viewer';

/**
 * Returns true if the app is currently hosted on the apps.wikitree.com domain.
 *
 * WikiTree's API requires being served from this domain due to authentication
 * and CORS restrictions. When not on this domain, WikiTree data loading does
 * not work.
 */
export function isOnWikitreeDomain(): boolean {
  return window.location.hostname === 'apps.wikitree.com';
}
