import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import { fileURLToPath } from "node:url";
import { KiroExecutor } from "../src/kiro-executor.js";

const FAKE = join(dirname(fileURLToPath(import.meta.url)), "fake-kiro.mjs");
let workDir;
let skillDir;

function run(scenario, { prompt = "hello", turns, config = {}, model, onTurnComplete, timeout = 20_000 } = {}) {
  process.env.FAKE_KIRO_SCENARIO = scenario;
  return new KiroExecutor().execute(
    { name: "stim", ...(turns ? { turns } : { prompt }) },
    { workDir, timeout, model, onTurnComplete, executorConfig: { skills: [skillDir], ...config } },
  );
}

beforeEach(() => {
  process.env.KIRO_CLI = JSON.stringify([process.execPath, FAKE]);
  workDir = mkdtempSync(join(tmpdir(), "vk-test-work-"));
  skillDir = join(mkdtempSync(join(tmpdir(), "vk-test-skill-")), "probe");
  mkdirSync(skillDir);
  writeFileSync(join(skillDir, "SKILL.md"), "---\nname: probe\ndescription: d\n---\n");
});
afterEach(() => { delete process.env.KIRO_CLI; delete process.env.FAKE_KIRO_SCENARIO; });

const ofType = (t, type) => t.events.filter((e) => e.type === type);

test("maps a run to a trajectory with activation, turns and final output", async () => {
  const t = await run("activates");
  assert.deepEqual(ofType(t, "skill_activation").map((e) => e.data.name), ["probe"]);
  assert.equal(t.metrics.skillActivationCount, 1);
  assert.equal(ofType(t, "turn_start").length, 1);
  assert.equal(ofType(t, "turn_end").length, 1);
  assert.equal(t.output, "Final answer to: hello");
  assert.equal(t.metadata.sessionID, "sess_fake");
  assert.deepEqual(t.metadata.skillsLoaded, ["probe"]);
});

test("denies shell by default and records it", async () => {
  const t = await run("activates");
  const result = ofType(t, "tool_result").find((e) => e.data.toolCallId === "t2");
  assert.equal(result.data.success, false);
  const denied = ofType(t, "custom").filter((e) => e.data.name === "kiro.permission_denied");
  assert.equal(denied.length, 1);
  assert.match(denied[0].data.reason, /shell denied/);
});

test("allowShell lets the same command run", async () => {
  const t = await run("activates", { config: { allowShell: true } });
  assert.equal(ofType(t, "tool_result").find((e) => e.data.toolCallId === "t2").data.success, true);
  assert.equal(ofType(t, "custom").filter((e) => e.data.name === "kiro.permission_denied").length, 0);
});

test("names tools by ID: from the permission request, and never from a model-written title", async () => {
  const t = await run("activates");
  const nameOf = (id) => ofType(t, "tool_call").find((e) => e.data.toolCallId === id).data.toolName;
  assert.equal(nameOf("t2"), "run_command");
  assert.equal(ofType(t, "tool_result").find((e) => e.data.toolCallId === "t2").data.toolName, "run_command");
  assert.equal(nameOf("t4"), "run_command");
});

test("ignores orphan tool updates", async () => {
  const t = await run("activates");
  assert.equal(ofType(t, "tool_result").some((e) => e.data.toolCallId === "orphan"), false);
});

test("a run without activation reports none", async () => {
  const t = await run("quiet");
  assert.equal(t.metrics.skillActivationCount, 0);
});

test("records credits", async () => {
  const t = await run("quiet");
  assert.equal(ofType(t, "custom").find((e) => e.data.name === "kiro.credits").data.credits, 0.25);
});

test("runs multiple turns and awaits completion callbacks", async () => {
  const seen = [];
  const t = await run("quiet", { turns: ["one", "two"], onTurnComplete: async (c) => { seen.push(c); } });
  assert.equal(ofType(t, "turn_end").length, 2);
  assert.deepEqual(seen.map((c) => [c.turn, c.status, c.final]), [[0, "completed", false], [1, "completed", true]]);
  assert.equal(t.output, "Final answer to: two");
});

test("fails clearly when the staged skill isn't advertised", { timeout: 40_000 }, async () => {
  await assert.rejects(run("no-skills", { timeout: 35_000 }), /did not load staged skill\(s\): probe/);
});

test("rejects a model Kiro doesn't offer", async () => {
  await assert.rejects(run("quiet", { model: "made-up" }), /does not offer model "made-up"/);
});

test("rejects a setting Kiro silently ignored", async () => {
  await assert.rejects(run("ignores-model", { model: "claude-sonnet-5.5" }), /kept model "auto"/);
});

test("a refusal becomes an error event", async () => {
  const t = await run("refuses");
  assert.equal(t.metrics.errorCount, 1);
});

test("rejects unknown executor config", () => {
  assert.throws(() => new KiroExecutor().validateConfig({ allowShel: true }), /Unknown kiro executor config "allowShel"/);
});
