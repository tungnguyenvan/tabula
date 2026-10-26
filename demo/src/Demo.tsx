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

/// Every picture is a real screenshot or recording of Tabula (scripts/render-demo.sh copies them into public/).
const font = "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Helvetica Neue', sans-serif";
const accent = "#4f8cff";
const frameWidth = 1440;
const fade = 12;

/// Fades a scene in and out at its edges.
const useSceneOpacity = (duration: number) => {
  const frame = useCurrentFrame();
  return interpolate(frame, [0, fade, duration - fade, duration], [0, 1, 1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
};

const Background: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <AbsoluteFill
    style={{
      background: "radial-gradient(ellipse at 30% 0%, #1d2a44 0%, #0d1018 55%, #08090d 100%)",
      fontFamily: font,
      color: "white",
    }}
  >
    {children}
  </AbsoluteFill>
);

/// The title and one line under it, sliding in.
const Caption: React.FC<{ title: string; text: string; delay?: number }> = ({ title, text, delay = 0 }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const enter = spring({ frame: frame - delay, fps, config: { damping: 200 } });
  return (
    <div
      style={{
        position: "absolute",
        top: 56,
        left: 0,
        right: 0,
        textAlign: "center",
        opacity: enter,
        transform: `translateY(${(1 - enter) * 24}px)`,
      }}
    >
      <div style={{ fontSize: 54, fontWeight: 700, letterSpacing: -1 }}>{title}</div>
      <div style={{ fontSize: 28, marginTop: 10, color: "rgba(255,255,255,0.72)" }}>{text}</div>
    </div>
  );
};

/// A screenshot in a soft shadow, slowly moving toward `zoom` around `origin`.
const Shot: React.FC<{ src: string; duration: number; zoom?: number; origin?: string }> = ({
  src,
  duration,
  zoom = 1.08,
  origin = "50% 50%",
}) => {
  const frame = useCurrentFrame();
  const scale = interpolate(frame, [0, duration], [1, zoom], { easing: Easing.inOut(Easing.quad) });
  return (
    <div
      style={{
        position: "absolute",
        top: 200,
        left: (1920 - frameWidth) / 2,
        width: frameWidth,
        height: 820,
        borderRadius: 18,
        overflow: "hidden",
        boxShadow: "0 40px 120px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.08)",
        background: "#1b1b1d",
      }}
    >
      <Img
        src={staticFile(src)}
        style={{ width: "100%", height: "100%", objectFit: "cover", objectPosition: "top", transform: `scale(${scale})`, transformOrigin: origin }}
      />
    </div>
  );
};

const ShotScene: React.FC<{
  src: string;
  title: string;
  text: string;
  duration: number;
  zoom?: number;
  origin?: string;
  next?: string;
}> = ({ src, title, text, duration, zoom, origin, next }) => {
  const frame = useCurrentFrame();
  const switchAt = duration / 2;
  const second = next ? interpolate(frame, [switchAt - 8, switchAt + 8], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" }) : 0;
  return (
    <Background>
      <AbsoluteFill style={{ opacity: useSceneOpacity(duration) }}>
        <Caption title={title} text={text} delay={4} />
        <AbsoluteFill style={{ opacity: 1 - second }}>
          <Shot src={src} duration={duration} zoom={zoom} origin={origin} />
        </AbsoluteFill>
        {next && (
          <AbsoluteFill style={{ opacity: second }}>
            <Shot src={next} duration={duration} zoom={zoom} origin={origin} />
          </AbsoluteFill>
        )}
      </AbsoluteFill>
    </Background>
  );
};

const kinds = ["PostgreSQL", "MySQL", "SQLite", "MongoDB", "Redis"];

const Intro: React.FC<{ duration: number }> = ({ duration }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const icon = spring({ frame, fps, config: { damping: 12 } });
  const title = spring({ frame: frame - 10, fps, config: { damping: 200 } });
  return (
    <Background>
      <AbsoluteFill style={{ opacity: useSceneOpacity(duration), alignItems: "center", justifyContent: "center" }}>
        <Img src={staticFile("icon.png")} style={{ width: 220, height: 220, transform: `scale(${icon})` }} />
        <div style={{ fontSize: 110, fontWeight: 800, letterSpacing: -3, marginTop: 24, opacity: title }}>Tabula</div>
        <div style={{ fontSize: 36, color: "rgba(255,255,255,0.75)", marginTop: 8, opacity: title }}>
          A fast, native database client for macOS
        </div>
        <div style={{ display: "flex", gap: 16, marginTop: 44 }}>
          {kinds.map((kind, index) => {
            const chip = spring({ frame: frame - 24 - index * 5, fps, config: { damping: 200 } });
            return (
              <div
                key={kind}
                style={{
                  fontSize: 26,
                  padding: "10px 22px",
                  borderRadius: 999,
                  background: "rgba(255,255,255,0.08)",
                  border: "1px solid rgba(255,255,255,0.14)",
                  opacity: chip,
                  transform: `translateY(${(1 - chip) * 16}px)`,
                }}
              >
                {kind}
              </div>
            );
          })}
        </div>
      </AbsoluteFill>
    </Background>
  );
};

/// The recorded chat (about 10 frames a second): the question, the wait (sped up), the tool step and the answer.
const recorded = { sent: 12, waitEnd: 164, answered: 204 };

const sourceFrame = (frame: number) => {
  if (frame < 90) return 1 + Math.floor(frame / 3);
  if (frame < 150) return Math.round(interpolate(frame, [90, 150], [31, recorded.waitEnd]));
  if (frame < 270) return Math.min(recorded.answered, recorded.waitEnd + Math.floor((frame - 150) / 3));
  return recorded.answered;
};

const AIScene: React.FC<{ duration: number }> = ({ duration }) => {
  const frame = useCurrentFrame();
  const zoom = interpolate(frame, [20, 75], [1, 1.75], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.inOut(Easing.cubic),
  });
  const n = String(sourceFrame(frame)).padStart(5, "0");
  const fastForward = frame >= 90 && frame < 150;
  const step = frame < 90 ? 0 : frame < 165 ? 1 : 2;
  const captions = [
    { title: "Ask about your data", text: "In plain words, in the chat next to your tables" },
    { title: "It looks things up", text: "A read-only query, on a read-only connection of its own" },
    { title: "And answers from the real data", text: "Every step shown. On Production, it asks before each query" },
  ];
  return (
    <Background>
      <AbsoluteFill style={{ opacity: useSceneOpacity(duration) }}>
        <Caption key={step} title={captions[step].title} text={captions[step].text} delay={[4, 90, 165][step]} />
        <div
          style={{
            position: "absolute",
            top: 200,
            left: (1920 - frameWidth) / 2,
            width: frameWidth,
            height: 820,
            borderRadius: 18,
            overflow: "hidden",
            boxShadow: "0 40px 120px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.08)",
            background: "#1b1b1d",
          }}
        >
          <Img
            src={staticFile(`chat/frame-${n}.jpg`)}
            style={{ width: "100%", height: "100%", objectFit: "cover", objectPosition: "top", transform: `scale(${zoom})`, transformOrigin: "100% 42%" }}
          />
          {fastForward && (
            <div
              style={{
                position: "absolute",
                left: 24,
                bottom: 24,
                fontSize: 24,
                padding: "8px 16px",
                borderRadius: 10,
                background: "rgba(0,0,0,0.65)",
              }}
            >
              ⏩ Sped up
            </div>
          )}
        </div>
        <div
          style={{
            position: "absolute",
            bottom: 18,
            left: 0,
            right: 0,
            textAlign: "center",
            fontSize: 22,
            color: "rgba(255,255,255,0.55)",
          }}
        >
          Claude Code shown · also Codex, the Claude API, OpenAI-compatible servers, Ollama, Apple Intelligence or a model on your Mac
        </div>
      </AbsoluteFill>
    </Background>
  );
};

const Outro: React.FC<{ duration: number }> = ({ duration }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const enter = spring({ frame, fps, config: { damping: 200 } });
  return (
    <Background>
      <AbsoluteFill style={{ opacity: useSceneOpacity(duration), alignItems: "center", justifyContent: "center" }}>
        <Img src={staticFile("icon.png")} style={{ width: 160, height: 160, opacity: enter }} />
        <div style={{ fontSize: 84, fontWeight: 800, letterSpacing: -2, marginTop: 20, opacity: enter }}>Tabula</div>
        <div style={{ fontSize: 34, color: "rgba(255,255,255,0.78)", marginTop: 12, opacity: enter }}>
          Free · Native · No account, no telemetry
        </div>
        <div
          style={{
            marginTop: 48,
            fontSize: 32,
            padding: "16px 32px",
            borderRadius: 14,
            background: accent,
            fontWeight: 600,
            opacity: spring({ frame: frame - 15, fps, config: { damping: 200 } }),
          }}
        >
          github.com/tungnguyenvan/tabula
        </div>
      </AbsoluteFill>
    </Background>
  );
};

const scenes: { duration: number; render: (duration: number) => React.ReactNode }[] = [
  { duration: 135, render: (d) => <Intro duration={d} /> },
  {
    duration: 150,
    render: (d) => (
      <ShotScene duration={d} src="shots/connections.png" title="All your databases"
        text="Tag connections Production, paste a URL to fill the form, passwords in the Keychain" zoom={1.04} />
    ),
  },
  {
    duration: 150,
    render: (d) => (
      <ShotScene duration={d} src="shots/data.png" title="A grid that keeps up"
        text="Paged, sorted and filtered on the server, edited inline, with row details" origin="30% 20%" />
    ),
  },
  {
    duration: 150,
    render: (d) => (
      <ShotScene duration={d} src="shots/query.png" title="An editor for real SQL"
        text="Highlighting, completion, Beautify, and a console of every statement" origin="40% 10%" />
    ),
  },
  {
    duration: 180,
    render: (d) => (
      <ShotScene duration={d} src="shots/mongodb.png" next="shots/mongodb-query.png" title="MongoDB, natively"
        text="Collections in the grid, types kept on edit, the shell in the query editor" origin="40% 20%" />
    ),
  },
  {
    duration: 135,
    render: (d) => (
      <ShotScene duration={d} src="shots/redis.png" title="Redis too" text="Keys, values and a console, by database" origin="30% 30%" />
    ),
  },
  {
    duration: 165,
    render: (d) => (
      <ShotScene duration={d} src="shots/diagram.png" next="shots/metrics.png" title="See the whole schema"
        text="Relationship diagrams and live server metrics" />
    ),
  },
  { duration: 420, render: (d) => <AIScene duration={d} /> },
  { duration: 165, render: (d) => <Outro duration={d} /> },
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
