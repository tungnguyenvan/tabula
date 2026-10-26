import React from "react";
import {
  AbsoluteFill,
  Easing,
  Img,
  Series,
  interpolate,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";

export const FPS = 30;

/// Every picture is Tabula itself: README screenshots and recordings of a debug build (scripts/render-demo.sh).
const font = "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Helvetica Neue', sans-serif";
const accent = "#4f8cff";
const stageWidth = 1640;
/// Where the camera's frame starts, under the titles.
const viewportTop = 175;
/// The zoom that shows a whole 1300×760 window in that frame.
const fit = 0.92;
const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;
const ease = Easing.inOut(Easing.cubic);

// MARK: Building blocks

/// Moving light behind every scene, so nothing sits still.
const Background: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const frame = useCurrentFrame();
  const x = 30 + Math.sin(frame / 40) * 12;
  const y = Math.cos(frame / 55) * 10;
  return (
    <AbsoluteFill
      style={{
        background: `radial-gradient(ellipse at ${x}% ${y}%, #23345a 0%, #0d1018 55%, #07080c 100%)`,
        fontFamily: font,
        color: "white",
        overflow: "hidden",
      }}
    >
      {children}
    </AbsoluteFill>
  );
};

/// Scenes come in with a quick zoom and leave with a fade.
const Enter: React.FC<{ duration: number; children: React.ReactNode }> = ({ duration, children }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const enter = spring({ frame, fps, config: { damping: 18, stiffness: 160 } });
  const leave = interpolate(frame, [duration - 8, duration], [1, 0], clamp);
  return (
    <AbsoluteFill style={{ opacity: Math.min(enter * 1.5, 1) * leave, transform: `scale(${0.9 + 0.1 * enter})` }}>
      {children}
    </AbsoluteFill>
  );
};

/// A title whose words pop in one after another.
const Title: React.FC<{ text: string; sub?: string; at?: number; top?: number }> = ({ text, sub, at = 0, top = 48 }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const words = text.split(" ");
  const subIn = spring({ frame: frame - at - words.length * 3 - 4, fps, config: { damping: 200 } });
  return (
    <div style={{ position: "absolute", top, left: 0, right: 0, textAlign: "center", zIndex: 10 }}>
      <div style={{ fontSize: 60, fontWeight: 800, letterSpacing: -1.5, textShadow: "0 8px 30px rgba(0,0,0,0.6)" }}>
        {words.map((word, index) => {
          const pop = spring({ frame: frame - at - index * 3, fps, config: { damping: 12, stiffness: 200 } });
          return (
            <span key={index} style={{ display: "inline-block", marginRight: 16, opacity: Math.min(pop * 2, 1), transform: `translateY(${(1 - pop) * 40}px) scale(${0.6 + 0.4 * pop})` }}>
              {word}
            </span>
          );
        })}
      </div>
      {sub && (
        <div style={{ fontSize: 28, marginTop: 8, color: "rgba(255,255,255,0.75)", opacity: subIn, transform: `translateY(${(1 - subIn) * 14}px)` }}>
          {sub}
        </div>
      )}
    </div>
  );
};

type Point = { at: number; x: number; y: number };
type Camera = { at: number; x: number; y: number; zoom: number };

/// Interpolates keyframes; before the first and after the last they hold.
const along = <T extends { at: number }>(keys: T[], frame: number, fields: (keyof T)[]): T => {
  if (frame <= keys[0].at) return keys[0];
  for (let index = 1; index < keys.length; index++) {
    const from = keys[index - 1], to = keys[index];
    if (frame <= to.at) {
      const t = ease((frame - from.at) / Math.max(1, to.at - from.at));
      const result = { ...to };
      for (const field of fields) {
        (result[field] as number) = (from[field] as number) + ((to[field] as number) - (from[field] as number)) * t;
      }
      return result;
    }
  }
  return keys[keys.length - 1];
};

/// The macOS arrow, with a ring where it clicks.
const Cursor: React.FC<{ path: Point[]; clicks: number[]; zoom: number; width: number; height: number }> = ({ path, clicks, zoom, width, height }) => {
  const frame = useCurrentFrame();
  const at = along(path, frame, ["x", "y"]);
  const appear = interpolate(frame, [path[0].at - 6, path[0].at], [0, 1], clamp);
  const pressed = clicks.some((click) => frame >= click && frame < click + 5);
  return (
    <div style={{ position: "absolute", left: at.x * width, top: at.y * height, transform: `scale(${1 / zoom})`, transformOrigin: "0 0", opacity: appear, zIndex: 5 }}>
      {clicks.map((click) => {
        const t = (frame - click) / 16;
        if (t < 0 || t > 1) return null;
        return (
          <div key={click} style={{
            position: "absolute", left: -40 * t - 4, top: -40 * t - 4, width: 80 * t + 8, height: 80 * t + 8, borderRadius: "50%",
            border: `4px solid ${accent}`, opacity: 1 - t, background: "rgba(79,140,255,0.18)",
          }} />
        );
      })}
      <svg width="44" height="44" viewBox="0 0 24 24" style={{ transform: `scale(${pressed ? 0.85 : 1})`, filter: "drop-shadow(0 3px 4px rgba(0,0,0,0.5))" }}>
        <path d="M3 2 L3 19 L7.5 14.8 L10.4 21.5 L13.2 20.3 L10.4 13.8 L16.5 13.8 Z" fill="black" stroke="white" strokeWidth="1.4" strokeLinejoin="round" />
      </svg>
    </div>
  );
};

/// A window of the app on the stage. The camera moves and zooms toward points of the picture; the cursor and
/// any overlays live in the picture's coordinates, so they follow it.
const Stage: React.FC<{
  src: (frame: number) => string;
  aspect: number;
  camera: Camera[];
  cursor?: Point[];
  clicks?: number[];
  top?: number;
  children?: React.ReactNode;
}> = ({ src, aspect, camera, cursor, clicks = [], top = viewportTop, children }) => {
  const frame = useCurrentFrame();
  const view = along(camera, frame, ["x", "y", "zoom"]);
  const width = stageWidth, height = stageWidth * aspect;
  const viewport = 1080 - top;
  const dx = -(view.x - 0.5) * width * view.zoom, dy = -(view.y - 0.5) * height * view.zoom;
  // The camera works inside a frame below the titles, so zooming in never covers them.
  return (
    <div style={{ position: "absolute", left: 0, top, width: 1920, height: viewport, overflow: "hidden" }}>
    <div style={{
      position: "absolute", left: (1920 - width) / 2, top: (viewport - height) / 2, width, height,
      transform: `translate(${dx}px, ${dy}px) scale(${view.zoom})`, transformOrigin: "50% 50%",
    }}>
      <div style={{ position: "absolute", inset: 0, borderRadius: 16, overflow: "hidden", boxShadow: "0 40px 120px rgba(0,0,0,0.65), 0 0 0 1px rgba(255,255,255,0.1)" }}>
        <Img src={staticFile(src(frame))} style={{ width: "100%", height: "100%", objectFit: "cover", objectPosition: "top" }} />
      </div>
      {children}
      {cursor && <Cursor path={cursor} clicks={clicks} zoom={view.zoom} width={width} height={height} />}
    </div>
    </div>
  );
};

/// Recorded frames: frame-00001.jpg… in public/<folder>.
const recording = (folder: string, frame: number) => `${folder}/frame-${String(Math.max(1, Math.round(frame))).padStart(5, "0")}.jpg`;

/// Maps the scene's frame to a recorded frame through (scene frame, recorded frame) pairs, linearly in between.
const timeline = (pairs: [number, number][]) => (frame: number) =>
  interpolate(frame, pairs.map((pair) => pair[0]), pairs.map((pair) => pair[1]), clamp);

const Badge: React.FC<{ text: string; show: boolean }> = ({ text, show }) =>
  show ? (
    <div style={{ position: "absolute", left: 40, bottom: 40, zIndex: 20, fontSize: 26, fontWeight: 600, padding: "10px 18px", borderRadius: 12, background: "rgba(0,0,0,0.7)", border: "1px solid rgba(255,255,255,0.15)" }}>
      {text}
    </div>
  ) : null;

// MARK: Scenes

const kinds = ["PostgreSQL", "MySQL", "SQLite", "MongoDB", "Redis"];

const Intro: React.FC<{ duration: number }> = ({ duration }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const icon = spring({ frame, fps, config: { damping: 9, stiffness: 140 } });
  const leave = interpolate(frame, [duration - 10, duration], [1, 0], clamp);
  const zoomOut = interpolate(frame, [duration - 10, duration], [1, 1.6], clamp);
  return (
    <Background>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", opacity: leave, transform: `scale(${zoomOut})` }}>
        <Img src={staticFile("icon.png")} style={{ width: 200, height: 200, transform: `scale(${icon}) rotate(${(1 - icon) * -25}deg)` }} />
        <div style={{ height: 120, position: "relative", width: "100%" }}><Title text="Tabula" top={10} at={6} /></div>
        <div style={{ fontSize: 34, color: "rgba(255,255,255,0.8)", opacity: spring({ frame: frame - 16, fps, config: { damping: 200 } }) }}>
          The native database client for macOS, with AI that knows your data
        </div>
        <div style={{ display: "flex", gap: 14, marginTop: 36 }}>
          {kinds.map((kind, index) => {
            const chip = spring({ frame: frame - 22 - index * 3, fps, config: { damping: 11, stiffness: 180 } });
            return (
              <div key={kind} style={{ fontSize: 26, padding: "10px 22px", borderRadius: 999, background: "rgba(255,255,255,0.09)", border: "1px solid rgba(255,255,255,0.16)", opacity: Math.min(chip * 2, 1), transform: `translateY(${(1 - chip) * 50}px) scale(${chip})` }}>
                {kind}
              </div>
            );
          })}
        </div>
      </AbsoluteFill>
    </Background>
  );
};

const Connections: React.FC<{ duration: number }> = ({ duration }) => (
  <Background>
    <Enter duration={duration}>
      <Title text="Every database, one app" sub="PostgreSQL · MySQL · SQLite · MongoDB · Redis" />
      {/* Double-clicking the connection dives into it. */}
      <Stage src={() => "shots/connections.png"} aspect={960 / 1440}
        camera={[{ at: 0, x: 0.5, y: 0.5, zoom: 0.78 }, { at: 40, x: 0.55, y: 0.35, zoom: 1.05 }, { at: 62, x: 0.47, y: 0.29, zoom: 1.25 }, { at: duration, x: 0.47, y: 0.29, zoom: 4 }]}
        cursor={[{ at: 6, x: 0.85, y: 0.8 }, { at: 40, x: 0.47, y: 0.29 }]} clicks={[50, 55]} />
    </Enter>
  </Background>
);

/// Keys pressed, shown as keycaps.
const Keys: React.FC<{ keys: string[]; label: string; show: boolean }> = ({ keys, label, show }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  if (!show) return null;
  return (
    <div style={{ position: "absolute", bottom: 46, left: 0, right: 0, display: "flex", justifyContent: "center", alignItems: "center", gap: 14, zIndex: 20 }}>
      {keys.map((key) => (
        <div key={key} style={{ minWidth: 76, height: 76, padding: "0 18px", borderRadius: 14, background: "linear-gradient(#3a3d46, #24262c)", border: "1px solid rgba(255,255,255,0.22)",
          boxShadow: "0 6px 0 #15161a, 0 14px 30px rgba(0,0,0,0.5)", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 36, fontWeight: 600 }}>
          {key}
        </div>
      ))}
      <div style={{ fontSize: 30, fontWeight: 600, marginLeft: 10, textShadow: "0 4px 16px rgba(0,0,0,0.7)", opacity: spring({ frame, fps, config: { damping: 200 } }) }}>{label}</div>
    </div>
  );
};

/// A glowing outline around the grey suggestion (its place in the recorded window), labelled AI.
const Suggestion: React.FC<{ show: boolean; from: number }> = ({ show, from }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  if (!show) return null;
  const pop = spring({ frame: frame - from, fps, config: { damping: 12, stiffness: 180 } });
  const glow = 0.6 + 0.4 * Math.sin((frame - from) / 4);
  return (
    <div style={{ position: "absolute", left: "47.4%", top: "15.2%", width: "46.2%", height: "3.2%", borderRadius: 8, zIndex: 4,
      border: `3px solid ${accent}`, boxShadow: `0 0 ${24 * glow}px ${accent}`, opacity: pop, transform: `scale(${0.9 + 0.1 * pop})` }}>
      <div style={{ position: "absolute", right: -2, top: -34, fontSize: 18, fontWeight: 700, padding: "3px 10px", borderRadius: 7, background: accent }}>AI</div>
    </div>
  );
};

const Inline: React.FC<{ duration: number }> = ({ duration }) => {
  const frame = useCurrentFrame();
  // Recorded at 15 frames a second: typing from 107 to 132, the grey suggestion at 151, Tab at 286, ⌘↩ at 318,
  // results from 325. The wait before Tab is cut.
  const source = timeline([[0, 100], [16, 107], [66, 132], [78, 150], [84, 152], [130, 160], [131, 284], [140, 288], [170, 316], [176, 326], [duration, 345]]);
  return (
    <Background>
      <Enter duration={duration}>
        <Title text="AI suggestions as you type" sub="A model running on your Mac finishes the line. Tab accepts it." />
        <Stage src={(f) => recording("inline", source(f))} aspect={1520 / 2600}
          camera={[
            { at: 0, x: 0.5, y: 0.5, zoom: fit },
            { at: 18, x: 0.36, y: 0.3, zoom: 2.2 },
            { at: 66, x: 0.5, y: 0.3, zoom: 2.2 },
            { at: 86, x: 0.57, y: 0.4, zoom: 1.4 },
            { at: 168, x: 0.57, y: 0.4, zoom: 1.4 },
            { at: 186, x: 0.5, y: 0.5, zoom: fit },
            { at: duration, x: 0.4, y: 0.35, zoom: 1.15 },
          ]}>
          <Suggestion show={frame >= 84 && frame < 131} from={84} />
        </Stage>
        <Keys keys={["⇥"]} label="Tab accepts the suggestion" show={frame >= 124 && frame < 156} />
        <Keys keys={["⌘", "↩"]} label="Run" show={frame >= 160 && frame < 192} />
      </Enter>
    </Background>
  );
};

const Filter: React.FC<{ duration: number }> = ({ duration }) => {
  // Recorded at 15 frames a second: the filter applies at frame 53.
  const source = timeline([[0, 34], [36, 52], [42, 54], [duration, 54 + (duration - 42) / 2]]);
  return (
    <Background>
      <Enter duration={duration}>
        <Title text="Filter millions of rows" sub="On the server, with a builder or plain WHERE" />
        <Stage src={(f) => recording("filter", source(f))} aspect={1520 / 2600}
          camera={[
            { at: 0, x: 0.5, y: 0.5, zoom: fit },
            { at: 30, x: 0.38, y: 0.85, zoom: 1.7 },
            { at: 50, x: 0.6, y: 0.15, zoom: 2.0 },
            { at: 85, x: 0.75, y: 0.17, zoom: 2.0 },
            { at: duration, x: 0.5, y: 0.5, zoom: fit },
          ]}
          cursor={[{ at: 4, x: 0.6, y: 0.6 }, { at: 30, x: 0.357, y: 0.979 }, { at: 62, x: 0.93, y: 0.129 }, { at: duration, x: 0.8, y: 0.4 }]}
          clicks={[32, 66]} />
      </Enter>
    </Background>
  );
};

const Mongo: React.FC<{ duration: number }> = ({ duration }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const sheet = spring({ frame: frame - 54, fps, config: { damping: 14, stiffness: 160 } });
  return (
    <Background>
      <Enter duration={duration}>
        <Title text="MongoDB, natively" sub="Documents in a grid. Types kept when you edit." />
        <Stage src={() => "shots/mongodb.png"} aspect={1520 / 2600}
          camera={[{ at: 0, x: 0.45, y: 0.4, zoom: 1.15 }, { at: 30, x: 0.35, y: 0.25, zoom: 1.6 }, { at: 50, x: 0.35, y: 0.8, zoom: 1.6 }, { at: 70, x: 0.5, y: 0.5, zoom: fit }]}
          cursor={[{ at: 4, x: 0.6, y: 0.5 }, { at: 26, x: 0.3, y: 0.21 }, { at: 48, x: 0.3515, y: 0.98 }]}
          clicks={[28, 50]}>
          {frame >= 54 && (
            <div style={{ position: "absolute", left: "50%", top: "48%", width: 760, height: 570, marginLeft: -380, marginTop: -285, zIndex: 4,
              transform: `scale(${0.4 + 0.6 * sheet})`, opacity: Math.min(sheet * 2, 1), borderRadius: 18, overflow: "hidden",
              boxShadow: "0 30px 100px rgba(0,0,0,0.75), 0 0 0 1px rgba(255,255,255,0.12)" }}>
              <Img src={staticFile("shots/mongodb-document.png")} style={{ width: "100%", height: "100%" }} />
            </div>
          )}
        </Stage>
      </Enter>
    </Background>
  );
};

const Montage: React.FC<{ duration: number }> = ({ duration }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const tiles = [
    { src: "shots/redis.png", label: "Redis keys & console" },
    { src: "shots/diagram.png", label: "Relationship diagrams" },
    { src: "shots/metrics.png", label: "Live server metrics" },
  ];
  return (
    <Background>
      <Enter duration={duration}>
        <Title text="And everything around it" />
        <div style={{ position: "absolute", top: 320, left: 0, right: 0, display: "flex", justifyContent: "center", gap: 40, perspective: 1600 }}>
          {tiles.map((tile, index) => {
            const pop = spring({ frame: frame - 4 - index * 6, fps, config: { damping: 13, stiffness: 150 } });
            const drift = interpolate(frame, [0, duration], [0, -20], clamp);
            const grow = interpolate(frame, [20, duration], [1, 1.05], clamp);
            return (
              <div key={tile.src} style={{ width: 540, opacity: Math.min(pop * 2, 1), transform: `translateY(${(1 - pop) * 300 + drift}px) rotateY(${(index - 1) * -14 * pop}deg) scale(${(0.8 + 0.2 * pop) * grow})` }}>
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

const AI: React.FC<{ duration: number }> = ({ duration }) => {
  const frame = useCurrentFrame();
  // Recorded at 10 frames a second: sent at 12, the tool step at 164, the answer done by 204.
  const source = timeline([[0, 1], [36, 13], [44, 15], [104, 164], [122, 175], [150, 183], [190, 204]]);
  const step = frame < 44 ? 0 : frame < 112 ? 1 : 2;
  const titles = [
    { text: "Ask your data anything", sub: "The AI chat sits next to your tables" },
    { text: "It runs the query", sub: "Read-only, on its own read-only connection" },
    { text: "And answers from real data", sub: "Every step shown. On Production it asks first." },
  ];
  return (
    <Background>
      <Enter duration={duration}>
        <Title key={step} text={titles[step].text} sub={titles[step].sub} at={[0, 44, 112][step]} />
        <Stage src={(f) => recording("chat", source(f))} aspect={1520 / 2600}
          camera={[
            { at: 0, x: 0.5, y: 0.5, zoom: fit },
            { at: 30, x: 0.86, y: 0.75, zoom: 2.0 },
            { at: 50, x: 0.86, y: 0.42, zoom: 2.0 },
            { at: 104, x: 0.86, y: 0.42, zoom: 2.0 },
            { at: 130, x: 0.86, y: 0.45, zoom: 2.2 },
            { at: 165, x: 0.885, y: 0.52, zoom: 2.7 },
            { at: 215, x: 0.885, y: 0.52, zoom: 2.7 },
            { at: 250, x: 0.85, y: 0.69, zoom: 2.4 },
            { at: 285, x: 0.85, y: 0.69, zoom: 2.4 },
            { at: duration, x: 0.6, y: 0.5, zoom: fit },
          ]}
          cursor={[{ at: 4, x: 0.6, y: 0.6 }, { at: 22, x: 0.8, y: 0.948 }, { at: 32, x: 0.961, y: 0.947 }, { at: 120, x: 0.95, y: 0.8 }, { at: 180, x: 0.93, y: 0.56 }, { at: 245, x: 0.842, y: 0.698 }]}
          clicks={[24, 34]} />
        <Badge text="⏩  Sped up" show={frame >= 44 && frame < 104} />
        <div style={{ position: "absolute", bottom: 0, left: 0, right: 0, textAlign: "center", fontSize: 22, color: "rgba(255,255,255,0.7)", zIndex: 20,
          padding: "40px 0 16px", background: "linear-gradient(transparent, rgba(7,8,12,0.92) 55%)" }}>
          Claude Code shown · also Codex, Claude API, OpenAI-compatible, Ollama, Apple Intelligence, or a model on your Mac
        </div>
      </Enter>
    </Background>
  );
};

const Outro: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const icon = spring({ frame, fps, config: { damping: 10, stiffness: 150 } });
  const button = spring({ frame: frame - 18, fps, config: { damping: 11, stiffness: 160 } });
  return (
    <Background>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
        <Img src={staticFile("icon.png")} style={{ width: 150, height: 150, transform: `scale(${icon})` }} />
        <div style={{ height: 120, position: "relative", width: "100%" }}><Title text="Tabula" top={10} at={4} /></div>
        <div style={{ fontSize: 34, color: "rgba(255,255,255,0.8)", opacity: spring({ frame: frame - 12, fps, config: { damping: 200 } }) }}>
          Free · Native · No account, no telemetry
        </div>
        <div style={{ marginTop: 40, fontSize: 34, padding: "16px 34px", borderRadius: 14, background: accent, fontWeight: 700, transform: `scale(${button})`, boxShadow: `0 10px 40px ${accent}88` }}>
          github.com/tungnguyenvan/tabula
        </div>
      </AbsoluteFill>
    </Background>
  );
};

const scenes: { duration: number; render: (duration: number) => React.ReactNode }[] = [
  { duration: 75, render: (d) => <Intro duration={d} /> },
  // AI first: the chat that looks things up, then suggestions while typing.
  { duration: 320, render: (d) => <AI duration={d} /> },
  { duration: 220, render: (d) => <Inline duration={d} /> },
  { duration: 85, render: (d) => <Connections duration={d} /> },
  { duration: 120, render: (d) => <Filter duration={d} /> },
  { duration: 120, render: (d) => <Mongo duration={d} /> },
  { duration: 90, render: (d) => <Montage duration={d} /> },
  { duration: 90, render: () => <Outro /> },
];

export const demoDuration = scenes.reduce((total, scene) => total + scene.duration, 0);

export const Demo: React.FC = () => (
  <Series>
    {scenes.map((scene, index) => (
      <Series.Sequence key={index} durationInFrames={scene.duration}>
        {scene.render(scene.duration)}
      </Series.Sequence>
    ))}
  </Series>
);
