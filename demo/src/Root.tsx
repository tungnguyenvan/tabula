import { AbsoluteFill, Composition, Still, staticFile } from "remotion";
import { Demo, demoDuration, FPS, PosterFrame, recordings, type DemoProps, type InputEvent } from "./Demo";

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

/// That frame of the video with a play button, linking to the video in the README.
const Poster: React.FC<DemoProps> = (props) => (
  <AbsoluteFill>
    <PosterFrame {...props} />
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", background: "radial-gradient(circle, rgba(0,0,0,0.15), rgba(0,0,0,0.45))" }}>
      <div style={{ width: 168, height: 168, borderRadius: "50%", background: "rgba(255,255,255,0.92)", display: "flex", alignItems: "center", justifyContent: "center",
        boxShadow: "0 20px 60px rgba(0,0,0,0.5)" }}>
        <svg width="70" height="70" viewBox="0 0 24 24"><path d="M8 5 L19 12 L8 19 Z" fill="#111" /></svg>
      </div>
      <div style={{ marginTop: 28, fontSize: 36, fontWeight: 600, color: "white", fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif", textShadow: "0 4px 20px rgba(0,0,0,0.8)" }}>
        Watch the demo · {Math.round(demoDuration / FPS)} s
      </div>
    </AbsoluteFill>
  </AbsoluteFill>
);

export const Root: React.FC = () => (
  <>
  <Still id="Poster" component={Poster} width={1920} height={1080} defaultProps={{ events: {} } as DemoProps}
    calculateMetadata={async () => ({ props: await loadEvents() })} />
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
  </>
);
