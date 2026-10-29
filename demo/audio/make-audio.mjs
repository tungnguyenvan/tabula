// Synthesizes the demo video's soundtrack and sound effects as WAV files, so the video uses no third-party audio.
//
//   node demo/audio/make-audio.mjs <directory>
//
// music.wav: calm and airy, in the manner of product videos: warm major-seventh chords on a soft electric
// piano, a mallet arpeggio, a pad, a sub bass and a light shaker, with a stereo echo for space (96 BPM).
// Effects, all quiet: click (mouse), key1–key4 (typing), keycap (Tab, ⌘↩), tink (titles, windows),
// chime (an answer arriving). halloween.wav: the soundtrack of the Halloween icon clip.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const rate = 44100;
const directory = process.argv[2] ?? "public/audio";
mkdirSync(directory, { recursive: true });

// A fixed seed, so every render sounds the same.
let seed = 11;
const random = () => {
  seed = (seed * 1664525 + 1013904223) >>> 0;
  return seed / 4294967296;
};
const noise = () => random() * 2 - 1;

const buffer = (seconds) => [new Float32Array(Math.ceil(seconds * rate)), new Float32Array(Math.ceil(seconds * rate))];

const writeWav = (name, [left, right], peakTarget = 0.89) => {
  const frames = left.length;
  const data = Buffer.alloc(44 + frames * 4);
  data.write("RIFF", 0);
  data.writeUInt32LE(36 + frames * 4, 4);
  data.write("WAVEfmt ", 8);
  data.writeUInt32LE(16, 16);
  data.writeUInt16LE(1, 20);
  data.writeUInt16LE(2, 22);
  data.writeUInt32LE(rate, 24);
  data.writeUInt32LE(rate * 4, 28);
  data.writeUInt16LE(4, 32);
  data.writeUInt16LE(16, 34);
  data.write("data", 36);
  data.writeUInt32LE(frames * 4, 40);
  let peak = 0;
  for (let i = 0; i < frames; i++) peak = Math.max(peak, Math.abs(left[i]), Math.abs(right[i]));
  const gain = peak > 0 ? peakTarget / peak : 1;
  for (let i = 0; i < frames; i++) {
    data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, left[i] * gain)) * 32767), 44 + i * 4);
    data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, right[i] * gain)) * 32767), 46 + i * 4);
  }
  writeFileSync(join(directory, name), data);
};

const midi = (note) => 440 * Math.pow(2, (note - 69) / 12);

const add = ([left, right], start, length, pan, sample) => {
  const from = Math.floor(start * rate);
  const count = Math.floor(length * rate);
  const l = Math.cos(((pan + 1) * Math.PI) / 4), r = Math.sin(((pan + 1) * Math.PI) / 4);
  for (let i = 0; i < count && from + i < left.length; i++) {
    const value = sample(i / rate);
    left[from + i] += value * l;
    right[from + i] += value * r;
  }
};

// MARK: Music

const bpm = 96;
const beat = 60 / bpm;
const bar = beat * 4;
const seconds = 50;
const music = buffer(seconds);
const bars = Math.ceil(seconds / bar);
// Fmaj7, Am7, Dm9, B♭maj7: roots and voicings (MIDI), warm and open.
const chords = [
  { root: 41, notes: [57, 60, 64, 65] },
  { root: 45, notes: [55, 60, 64, 67] },
  { root: 38, notes: [57, 60, 64, 65] },
  { root: 46, notes: [57, 62, 65, 69] },
];

/// A soft electric piano: a sine with a quiet bell partial, decaying slowly.
const piano = (frequency, gain) => (t) =>
  (Math.sin(2 * Math.PI * frequency * t) + 0.18 * Math.sin(2 * Math.PI * frequency * 3.01 * t) * Math.exp(-t * 6)) *
  Math.min(1, t / 0.008) * Math.exp(-t * 1.6) * gain;

/// A mallet: a pure tone with a short wooden partial.
const mallet = (frequency, gain) => (t) =>
  (Math.sin(2 * Math.PI * frequency * t) + 0.35 * Math.sin(2 * Math.PI * frequency * 4 * t) * Math.exp(-t * 40)) *
  Math.min(1, t / 0.004) * Math.exp(-t * 7) * gain;

for (let index = 0; index < bars; index++) {
  const chord = chords[index % chords.length];
  const start = index * bar;
  // Piano: the chord on beat one and, softer, on the "and" of two.
  for (const [offset, gain] of [[0, 0.05], [beat * 1.5, 0.03]]) {
    chord.notes.forEach((note, voice) => add(music, start + offset + voice * 0.012, bar, (voice - 1.5) * 0.3, piano(midi(note), gain)));
  }
  // Pad: the chord an octave up, breathing in and out under everything.
  for (const note of chord.notes) {
    const frequency = midi(note + 12);
    add(music, start, bar + 0.5, 0, (t) =>
      (Math.sin(2 * Math.PI * frequency * t) + Math.sin(2 * Math.PI * frequency * 1.003 * t)) *
      Math.sin(Math.PI * Math.min(1, t / (bar + 0.5))) * 0.006);
  }
  // Sub bass: the root, held, from the second bar.
  if (index >= 1) {
    const frequency = midi(chord.root - 12);
    add(music, start, bar, 0, (t) => Math.sin(2 * Math.PI * frequency * t) * Math.min(1, t / 0.05) * Math.exp(-t * 0.6) * 0.09);
  }
  // Mallet arpeggio in eighths, from the third bar, up the chord and back.
  if (index >= 2) {
    const order = [0, 1, 2, 3, 2, 1, 2, 3];
    for (let step = 0; step < 8; step++) {
      const note = chord.notes[order[step]] + 12;
      add(music, start + (step * beat) / 2, 0.6, step % 2 === 0 ? -0.4 : 0.4, mallet(midi(note), step === 0 ? 0.045 : 0.03));
    }
  }
  // A light shaker on the off-beats and a soft low pulse on one and three, from the fifth bar.
  if (index >= 4) {
    for (let step = 0; step < 8; step++) {
      let last = 0;
      add(music, start + (step * beat) / 2, 0.08, 0.3, (t) => {
        const value = noise();
        const high = value - last;
        last = value;
        return high * Math.exp(-t * 60) * (step % 2 === 1 ? 0.018 : 0.008);
      });
    }
    for (const step of [0, 2]) {
      add(music, start + step * beat, 0.3, 0, (t) => Math.sin(2 * Math.PI * (52 * t + (40 / 25) * (1 - Math.exp(-t * 25)))) * Math.exp(-t * 12) * 0.12);
    }
  }
}

// A stereo echo (dotted eighth, left and right in turn) gives the room.
const delay = Math.floor(beat * 0.75 * rate);
for (let i = delay; i < music[0].length; i++) {
  music[0][i] += music[1][i - delay] * 0.28;
  music[1][i] += music[0][i - delay] * 0.28;
}
for (let i = 0; i < music[0].length; i++) {
  music[0][i] = Math.tanh(music[0][i] * 1.2);
  music[1][i] = Math.tanh(music[1][i] * 1.2);
}
writeWav("music.wav", music);

// MARK: Effects

const effect = (name, length, sample, peak) => {
  const sound = buffer(length);
  add(sound, 0, length, 0, sample);
  writeWav(name, sound, peak);
};

// Mouse click: a small, soft tick, like a trackpad.
effect("click.wav", 0.05, (t) => (Math.sin(2 * Math.PI * 1500 * t) * Math.exp(-t * 260) + noise() * Math.exp(-t * 900) * 0.25), 0.35);

// Typing: four soft keys, slightly different, so a run of them doesn't sound mechanical.
for (let index = 1; index <= 4; index++) {
  const pitch = 0.9 + random() * 0.2;
  let low = 0;
  effect(`key${index}.wav`, 0.05, (t) => {
    low += 0.35 * (noise() - low);
    return low * Math.exp(-t * 320) * 0.6 + Math.sin(2 * Math.PI * 220 * pitch * t) * Math.exp(-t * 120) * 0.4;
  }, 0.22);
}

// Tab, ⌘↩: a rounder key.
effect("keycap.wav", 0.12, (t) => Math.sin(2 * Math.PI * 150 * t) * Math.exp(-t * 45) + noise() * Math.exp(-t * 400) * 0.15, 0.32);

// Tink: a gentle glassy note for titles and windows appearing.
effect("tink.wav", 0.6, (t) => (Math.sin(2 * Math.PI * midi(88) * t) + 0.3 * Math.sin(2 * Math.PI * midi(88) * 2.7 * t) * Math.exp(-t * 20)) * Math.exp(-t * 9), 0.18);

// Chime: two soft bell notes, a fifth apart, for an answer arriving.
effect("chime.wav", 1.6, (t) => {
  const bell = (frequency, start) => (t < start ? 0 : (Math.sin(2 * Math.PI * frequency * (t - start)) + 0.25 * Math.sin(2 * Math.PI * frequency * 2.76 * (t - start)) * Math.exp(-(t - start) * 8)) * Math.exp(-(t - start) * 3.2));
  return bell(midi(79), 0) + bell(midi(86), 0.11);
}, 0.3);


// MARK: Halloween icon video

// halloween.wav: the soundtrack of the 5-second icon video (demo/src/HalloweenIcon.tsx), timed to its picture.
// The old icon pops in (0.35 s), spins with a rising then falling whoosh (0.7–2.9 s), turns into the Halloween icon
// with a shimmer (2.0 s), lands on a low minor bell with a drone (2.9 s), then bats flutter and squeak around it.
{
  const length = 5;
  const sound = buffer(length);
  // Pop-in: the glassy tink, lower.
  add(sound, 0.35, 0.6, 0, (t) => Math.sin(2 * Math.PI * midi(81) * t) * Math.exp(-t * 10) * 0.35);
  // Whoosh: noise through a moving one-pole low-pass, swelling with the spin's speed and panning across.
  {
    const start = 0.7;
    const span = 2.2;
    let low = 0;
    let lower = 0;
    const from = Math.floor(start * rate);
    const count = Math.floor(span * rate);
    for (let i = 0; i < count; i++) {
      const progress = i / count;
      const speed = Math.sin(Math.PI * progress);
      const cutoff = 0.02 + 0.25 * speed;
      low += cutoff * (noise() - low);
      lower += cutoff * (low - lower);
      const value = lower * speed * speed * 0.9;
      const pan = Math.sin(progress * Math.PI * 6) * 0.6;
      sound[0][from + i] += value * Math.cos(((pan + 1) * Math.PI) / 4);
      sound[1][from + i] += value * Math.sin(((pan + 1) * Math.PI) / 4);
    }
  }
  // Shimmer as it turns: a quick upward run of soft bells.
  [76, 79, 83, 88, 91].forEach((note, index) => {
    add(sound, 1.95 + index * 0.05, 0.9, (index - 2) * 0.3, (t) =>
      Math.sin(2 * Math.PI * midi(note) * t) * Math.exp(-t * 7) * 0.14);
  });
  // Landing: a low bell on a minor chord, and a drone under the bats.
  const bell = (frequency) => (t) =>
    (Math.sin(2 * Math.PI * frequency * t) + 0.3 * Math.sin(2 * Math.PI * frequency * 2.4 * t) * Math.exp(-t * 4))
      * Math.exp(-t * 1.6);
  for (const note of [45, 52, 57, 60]) {
    add(sound, 2.9, 2.1, 0, (t) => bell(midi(note))(t) * 0.22);
  }
  add(sound, 2.9, 2.1, 0, (t) => {
    const swell = Math.min(1, t / 0.4) * Math.min(1, (2.1 - t) / 0.5);
    return (Math.sin(2 * Math.PI * midi(33) * t) + 0.4 * Math.sin(2 * Math.PI * midi(40) * t)) * swell * 0.18;
  });
  // Bats: bursts of wing flutter (noise pulsed about 18 times a second) that pass from side to side.
  const flutter = (start, span, fromPan, toPan) => {
    let low = 0;
    const from = Math.floor(start * rate);
    const count = Math.floor(span * rate);
    for (let i = 0; i < count; i++) {
      const t = i / rate;
      const progress = i / count;
      low += 0.18 * (noise() - low);
      const beat = Math.pow(Math.max(0, Math.sin(2 * Math.PI * 18 * t)), 3);
      const envelope = Math.sin(Math.PI * progress);
      const value = low * beat * envelope * 0.5;
      const pan = fromPan + (toPan - fromPan) * progress;
      sound[0][from + i] += value * Math.cos(((pan + 1) * Math.PI) / 4);
      sound[1][from + i] += value * Math.sin(((pan + 1) * Math.PI) / 4);
    }
  };
  flutter(3.0, 0.9, -0.9, 0.7);
  flutter(3.5, 0.8, 0.8, -0.6);
  flutter(4.0, 0.9, -0.5, 0.9);
  // Squeaks: short high chirps that slide down.
  const squeak = (start, pan, pitch) =>
    add(sound, start, 0.09, pan, (t) => {
      const frequency = pitch * (1 - t * 3);
      return Math.sin(2 * Math.PI * frequency * t) * Math.sin((Math.PI * t) / 0.09) * 0.12;
    });
  squeak(3.15, -0.6, 5200);
  squeak(3.3, -0.4, 6100);
  squeak(3.75, 0.7, 5600);
  squeak(4.2, -0.2, 6400);
  squeak(4.35, 0.1, 5000);
  // Fade the last half second.
  const fadeFrom = Math.floor(4.5 * rate);
  for (let i = fadeFrom; i < sound[0].length; i++) {
    const fade = 1 - (i - fadeFrom) / (sound[0].length - fadeFrom);
    sound[0][i] *= fade;
    sound[1][i] *= fade;
  }
  writeWav("halloween.wav", sound, 0.85);
}

console.log(`Wrote music.wav (${seconds} s) and effects to ${directory}`);
