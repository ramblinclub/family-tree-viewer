import queryString from 'query-string';
import {FormattedMessage} from 'react-intl';
import {useLocation, useNavigate} from 'react-router';
import {Dropdown, Icon, Menu} from 'semantic-ui-react';
import {IndiInfo, JsonGedcomData} from 'topola';
import {SITE_TITLE} from '../app_config';
import {ChartType} from '../chart';
import {Media} from '../util/media';
import {SearchBar} from './search';
import {useSearch} from './use_search';

interface EventHandlers {
  onSelection: (indiInfo: IndiInfo) => void;
  onPrint: () => void;
  onDownloadPdf: () => void;
  onDownloadPng: () => void;
  onDownloadSvg: () => void;
}

interface Props {
  /** True if the application is currently showing a chart. */
  showingChart: boolean;
  /** Data used for the search index. */
  data?: JsonGedcomData;
  standalone: boolean;
  /** Whether to show the "All relatives" chart type in the menu. */
  allowAllRelativesChart?: boolean;
  allowPrintAndDownload?: boolean;
  eventHandlers?: EventHandlers;
  sourceUrl?: string;
}

const chartTypeLabels = new Map<ChartType, string>([
  [ChartType.Hourglass, 'Hourglass'],
  [ChartType.Relatives, 'All relatives'],
  [ChartType.Donatso, 'Donatso'],
  [ChartType.Fancy, 'Fancy'],
]);

function getSourceFileName(sourceUrl: string | undefined) {
  if (!sourceUrl || typeof window === 'undefined') {
    return null;
  }
  try {
    return new URL(sourceUrl, window.location.href).pathname.split('/').pop();
  } catch (_e) {
    return null;
  }
}

export function TopBar(props: Props) {
  const navigate = useNavigate();
  const location = useLocation();

  const {searchResults, searchString, setSearchString, handleResultSelect} =
    useSearch({
      data: props.data,
      onSelection: props.eventHandlers?.onSelection,
    });

  const search = queryString.parse(location.search);
  const currentChartType =
    search.view === 'relatives'
      ? ChartType.Relatives
      : search.view === 'donatso'
        ? ChartType.Donatso
        : search.view === 'fancy'
          ? ChartType.Fancy
          : ChartType.Hourglass;

  function changeView(view: string | null) {
    const nextSearch = queryString.parse(location.search);
    if (view) {
      nextSearch.view = view;
    } else {
      delete nextSearch.view;
    }
    navigate({
      pathname: location.pathname,
      search: queryString.stringify(nextSearch),
      hash: location.hash,
    });
  }

  function chartViewMenu() {
    if (!props.showingChart || !props.data) {
      return null;
    }
    return (
      <Dropdown
        trigger={
          <div>
            <Icon name="sitemap" />
            {chartTypeLabels.get(currentChartType)}
          </div>
        }
        className="item"
      >
        <Dropdown.Menu>
          <Dropdown.Item onClick={() => changeView(null)}>
            <Icon name="hourglass" />
            <FormattedMessage
              id="menu.hourglass"
              defaultMessage="Hourglass chart"
            />
          </Dropdown.Item>
          {props.allowAllRelativesChart ? (
            <Dropdown.Item onClick={() => changeView('relatives')}>
              <Icon name="users" />
              <FormattedMessage
                id="menu.relatives"
                defaultMessage="All relatives"
              />
            </Dropdown.Item>
          ) : null}
          <Dropdown.Item onClick={() => changeView('donatso')}>
            <Icon name="users" />
            <FormattedMessage
              id="menu.donatso"
              defaultMessage="Donatso family chart"
            />
          </Dropdown.Item>
          <Dropdown.Item onClick={() => changeView('fancy')}>
            <Icon name="users" />
            <FormattedMessage id="menu.fancy" defaultMessage="Fancy tree" />
          </Dropdown.Item>
        </Dropdown.Menu>
      </Dropdown>
    );
  }

  function exportMenu() {
    if (!props.showingChart || !props.data) {
      return null;
    }
    return (
      <>
        <Menu.Item
          onClick={props.eventHandlers?.onPrint}
          disabled={!props.allowPrintAndDownload}
        >
          <Icon name="print" />
          <FormattedMessage id="menu.print" defaultMessage="Print" />
        </Menu.Item>
        <Dropdown
          trigger={
            <div>
              <Icon name="download" />
              <FormattedMessage id="menu.download" defaultMessage="Download" />
            </div>
          }
          className="item"
          disabled={!props.allowPrintAndDownload}
        >
          <Dropdown.Menu>
            <Dropdown.Item onClick={props.eventHandlers?.onDownloadPdf}>
              <FormattedMessage id="menu.pdf_file" defaultMessage="PDF file" />
            </Dropdown.Item>
            <Dropdown.Item onClick={props.eventHandlers?.onDownloadPng}>
              <FormattedMessage id="menu.png_file" defaultMessage="PNG file" />
            </Dropdown.Item>
            <Dropdown.Item onClick={props.eventHandlers?.onDownloadSvg}>
              <FormattedMessage id="menu.svg_file" defaultMessage="SVG file" />
            </Dropdown.Item>
          </Dropdown.Menu>
        </Dropdown>
      </>
    );
  }

  function title() {
    const fileName = getSourceFileName(props.sourceUrl);
    return (
      <Menu.Item className="family-site-title">
        <b>{SITE_TITLE}</b>
        {fileName ? <span>{fileName}</span> : null}
      </Menu.Item>
    );
  }

  const searchBar =
    props.showingChart && props.data ? (
      <SearchBar
        results={searchResults}
        value={searchString}
        onSearchChange={setSearchString}
        onResultSelect={handleResultSelect}
      />
    ) : null;

  return (
    <div>
      <Menu
        as={Media}
        greaterThanOrEqual="large"
        attached="top"
        inverted
        color="blue"
        size="large"
      >
        {title()}
        {chartViewMenu()}
        {exportMenu()}
        <Menu.Menu position="right">{searchBar}</Menu.Menu>
      </Menu>
      <Menu
        as={Media}
        at="small"
        attached="top"
        inverted
        color="blue"
        size="large"
      >
        {title()}
        {chartViewMenu()}
        <Menu.Menu position="right">{searchBar}</Menu.Menu>
      </Menu>
    </div>
  );
}
