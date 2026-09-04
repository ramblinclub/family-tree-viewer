import {
  ChartColors,
  DetailedRenderer,
  HourglassChart,
  createChart,
  type JsonGedcomData,
} from 'topola';
import 'd3-transition';
import './style.css';

type TreePayload = {
  data: JsonGedcomData;
  selectionID: string;
  locale: string;
};

let chart: ReturnType<typeof createChart> | undefined;

function render(payload: TreePayload) {
  const chartRoot = document.querySelector('#chart');
  const svg = document.querySelector('#treeSvg');
  if (!chartRoot || !svg) return;

  try {
    chartRoot.innerHTML = '';
    chart = createChart({
      json: payload.data,
      chartType: HourglassChart,
      renderer: DetailedRenderer,
      // Topola expects the selector for the outer SVG (the chart group is
      // created inside it by the renderer).
      svgSelector: '#treeSvg',
      colors: ChartColors.COLOR_BY_GENERATION,
      animate: false,
      updateSvgSize: true,
      locale: payload.locale,
      indiCallback: (info) => {
        window.webkit?.messageHandlers?.personSelected?.postMessage(info.id);
      },
    });

    const chartInfo = chart.render({
      startIndi: payload.selectionID,
      baseGeneration: 0,
    });
    svg.setAttribute('width', String(chartInfo.size[0]));
    svg.setAttribute('height', String(chartInfo.size[1]));
    document.querySelector('#status')?.remove();
  } catch (error) {
    console.error('Topola render failed', error);
    const status = document.querySelector('#status');
    if (status) status.textContent = 'Unable to display tree';
  }
}

declare global {
  interface Window {
    setTreePayload?: (payload: TreePayload) => void;
    webkit?: {
      messageHandlers?: {
        personSelected?: {postMessage: (message: string) => void};
      };
    };
  }
}

window.setTreePayload = render;
window.webkit?.messageHandlers?.topolaReady?.postMessage('ready');
