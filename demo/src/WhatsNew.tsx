import React from "react";
import { AbsoluteFill, Audio, Img, Series, interpolate, spring, staticFile } from "remotion";
import {
  Background,
  Caption,
  Enter,
  Key,
  Recording,
  Sfx,
  Title,
  accent,
  clamp,
  fit,
  scale,
  stageWidth,
  unit,
  useFrame,
  type InputEvent,
} from "./Demo";

/// What's new from 0.5.0 to 0.5.4, each feature in the real app (scripts/render-whats-new.sh lists the recordings).
/// Chat scenes use the current development composer, explicitly labelled because it is not in release 0.5.4.
/// The pointer shows only where it clicks. Timed in thirtieths of a second, as in Demo.tsx.
export const whatsNewRecordings = ["tools", "history", "state", "sidebar", "sqlfile", "connstring"] as const;
type Name = (typeof whatsNewRecordings)[number];
export type WhatsNewProps = { events: Partial<Record<Name, InputEvent[]>> };

/// The Connections window was recorded at 1000×640.
const connectionsAspect = 1280 / 2000;
/// The zoom that shows that whole window under the titles.
const connectionsFit = 0.84;
/// Puts the window's right edge, where the AI panel is, near the right of the picture at this zoom.
const rightEdge = (zoom: number) => 1.0 + 40 / (stageWidth * zoom) - 960 / (stageWidth * zoom);

const file = (name: Name) => `whatsnew/${name}`;

/// A ring around part of the recorded window (fractions of it), with a label above.
const Mark: React.FC<{ from: number; to: number; left: number; top: number; width: number; height: number; label: string }> = ({ from, to, left, top, width, height, label }) => {
  const frame = useFrame();
  if (frame < from || frame >= to) return null;
  const pop = spring({ frame: frame - from, fps: unit, config: { damping: 16, stiffness: 160 } });
  const fade = interpolate(frame, [to - 6, to], [1, 0], clamp);
  return (
    <div style={{ position: "absolute", left: `${left * 100}%`, top: `${top * 100}%`, width: `${width * 100}%`, height: `${height * 100}%`, borderRadius: 8, zIndex: 4,
      border: `3px solid ${accent}`, boxShadow: `0 0 18px ${accent}`, opacity: pop * fade }}>
      <div style={{ position: "absolute", left: -2, top: -34, fontSize: 18, fontWeight: 700, padding: "3px 10px", borderRadius: 7, background: accent, whiteSpace: "nowrap" }}>{label}</div>
    </div>
  );
};

const versions = ["0.5.0", "0.5.1", "0.5.2", "0.5.3", "0.5.4"];

const Intro: React.FC<{ duration: number }> = ({ duration }) => {
  const frame = useFrame();
  const icon = spring({ frame, fps: unit, config: { damping: 14, stiffness: 120 } });
  const leave = interpolate(frame, [duration - 10, duration], [1, 0], clamp);
  return (
    <Background>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", opacity: leave, transform: `scale(${interpolate(frame, [duration - 10, duration], [1, 1.2], clamp)})` }}>
        <Img src={staticFile("icon.png")} style={{ width: 170, height: 170, transform: `scale(${icon})` }} />
        <div style={{ height: 120, position: "relative", width: "100%" }}><Title text="What's new in Tabula" top={10} at={6} /></div>
        <div style={{ display: "flex", gap: 14, marginTop: 10 }}>
          {versions.map((version, index) => {
            const chip = spring({ frame: frame - 20 - index * 4, fps: unit, config: { damping: 16, stiffness: 150 } });
            return (
              <div key={version} style={{ fontSize: 28, fontWeight: 600, padding: "10px 24px", borderRadius: 999, background: "rgba(255,255,255,0.09)", border: "1px solid rgba(255,255,255,0.16)", opacity: chip, transform: `translateY(${(1 - chip) * 30}px)` }}>
                {version}
              </div>
            );
          })}
        </div>
      </AbsoluteFill>
    </Background>
  );
};

type SceneProps = { duration: number; events: InputEvent[] };

/// Actual saved conversation, reopened in the current UI with a 520-point inspector: chat at 181,
/// query disclosure at 244, collapsed again at 337. This is not a simulated live AI answer.
const Tools: React.FC<SceneProps> = ({ duration, events }) => (
  <Background>
    <Enter duration={duration}>
      <Title text="See what the AI looked up" sub="Read-only queries, visible steps and answers in tables" />
      <Recording name={file("tools")} events={events} duration={duration} pointer="clicks"
        timeline={[[0, 166], [15, 181], [62, 244], [112, 294], [155, 337], [duration, 387]]}
        camera={[
          { at: 0, x: 0.5, y: 0.5, zoom: fit },
          { at: 24, x: 0.5, y: 0.5, zoom: fit },
          { at: 54, x: rightEdge(1.15), y: 0.45, zoom: 1.15 },
          { at: 150, x: rightEdge(1.15), y: 0.45, zoom: 1.15 },
          { at: duration, x: 0.5, y: 0.5, zoom: fit },
        ]} />
      <Caption from={24} to={58}>A real saved conversation, reopened</Caption>
    </Enter>
  </Background>
);

/// Current chat UI, widened for legible model and effort labels. History menu at 244; Escape at 328;
/// New Chat at 376; composer focus at 434; then typing an unsent draft.
const History: React.FC<SceneProps> = ({ duration, events }) => (
  <Background>
    <Enter duration={duration}>
      <Title text="Keep your conversations" sub="Reopen earlier chats, or start fresh in the new composer" />
      <Recording name={file("history")} events={events} duration={duration} pointer="clicks"
        timeline={[[0, 224], [20, 244], [62, 328], [86, 376], [115, 434], [128, 460], [duration, 508]]}
        camera={[
          { at: 0, x: 0.5, y: 0.5, zoom: fit },
          { at: 25, x: rightEdge(1.1), y: 0.4, zoom: 1.1 },
          { at: 78, x: rightEdge(1.1), y: 0.4, zoom: 1.1 },
          { at: 113, x: rightEdge(1.1), y: 0.7, zoom: 1.1 },
          { at: duration, x: rightEdge(1.1), y: 0.7, zoom: 1.1 },
        ]} />
      <Caption from={117} to={duration}>New composer · current development build</Caption>
    </Enter>
  </Background>
);

/// Recorded after closing the connection, so the empty window really has no connection. Opening PostgreSQL at
/// frame 304 restores all four tabs; the Orders tab is selected at 398 and the file tab at 470.
const WorkspaceState: React.FC<SceneProps> = ({ duration, events }) => (
  <Background>
    <Enter duration={duration}>
      <Title text="Pick up where you left off" sub="Each connection remembers its tabs, SQL, schema and query history" />
      <Recording name={file("state")} events={events} duration={duration} pointer="clicks"
        timeline={[[0, 286], [18, 304], [42, 328], [84, 398], [126, 440], [156, 470], [duration, 544]]}
        camera={[
          { at: 0, x: 0.5, y: 0.47, zoom: 1.15 },
          { at: 24, x: 0.5, y: 0.47, zoom: 1.15 },
          { at: 52, x: 0.48, y: 0.28, zoom: 1.45 },
          { at: 190, x: 0.48, y: 0.28, zoom: 1.45 },
          { at: duration, x: 0.5, y: 0.5, zoom: fit },
        ]}>
        <Mark from={44} to={78} left={0.184} top={0.068} width={0.65} height={0.038} label="Your tabs, restored" />
      </Recording>
      <Caption from={44} to={80}>Your SQL comes back. It is not run automatically.</Caption>
      <Caption from={166} to={214}>Table tabs and .sql files, together</Caption>
    </Enter>
  </Background>
);

/// Recorded at 30 frames a second: Triggers, Functions, Views and Tables collapse at 181, 227, 272 and 316; Tables
/// opens again at 379.
const Sidebar: React.FC<SceneProps> = ({ duration, events }) => (
  <Background>
    <Enter duration={duration}>
      <Title text="Fold the sidebar" sub="Collapse Tables, Views, Functions or Triggers; Tabula remembers" />
      <Recording name={file("sidebar")} events={events} duration={duration} pointer="clicks"
        timeline={[[0, 168], [13, 181], [36, 227], [59, 272], [81, 316], [113, 379], [duration, 426]]}
        camera={[
          { at: 0, x: 0.5, y: 0.5, zoom: fit },
          { at: 14, x: 0.32, y: 0.42, zoom: 1.6 },
          { at: duration, x: 0.32, y: 0.38, zoom: 1.7 },
        ]} />
    </Enter>
  </Background>
);

/// Recorded at 30 frames a second: the file opens at 243 (as from Finder), the caret moves at 304–358, typing
/// 385–424, Save at 471, ⌘↩ at 534.
const SQLFile: React.FC<SceneProps> = ({ duration, events }) => (
  <Background>
    <Enter duration={duration}>
      <Title text="Open and save .sql files" sub="⌘O opens, a dot marks unsaved edits, ⌘S saves" />
      <Recording name={file("sqlfile")} events={events} duration={duration} pointer="clicks"
        timeline={[[0, 228], [15, 243], [45, 303], [72, 358], [85, 385], [105, 424], [128, 471], [159, 534], [duration, 580]]}
        camera={[
          { at: 0, x: 0.5, y: 0.5, zoom: fit },
          { at: 20, x: 0.42, y: 0.2, zoom: 2.0 },
          { at: 150, x: 0.42, y: 0.2, zoom: 2.0 },
          { at: 170, x: 0.5, y: 0.35, zoom: 1.2 },
          { at: duration, x: 0.5, y: 0.35, zoom: 1.25 },
        ]}>
        <Mark from={92} to={128} left={0.185} top={0.068} width={0.17} height={0.04} label="Unsaved" />
      </Recording>
      <Caption from={15} to={44}>A file opened from Finder</Caption>
      <Caption from={112} to={150}><Key>⌘</Key><Key>S</Key> or the Save button</Caption>
      <Caption from={154} to={duration}><Key>⌘</Key><Key>Return</Key> runs it</Caption>
    </Enter>
  </Background>
);

/// Recorded at 30 frames a second in the Connections window: Connection String… at 167, the field at 221, the
/// string pasted at 262, Continue at 347, the filled-in form from about 352.
const ConnString: React.FC<SceneProps> = ({ duration, events }) => (
  <Background>
    <Enter duration={duration}>
      <Title text="Paste a connection string" sub="URLs, JDBC or key=value pairs: Tabula fills in the form" />
      <Recording name={file("connstring")} events={events} duration={duration} pointer="clicks" aspect={connectionsAspect} shape="connections"
        timeline={[[0, 150], [17, 167], [44, 221], [65, 262], [107, 347], [duration, 425]]}
        camera={[
          { at: 0, x: 0.5, y: 0.5, zoom: connectionsFit },
          { at: 10, x: 0.3, y: 0.7, zoom: 1.2 },
          { at: 34, x: 0.5, y: 0.47, zoom: 1.25 },
          { at: 106, x: 0.5, y: 0.47, zoom: 1.25 },
          { at: 128, x: 0.5, y: 0.5, zoom: connectionsFit * 1.12 },
          { at: duration, x: 0.5, y: 0.5, zoom: connectionsFit * 1.15 },
        ]} />
      <Caption from={62} to={100}><Key>⌘</Key><Key>V</Key> and Tabula shows what it read</Caption>
    </Enter>
  </Background>
);

const Outro: React.FC = () => {
  const frame = useFrame();
  const icon = spring({ frame, fps: unit, config: { damping: 14, stiffness: 130 } });
  const button = spring({ frame: frame - 18, fps: unit, config: { damping: 16, stiffness: 150 } });
  return (
    <Background>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
        <Img src={staticFile("icon.png")} style={{ width: 150, height: 150, transform: `scale(${icon})` }} />
        <Sfx at={18} name="chime" volume={0.6} />
        <div style={{ height: 120, position: "relative", width: "100%" }}><Title text="Tabula 0.5.4" top={10} at={4} /></div>
        <div style={{ fontSize: 34, color: "rgba(255,255,255,0.8)", opacity: spring({ frame: frame - 12, fps: unit, config: { damping: 200 } }) }}>
          Free · Native · No account, no telemetry
        </div>
        <div style={{ marginTop: 40, fontSize: 34, padding: "16px 34px", borderRadius: 14, background: accent, fontWeight: 700, opacity: button, transform: `scale(${0.9 + 0.1 * button})`, boxShadow: `0 10px 40px ${accent}66` }}>
          github.com/tungnguyenvan/tabula
        </div>
      </AbsoluteFill>
    </Background>
  );
};

const scenes: { duration: number; render: (duration: number, props: WhatsNewProps) => React.ReactNode }[] = [
  { duration: 80, render: (d) => <Intro duration={d} /> },
  { duration: 205, render: (d, p) => <Tools duration={d} events={p.events.tools ?? []} /> },
  { duration: 165, render: (d, p) => <History duration={d} events={p.events.history ?? []} /> },
  { duration: 230, render: (d, p) => <WorkspaceState duration={d} events={p.events.state ?? []} /> },
  { duration: 150, render: (d, p) => <Sidebar duration={d} events={p.events.sidebar ?? []} /> },
  { duration: 205, render: (d, p) => <SQLFile duration={d} events={p.events.sqlfile ?? []} /> },
  { duration: 185, render: (d, p) => <ConnString duration={d} events={p.events.connstring ?? []} /> },
  { duration: 85, render: () => <Outro /> },
];

export const whatsNewDuration = scenes.reduce((total, scene) => total + scene.duration, 0) * scale;

export const WhatsNew: React.FC<WhatsNewProps> = (props) => (
  <>
    <Audio src={staticFile("audio/music.wav")}
      volume={(frame) => interpolate(frame, [0, 20 * scale, whatsNewDuration - 50 * scale, whatsNewDuration], [0, 0.85, 0.85, 0], clamp)} />
    <Series>
      {scenes.map((scene, index) => (
        <Series.Sequence key={index} durationInFrames={scene.duration * scale}>
          {scene.render(scene.duration, props)}
        </Series.Sequence>
      ))}
    </Series>
  </>
);

