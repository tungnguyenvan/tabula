import { Composition, staticFile } from "remotion";
import { Demo, demoDuration, FPS, recordings, type DemoProps, type InputEvent } from "./Demo";

/// Each recording's input (clicks, keys) is read from public/<recording>/events.json before rendering.
const loadEvents = async (): Promise<DemoProps> => {
  const entries = await Promise.all(
    recordings.map(async (name) => {
      const response = await fetch(staticFile(`${name}/events.json`));
      return [name, (await response.json()) as InputEvent[]] as const;
    }),
  );
  return { events: Object.fromEntries(entries) };
};

export const Root: React.FC = () => (
  <Composition
    id="TabulaDemo"
    component={Demo}
    durationInFrames={demoDuration}
    fps={FPS}
    width={1920}
    height={1080}
    defaultProps={{ events: {} } as DemoProps}
    calculateMetadata={async () => ({ props: await loadEvents() })}
  />
);
