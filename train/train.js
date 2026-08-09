#!/usr/bin/env node
// Trains bigram log-probability tables for Translit and emits Bigrams.swift.
//
// Usage:  node train.js <corpus-file-or-dir>...
//
// Every input file contributes to BOTH languages: Cyrillic words feed the
// Russian table, Latin words feed the English one, so mixed-language docs
// (READMEs, CLAUDE.md) are fine as-is.
//
// Output: ../Sources/translit/Bigrams.swift — two flat Int8 tables of
// scaled log2 conditional probabilities p(next | prev), boundary included.
// A validation pass simulates the runtime classifier on held-out words and
// prints accuracy plus score-gap percentiles used to pick the thresholds.

// Frequency lists ("word count" per line, e.g. hermitdave/FrequencyWords)
// are detected automatically and weighted by the count — real usage
// frequencies beat flat word lists for bigram estimation. Weights are
// dampened with sqrt so the top few words don't drown the tail.

const fs = require('fs');
const path = require('path');

// Known-word Bloom filters. Bigrams alone cannot tell a real word from a
// soup of frequent letter pairs ("inere" scored better than «штуку»), so the
// runtime also asks "is this an actual word?". ~30k words per language at
// ~1% false positives fits in ~36 KB each, emitted as base64.
const BLOOM_WORDS = 50000;
const BLOOM_BITS_PER_WORD = 16;
const BLOOM_HASHES = 11;

const EN = 'abcdefghijklmnopqrstuvwxyz'; // 26, index 1..26; 0 = boundary
const RU = 'абвгдежзийклмнопрстуфхцчшщъыьэюяё'; // 33, index 1..33; 0 = boundary
const LOG_SCALE = 4; // stored value = round(log2(p) * LOG_SCALE), clamped to Int8

// Physical-key mapping between US QWERTY and macOS Russian layouts, lowercase.
// Used only for validation (simulating a word typed in the wrong layout);
// the runtime builds its maps from the actual input sources via UCKeyTranslate.
const QWERTY_TO_RU = {
  q: 'й', w: 'ц', e: 'у', r: 'к', t: 'е', y: 'н', u: 'г', i: 'ш', o: 'щ', p: 'з',
  '[': 'х', ']': 'ъ',
  a: 'ф', s: 'ы', d: 'в', f: 'а', g: 'п', h: 'р', j: 'о', k: 'л', l: 'д',
  ';': 'ж', "'": 'э',
  z: 'я', x: 'ч', c: 'с', v: 'м', b: 'и', n: 'т', m: 'ь', ',': 'б', '.': 'ю',
  '`': 'ё',
};
const RU_TO_QWERTY = Object.fromEntries(
  Object.entries(QWERTY_TO_RU).map(([k, v]) => [v, k]),
);

// --- Corpus collection ---------------------------------------------------

function* walkFiles(entry) {
  const st = fs.statSync(entry);
  if (st.isFile()) {
    yield entry;
    return;
  }
  if (!st.isDirectory()) return;
  for (const name of fs.readdirSync(entry)) {
    if (name === 'node_modules' || name === '.git' || name === '.build') continue;
    yield* walkFiles(path.join(entry, name));
  }
}

// A file where the majority of the first lines look like "word 12345" is a
// frequency list, not running text.
function isFrequencyList(text) {
  const lines = text.split('\n', 50).filter((l) => l.trim());
  if (lines.length < 10) return false;
  const hits = lines.filter((l) => /^\S+ \d+$/.test(l)).length;
  return hits / lines.length > 0.8;
}

function extractWords(text) {
  const lower = text.toLowerCase();
  return {
    en: lower.match(/[a-z]+/g) || [],
    ru: lower.match(/[а-яё]+/g) || [],
  };
}

// --- Bigram counting -----------------------------------------------------

function makeCounter(alphabet) {
  const n = alphabet.length + 1; // +1 for boundary at index 0
  const index = new Map([...alphabet].map((ch, i) => [ch, i + 1]));
  const counts = new Float64Array(n * n);
  return {
    n,
    index,
    counts,
    addWord(word, weight = 1) {
      let prev = 0;
      for (const ch of word) {
        const cur = index.get(ch);
        if (cur === undefined) return; // shouldn't happen after regex filter
        counts[prev * n + cur] += weight;
        prev = cur;
      }
      counts[prev * n + 0] += weight; // word → boundary
    },
  };
}

// Conditional log2 probabilities with add-one smoothing, scaled and clamped.
function toLogTable(counter) {
  const { n, counts } = counter;
  const table = new Int8Array(n * n);
  for (let prev = 0; prev < n; prev++) {
    let rowTotal = 0;
    for (let cur = 0; cur < n; cur++) rowTotal += counts[prev * n + cur];
    for (let cur = 0; cur < n; cur++) {
      const p = (counts[prev * n + cur] + 1) / (rowTotal + n);
      const scaled = Math.round(Math.log2(p) * LOG_SCALE);
      table[prev * n + cur] = Math.max(-127, scaled);
    }
  }
  return table;
}

// --- Bloom filter (hashes mirrored exactly in the Swift runtime) ---------

// FNV-1a and djb2 over UTF-8 bytes, combined by double hashing. Both sides
// must agree bit for bit, so all arithmetic is explicitly 32-bit.
function bloomHashes(word, bitCount) {
  const bytes = Buffer.from(word, 'utf8');
  let h1 = 0x811c9dc5; // FNV-1a
  let h2 = 5381; // djb2
  for (const b of bytes) {
    h1 = Math.imul(h1 ^ b, 0x01000193) >>> 0;
    h2 = (Math.imul(h2, 33) + b) >>> 0;
  }
  if (h2 % 2 === 0) h2 = (h2 + 1) >>> 0; // odd step: visits distinct slots
  const out = [];
  for (let i = 0; i < BLOOM_HASHES; i++) {
    out.push(((h1 + Math.imul(i, h2)) >>> 0) % bitCount);
  }
  return out;
}

function buildBloom(words) {
  const bitCount = BLOOM_WORDS * BLOOM_BITS_PER_WORD;
  const bytes = new Uint8Array(Math.ceil(bitCount / 8));
  for (const word of words) {
    for (const bit of bloomHashes(word, bitCount)) {
      bytes[bit >> 3] |= 1 << (bit & 7);
    }
  }
  return { bytes, bitCount };
}

// --- Scoring (mirrors the Swift runtime) ---------------------------------

// Average scaled log2 prob per transition; null when the word contains a
// character outside the alphabet (impossible reading).
function scoreWord(word, counter, table) {
  const { n, index } = counter;
  let sum = 0;
  let prev = 0;
  for (const ch of word) {
    const cur = index.get(ch);
    if (cur === undefined) return null;
    sum += table[prev * n + cur];
    prev = cur;
  }
  sum += table[prev * n + 0];
  return sum / (word.length + 1);
}

// --- Main ----------------------------------------------------------------

function main() {
  const inputs = process.argv.slice(2);
  if (inputs.length === 0) {
    console.error('usage: node train.js <file-or-dir>...');
    process.exit(1);
  }

  const enWords = [];
  const ruWords = [];
  // word → dampened weight, filled from frequency lists; applied at training.
  const enWeighted = new Map();
  const ruWeighted = new Map();
  // word → raw count, used to pick the most frequent words for the Bloom
  // filters (running text contributes with count 1 per occurrence).
  const enFreq = new Map();
  const ruFreq = new Map();
  let files = 0;
  for (const input of inputs) {
    for (const file of walkFiles(input)) {
      let text;
      try {
        text = fs.readFileSync(file, 'utf8');
      } catch {
        continue;
      }
      files++;
      if (isFrequencyList(text)) {
        for (const line of text.split('\n')) {
          const m = line.match(/^(\S+) (\d+)$/);
          if (!m) continue;
          const word = m[1].toLowerCase();
          const weight = Math.sqrt(Number(m[2]));
          const count = Number(m[2]);
          if (/^[a-z]+$/.test(word)) {
            enWeighted.set(word, (enWeighted.get(word) || 0) + weight);
            enFreq.set(word, (enFreq.get(word) || 0) + count);
          } else if (/^[а-яё]+$/.test(word)) {
            ruWeighted.set(word, (ruWeighted.get(word) || 0) + weight);
            ruFreq.set(word, (ruFreq.get(word) || 0) + count);
          }
        }
        continue;
      }
      const { en, ru } = extractWords(text);
      for (const w of en) {
        enWords.push(w);
        enFreq.set(w, (enFreq.get(w) || 0) + 1);
      }
      for (const w of ru) {
        ruWords.push(w);
        ruFreq.set(w, (ruFreq.get(w) || 0) + 1);
      }
    }
  }
  console.log(
    `corpus: ${files} files, ${enWords.length} en + ${ruWords.length} ru running words, ` +
    `${enWeighted.size} en + ${ruWeighted.size} ru weighted list entries`,
  );

  // Hold out every 10th word for validation.
  const split = (words) => {
    const train = [];
    const test = [];
    words.forEach((w, i) => (i % 10 === 9 ? test : train).push(w));
    return { train, test };
  };
  const en = split(enWords);
  const ru = split(ruWords);

  const enCounter = makeCounter(EN);
  const ruCounter = makeCounter(RU);
  en.train.forEach((w) => enCounter.addWord(w));
  ru.train.forEach((w) => ruCounter.addWord(w));
  for (const [w, weight] of enWeighted) enCounter.addWord(w, weight);
  for (const [w, weight] of ruWeighted) ruCounter.addWord(w, weight);
  const enTable = toLogTable(enCounter);
  const ruTable = toLogTable(ruCounter);

  // --- Validation: can we tell "typed in wrong layout" from correct text? --
  //
  // For each held-out ru word, its en-projection is what would appear on
  // screen if typed with the en layout active (and vice versa). The runtime
  // switches when: own-reading score is null-or-bad AND other-reading beats
  // it by a margin. Here we measure the raw gap distribution.
  const project = (word, map) => [...word].map((ch) => map[ch] ?? ' ').join('');

  function evaluate(words, ownCounter, ownTable, otherCounter, otherTable, mapToOther, label) {
    let correct = 0;
    let total = 0;
    const gaps = [];
    for (const w of words) {
      if (w.length < 3) continue;
      const own = scoreWord(w, ownCounter, ownTable);
      if (own === null) continue; // word itself has out-of-alphabet chars
      const projected = project(w, mapToOther);
      const other = scoreWord(projected, otherCounter, otherTable);
      total++;
      // Correct behaviour: the true reading must win (other is null or worse).
      if (other === null || own > other) correct++;
      if (other !== null) gaps.push(own - other);
    }
    gaps.sort((a, b) => a - b);
    const pct = (p) => gaps.length ? gaps[Math.floor((gaps.length - 1) * p)].toFixed(1) : '—';
    console.log(
      `${label}: ${((correct / total) * 100).toFixed(2)}% of ${total} held-out words ` +
      `score their true reading higher; gap percentiles ` +
      `p1=${pct(0.01)} p5=${pct(0.05)} p50=${pct(0.5)} (scaled log2 units, >0 = true wins)`,
    );
  }

  evaluate(ru.test, ruCounter, ruTable, enCounter, enTable, RU_TO_QWERTY, 'ru');
  evaluate(en.test, enCounter, enTable, ruCounter, ruTable, QWERTY_TO_RU, 'en');

  // --- Emit Swift ---------------------------------------------------------
  const emit = (arr) => {
    const lines = [];
    for (let i = 0; i < arr.length; i += 30) {
      lines.push('    ' + Array.from(arr.slice(i, i + 30)).join(', ') + ',');
    }
    return lines.join('\n');
  };

  // Bloom filters over the most frequent words of each language. Words
  // shorter than 2 letters are pointless (the rules list covers them).
  const topWords = (freq) =>
    [...freq.entries()]
      .filter(([w]) => w.length >= 2)
      .sort((a, b) => b[1] - a[1])
      .slice(0, BLOOM_WORDS)
      .map(([w]) => w);
  const enTop = topWords(enFreq);
  const ruTop = topWords(ruFreq);
  const enBloom = buildBloom(enTop);
  const ruBloom = buildBloom(ruTop);

  // Measured false-positive rate on wrong-layout projections: how often a
  // garbage string is mistaken for a real word.
  const fpRate = (words, bloom, project) => {
    let hits = 0;
    let total = 0;
    for (const w of words) {
      const projected = project(w);
      if (!projected || projected.includes(' ')) continue;
      total++;
      if (bloomHashes(projected, bloom.bitCount).every((b) => bloom.bytes[b >> 3] & (1 << (b & 7)))) {
        hits++;
      }
    }
    return total ? (hits * 100) / total : 0;
  };
  console.log(
    `bloom: ${enTop.length} en words in ${(enBloom.bytes.length / 1024).toFixed(0)} KB, ` +
    `${ruTop.length} ru words in ${(ruBloom.bytes.length / 1024).toFixed(0)} KB`,
  );
  console.log(
    `bloom false positives on wrong-layout garbage: ` +
    `en ${fpRate(ruTop.slice(0, 5000), enBloom, (w) => project(w, RU_TO_QWERTY)).toFixed(2)}%, ` +
    `ru ${fpRate(enTop.slice(0, 5000), ruBloom, (w) => project(w, QWERTY_TO_RU)).toFixed(2)}%`,
  );

  const base64 = (bytes) => Buffer.from(bytes).toString('base64');

  const out = `// Generated by train/train.js — do not edit by hand.
// Scaled log2 conditional bigram probabilities: value = round(log2(p) * ${LOG_SCALE}),
// clamped to Int8. Index 0 is the word boundary; letters follow alphabet order.

// swiftlint:disable all

let enAlphabet = "${EN}"
let ruAlphabet = "${RU}"
let bigramLogScale = ${LOG_SCALE}

// ${enCounter.n}×${enCounter.n}, row = previous char, column = next char.
let enBigrams: [Int8] = [
${emit(enTable)}
]

// ${ruCounter.n}×${ruCounter.n}, row = previous char, column = next char.
let ruBigrams: [Int8] = [
${emit(ruTable)}
]

// Known-word Bloom filters (${BLOOM_HASHES} hashes). "Is this an actual word?"
// is the evidence bigrams cannot provide: a string of frequent letter pairs
// can outscore a real word, so a fix must land on a known word unless the
// statistics are overwhelming.
let bloomHashCount = ${BLOOM_HASHES}
let enBloomBitCount = ${enBloom.bitCount}
let ruBloomBitCount = ${ruBloom.bitCount}
let enBloomBase64 = "${base64(enBloom.bytes)}"
let ruBloomBase64 = "${base64(ruBloom.bytes)}"
`;
  const dest = path.join(__dirname, '..', 'Sources', 'translit', 'Bigrams.swift');
  fs.writeFileSync(dest, out);
  console.log(`wrote ${dest} (${enCounter.n * enCounter.n + ruCounter.n * ruCounter.n} table cells)`);
}

main();
