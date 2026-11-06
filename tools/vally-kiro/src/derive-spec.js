// Derives a Kiro variant of an eval spec. The canonical eval.yaml is never edited, so it
// stays portable to other runtimes.
import { existsSync, readFileSync } from "node:fs";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { parse, stringify } from "yaml";

const JUDGE_TYPES = new Map([["prompt", "kiro-prompt"], ["panel", "kiro-panel"]]);

function renameGraders(graders, judgeModel) {
  return graders?.map((grader) => {
    const type = JUDGE_TYPES.get(grader.type);
    if (!type) return grader;
    const config = { ...grader.config };
    if (judgeModel && !config.model && !config.models) config.model = judgeModel;
    return { ...grader, type, ...(Object.keys(config).length > 0 && { config }) };
  });
}

function renameWeights(scoring) {
  if (!scoring?.weights) return scoring;
  const weights = Object.fromEntries(Object.entries(scoring.weights).map(([type, weight]) => [JUDGE_TYPES.get(type) ?? type, weight]));
  return { ...scoring, weights };
}

// `expect_activation` comes from dotnet/skills' skill-validator and is unknown to Vally.
// It becomes a skill-invocation grader, defaulting to true as skill-validator does.
function activationGrader(stimulus, skillName) {
  const expected = stimulus.expect_activation ?? true;
  return { type: "skill-invocation", config: expected ? { required: [skillName] } : { disallowed: [skillName] } };
}

function absolutizeEnvironment(env, baseDir) {
  if (!env || typeof env !== "object" || !Array.isArray(env.files)) return env;
  const files = env.files.map((file) => (typeof file?.src === "string" && !isAbsolute(file.src) ? { ...file, src: resolve(baseDir, file.src) } : file));
  return { ...env, files };
}

/** tests/<skill>/eval.yaml maps to <repo>/<skill>. */
export function inferSkillDir(specPath) {
  const specDir = dirname(resolve(specPath));
  const candidate = join(dirname(dirname(specDir)), basename(specDir));
  return existsSync(join(candidate, "SKILL.md")) ? candidate : undefined;
}

/**
 * @param {string} specPath
 * @param {{skillDir: string, judgeModel?: string, model?: string, allowShell?: boolean, mode?: string, activation?: boolean}} options
 */
export function deriveKiroSpec(specPath, { skillDir, judgeModel, model, allowShell, mode, activation = true }) {
  const baseDir = dirname(resolve(specPath));
  const spec = parse(readFileSync(specPath, "utf8"));
  const skillName = basename(resolve(skillDir));
  if (spec.defaults?.judge_provider) throw new Error("judge_provider isn't compatible with Kiro judges; remove it from the spec");
  const effectiveJudgeModel = judgeModel ?? spec.defaults?.judge_model;

  // Skills go through executor config, not agent_environment.skills: Vally copies the
  // latter into the workspace root, where an agent could read them without activating.
  const { judge_model: _judgeModel, judge_reasoning_effort: _effort, ...defaults } = spec.defaults ?? {};
  const executorConfig = { skills: [resolve(skillDir)], ...(allowShell && { allowShell }), ...(mode && { mode }) };

  return {
    ...spec,
    agent_environment: absolutizeEnvironment(spec.agent_environment, baseDir),
    grading_environment: absolutizeEnvironment(spec.grading_environment, baseDir),
    defaults: { ...defaults, executor: { name: "kiro", config: executorConfig }, ...(model && { model }) },
    scoring: renameWeights(spec.scoring),
    stimuli: spec.stimuli.map(({ expect_activation, ...stimulus }) => ({
      ...stimulus,
      agent_environment: absolutizeEnvironment(stimulus.agent_environment, baseDir),
      grading_environment: absolutizeEnvironment(stimulus.grading_environment, baseDir),
      scoring: renameWeights(stimulus.scoring),
      graders: [
        ...(renameGraders(stimulus.graders, effectiveJudgeModel) ?? []),
        ...(activation ? [activationGrader({ expect_activation }, skillName)] : []),
      ],
    })),
  };
}

export function renderSpec(spec) {
  const compact = (value) => JSON.parse(JSON.stringify(value));
  return stringify(compact(spec), { lineWidth: 0 });
}
