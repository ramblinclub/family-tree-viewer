import {ChartColors, Config, Ids, Sex} from './sidepanel/config/config';
import {DEFAULT_PLACE_DISPLAY_COUNT, PlaceDisplay} from './util/place_util';

export const SITE_TITLE = 'Family Tree';

export const STATIC_CHART_CONFIG: Config = {
  color: ChartColors.COLOR_BY_GENERATION,
  id: Ids.SHOW,
  sex: Sex.SHOW,
  place: PlaceDisplay.FULL,
  placeCount: DEFAULT_PLACE_DISPLAY_COUNT,
};
