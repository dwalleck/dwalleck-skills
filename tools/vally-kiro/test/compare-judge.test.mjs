import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

function savedRun(dir, name, output) {
  const stimulus = { name: "stim", prompt: "Do the thing", rubric: ["Did the thing"] };
  const events = [{ type: "assistant_message", timestamp: new Date().toISOString(), data: { content: output } }];
  const metrics = { tokenUsage: { totalTokens: 0 }, turnCount: 1, toolCallCount: 0, wallTimeMs: 1, errorCount: 0, skillActivationCount: 0 };
  const trajectory = { id: name, stimulus, events, metrics, output, workDir: join(dir, name) };
  const path = join(dir, `${name}.jsonl`);
  writeFileSync(path, `${JSON.stringify({ type: "trial-result", trialIndex: 0, trajectory })}\n`);
  return path;
}

// The fake Kiro never delivers a verdict, so a judge that really went through Kiro fails
// with the Kiro client's own error. Copilot would fail differently, or quietly succeed.
test("compare judges through Kiro, not Copilot", { timeout: 120_000 }, () => {
  const dir = mkdtempSync(join(tmpdir(), "vk-test-compare-"));
  const out = join(dir, "comparison.jsonl");
  const run = spawnSync(process.execPath, [
    join(HERE, "..", "bin", "vally-kiro.mjs"), "compare",
    "--baseline", savedRun(dir, "baseline", "a"), "--treatment", savedRun(dir, "treatment", "b"), "--output", out,
  ], {
    encoding: "utf8",
    env: { ...process.env, KIRO_CLI: JSON.stringify([process.execPath, join(HERE, "fake-kiro.mjs")]), FAKE_KIRO_SCENARIO: "quiet", VALLY_TELEMETRY_OPTOUT: "1" },
  });
  assert.equal(run.status, 1, run.stdout + run.stderr);
  assert.match(readFileSync(out, "utf8"), /Kiro judge gave no valid verdict/, run.stdout + run.stderr);
});
