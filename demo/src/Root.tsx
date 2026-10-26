import { Composition } from "remotion";
import { Demo, demoDuration, FPS } from "./Demo";

export const Root: React.FC = () => (
  <Composition id="TabulaDemo" component={Demo} durationInFrames={demoDuration} fps={FPS} width={1920} height={1080} />
);
