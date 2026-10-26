// Synthesizes the demo video's soundtrack and sound effects as WAV files, so the video uses no third-party audio.
//
//   node demo/audio/make-audio.mjs <directory>
//
// music.wav: an upbeat electronic loop (118 BPM, Am–F–C–G) with pads, bass, an arpeggio and drums.
// Effects: click (mouse), key1–key4 (typing), keycap (Tab, ⌘↩), whoosh (scene changes), pop (titles), chime (answers).
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const rate = 44100;
const directory = process.argv[2] ?? "public/audio";
mkdirSync(directory, { recursive: true });

// A fixed seed, so every render sounds the same.
let seed = 7;
const random = () => {
  seed = (seed * 1664525 + 1013904223) >>> 0;
  return seed / 4294967296;
};
const noise = () => random() * 2 - 1;

const buffer = (seconds) => [new Float32Array(Math.ceil(seconds * rate)), new Float32Array(Math.ceil(seconds * rate))];

const writeWav = (name, [left, right]) => {
  const frames = left.length;
  const data = Buffer.alloc(44 + frames * 4);
  data.write("RIFF", 0);
  data.writeUInt32LE(36 + frames * 4, 4);
  data.write("WAVEfmt ", 8);
  data.writeUInt32LE(16, 16);
  data.writeUInt16LE(1, 20); // PCM
  data.writeUInt16LE(2, 22); // stereo
  data.writeUInt32LE(rate, 24);
  data.writeUInt32LE(rate * 4, 28);
  data.writeUInt16LE(4, 32);
  data.writeUInt16LE(16, 34);
  data.write("data", 36);
  data.writeUInt32LE(frames * 4, 40);
  let peak = 0;
  for (let i = 0; i < frames; i++) peak = Math.max(peak, Math.abs(left[i]), Math.abs(right[i]));
  const gain = peak > 0.89 ? 0.89 / peak : 1;
  for (let i = 0; i < frames; i++) {
    data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, left[i] * gain)) * 32767), 44 + i * 4);
    data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, right[i] * gain)) * 32767), 46 + i * 4);
  }
  writeFileSync(join(directory, name), data);
};

const midi = (note) => 440 * Math.pow(2, (note - 69) / 12);

/// Adds a voice to the buffer from `start` for `length` seconds, panned (-1 left … 1 right).
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

const bpm = 118;
const beat = 60 / bpm;
const bar = beat * 4;
const seconds = 42;
const music = buffer(seconds);
const bars = Math.ceil(seconds / bar);
// Am, F, C, G: roots and chord tones (MIDI).
const chords = [
  { root: 45, notes: [57, 60, 64] },
  { root: 41, notes: [53, 57, 60] },
  { root: 48, notes: [55, 60, 64] },
  { root: 43, notes: [55, 59, 62] },
];

const soft = (t, frequency) => Math.sin(2 * Math.PI * frequency * t) + 0.3 * Math.sin(4 * Math.PI * frequency * t) + 0.12 * Math.sin(6 * Math.PI * frequency * t);

for (let index = 0; index < bars; index++) {
  const chord = chords[index % chords.length];
  const start = index * bar;
  // Pad: three notes, each two slightly detuned voices, slow in and out.
  for (const note of chord.notes) {
    for (const detune of [-0.07, 0.07]) {
      const frequency = midi(note + detune);
      add(music, start, bar + 0.3, detune < 0 ? -0.5 : 0.5, (t) => {
        const envelope = Math.min(1, t / 0.35) * Math.min(1, Math.max(0, (bar + 0.3 - t) / 0.4));
        return soft(t, frequency) * envelope * 0.028;
      });
    }
  }
  // Bass: eighth notes on the root, from the second bar.
  if (index >= 1) {
    for (let step = 0; step < 8; step++) {
      const frequency = midi(chord.root - 12 + (step % 4 === 3 ? 12 : 0));
      add(music, start + (step * beat) / 2, beat / 2, 0, (t) => Math.tanh(1.6 * Math.sin(2 * Math.PI * frequency * t)) * Math.exp(-t * 7) * 0.13);
    }
  }
  // Arpeggio: sixteenths up the chord, an octave higher, from the second bar; lifts in the last bars.
  if (index >= 1) {
    const pattern = [0, 1, 2, 1, 0, 2, 1, 2];
    for (let step = 0; step < 16; step++) {
      const note = chord.notes[pattern[step % pattern.length]] + 12 + (index >= bars - 4 && step % 4 === 0 ? 12 : 0);
      const frequency = midi(note);
      add(music, start + (step * beat) / 4, 0.25, step % 2 === 0 ? -0.35 : 0.35, (t) => {
        const triangle = (2 / Math.PI) * Math.asin(Math.sin(2 * Math.PI * frequency * t));
        return triangle * Math.exp(-t * 18) * 0.06;
      });
    }
  }
  // Drums: kick on every beat from the second bar, hats on the off-beats from the third, a clap on 2 and 4 from the fifth.
  for (let step = 0; step < 4; step++) {
    const at = start + step * beat;
    if (index >= 1) {
      add(music, at, 0.35, 0, (t) => Math.sin(2 * Math.PI * (45 * t + (80 / 18) * (1 - Math.exp(-t * 18)))) * Math.exp(-t * 9) * 0.5);
    }
    if (index >= 2) {
      let last = 0;
      add(music, at + beat / 2, 0.06, 0.4, (t) => {
        const value = noise();
        const high = value - last;
        last = value;
        return high * Math.exp(-t * 70) * 0.06;
      });
    }
    if (index >= 4 && (step === 1 || step === 3)) {
      add(music, at, 0.2, -0.1, (t) => (noise() * 0.7 + Math.sin(2 * Math.PI * 190 * t) * 0.3) * Math.exp(-t * 22) * 0.12);
    }
  }
}

// Ducks everything but the kick a little on each beat, for the pumping feel of the genre.
for (let i = 0; i < music[0].length; i++) {
  const t = i / rate;
  const sinceBeat = t % beat;
  const duck = t >= bar ? 1 - 0.35 * Math.exp(-sinceBeat * 9) : 1;
  music[0][i] = Math.tanh(music[0][i] * 1.4 * duck);
  music[1][i] = Math.tanh(music[1][i] * 1.4 * duck);
}
writeWav("music.wav", music);

// MARK: Effects

const effect = (name, length, sample, pan = 0) => {
  const sound = buffer(length);
  add(sound, 0, length, pan, sample);
  writeWav(name, sound);
};

// Mouse click: a short bright tick with a little body.
effect("click.wav", 0.06, (t) => (noise() * Math.exp(-t * 400) * 0.5 + Math.sin(2 * Math.PI * 2400 * t) * Math.exp(-t * 180) * 0.4 + Math.sin(2 * Math.PI * 600 * t) * Math.exp(-t * 90) * 0.3));

// Typing: four slightly different keys, so a run of them doesn't sound mechanical.
for (let index = 1; index <= 4; index++) {
  const pitch = 0.85 + random() * 0.3;
  let last = 0;
  effect(`key${index}.wav`, 0.07, (t) => {
    const value = noise();
    const bright = value - last;
    last = value;
    return bright * Math.exp(-t * 260) * 0.45 + Math.sin(2 * Math.PI * 170 * pitch * t) * Math.exp(-t * 60) * 0.35;
  });
}

// A bigger key (Tab, ⌘↩): a deeper thock.
effect("keycap.wav", 0.14, (t) => noise() * Math.exp(-t * 160) * 0.35 + Math.sin(2 * Math.PI * 120 * t) * Math.exp(-t * 35) * 0.6);

// Whoosh: noise through a filter that opens and closes, swelling in and out.
{
  let low = 0;
  effect("whoosh.wav", 0.5, (t) => {
    const shape = Math.sin((Math.PI * t) / 0.5);
    const cutoff = 0.02 + 0.25 * shape;
    low += cutoff * (noise() - low);
    return low * shape * shape * 1.6;
  });
}

// Pop: a quick falling blip for titles and windows appearing.
effect("pop.wav", 0.12, (t) => Math.sin(2 * Math.PI * (500 * t + 400 * (1 - Math.exp(-t * 40)) / 40)) * Math.exp(-t * 30) * 0.5);

// Chime: two bell notes, for an answer arriving.
effect("chime.wav", 1.2, (t) => {
  const bell = (frequency, delay) => (t < delay ? 0 : (Math.sin(2 * Math.PI * frequency * (t - delay)) + 0.4 * Math.sin(2 * Math.PI * frequency * 2.76 * (t - delay))) * Math.exp(-(t - delay) * 4));
  return (bell(midi(76), 0) + bell(midi(83), 0.09)) * 0.22;
});

console.log(`Wrote music.wav (${seconds} s) and effects to ${directory}`);
