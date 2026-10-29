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

/// What's new in 0.6.0 and 0.7.0, each feature in the real app (scripts/render-whats-new.sh lists the recordings).
/// The pointer shows only where it clicks. Timed in thirtieths of a second, as in Demo.tsx.
export const whatsNewRecordings = ["ssh", "stop", "mysql", "tabs", "dump", "restore"] as const;
type Name = (typeof whatsNewRecordings)[number];
export type WhatsNewProps = { events: Partial<Record<Name, InputEvent[]>> };

/// The Connections window was recorded at 1000×640.
const connectionsAspect = 1280 / 2000;
/// The zoom that shows that whole window under the titles.
const connectionsFit = 0.84;

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

const versions = ["0.6.0", "0.7.0"];

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

/// Editing the PostgreSQL connection: Connect over SSH at 208, the SSH host typed at 295–387, the user at 420–460.
const SSH: React.FC<SceneProps> = ({ duration, events }) => (
  <Background>
    <Enter duration={duration}>
      <Title text="Connect over SSH" sub="PostgreSQL and MySQL through a bastion, with your SSH keys" />
      <Recording name={file("ssh")} events={events} duration={duration} pointer="clicks" aspect={connectionsAspect} shape="connections"
        timeline={[[0, 160], [15, 208], [35, 262], [50, 295], [80, 387], [95, 420], [115, 470], [duration, 560]]}
        camera={[
          { at: 0, x: 0.5, y: 0.5, zoom: connectionsFit },
          { at: 12, x: 0.5, y: 0.72, zoom: 1.35 },
          { at: duration, x: 0.5, y: 0.74, zoom: 1.45 },
        ]} />
      <Caption from={95} to={duration}>Key authentication only; host keys from known_hosts</Caption>
    </Enter>
  </Background>
);

/// A 30-second pg_sleep: typed at 181–208, run (⌘↩) at 237, Stop clicked at 360, the cancelled message from about 365.
const Stop: React.FC<SceneProps> = ({ duration, events }) => (
  <Background>
    <Enter duration={duration}>
      <Title text="Stop a running query" sub="PostgreSQL cancels it on the server; your transaction is left to you" />
      <Recording name={file("stop")} events={events} duration={duration} pointer="clicks"
        timeline={[[0, 165], [25, 237], [45, 300], [65, 360], [100, 420], [duration, 520]]}
        camera={[
          { at: 0, x: 0.5, y: 0.5, zoom: fit },
          { at: 14, x: 0.45, y: 0.22, zoom: 1.6 },
          { at: duration, x: 0.48, y: 0.24, zoom: 1.6 },
        ]}>
        <Mark from={70} to={115} left={0.2} top={0.265} width={0.65} height={0.04} label="Cancelled on the server" />
      </Recording>
      <Caption from={30} to={64}>Running… <Key>⌘</Key><Key>.</Key> or Stop</Caption>
    </Enter>
  </Background>
);

/// MySQL employees: run at 214, salary of row 2 edited at 367–421, dept of row 4 at 553–609, Commit 2 clicked at 693.
const MySQLEdit: React.FC<SceneProps> = ({ duration, events }) => (
  <Background>
    <Enter duration={duration}>
      <Title text="Edit MySQL query results" sub="Change cells in a SELECT's result, then commit them in one transaction" />
      <Recording name={file("mysql")} events={events} duration={duration} pointer="clicks"
        timeline={[[0, 200], [15, 230], [30, 304], [50, 367], [70, 421], [88, 490], [103, 553], [123, 609], [145, 693], [165, 760], [duration, 850]]}
        camera={[
          { at: 0, x: 0.5, y: 0.5, zoom: fit },
          { at: 20, x: 0.36, y: 0.36, zoom: 1.75 },
          { at: 126, x: 0.36, y: 0.36, zoom: 1.75 },
          { at: 140, x: 0.45, y: 0.62, zoom: 1.12 },
          { at: duration, x: 0.45, y: 0.62, zoom: 1.15 },
        ]} />
      <Caption from={125} to={160}>Commit, or <Key>⌘</Key><Key>S</Key></Caption>
    </Enter>
  </Background>
);

/// Query 1 runs at 217 and row 4 is selected at 307; customers opens at 389, order_items at 488; back to Query 1 at 586.
const Tabs: React.FC<SceneProps> = ({ duration, events }) => (
  <Background>
    <Enter duration={duration}>
      <Title text="Switch tabs instantly" sub="Each tab keeps its results, scroll position, selection and caret" />
      <Recording name={file("tabs")} events={events} duration={duration} pointer="clicks"
        timeline={[[0, 165], [20, 217], [40, 300], [50, 307], [75, 389], [100, 488], [125, 586], [duration, 700]]}
        camera={[
          { at: 0, x: 0.5, y: 0.5, zoom: fit },
          { at: 20, x: 0.5, y: 0.4, zoom: 1.12 },
          { at: duration, x: 0.5, y: 0.4, zoom: 1.15 },
        ]}>
        <Mark from={128} to={duration - 4} left={0.2} top={0.383} width={0.255} height={0.03} label="Same result, same row" />
      </Recording>
    </Enter>
  </Background>
);

/// The Dump sheet opens at about 190, Dump… is clicked at 307 (saving to a set file), pg_dump finishes at about 362.
const Dump: React.FC<SceneProps> = ({ duration, events }) => (
  <Background>
    <Enter duration={duration}>
      <Title text="Dump a database" sub="With the pg_dump or mysqldump you have installed; passwords never on a command line" />
      <Recording name={file("dump")} events={events} duration={duration} pointer="clicks"
        timeline={[[0, 190], [30, 274], [42, 307], [70, 362], [duration, 470]]}
        camera={[
          { at: 0, x: 0.5, y: 0.5, zoom: fit },
          { at: 14, x: 0.5, y: 0.5, zoom: 1.35 },
          { at: duration, x: 0.5, y: 0.5, zoom: 1.4 },
        ]} />
      <Caption from={74} to={duration}>File › Dump Database…, or Dump Table… in the sidebar</Caption>
    </Enter>
  </Background>
);

/// That dump restored into an empty database: the sheet at about 195, Restore clicked at 322, done at about 400.
const Restore: React.FC<SceneProps> = ({ duration, events }) => (
  <Background>
    <Enter duration={duration}>
      <Title text="Restore from a dump" sub="PostgreSQL restores all or nothing, in one transaction" />
      <Recording name={file("restore")} events={events} duration={duration} pointer="clicks"
        timeline={[[0, 195], [30, 290], [42, 322], [90, 400], [duration, 480]]}
        camera={[
          { at: 0, x: 0.5, y: 0.5, zoom: fit },
          { at: 14, x: 0.5, y: 0.5, zoom: 1.35 },
          { at: duration, x: 0.5, y: 0.5, zoom: 1.4 },
        ]} />
      <Caption from={94} to={duration}>Production restores ask for the database name first</Caption>
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
        <div style={{ height: 120, position: "relative", width: "100%" }}><Title text="Tabula 0.7.0" top={10} at={4} /></div>
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
  { duration: 150, render: (d, p) => <SSH duration={d} events={p.events.ssh ?? []} /> },
  { duration: 140, render: (d, p) => <Stop duration={d} events={p.events.stop ?? []} /> },
  { duration: 185, render: (d, p) => <MySQLEdit duration={d} events={p.events.mysql ?? []} /> },
  { duration: 160, render: (d, p) => <Tabs duration={d} events={p.events.tabs ?? []} /> },
  { duration: 120, render: (d, p) => <Dump duration={d} events={p.events.dump ?? []} /> },
  { duration: 140, render: (d, p) => <Restore duration={d} events={p.events.restore ?? []} /> },
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

