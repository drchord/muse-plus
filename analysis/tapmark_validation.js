#!/usr/bin/env bun
// tapmark_validation.js — Validate gauge-depth vs user tap-marks
// Usage: bun tapmark_validation.js [path/to/session.ndjson]
// Requires Bun (no npm deps).

import { readFileSync } from "fs";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
const DEFAULT_PATH =
  "C:\\Users\\sugat\\MusePlus\\analysis\\incoming\\session_2026-05-09_0846.ndjson";
const WINDOW_SEC = 5; // ± seconds around each mark

const filePath = process.argv[2] ?? DEFAULT_PATH;

// ---------------------------------------------------------------------------
// Parse
// ---------------------------------------------------------------------------
let rawText;
try {
  rawText = readFileSync(filePath, "utf8");
} catch (e) {
  console.error(`[ERROR] Cannot open file: ${filePath}`);
  console.error(`  ${e.message}`);
  process.exit(1);
}

const lines = rawText.split("\n").filter((l) => l.trim().length > 0);
const records = [];
let malformed = 0;

for (const line of lines) {
  try {
    records.push(JSON.parse(line));
  } catch {
    malformed++;
  }
}

if (malformed > 0) {
  console.warn(`[WARN] Skipped ${malformed} malformed line(s).`);
}

console.log(`Parsed ${records.length} records from: ${filePath}`);

// ---------------------------------------------------------------------------
// Separate by type
// ---------------------------------------------------------------------------
const header = records.find((r) => r._type === "header");
const samples = records.filter((r) => r._type === "sample");
const marks = records.filter((r) => r._type === "mark");
const footer = records.find((r) => r._type === "footer");

console.log(
  `  header: ${header ? 1 : 0}  samples: ${samples.length}  marks: ${marks.length}  footer: ${footer ? 1 : 0}`
);

if (samples.length === 0) {
  console.error("[ERROR] No sample records found — cannot validate.");
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Check raw EEG channel presence
// ---------------------------------------------------------------------------
const firstSample = samples[0];
const RAW_EEG_CANDIDATES = [
  "eegTP9", "eegAF7", "eegAF8", "eegTP10",
  "tp9", "af7", "af8", "tp10",
  "eeg_tp9", "eeg_af7", "eeg_af8", "eeg_tp10",
];

const presentRawFields = RAW_EEG_CANDIDATES.filter(
  (f) => firstSample[f] !== undefined
);

console.log("");
if (presentRawFields.length === 0) {
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log("[RAW EEG CHECK] ABSENT");
  console.log(
    "  No raw EEG channel fields found in this session's samples."
  );
  console.log(
    "  (Checked: " + RAW_EEG_CANDIDATES.join(", ") + ")"
  );
  console.log(
    "  This session (B82 or earlier) only contains band-power features."
  );
  console.log(
    "  Re-run this script after B83 ships with raw EEG instrumentation."
  );
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log("");
  console.log("Continuing with ecdfDisplay-only analysis (gauge validation)...");
  console.log("");
} else {
  console.log(`[RAW EEG CHECK] PRESENT — fields: ${presentRawFields.join(", ")}`);
  console.log("");
}

// ---------------------------------------------------------------------------
// Confirm ecdfDisplay presence
// ---------------------------------------------------------------------------
const hasEcdf = samples.some((s) => s.ecdfDisplay !== undefined);
if (!hasEcdf) {
  console.error(
    "[ERROR] No ecdfDisplay field found in samples — cannot compute gauge scores."
  );
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Mark categorisation
// ---------------------------------------------------------------------------
// kind: "deep" → user self-reported deep
// kind: "shallow" → user self-reported shallow/light
// kind: "neutral" or absent → treat as neutral (excluded from deep/shallow diff)
const deepMarks = marks.filter((m) => m.kind === "deep");
const shallowMarks = marks.filter(
  (m) => m.kind === "shallow"
);
const neutralMarks = marks.filter(
  (m) => !m.kind || m.kind === "neutral"
);

console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
console.log("MARK INVENTORY");
console.log(`  Deep marks:    ${deepMarks.length}`);
console.log(`  Shallow marks: ${shallowMarks.length}`);
console.log(`  Neutral marks: ${neutralMarks.length}`);
console.log(`  Total marks:   ${marks.length}`);
console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
console.log("");

if (marks.length === 0) {
  console.log(
    "[NOTE] No mark records in this session. Tap-mark feature requires B77+."
  );
  console.log(
    "       Record a session with user taps to enable gauge validation."
  );
  printFilterPreflight();
  process.exit(0);
}

// ---------------------------------------------------------------------------
// Windowed ecdfDisplay mean
// ---------------------------------------------------------------------------
function windowedMean(markTime, windowSec) {
  const lo = markTime - windowSec;
  const hi = markTime + windowSec;
  const inWindow = samples.filter(
    (s) => s.time !== undefined && s.time >= lo && s.time <= hi && s.ecdfDisplay !== undefined
  );
  if (inWindow.length === 0) return null;
  const sum = inWindow.reduce((acc, s) => acc + s.ecdfDisplay, 0);
  return sum / inWindow.length;
}

// Annotate each mark with its windowed gauge score
function annotateMarks(markArr) {
  return markArr.map((m) => {
    const score = windowedMean(m.time, WINDOW_SEC);
    return { ...m, gaugeScore: score };
  });
}

const deepAnnotated = annotateMarks(deepMarks).filter(
  (m) => m.gaugeScore !== null
);
const shallowAnnotated = annotateMarks(shallowMarks).filter(
  (m) => m.gaugeScore !== null
);

// ---------------------------------------------------------------------------
// Aggregate metrics
// ---------------------------------------------------------------------------
function mean(arr) {
  if (arr.length === 0) return null;
  return arr.reduce((a, b) => a + b, 0) / arr.length;
}

const deepScores = deepAnnotated.map((m) => m.gaugeScore);
const shallowScores = shallowAnnotated.map((m) => m.gaugeScore);

const meanDeep = mean(deepScores);
const meanShallow = mean(shallowScores);
const diff =
  meanDeep !== null && meanShallow !== null ? meanDeep - meanShallow : null;

// ---------------------------------------------------------------------------
// Print results
// ---------------------------------------------------------------------------
console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
console.log(`GAUGE VALIDATION  (window = ±${WINDOW_SEC}s)`);
console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

if (deepAnnotated.length > 0) {
  console.log(
    `  Mean ecdfDisplay @ deep marks    : ${meanDeep.toFixed(4)}  (n=${deepAnnotated.length})`
  );
} else {
  console.log(`  Mean ecdfDisplay @ deep marks    : N/A  (no scorable deep marks)`);
}

if (shallowAnnotated.length > 0) {
  console.log(
    `  Mean ecdfDisplay @ shallow marks : ${meanShallow.toFixed(4)}  (n=${shallowAnnotated.length})`
  );
} else {
  console.log(
    `  Mean ecdfDisplay @ shallow marks : N/A  (no scorable shallow marks)`
  );
}

if (diff !== null) {
  const verdict = diff > 0 ? "GAUGE AGREES WITH USER ✓" : "GAUGE DISAGREES ✗";
  console.log(`  Difference (deep − shallow)      : ${diff.toFixed(4)}`);
  console.log(`  Verdict                          : ${verdict}`);
} else {
  console.log(
    `  Difference                       : N/A — need both deep AND shallow marks`
  );
}
console.log("");

// ---------------------------------------------------------------------------
// Worst-case deep marks (lowest gauge score = most missed by gauge)
// ---------------------------------------------------------------------------
if (deepAnnotated.length > 0) {
  const sorted = [...deepAnnotated].sort((a, b) => a.gaugeScore - b.gaugeScore);
  const worst = sorted.slice(0, 5);
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log(
    "TOP 5 DEEP MARKS WITH LOWEST GAUGE SCORE  (filter wins here)"
  );
  console.log("  time(s)   gaugeScore  kind");
  for (const m of worst) {
    console.log(
      `  ${String(m.time ?? "?").padStart(7)}   ${m.gaugeScore.toFixed(4)}      ${m.kind ?? "?"}`
    );
  }
  console.log("");
}

// ---------------------------------------------------------------------------
// Worst-case shallow marks (highest gauge score = gauge most wrong)
// ---------------------------------------------------------------------------
if (shallowAnnotated.length > 0) {
  const sorted = [...shallowAnnotated].sort(
    (a, b) => b.gaugeScore - a.gaugeScore
  );
  const worst = sorted.slice(0, 5);
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log(
    "TOP 5 SHALLOW MARKS WITH HIGHEST GAUGE SCORE  (inverse filter wins)"
  );
  console.log("  time(s)   gaugeScore  kind");
  for (const m of worst) {
    console.log(
      `  ${String(m.time ?? "?").padStart(7)}   ${m.gaugeScore.toFixed(4)}      ${m.kind ?? "?"}`
    );
  }
  console.log("");
}

// ---------------------------------------------------------------------------
// Filter pre-flight stub
// ---------------------------------------------------------------------------
printFilterPreflight();

function printFilterPreflight() {
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log("[FILTER PRE-FLIGHT]");
  console.log(
    "  Re-run this script after B83 ships with raw EEG instrumentation."
  );
  console.log(
    "  Expected: difference (deep − shallow) should INCREASE if the"
  );
  console.log(
    "  SWT denoiser in EEGDenoiser.swift correctly removes motion/EMG"
  );
  console.log("  artifacts and sharpens the depth signal.");
  console.log(
    "  Baseline to beat: " +
      (diff !== null ? diff.toFixed(4) : "N/A (run after adding both mark kinds)")
  );
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
}
