import {useCallback, useMemo} from 'react';
import {useLocation, useNavigate} from 'react-router';
import {IndiInfo} from 'topola';
import {analyticsEvent} from '../util/analytics';
import {getArguments, getUrlForArgs} from '../util/url_args';

/**
 * Custom React hook to manage and synchronize URL routing and query parameter state
 * for the genealogy chart workspace.
 */
export function useUrlState() {
  const location = useLocation();
  const navigate = useNavigate();

  // Parse all URL arguments memoized on location changes.
  const args = useMemo(() => getArguments(location), [location]);

  /**
   * Helper to update the browser URL query parameters.
   */
  const updateUrl = useCallback(
    (
      newArgs: Record<string, string | (string | null)[] | null | undefined>,
      options?: {replace?: boolean},
    ) => {
      navigate(getUrlForArgs(location, newArgs), options);
    },
    [location, navigate],
  );

  /**
   * Called when the user clicks an individual box in the chart.
   * Updates the browser URL with the new primary individual selection.
   */
  const onSelection = useCallback(
    (selection: IndiInfo) => {
      analyticsEvent('selection_changed');
      updateUrl({
        indi: selection.id,
        gen: String(selection.generation),
        detail: null,
      });
    },
    [updateUrl],
  );

  /**
   * Called when the user shift+clicks an individual box in the chart.
   * Shows the individual in the details pane.
   */
  const onDetailSelection = useCallback(
    (selection: IndiInfo) => {
      updateUrl({
        detail: selection.id,
      });
    },
    [updateUrl],
  );

  /**
   * Toggles the side panel expansion state.
   */
  const onToggleSidePanel = useCallback(() => {
    const newShowSidePanel = !args.showSidePanel;
    updateUrl(
      {
        sidePanel: newShowSidePanel ? 'true' : 'false',
      },
      {replace: true},
    );
  }, [args.showSidePanel, updateUrl]);

  return {
    args,
    chartType: args.chartType,
    standalone: args.standalone,
    freezeAnimation: args.freezeAnimation,
    showSidePanel: args.showSidePanel,
    config: args.config,
    sourceSpec: args.sourceSpec,
    selection: args.selection,
    detail: args.detail,
    updateUrl,
    onSelection,
    onDetailSelection,
    onToggleSidePanel,
  };
}
