import {Intro} from '../intro';
import {TopBar} from '../menu/top_bar';

/**
 * IntroPage component that represents the landing page of the application.
 * It renders the intro text and lists examples alongside its own TopBar.
 */
export function IntroPage() {
  return (
    <>
      <TopBar showingChart={false} standalone={false} />
      <Intro />
    </>
  );
}
