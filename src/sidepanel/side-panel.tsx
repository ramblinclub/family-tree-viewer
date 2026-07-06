import {useIntl} from 'react-intl';
import {Button, Icon, Sidebar} from 'semantic-ui-react';
import {TopolaData} from '../util/gedcom_util';
import {Config} from './config/config';
import {CollapsedDetails} from './details/collapsed-details';
import {Details} from './details/details';

interface SidePanelProps {
  data: TopolaData;
  selectedIndiId: string;
  config: Config;
  expanded: boolean;
  onToggle: () => void;
}

export function SidePanel({
  data,
  selectedIndiId,
  config,
  expanded,
  onToggle,
}: SidePanelProps) {
  const intl = useIntl();
  const label = intl.formatMessage({
    id: 'tab.info',
    defaultMessage: 'Info',
  });

  return (
    <Sidebar
      id="sidebar"
      animation="overlay"
      icon="labeled"
      width={expanded ? 'wide' : 'very thin'}
      direction="right"
      visible={true}
    >
      {expanded ? (
        <section id="sideDetails" aria-label={label}>
          <Details
            gedcom={data.gedcom}
            indi={selectedIndiId}
            config={config}
            images={data.images}
          />
        </section>
      ) : (
        <CollapsedDetails gedcom={data.gedcom} indi={selectedIndiId} />
      )}
      <Button id="sideToggle" icon size="mini" onClick={() => onToggle()}>
        <Icon size="large" name={expanded ? 'arrow right' : 'arrow left'} />
      </Button>
    </Sidebar>
  );
}
