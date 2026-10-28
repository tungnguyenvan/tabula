// Synthesizes the demo video's soundtrack and sound effects as WAV files, so the video uses no third-party audio.
//
//   node demo/audio/make-audio.mjs <directory>
//
// music.wav: calm and airy, in the manner of product videos: warm major-seventh chords on a soft electric
// piano, a mallet arpeggio, a pad, a sub bass and a light shaker, with a stereo echo for space (96 BPM).
// Effects, all quiet: click (mouse), key1–key4 (typing), keycap (Tab, ⌘↩), tink (titles, windows),
// chime (an answer arriving).
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

console.log(`Wrote music.wav (${seconds} s) and effects to ${directory}`);
