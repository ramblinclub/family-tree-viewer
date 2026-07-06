import {useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {IntlShape} from 'react-intl';
import {useLocation, useNavigate} from 'react-router';
import {IndiInfo} from 'topola';
import {SourceSelection} from '../datasource/data_source';
import {gedcomUrlDataSource} from '../datasource/instances';
import {
  getSelection,
  revokeObjectUrls,
  UrlSourceSpec,
} from '../datasource/load_data';
import {AppState} from '../pages/view_page';
import {getI18nMessage} from '../util/error_i18n';
import {TopolaData} from '../util/gedcom_util';
import {DataSourceSpec, getArguments} from '../util/url_args';

/**
 * Custom React hook that orchestrates loading genealogy data from various sources
 * (Uploaded files, Google Drive, WikiTree API, URL params, or Embedded data).
 * It manages the async lifecycle, error boundary popups, and incremental WikiTree loading.
 */
export function useGenealogyLoader(options: {
  intl: IntlShape;
  urlSelection?: IndiInfo;
  urlDetail?: string;
}) {
  const {intl, urlSelection, urlDetail} = options;
  const navigate = useNavigate();
  const location = useLocation();

  const [state, setState] = useState<AppState>(AppState.INITIAL);
  const [loadingStatus, setLoadingStatus] = useState('Loading…');
  const [data, setData] = useState<TopolaData>();
  const [error, setError] = useState<string>();
  const [showErrorPopup, setShowErrorPopup] = useState(false);
  const [sourceSpec, setSourceSpec] = useState<DataSourceSpec>();

  const isMountedRef = useRef(true);
  const fetchIdRef = useRef(0);
  const loadedSelectionRef = useRef<IndiInfo>();

  useEffect(() => {
    isMountedRef.current = true;
    return () => {
      isMountedRef.current = false;
    };
  }, []);

  const isNewData = useCallback(
    (newSourceSpec: DataSourceSpec, newSelection?: IndiInfo) => {
      if (!sourceSpec || sourceSpec.source !== newSourceSpec.source) {
        return true;
      }
      const newSource = {spec: newSourceSpec, selection: newSelection};
      const oldSource = {
        spec: sourceSpec,
        selection: loadedSelectionRef.current,
      };
      return gedcomUrlDataSource.isNewData(
        newSource as SourceSelection<UrlSourceSpec>,
        oldSource as SourceSelection<UrlSourceSpec>,
        data,
      );
    },
    [sourceSpec, data],
  );

  const loadData = useCallback(
    (
      newSourceSpec: DataSourceSpec,
      newSelection?: IndiInfo,
      onProgress?: (status: string) => void,
    ) => {
      return gedcomUrlDataSource.loadData(
        {spec: newSourceSpec as UrlSourceSpec, selection: newSelection},
        onProgress,
      );
    },
    [],
  );

  const setErrorMessage = useCallback((message: string) => {
    setError(message);
    setState(AppState.ERROR);
  }, []);

  const displayErrorPopup = useCallback((message: string) => {
    setShowErrorPopup(true);
    setError(message);
  }, []);

  const onDismissErrorPopup = useCallback(() => {
    setShowErrorPopup(false);
  }, []);

  const resetLoader = useCallback(() => {
    setState(AppState.INITIAL);
  }, []);

  const clearData = useCallback(() => {
    setData(undefined);
    loadedSelectionRef.current = undefined;
  }, []);

  const shouldTriggerNewLoad = useCallback(
    (newSourceSpec: DataSourceSpec, newSelection?: IndiInfo) => {
      return (
        (state === AppState.INITIAL ||
          isNewData(newSourceSpec, newSelection)) &&
        state !== AppState.LOADING &&
        state !== AppState.LOADING_MORE
      );
    },
    [state, isNewData],
  );

  const triggerNewLoad = useCallback(
    async (newSourceSpec: DataSourceSpec, newSelection?: IndiInfo) => {
      setState(AppState.LOADING);
      setSourceSpec(newSourceSpec);
      loadedSelectionRef.current = newSelection;
      const currentFetchId = ++fetchIdRef.current;
      setLoadingStatus('Loading…');
      try {
        const data = await loadData(newSourceSpec, newSelection, (status) => {
          if (isMountedRef.current) setLoadingStatus(status);
        });
        if (!isMountedRef.current || fetchIdRef.current !== currentFetchId) {
          return;
        }
        setLoadingStatus(
          `Rendering chart (${data.chartData.indis.length.toLocaleString()} people)…`,
        );
        setData(data);
        loadedSelectionRef.current = getSelection(data.chartData, newSelection);
        setState(AppState.SHOWING_CHART);
      } catch (error: unknown) {
        if (!isMountedRef.current || fetchIdRef.current !== currentFetchId) {
          return;
        }
        setErrorMessage(getI18nMessage(error as Error, intl));
      }
    },
    [intl, loadData, setErrorMessage],
  );

  // Main data loading and updating side-effect
  useEffect(() => {
    if (location.pathname !== '/view') {
      if (state !== AppState.INITIAL) {
        setState(AppState.INITIAL);
      }
      setData(undefined);
      return;
    }

    const args = getArguments(location);
    if (!args.sourceSpec) {
      navigate({pathname: '/'}, {replace: true});
      return;
    }

    if (shouldTriggerNewLoad(args.sourceSpec, args.selection)) {
      triggerNewLoad(args.sourceSpec, args.selection);
    } else if (state === AppState.LOADING_MORE) {
      setState(AppState.SHOWING_CHART);
    }
  }, [location, state, navigate, shouldTriggerNewLoad, triggerNewLoad]);

  // Clean up object URLs created for uploaded images/files when the dataset
  // changes or the app unmounts to prevent memory leaks.
  useEffect(() => {
    return () => {
      revokeObjectUrls(data?.images);
    };
  }, [data]);

  const updatedSelection = useMemo(() => {
    return data ? getSelection(data.chartData, urlSelection) : undefined;
  }, [data, urlSelection]);

  const detailIndi = urlDetail || updatedSelection?.id;

  return {
    state,
    loadingStatus,
    data,
    error,
    showErrorPopup,
    sourceSpec,
    updatedSelection,
    detailIndi,
    loadedSelectionRef,
    onDismissErrorPopup,
    resetLoader,
    clearData,
    setLoadingStatus,
    displayErrorPopup,
  };
}
