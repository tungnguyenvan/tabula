import { Composition, staticFile } from "remotion";
import { Demo, demoDuration, FPS, recordings, type DemoProps, type InputEvent } from "./Demo";
import { WhatsNew, whatsNewDuration, whatsNewRecordings, type WhatsNewProps } from "./WhatsNew";

/// Each recording's input (clicks, keys) is read from public/<directory>/events.json before rendering.
const loadEvents = async <Name extends string>(names: readonly Name[], directory: (name: Name) => string) => {
  const entries = await Promise.all(
    names.map(async (name) => {
      const response = await fetch(staticFile(`${directory(name)}/events.json`));
      return [name, (await response.json()) as InputEvent[]] as const;
    }),
  );
  return { events: Object.fromEntries(entries) as Partial<Record<Name, InputEvent[]>> };
};

export const Root: React.FC = () => (
  <>
    <Composition
      id="TabulaDemo"
      component={Demo}
      durationInFrames={demoDuration}
      fps={FPS}
      width={1920}
      height={1080}
      defaultProps={{ events: {} } as DemoProps}
      calculateMetadata={async () => ({ props: await loadEvents(recordings, (name) => name) })}
    />
    {/* What's new in 0.6.0–0.7.0 (scripts/render-whats-new.sh). */}
    <Composition
      id="WhatsNew"
      component={WhatsNew}
      durationInFrames={whatsNewDuration}
      fps={FPS}
      width={1920}
      height={1080}
      defaultProps={{ events: {} } as WhatsNewProps}
      calculateMetadata={async () => ({ props: await loadEvents(whatsNewRecordings, (name) => `whatsnew/${name}`) })}
    />
  </>
);
