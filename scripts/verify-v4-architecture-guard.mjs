/* global console, process */

/**
 * Architecture v4 Guard Script
 *
 * Prevents new introductions of deprecated v3 concepts in production source code.
 * Uses a baseline allowlist: existing occurrences are recorded and permitted,
 * but any NEW occurrence not in the baseline causes a CI failure.
 *
 * Guard keywords:
 *   - ConclaveAgent (as type/interface/class identifier)
 *   - AgentEngine (as type/interface/class identifier)
 *   - WorkerPlugin (as type/interface/class identifier)
 *   - agent_plugin_installs (table/reference)
 *   - pluginId (field declarations and assignments in routing code)
 *
 * Usage:
 *   node scripts/verify-v4-architecture-guard.mjs                 # check mode (CI)
 *   node scripts/verify-v4-architecture-guard.mjs --update-baseline  # regenerate baseline
 */

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const BASELINE_PATH = join(__dirname, "v4-architecture-baseline.json");

const updateBaseline = process.argv.includes("--update-baseline");

// ── Guard keyword patterns ─────────────────────────────────────────────────
// Each pattern matches a deprecated v3 concept as an identifier boundary.
// We use word-boundary-like checks via the regex to avoid substring false
// positives (e.g. "ConclaveAgentApp" is a separate identifier from "ConclaveAgent").

const GUARD_PATTERNS = [
  {
    id: "ConclaveAgent",
    // Match ConclaveAgent and all derived identifiers (ConclaveAgentApp, etc.)
    regex: /\bConclaveAgent\w*/g,
    description: "v3 Agent entity type",
  },
  {
    id: "AgentEngine",
    regex: /\bAgentEngine\w*/g,
    description: "v3 Agent Engine concept",
  },
  {
    id: "WorkerPlugin",
    regex: /\bWorkerPlugin\w*/g,
    description: "v3 Worker Plugin concept",
  },
  {
    id: "agent_plugin_installs",
    regex: /\bagent_plugin_installs\b/g,
    description: "v3 plugin installation table",
  },
  {
    id: "pluginId",
    regex: /\bpluginId\b/g,
    description: "v3 plugin-based assignment routing",
  },
];

// ── File discovery ──────────────────────────────────────────────────────────

const SOURCE_EXTENSIONS = /\.(?:ts|tsx|dart|sql|mjs)$/;
const EXCLUDED_PATHS = [
  /^docs\//,
  /\.md$/,
  /\.test\./,
  /_test\./,
  /\/test\//,
  /^scripts\/verify-v4-architecture-guard\.mjs$/,
  /^scripts\/v4-architecture-baseline\.json$/,
  /node_modules\//,
];

function getTrackedSourceFiles() {
  const files = execFileSync("git", ["ls-files", "-z"], {
    encoding: "utf8",
  })
    .split("\0")
    .filter(Boolean);

  return files.filter((file) => {
    if (!existsSync(file)) return false;
    if (!SOURCE_EXTENSIONS.test(file)) return false;
    for (const pattern of EXCLUDED_PATHS) {
      if (pattern.test(file)) return false;
    }
    return true;
  });
}

// ── Scanning ────────────────────────────────────────────────────────────────

function scanFiles(files) {
  /** @type {Map<string, string[]>} keyword -> ["file:line", ...] */
  const occurrences = new Map();

  for (const guard of GUARD_PATTERNS) {
    occurrences.set(guard.id, []);
  }

  for (const file of files) {
    const contents = readFileSync(file, "utf8");
    const lines = contents.split("\n");

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      for (const guard of GUARD_PATTERNS) {
        guard.regex.lastIndex = 0;
        if (guard.regex.test(line)) {
          const key = `${file}:${i + 1}`;
          occurrences.get(guard.id).push(key);
        }
      }
    }
  }

  return occurrences;
}

// ── Baseline management ─────────────────────────────────────────────────────

function loadBaseline() {
  if (!existsSync(BASELINE_PATH)) {
    return new Map();
  }
  const data = JSON.parse(readFileSync(BASELINE_PATH, "utf8"));
  const baseline = new Map();
  for (const [keyword, locations] of Object.entries(data)) {
    baseline.set(keyword, new Set(locations));
  }
  return baseline;
}

function saveBaseline(occurrences) {
  const data = {};
  for (const [keyword, locations] of occurrences.entries()) {
    data[keyword] = locations.sort();
  }
  writeFileSync(BASELINE_PATH, JSON.stringify(data, null, 2) + "\n");
}

// ── Main ────────────────────────────────────────────────────────────────────

const files = getTrackedSourceFiles();
const occurrences = scanFiles(files);

if (updateBaseline) {
  saveBaseline(occurrences);
  let total = 0;
  for (const locations of occurrences.values()) {
    total += locations.length;
  }
  console.log(
    `Baseline updated: ${total} occurrences across ${GUARD_PATTERNS.length} keywords.`,
  );
  for (const [keyword, locations] of occurrences.entries()) {
    console.log(`  ${keyword}: ${locations.length}`);
  }
  process.exit(0);
}

// Check mode
const baseline = loadBaseline();
const violations = [];
const staleEntries = [];

for (const guard of GUARD_PATTERNS) {
  const currentLocations = new Set(occurrences.get(guard.id) ?? []);
  const baselineLocations = baseline.get(guard.id) ?? new Set();

  // New occurrences not in baseline = violations
  for (const loc of currentLocations) {
    if (!baselineLocations.has(loc)) {
      violations.push({
        keyword: guard.id,
        location: loc,
        description: guard.description,
      });
    }
  }

  // Baseline entries no longer present = stale (informational)
  for (const loc of baselineLocations) {
    if (!currentLocations.has(loc)) {
      staleEntries.push({ keyword: guard.id, location: loc });
    }
  }
}

// Report
if (staleEntries.length > 0) {
  console.log(
    `ℹ  ${staleEntries.length} baseline entries no longer exist (v3 code removed — good!):`,
  );
  for (const entry of staleEntries) {
    console.log(`   ${entry.keyword} at ${entry.location}`);
  }
  console.log("   Run with --update-baseline to clean up the baseline.\n");
}

if (violations.length > 0) {
  console.error(
    `✗  Architecture v4 guard failed: ${violations.length} new v3 concept(s) found.\n`,
  );
  console.error(
    "   New production code must not introduce deprecated v3 concepts.",
  );
  console.error(
    "   See docs/architecture/ARCHITECTURE_V4.md for the current architecture.\n",
  );
  for (const v of violations) {
    console.error(`   ${v.keyword} (${v.description})`);
    console.error(`     at ${v.location}`);
  }
  console.error(
    "\n   If this is active migration code being removed in a current phase,",
  );
  console.error(
    "   run: node scripts/verify-v4-architecture-guard.mjs --update-baseline",
  );
  process.exit(1);
}

let total = 0;
for (const locations of occurrences.values()) {
  total += locations.length;
}
console.log(
  `Architecture v4 guard passed: ${total} baselined occurrences, 0 new violations.`,
);
