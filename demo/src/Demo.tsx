import React from "react";
import {
  AbsoluteFill,
  Audio,
  Easing,
  Img,
  Sequence,
  Series,
  interpolate,
  spring,
  staticFile,
  useCurrentFrame,
} from "remotion";

/// Rendered at 60 frames a second, so camera moves and the pointer are smooth; everything below is timed in
/// thirtieths of a second (`useFrame`), the rate the app was recorded at.
export const FPS = 60;
const unit = 30;
const scale = FPS / unit;
/// The current moment in thirtieths of a second (fractional at 60 frames a second).
const useFrame = () => useCurrentFrame() / scale;

/// Everything shown is Tabula itself, recorded from a debug build driven by real clicks and keys
/// (scripts/render-demo.sh lists the commands), plus README screenshots for the montage.
export const recordings = ["chat", "chatrun", "ask", "inline", "filter", "mongo"] as const;
type RecordingName = (typeof recordings)[number];

/// Input logged while recording: the frame it happened on and, for the mouse, where (fractions of the window).
export type InputEvent = { frame: number; kind: "move" | "click" | "dclick" | "key" | "space" | "keycap"; x?: number; y?: number };
export type DemoProps = { events: Partial<Record<RecordingName, InputEvent[]>> };

const font = "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Helvetica Neue', sans-serif";
const accent = "#4f8cff";
const stageWidth = 1640;
/// Recordings are 1300×760 windows.
const windowAspect = 1520 / 2600;
/// Where the camera's frame starts, under the titles.
const viewportTop = 175;
/// The zoom that shows a whole window in that frame.
const fit = 0.92;
const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;
const ease = Easing.inOut(Easing.cubic);

// MARK: Building blocks

/// A sound (demo/audio/make-audio.mjs) at a frame of the scene.
const Sfx: React.FC<{ at: number; name: string; volume?: number }> = ({ at, name, volume = 1 }) => (
  <Sequence from={Math.round(at * scale)} durationInFrames={50 * scale} layout="none">
    <Audio src={staticFile(`audio/${name}.wav`)} volume={volume} />
  </Sequence>
);

const Background: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const frame = useFrame();
  const x = 30 + Math.sin(frame / 50) * 12;
  const y = Math.cos(frame / 70) * 10;
  return (
    <AbsoluteFill style={{ background: `radial-gradient(ellipse at ${x}% ${y}%, #22314f 0%, #0d1018 55%, #07080c 100%)`, fontFamily: font, color: "white", overflow: "hidden" }}>
      {children}
    </AbsoluteFill>
  );
};

/// Scenes come in with a gentle zoom and leave with a fade.
const Enter: React.FC<{ duration: number; children: React.ReactNode }> = ({ duration, children }) => {
  const frame = useFrame();
  const fps = unit;
  const enter = spring({ frame, fps, config: { damping: 20, stiffness: 140 } });
  const leave = interpolate(frame, [duration - 8, duration], [1, 0], clamp);
  return (
    <AbsoluteFill style={{ opacity: Math.min(enter * 1.5, 1) * leave, transform: `scale(${0.94 + 0.06 * enter})` }}>
      {children}
    </AbsoluteFill>
  );
};

/// A title whose words rise in one after another.
const Title: React.FC<{ text: string; sub?: string; at?: number; top?: number }> = ({ text, sub, at = 0, top = 48 }) => {
  const frame = useFrame();
  const fps = unit;
  const words = text.split(" ");
  const subIn = spring({ frame: frame - at - words.length * 3 - 4, fps, config: { damping: 200 } });
  return (
    <div style={{ position: "absolute", top, left: 0, right: 0, textAlign: "center", zIndex: 10 }}>
      <Sfx at={at + 2} name="tink" volume={0.5} />
      <div style={{ fontSize: 60, fontWeight: 700, letterSpacing: -1.5, textShadow: "0 8px 30px rgba(0,0,0,0.6)" }}>
        {words.map((word, index) => {
          const rise = spring({ frame: frame - at - index * 3, fps, config: { damping: 16, stiffness: 160 } });
          return (
            <span key={index} style={{ display: "inline-block", marginRight: 16, opacity: Math.min(rise * 2, 1), transform: `translateY(${(1 - rise) * 30}px)` }}>
              {word}
            </span>
          );
        })}
      </div>
      {sub && (
        <div style={{ fontSize: 28, marginTop: 8, color: "rgba(255,255,255,0.75)", opacity: subIn, transform: `translateY(${(1 - subIn) * 12}px)` }}>
          {sub}
        </div>
      )}
    </div>
  );
};

type Camera = { at: number; x: number; y: number; zoom: number };

const along = (keys: Camera[], frame: number): Camera => {
  if (frame <= keys[0].at) return keys[0];
  for (let index = 1; index < keys.length; index++) {
    const from = keys[index - 1], to = keys[index];
    if (frame <= to.at) {
      const t = ease((frame - from.at) / Math.max(1, to.at - from.at));
      return { at: frame, x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t, zoom: from.zoom + (to.zoom - from.zoom) * t };
    }
  }
  return keys[keys.length - 1];
};

/// A recording on the stage, played through `timeline`: (scene frame, recorded frame) pairs, linear in between,
/// so waits can be cut or sped up while what was done keeps its real order. The cursor and the sounds come from the
/// recording's logged input, at the frames and places they really happened.
const Recording: React.FC<{
  name: RecordingName;
  events: InputEvent[];
  timeline: [number, number][];
  camera: Camera[];
  duration: number;
  children?: React.ReactNode;
}> = ({ name, events, timeline, camera, duration, children }) => {
  const frame = useFrame();
  const scenes = timeline.map((pair) => pair[0]), recorded = timeline.map((pair) => pair[1]);
  const source = interpolate(frame, scenes, recorded, clamp);
  // The scene frame a recorded frame shows at; input during a cut part lands at its end.
  const sceneFrame = (recordedFrame: number) => interpolate(recordedFrame, recorded, scenes, clamp);
  const keyed = along(camera, frame);
  // A slow breath on top of the camera's moves, so the picture never sits dead still while someone types.
  const view = { ...keyed, zoom: keyed.zoom * (1 + 0.015 * Math.sin(frame / 45)) };
  const width = stageWidth, height = stageWidth * windowAspect;
  const viewport = 1080 - viewportTop;
  const dx = -(view.x - 0.5) * width * view.zoom, dy = -(view.y - 0.5) * height * view.zoom;
  const image = `${name}/frame-${String(Math.max(1, Math.round(source))).padStart(5, "0")}.jpg`;

  const pointer = events.filter((event) => event.x !== undefined && event.y !== undefined);
  const visible = (event: InputEvent) => event.frame >= recorded[0] && event.frame <= recorded[recorded.length - 1];

  return (
    <div style={{ position: "absolute", left: 0, top: viewportTop, width: 1920, height: viewport, overflow: "hidden" }}>
      <div style={{ position: "absolute", left: (1920 - width) / 2, top: (viewport - height) / 2, width, height, transform: `translate(${dx}px, ${dy}px) scale(${view.zoom})`, transformOrigin: "50% 50%" }}>
        <div style={{ position: "absolute", inset: 0, borderRadius: 16, overflow: "hidden", boxShadow: "0 40px 120px rgba(0,0,0,0.65), 0 0 0 1px rgba(255,255,255,0.1)" }}>
          <Img src={staticFile(image)} style={{ width: "100%", height: "100%", objectFit: "cover", objectPosition: "top" }} />
        </div>
        {children}
        <Pointer events={pointer} source={source} sceneFrame={sceneFrame} zoom={view.zoom} width={width} height={height} />
      </div>
      {events.filter(visible).map((event, index) => {
        const at = sceneFrame(event.frame);
        if (at >= duration) return null;
        switch (event.kind) {
          case "click":
          case "dclick":
            return <Sfx key={index} at={at} name="click" volume={0.9} />;
          case "key":
          case "space":
            return <Sfx key={index} at={at} name={`key${(index % 4) + 1}`} volume={event.kind === "space" ? 0.5 : 0.7} />;
          case "keycap":
            return <Sfx key={index} at={at} name="keycap" volume={0.9} />;
          default:
            return null;
        }
      })}
    </div>
  );
};

/// The pointer where the mouse really was: it glides to each logged position over the moments before reaching it,
/// and rings where it clicked.
const Pointer: React.FC<{
  events: InputEvent[];
  source: number;
  sceneFrame: (recordedFrame: number) => number;
  zoom: number;
  width: number;
  height: number;
}> = ({ events, source, sceneFrame, zoom, width, height }) => {
  const frame = useFrame();
  if (events.length === 0) return null;
  const glide = 10; // recorded frames spent travelling to the next position
  let x = events[0].x!, y = events[0].y!;
  for (let index = 0; index < events.length; index++) {
    const event = events[index];
    if (source >= event.frame) {
      x = event.x!;
      y = event.y!;
    } else {
      const t = ease(Math.min(1, Math.max(0, (source - (event.frame - glide)) / glide)));
      if (index > 0 && t > 0) {
        x = x + (event.x! - x) * t;
        y = y + (event.y! - y) * t;
      }
      break;
    }
  }
  const appear = interpolate(source, [events[0].frame - glide, events[0].frame - glide / 2], [0, 1], clamp);
  const clicks = events.filter((event) => event.kind === "click" || event.kind === "dclick").map((event) => sceneFrame(event.frame));
  const pressed = clicks.some((click) => frame >= click && frame < click + 4);
  return (
    <div style={{ position: "absolute", left: x * width, top: y * height, transform: `scale(${1 / zoom})`, transformOrigin: "0 0", opacity: appear, zIndex: 5 }}>
      {clicks.map((click) => {
        const t = (frame - click) / 14;
        if (t < 0 || t > 1) return null;
        return (
          <div key={click} style={{ position: "absolute", left: -32 * t - 4, top: -32 * t - 4, width: 64 * t + 8, height: 64 * t + 8, borderRadius: "50%",
            border: `3px solid ${accent}`, opacity: 1 - t, background: "rgba(79,140,255,0.15)" }} />
        );
      })}
      <svg width="40" height="40" viewBox="0 0 24 24" style={{ transform: `scale(${pressed ? 0.88 : 1})`, filter: "drop-shadow(0 3px 4px rgba(0,0,0,0.5))" }}>
        <path d="M3 2 L3 19 L7.5 14.8 L10.4 21.5 L13.2 20.3 L10.4 13.8 L16.5 13.8 Z" fill="black" stroke="white" strokeWidth="1.4" strokeLinejoin="round" />
      </svg>
    </div>
  );
};

/// A note at the bottom (sped-up waits, keys pressed).
const Caption: React.FC<{ from: number; to: number; children: React.ReactNode }> = ({ from, to, children }) => {
  const frame = useFrame();
  if (frame < from || frame >= to) return null;
  const fade = interpolate(frame, [from, from + 6, to - 6, to], [0, 1, 1, 0], clamp);
  return (
    <div style={{ position: "absolute", bottom: 40, left: 0, right: 0, display: "flex", justifyContent: "center", zIndex: 20, opacity: fade }}>
      <div style={{ display: "flex", alignItems: "center", gap: 12, fontSize: 28, fontWeight: 600, padding: "12px 22px", borderRadius: 14,
        background: "rgba(20,22,28,0.85)", border: "1px solid rgba(255,255,255,0.14)", boxShadow: "0 12px 40px rgba(0,0,0,0.5)" }}>
        {children}
      </div>
    </div>
  );
};

const Key: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <span style={{ minWidth: 44, height: 44, padding: "0 12px", borderRadius: 9, background: "linear-gradient(#3a3d46, #26282e)", border: "1px solid rgba(255,255,255,0.22)",
    boxShadow: "0 4px 0 #15161a", display: "inline-flex", alignItems: "center", justifyContent: "center", fontSize: 24 }}>
    {children}
  </span>
);

// MARK: Scenes

const kinds = ["PostgreSQL", "MySQL", "SQLite", "MongoDB", "Redis"];

const Intro: React.FC<{ duration: number }> = ({ duration }) => {
  const frame = useFrame();
  const fps = unit;
  const icon = spring({ frame, fps, config: { damping: 14, stiffness: 120 } });
  const leave = interpolate(frame, [duration - 10, duration], [1, 0], clamp);
  return (
    <Background>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", opacity: leave, transform: `scale(${interpolate(frame, [duration - 10, duration], [1, 1.25], clamp)})` }}>
        <Img src={staticFile("icon.png")} style={{ width: 190, height: 190, transform: `scale(${icon})` }} />
        <div style={{ height: 120, position: "relative", width: "100%" }}><Title text="Tabula" top={10} at={6} /></div>
        <div style={{ fontSize: 34, color: "rgba(255,255,255,0.8)", opacity: spring({ frame: frame - 16, fps, config: { damping: 200 } }) }}>
          The native database client for macOS, with AI that knows your data
        </div>
        <div style={{ display: "flex", gap: 14, marginTop: 36 }}>
          {kinds.map((kind, index) => {
            const chip = spring({ frame: frame - 22 - index * 3, fps, config: { damping: 16, stiffness: 150 } });
            return (
              <div key={kind} style={{ fontSize: 26, padding: "10px 22px", borderRadius: 999, background: "rgba(255,255,255,0.09)", border: "1px solid rgba(255,255,255,0.16)", opacity: chip, transform: `translateY(${(1 - chip) * 30}px)` }}>
                {kind}
              </div>
            );
          })}
        </div>
      </AbsoluteFill>
    </Background>
  );
};

type SceneProps = { duration: number; events: InputEvent[] };

/// Puts the window's right edge, where the AI panel is, near the right of the picture at zoom 1.55, with the editor
/// beside it.
const chatX = 1.0 + 40 / (stageWidth * 1.55) - 960 / (stageWidth * 1.55);

/// Recorded at 30 frames a second: the chat button at 209, the field at 262, typing 289–389, Return at 408, the
/// assistant's query at 638, its answer streaming 858–905. The waits for the model are sped up.
const Chat: React.FC<SceneProps> = ({ duration, events }) => (
  <Background>
    <Enter duration={duration}>
      <Title text="Ask your data anything" sub="The AI chat runs read-only queries and answers from the real data" />
      <Recording name="chat" events={events} duration={duration}
        timeline={[[0, 195], [14, 209], [60, 262], [75, 287], [142, 389], [154, 408], [178, 638], [196, 858], [236, 905], [duration, 925]]}
        camera={[
          { at: 0, x: 0.5, y: 0.5, zoom: fit },
          { at: 30, x: chatX, y: 0.72, zoom: 1.55 },
          { at: 150, x: chatX, y: 0.72, zoom: 1.55 },
          { at: 178, x: chatX, y: 0.42, zoom: 1.55 },
          { at: 236, x: chatX, y: 0.52, zoom: 1.55 },
          { at: duration, x: chatX, y: 0.55, zoom: 1.55 },
        ]} />
      <Caption from={156} to={196}>Waiting for the model, sped up</Caption>
      <Sfx at={196} name="chime" volume={0.7} />
    </Enter>
  </Background>
);

/// Recorded at 30 frames a second, with the conversation saved from the scene before: Run on the answer's query
/// at 277 puts it in the editor and runs it.
const ChatRun: React.FC<SceneProps> = ({ duration, events }) => (
  <Background>
    <Enter duration={duration}>
      <Title text="Run it in one click" sub="The query goes to the editor and runs, next to the conversation" />
      <Recording name="chatrun" events={events} duration={duration}
        timeline={[[0, 232], [45, 277], [duration, 327]]}
        camera={[
          { at: 0, x: 0.8, y: 0.62, zoom: 1.5 },
          { at: 46, x: 0.8, y: 0.68, zoom: 1.5 },
          { at: 70, x: 0.55, y: 0.4, zoom: 1.1 },
          { at: duration, x: 0.55, y: 0.4, zoom: 1.15 },
        ]} />
    </Enter>
  </Background>
);

/// Recorded at 30 frames a second: Ask AI at 211, typing 256–324, Return at 346, the SQL written 544–572, Run at 1111.
const Ask: React.FC<SceneProps> = ({ duration, events }) => (
  <Background>
    <Enter duration={duration}>
      <Title text="Ask AI, right in the editor" sub="Describe the query, Tabula writes the SQL" />
      <Recording name="ask" events={events} duration={duration}
        timeline={[[0, 195], [16, 211], [45, 254], [100, 324], [118, 346], [138, 540], [168, 572], [176, 1098], [189, 1111], [duration, 1150]]}
        camera={[
          { at: 0, x: 0.5, y: 0.5, zoom: fit },
          { at: 24, x: 0.45, y: 0.28, zoom: 1.9 },
          { at: 168, x: 0.45, y: 0.28, zoom: 1.9 },
          { at: 196, x: 0.4, y: 0.32, zoom: 1.6 },
          { at: duration, x: 0.5, y: 0.5, zoom: fit },
        ]} />
      <Caption from={120} to={138}>Waiting for the model, sped up</Caption>
    </Enter>
  </Background>
);

/// Recorded at 30 frames a second: typing 211–273, the grey suggestion at 307, Tab at 553, ⌘↩ at 616, results at 617.
const Inline: React.FC<SceneProps> = ({ duration, events }) => (
  <Background>
    <Enter duration={duration}>
      <Title text="Suggestions as you type" sub="A model running on your Mac finishes the line" />
      <Recording name="inline" events={events} duration={duration}
        timeline={[[0, 205], [8, 211], [70, 273], [104, 307], [118, 321], [119, 545], [127, 553], [150, 576], [190, 616], [duration, 621]]}
        camera={[
          { at: 0, x: 0.5, y: 0.5, zoom: fit },
          { at: 16, x: 0.36, y: 0.3, zoom: 2.1 },
          { at: 70, x: 0.5, y: 0.3, zoom: 2.1 },
          { at: 100, x: 0.57, y: 0.4, zoom: 1.4 },
          { at: 186, x: 0.57, y: 0.4, zoom: 1.4 },
          { at: 205, x: 0.5, y: 0.5, zoom: fit },
          { at: duration, x: 0.45, y: 0.45, zoom: 1.0 },
        ]}>
        <SuggestionMark from={104} to={127} />
      </Recording>
      <Caption from={124} to={160}><Key>Tab</Key> accepts the suggestion</Caption>
      <Caption from={180} to={212}><Key>⌘</Key><Key>Return</Key> runs it</Caption>
    </Enter>
  </Background>
);

/// An outline around the grey suggestion, where it sits in the recorded window, labelled AI.
const SuggestionMark: React.FC<{ from: number; to: number }> = ({ from, to }) => {
  const frame = useFrame();
  const fps = unit;
  if (frame < from || frame >= to) return null;
  const pop = spring({ frame: frame - from, fps, config: { damping: 16, stiffness: 160 } });
  const glow = 0.6 + 0.4 * Math.sin((frame - from) / 5);
  return (
    <div style={{ position: "absolute", left: "47.4%", top: "15.2%", width: "46.2%", height: "3.2%", borderRadius: 8, zIndex: 4,
      border: `3px solid ${accent}`, boxShadow: `0 0 ${20 * glow}px ${accent}`, opacity: pop }}>
      <div style={{ position: "absolute", right: -2, top: -34, fontSize: 18, fontWeight: 700, padding: "3px 10px", borderRadius: 7, background: accent }}>AI</div>
    </div>
  );
};

/// Recorded at 30 frames a second: the filter button at 208, SQL at 253, the field at 292, typing 319–336, Return at
/// 358, results at 363.
const Filter: React.FC<SceneProps> = ({ duration, events }) => (
  <Background>
    <Enter duration={duration}>
      <Title text="Filter on the server" sub="With the builder, or a plain WHERE clause" />
      <Recording name="filter" events={events} duration={duration}
        timeline={[[0, 194], [14, 208], [50, 253], [80, 292], [100, 318], [118, 336], [140, 358], [duration, 388]]}
        camera={[
          { at: 0, x: 0.5, y: 0.5, zoom: fit },
          { at: 14, x: 0.4, y: 0.82, zoom: 1.5 },
          { at: 30, x: 0.5, y: 0.5, zoom: fit },
          { at: 48, x: 0.6, y: 0.24, zoom: 1.6 },
          { at: 146, x: 0.6, y: 0.24, zoom: 1.6 },
          { at: duration, x: 0.5, y: 0.5, zoom: fit },
        ]} />
    </Enter>
  </Background>
);

/// Recorded at 30 frames a second: the first document at 208, the JSON button at 250, the editor open from 253.
const Mongo: React.FC<SceneProps> = ({ duration, events }) => (
  <Background>
    <Enter duration={duration}>
      <Title text="MongoDB, natively" sub="Documents in a grid, types kept when you edit" />
      <Recording name="mongo" events={events} duration={duration}
        timeline={[[0, 194], [14, 208], [56, 250], [duration, 299]]}
        camera={[
          { at: 0, x: 0.5, y: 0.5, zoom: fit },
          { at: 14, x: 0.4, y: 0.25, zoom: 1.5 },
          { at: 22, x: 0.4, y: 0.25, zoom: 1.5 },
          { at: 46, x: 0.5, y: 0.5, zoom: fit },
        ]} />
      <Sfx at={58} name="tink" volume={0.5} />
    </Enter>
  </Background>
);

const Montage: React.FC<{ duration: number }> = ({ duration }) => {
  const frame = useFrame();
  const fps = unit;
  const tiles = [
    { src: "shots/redis.png", label: "Redis keys and console" },
    { src: "shots/diagram.png", label: "Relationship diagrams" },
    { src: "shots/metrics.png", label: "Live server metrics" },
  ];
  return (
    <Background>
      <Enter duration={duration}>
        <Title text="And everything around it" />
        <div style={{ position: "absolute", top: 320, left: 0, right: 0, display: "flex", justifyContent: "center", gap: 40, perspective: 1600 }}>
          {tiles.map((tile, index) => {
            const rise = spring({ frame: frame - 4 - index * 6, fps, config: { damping: 18, stiffness: 130 } });
            const grow = interpolate(frame, [20, duration], [1, 1.04], clamp);
            return (
              <div key={tile.src} style={{ width: 540, opacity: rise, transform: `translateY(${(1 - rise) * 120}px) rotateY(${(index - 1) * -12 * rise}deg) scale(${grow})` }}>
                <div style={{ borderRadius: 14, overflow: "hidden", boxShadow: "0 30px 80px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.1)" }}>
                  <Img src={staticFile(tile.src)} style={{ width: "100%", display: "block" }} />
                </div>
                <div style={{ textAlign: "center", fontSize: 30, fontWeight: 600, marginTop: 22 }}>{tile.label}</div>
              </div>
            );
          })}
        </div>
      </Enter>
    </Background>
  );
};

const Outro: React.FC = () => {
  const frame = useFrame();
  const fps = unit;
  const icon = spring({ frame, fps, config: { damping: 14, stiffness: 130 } });
  const button = spring({ frame: frame - 18, fps, config: { damping: 16, stiffness: 150 } });
  return (
    <Background>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
        <Img src={staticFile("icon.png")} style={{ width: 150, height: 150, transform: `scale(${icon})` }} />
        <Sfx at={18} name="chime" volume={0.6} />
        <div style={{ height: 120, position: "relative", width: "100%" }}><Title text="Tabula" top={10} at={4} /></div>
        <div style={{ fontSize: 34, color: "rgba(255,255,255,0.8)", opacity: spring({ frame: frame - 12, fps, config: { damping: 200 } }) }}>
          Free · Native · No account, no telemetry
        </div>
        <div style={{ marginTop: 40, fontSize: 34, padding: "16px 34px", borderRadius: 14, background: accent, fontWeight: 700, opacity: button, transform: `scale(${0.9 + 0.1 * button})`, boxShadow: `0 10px 40px ${accent}66` }}>
          github.com/tungnguyenvan/tabula
        </div>
      </AbsoluteFill>
    </Background>
  );
};

const scenes: { duration: number; render: (duration: number, props: DemoProps) => React.ReactNode }[] = [
  { duration: 70, render: (d) => <Intro duration={d} /> },
  // AI first: the chat that looks things up, running its answer, Ask AI in the editor, suggestions while typing.
  { duration: 260, render: (d, p) => <Chat duration={d} events={p.events.chat ?? []} /> },
  { duration: 95, render: (d, p) => <ChatRun duration={d} events={p.events.chatrun ?? []} /> },
  { duration: 225, render: (d, p) => <Ask duration={d} events={p.events.ask ?? []} /> },
  { duration: 225, render: (d, p) => <Inline duration={d} events={p.events.inline ?? []} /> },
  { duration: 170, render: (d, p) => <Filter duration={d} events={p.events.filter ?? []} /> },
  { duration: 105, render: (d, p) => <Mongo duration={d} events={p.events.mongo ?? []} /> },
  { duration: 85, render: (d) => <Montage duration={d} /> },
  { duration: 90, render: () => <Outro /> },
];

export const demoDuration = scenes.reduce((total, scene) => total + scene.duration, 0) * scale;

export const Demo: React.FC<DemoProps> = (props) => (
  <>
    {/* Fades in, sits under the effects, fades out with the last scene. */}
    <Audio src={staticFile("audio/music.wav")}
      volume={(frame) => interpolate(frame, [0, 20 * scale, demoDuration - 50 * scale, demoDuration], [0, 0.85, 0.85, 0], clamp)} />
    <Series>
      {scenes.map((scene, index) => (
        <Series.Sequence key={index} durationInFrames={scene.duration * scale}>
          {scene.render(scene.duration, props)}
        </Series.Sequence>
      ))}
    </Series>
  </>
);
