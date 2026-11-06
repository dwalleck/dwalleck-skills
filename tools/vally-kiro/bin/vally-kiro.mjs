#!/usr/bin/env node
// Runs a Vally command against Kiro: derives the Kiro spec, then calls the Vally CLI with
// the plugin loaded. Anything not listed below passes straight through to Vally.
import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { deriveKiroSpec, inferSkillDir, renderSpec } from "../src/derive-spec.js";
import { DEFAULT_JUDGE_MODEL } from "../src/kiro-judges.js";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const PLUGIN = join(ROOT, "src", "index.js");
const DEFAULT_WORKERS = "2";
const USAGE = `Usage: vally-kiro <eval|lint|grade|derive> <eval.yaml> [options] [vally options]
       vally-kiro compare --baseline <run> --treatment <run> [vally compare options]

  grade re-scores saved results without re-running the agent: pipe in results.jsonl.
  compare judges two saved runs head to head, using Kiro judges.

  --skill <dir>          Skill under test (default: <repo>/<name> for tests/<name>/eval.yaml)
  --model <id>           Model for the agent under test (default: Kiro's auto)
  --judge-model <id>     Model for Kiro judges (default: claude-sonnet-5.5)
  --mode <id>            Kiro agent/mode for the agent under test
  --allow-shell          Let the agent run shell commands (off by default)
  --no-activation        Don't add skill-invocation graders

Any other option goes to Vally, e.g. --runs 3, --tag journey=review-test-assertion,
--output-dir ./results, --require-pass, --workers 4.`;

function parseArgs(argv) {
  const own = { passthrough: [] };
  const valued = { "--skill": "skill", "--model": "model", "--judge-model": "judgeModel", "--mode": "mode" };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (valued[arg]) own[valued[arg]] = argv[++i];
    else if (arg === "--allow-shell") own.allowShell = true;
    else if (arg === "--no-activation") own.activation = false;
    else own.passthrough.push(arg);
  }
  return own;
}

function vallyCli() {
  const require = createRequire(import.meta.url);
  return join(dirname(require.resolve("@microsoft/vally-cli/package.json")), "dist", "index.js");
}

function compare(argv) {
  const hook = pathToFileURL(join(ROOT, "src", "compare-judge-hook.js")).href;
  const vallyArgs = ["--import", hook, vallyCli(), "compare", ...argv];
  // Vally's default judge model isn't one Kiro offers.
  if (!argv.includes("--judge-model")) vallyArgs.push("--judge-model", process.env.KIRO_JUDGE_MODEL ?? DEFAULT_JUDGE_MODEL);
  return spawnSync(process.execPath, vallyArgs, { stdio: "inherit" }).status ?? 1;
}

function main() {
  const [command, specArg, ...rest] = process.argv.slice(2);
  if (command === "compare") return compare(process.argv.slice(3));
  if (!["eval", "lint", "grade", "derive"].includes(command) || !specArg) {
    console.error(USAGE);
    return 2;
  }
  const args = parseArgs(rest);
  const skillDir = args.skill ?? inferSkillDir(specArg);
  if (!skillDir) {
    console.error(`Could not infer the skill for ${specArg}. Pass --skill <dir>.`);
    return 2;
  }
  const spec = deriveKiroSpec(specArg, {
    skillDir, judgeModel: args.judgeModel, model: args.model, allowShell: args.allowShell, mode: args.mode, activation: args.activation,
  });
  const generatedDir = join(ROOT, ".generated", basename(resolve(skillDir)));
  mkdirSync(generatedDir, { recursive: true });
  const generatedSpec = join(generatedDir, "eval.yaml");
  writeFileSync(generatedSpec, renderSpec(spec));
  console.error(`Derived Kiro spec: ${generatedSpec}`);
  if (command === "derive") return 0;

  const vallyArgs = [vallyCli(), command, "--eval-spec", generatedSpec, "--grader-plugin", PLUGIN];
  if (command === "eval") {
    vallyArgs.push("--executor-plugin", PLUGIN);
    // Every trial and judge starts its own KAS process, so keep concurrency modest.
    if (!args.passthrough.includes("--workers")) vallyArgs.push("--workers", DEFAULT_WORKERS);
  }
  vallyArgs.push(...args.passthrough);
  const result = spawnSync(process.execPath, vallyArgs, { stdio: "inherit" });
  return result.status ?? 1;
}

process.exitCode = main();
