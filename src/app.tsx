import {useMemo} from 'react';
import {Navigate, Route, Routes} from 'react-router';
import {ViewPage} from './pages/view_page';
import {getStaticUrl} from './util/url_args';

const staticUrl = getStaticUrl();

function MissingStaticDataPage() {
  return (
    <main className="missing-static-data">
      <h1>Family Tree</h1>
      <p>
        Set <code>VITE_STATIC_URL</code> to the GEDCOM or GDZ file that should
        be loaded by this static family site.
      </p>
    </main>
  );
}

/**
 * Root App component for the static family-tree site.
 */
export function App() {
  const staticDataConfigured = useMemo(() => !!staticUrl, []);
  if (staticDataConfigured) {
    return (
      <Routes>
        <Route path="/view" element={<ViewPage />} />
        <Route path="*" element={<Navigate to="/view" replace />} />
      </Routes>
    );
  }

  return (
    <Routes>
      <Route path="*" element={<MissingStaticDataPage />} />
    </Routes>
  );
}
