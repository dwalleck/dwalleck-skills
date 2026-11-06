import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { deriveKiroSpec, inferSkillDir } from "../src/derive-spec.js";

function fixture(yaml) {
  const repo = mkdtempSync(join(tmpdir(), "vk-derive-"));
  mkdirSync(join(repo, "tests", "my-skill"), { recursive: true });
  mkdirSync(join(repo, "my-skill"));
  writeFileSync(join(repo, "my-skill", "SKILL.md"), "x");
  const specPath = join(repo, "tests", "my-skill", "eval.yaml");
  writeFileSync(specPath, yaml);
  return { specPath, skillDir: join(repo, "my-skill") };
}
const BASIC = `
name: s
defaults: { timeout: 5m, judge_model: spec-judge }
scoring: { weights: { prompt: 0.5, exit-success: 0.5 } }
stimuli:
  - name: triggers
    prompt: p
    graders: [ { type: exit-success }, { type: prompt } ]
  - name: dormant
    prompt: p
    expect_activation: false
    graders: [ { type: panel, config: { models: [a, b] } } ]
`;

test("infers the skill from tests/<name>/eval.yaml", () => {
  const { specPath, skillDir } = fixture(BASIC);
  assert.equal(inferSkillDir(specPath), resolve(skillDir));
});

test("selects the Kiro executor and stages the skill through its config", () => {
  const { specPath, skillDir } = fixture(BASIC);
  const spec = deriveKiroSpec(specPath, { skillDir });
  assert.deepEqual(spec.defaults.executor, { name: "kiro", config: { skills: [resolve(skillDir)] } });
  assert.equal(spec.agent_environment, undefined);
});

test("renames judges, including scoring weights", () => {
  const { specPath, skillDir } = fixture(BASIC);
  const spec = deriveKiroSpec(specPath, { skillDir });
  assert.deepEqual(spec.stimuli[0].graders.map((g) => g.type), ["exit-success", "kiro-prompt", "skill-invocation"]);
  assert.equal(spec.stimuli[1].graders[0].type, "kiro-panel");
  assert.deepEqual(spec.scoring.weights, { "kiro-prompt": 0.5, "exit-success": 0.5 });
});

test("translates expect_activation, defaulting to required", () => {
  const { specPath, skillDir } = fixture(BASIC);
  const spec = deriveKiroSpec(specPath, { skillDir });
  assert.deepEqual(spec.stimuli[0].graders.at(-1).config, { required: ["my-skill"] });
  assert.deepEqual(spec.stimuli[1].graders.at(-1).config, { disallowed: ["my-skill"] });
  assert.equal("expect_activation" in spec.stimuli[1], false);
});

test("judge model: flag beats spec, and panel's own models are kept", () => {
  const { specPath, skillDir } = fixture(BASIC);
  assert.equal(deriveKiroSpec(specPath, { skillDir }).stimuli[0].graders[1].config.model, "spec-judge");
  const flagged = deriveKiroSpec(specPath, { skillDir, judgeModel: "flag-judge" });
  assert.equal(flagged.stimuli[0].graders[1].config.model, "flag-judge");
  assert.equal(flagged.stimuli[1].graders[0].config.model, undefined);
});

test("--no-activation adds no grader", () => {
  const { specPath, skillDir } = fixture(BASIC);
  const spec = deriveKiroSpec(specPath, { skillDir, activation: false });
  assert.equal(spec.stimuli[0].graders.some((g) => g.type === "skill-invocation"), false);
});

test("relative environment files still resolve from the original spec", () => {
  const { specPath, skillDir } = fixture(`
name: s
agent_environment: { files: [ { src: fixtures/a, dest: a } ] }
stimuli: [ { name: x, prompt: p, graders: [ { type: exit-success } ] } ]
`);
  const spec = deriveKiroSpec(specPath, { skillDir });
  assert.equal(spec.agent_environment.files[0].src, resolve(specPath, "..", "fixtures", "a"));
});

test("rejects judge_provider", () => {
  const { specPath, skillDir } = fixture(`
name: s
defaults: { judge_provider: { baseUrl: http://x } }
stimuli: [ { name: x, prompt: p, graders: [ { type: prompt } ] } ]
`);
  assert.throws(() => deriveKiroSpec(specPath, { skillDir }), /judge_provider/);
});
