import React from "react";
import { AbsoluteFill, Audio, Easing, Img, interpolate, spring, staticFile } from "remotion";
import { clamp, scale, unit, useFrame } from "./Demo";

/// A 5-second clip for Halloween: the Tabula icon spins and turns into its Halloween version, then bats fly around
/// it (scripts/render-halloween.sh). Timed in thirtieths of a second, as in Demo.tsx; the sound is
/// audio/halloween.wav from demo/audio/make-audio.mjs, timed to the same moments.
const length = 150;
export const halloweenDuration = length * scale;

const font = "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Helvetica Neue', sans-serif";
const orange = "#ff8a1f";
const iconSize = 560;

const spinStart = 21;
const spinEnd = 87;
/// Three whole turns, so the icon lands facing front.
const spinDegrees = 1080;
/// The picture changes while the icon is edge-on, past the middle of the spin.
const swapDegrees = 630;
const spinEasing = Easing.inOut(Easing.cubic);

const angleAt = (frame: number) =>
  interpolate(frame, [spinStart, spinEnd], [0, spinDegrees], { ...clamp, easing: spinEasing });

/// The first frame at which the spin has passed `swapDegrees`.
const swapFrame = (() => {
  let frame = spinStart;
  while (angleAt(frame) < swapDegrees) {
    frame += 0.25;
  }
  return frame;
})();

const batsStart = spinEnd + 2;

const Icon: React.FC = () => {
  const frame = useFrame();
  const angle = angleAt(frame);
  const appear = spring({ frame, fps: unit, config: { damping: 14, stiffness: 120 } });
  const landing = spring({ frame: frame - spinEnd, fps: unit, config: { damping: 9, stiffness: 160 } });
  const spinning = interpolate(frame, [spinStart, (spinStart + spinEnd) / 2, spinEnd], [0, 1, 0], clamp);
  const size = appear * (1 + 0.06 * spinning) * (frame < spinEnd ? 1 : 0.94 + 0.06 * landing);
  const halloween = angle >= swapDegrees;
  // Past a quarter turn the picture faces away and would read mirrored; flip it back.
  const facingAway = Math.cos((angle * Math.PI) / 180) < 0;
  const source = halloween ? "halloween-icon.png" : "icon.png";
  return (
    <div style={{ perspective: 1600, width: iconSize, height: iconSize }}>
      <div style={{ width: "100%", height: "100%", transform: `rotateY(${angle}deg) scale(${size})` }}>
        <Img src={staticFile(source)} style={{ width: "100%", height: "100%", transform: facingAway ? "scaleX(-1)" : undefined }} />
      </div>
    </div>
  );
};

/// An orange glow behind the icon once it has turned.
const Glow: React.FC = () => {
  const frame = useFrame();
  const glow = spring({ frame: frame - swapFrame, fps: unit, config: { damping: 30, stiffness: 60 } });
  const breathe = 1 + 0.05 * Math.sin(frame / 9);
  return (
    <div style={{ position: "absolute", width: iconSize * 1.8, height: iconSize * 1.8, borderRadius: "50%", opacity: glow * 0.55,
      transform: `scale(${breathe})`, background: `radial-gradient(circle, ${orange}aa 0%, ${orange}33 35%, transparent 68%)` }} />
  );
};

/// Sparks that burst out as the icon turns.
const Sparks: React.FC = () => {
  const frame = useFrame();
  const age = frame - swapFrame;
  if (age < 0 || age > 24) {
    return null;
  }
  const sparks = Array.from({ length: 14 }, (_, index) => index);
  return (
    <>
      {sparks.map((index) => {
        const direction = (index / sparks.length) * Math.PI * 2 + 0.3;
        const distance = interpolate(age, [0, 24], [iconSize * 0.3, iconSize * 0.85], { ...clamp, easing: Easing.out(Easing.cubic) });
        const fade = interpolate(age, [0, 6, 24], [0, 1, 0], clamp);
        const size = 6 + (index % 3) * 3;
        return (
          <div key={index} style={{ position: "absolute", width: size, height: size, borderRadius: "50%", background: index % 2 === 0 ? orange : "#ffd9a8",
            boxShadow: `0 0 12px ${orange}`, opacity: fade,
            transform: `translate(${Math.cos(direction) * distance}px, ${Math.sin(direction) * distance}px)` }} />
        );
      })}
    </>
  );
};

/// A bat silhouette, wings flapping about eight times a second.
const Bat: React.FC<{ size: number; flap: number; shade: number }> = ({ size, flap, shade }) => {
  const lift = Math.sin(flap) * 28;
  const color = `rgb(${Math.round(40 * shade)}, ${Math.round(18 * shade)}, ${Math.round(62 * shade)})`;
  const wing = "M0 0 C -14 -16, -34 -20, -52 -12 C -46 -6, -44 0, -46 6 C -40 2, -34 4, -30 10 C -24 4, -16 4, -10 10 C -8 4, -4 2, 0 2 Z";
  return (
    <svg width={size} height={size * 0.6} viewBox="-60 -30 120 60"
      style={{ overflow: "visible", filter: `drop-shadow(0 0 ${size * 0.06}px ${orange}) drop-shadow(0 0 ${size * 0.02}px ${orange})` }}>
      <g transform={`rotate(${-lift})`}>
        <path d={wing} fill={color} />
      </g>
      <g transform={`scale(-1, 1) rotate(${-lift})`}>
        <path d={wing} fill={color} />
      </g>
      <ellipse cx="0" cy="2" rx="7" ry="11" fill={color} />
      <path d="M -6 -6 L -5 -15 L -1 -9 L 1 -9 L 5 -15 L 6 -6 Z" fill={color} />
      <circle cx="-2.5" cy="-5" r="1.4" fill={orange} />
      <circle cx="2.5" cy="-5" r="1.4" fill={orange} />
    </svg>
  );
};

type Orbit = { delay: number; radiusX: number; radiusY: number; speed: number; phase: number; height: number; size: number };

/// Each bat sweeps in from outside the picture, then circles the icon; on the far side of its loop it is smaller,
/// darker and behind the icon.
const orbits: Orbit[] = [
  { delay: 0, radiusX: 400, radiusY: 120, speed: 0.11, phase: 3.6, height: -190, size: 240 },
  { delay: 4, radiusX: 450, radiusY: 140, speed: -0.09, phase: 0.4, height: 40, size: 200 },
  { delay: 9, radiusX: 370, radiusY: 100, speed: 0.13, phase: 1.9, height: 230, size: 170 },
  { delay: 13, radiusX: 480, radiusY: 160, speed: -0.1, phase: 5.2, height: -70, size: 150 },
  { delay: 18, radiusX: 330, radiusY: 90, speed: 0.15, phase: 2.8, height: -290, size: 130 },
];

const Bats: React.FC<{ side: "front" | "back" }> = ({ side }) => {
  const frame = useFrame();
  return (
    <>
      {orbits.map((orbit, index) => {
        const age = frame - batsStart - orbit.delay;
        if (age < 0) {
          return null;
        }
        const angle = orbit.phase + orbit.speed * age;
        const depth = Math.sin(angle);
        if ((side === "front") !== (depth >= 0)) {
          return null;
        }
        const arrive = interpolate(age, [0, 18], [2.4, 1], { ...clamp, easing: Easing.out(Easing.cubic) });
        const x = Math.cos(angle) * orbit.radiusX * arrive;
        const y = orbit.height + depth * orbit.radiusY * 0.35 + Math.sin(age / 5 + index) * 10;
        const near = 0.75 + 0.25 * depth;
        const fade = interpolate(frame, [length - 10, length], [1, 0], clamp);
        return (
          <div key={index} style={{ position: "absolute", opacity: fade, transform: `translate(${x}px, ${y}px) scale(${near})` }}>
            <Bat size={orbit.size} flap={age * 1.7 + index} shade={0.6 + 0.4 * near} />
          </div>
        );
      })}
    </>
  );
};

const Greeting: React.FC = () => {
  const frame = useFrame();
  const rise = spring({ frame: frame - 100, fps: unit, config: { damping: 18, stiffness: 120 } });
  return (
    <div style={{ position: "absolute", bottom: 90, left: 0, right: 0, textAlign: "center", fontFamily: font, color: "white",
      fontSize: 52, fontWeight: 700, letterSpacing: -1, opacity: rise, transform: `translateY(${(1 - rise) * 24}px)`,
      textShadow: `0 6px 30px ${orange}88` }}>
      Happy Halloween
    </div>
  );
};

export const HalloweenIcon: React.FC = () => {
  const frame = useFrame();
  const night = interpolate(frame, [swapFrame, spinEnd + 10], [0, 1], clamp);
  return (
    <AbsoluteFill style={{ background: `radial-gradient(circle at 50% 45%, rgb(${34 + 20 * night}, ${22 - 6 * night}, ${58}) 0%, #0b0712 60%, #050308 100%)`, overflow: "hidden" }}>
      <Audio src={staticFile("audio/halloween.wav")} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
        <Glow />
        <Bats side="back" />
        <Icon />
        <Sparks />
        <Bats side="front" />
      </AbsoluteFill>
      <Greeting />
    </AbsoluteFill>
  );
};
