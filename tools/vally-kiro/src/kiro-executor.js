// Vally executor: runs a stimulus through a fresh Kiro v3 ACP session.
import { randomUUID } from "node:crypto";
import { cpSync, existsSync, statSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { computeMetrics, stimulusPrompts } from "@microsoft/vally";
import { createIsolatedHome, isolatedEnv, openKasSession, removeTree, withTimeout } from "./kas-session.js";
import { createPermissionPolicy } from "./permission-policy.js";
import { TrajectoryBuilder } from "./trajectory-builder.js";

const CANCEL_GRACE_MS = 15_000;
const SKILL_ADVERTISE_TIMEOUT_MS = 20_000;
const CONFIG_KEYS = new Set(["skills", "mode", "allowShell"]);

function parseConfig(config) {
  if (config === undefined) return {};
  if (typeof config !== "object" || config === null) throw new Error("kiro executor config must be an object");
  for (const key of Object.keys(config)) {
    if (!CONFIG_KEYS.has(key)) throw new Error(`Unknown kiro executor config "${key}". Allowed: ${[...CONFIG_KEYS].join(", ")}`);
  }
  if (config.skills !== undefined && !Array.isArray(config.skills)) throw new Error("kiro executor config.skills must be an array of skill directories");
  return config;
}

function skillDirectory(path) {
  return statSync(path).isDirectory() ? path : dirname(path);
}

/** Stages skills as global Kiro skills in the isolated KIRO_HOME, keeping the workspace pristine. */
function stageSkills(kiroHome, config, skills = []) {
  const skillsRoot = join(kiroHome, "skills");
  const requested = new Map();
  for (const path of config.skills ?? []) {
    const dir = resolve(path);
    if (!existsSync(join(dir, "SKILL.md"))) throw new Error(`Skill directory has no SKILL.md: ${dir}`);
    requested.set(basename(dir), dir);
  }
  for (const skill of skills) {
    if (skill.path) requested.set(skill.name, skillDirectory(skill.path));
  }
  for (const [name, dir] of requested) cpSync(dir, join(skillsRoot, name), { recursive: true });
  return { skillsRoot, names: [...requested.keys()] };
}

export class KiroExecutor {
  name = "kiro";
  supportsMultiTurn = true;
  supportsTurnCompletion = true;
  supportsEnvVars = true;

  validateConfig(config) {
    parseConfig(config);
  }

  async execute(stimulus, options) {
    const config = parseConfig(options.executorConfig);
    if (options.mcpServers && Object.keys(options.mcpServers).length > 0) {
      throw new Error("kiro executor does not support stimulus MCP servers yet");
    }
    const startedAt = new Date();
    const fakeHome = createIsolatedHome();
    const builder = new TrajectoryBuilder();
    const deadline = AbortSignal.timeout(options.timeout);
    const prompts = stimulusPrompts(stimulus);
    let session;
    try {
      const staged = stageSkills(fakeHome, config, options.skills);
      const policy = createPermissionPolicy({ workDir: options.workDir, skillsRoot: staged.skillsRoot, allowShell: config.allowShell });
      session = openKasSession({
        cwd: options.workDir,
        env: isolatedEnv(fakeHome, options.env),
        decidePermission: (request) => {
          builder.nameTool(request?.toolCall?.toolCallId, request?._meta?.kiro?.toolId);
          return policy(request);
        },
        onUpdate: (update) => builder.handleUpdate(update),
        onFrame: options.onRawEvent,
        signal: deadline,
      });
      const { sessionId } = await session.start({
        settings: [["mode", config.mode], ["model", options.model], ["effortLevel", options.reasoningEffort]],
      });
      // Kiro advertises skills in an update that arrives after session/new responds.
      const missingSkills = () => staged.names.filter((name) => !builder.advertisedSkills.has(name));
      const advertiseDeadline = Date.now() + SKILL_ADVERTISE_TIMEOUT_MS;
      while (missingSkills().length > 0 && Date.now() < advertiseDeadline) {
        await new Promise((r) => setTimeout(r, 100));
      }
      const missing = missingSkills();
      if (missing.length > 0) {
        throw new Error(`Kiro did not load staged skill(s): ${missing.join(", ")}. Advertised: ${[...builder.advertisedSkills].join(", ") || "none"}`);
      }

      let endReason = "completed";
      let budgetTimer;
      if (options.maxAgentDurationMs > 0) {
        budgetTimer = setTimeout(() => { endReason = "agent_timeout"; session.cancel(sessionId); }, options.maxAgentDurationMs);
      }
      try {
        for (const [turn, prompt] of prompts.entries()) {
          if (endReason !== "completed") break;
          builder.startTurn(String(turn), prompt);
          const result = await session.prompt(sessionId, prompt);
          builder.endTurn();
          if (result?.stopReason === "refusal") builder.addError("Kiro refused the prompt", "refusal");
          const final = turn === prompts.length - 1 || endReason !== "completed";
          await options.onTurnComplete?.({ turn, status: endReason === "completed" ? "completed" : "interrupted", final });
        }
      } finally {
        clearTimeout(budgetTimer);
      }

      // A denied tool can look like a weak skill, so denials are recorded and also printed.
      const denials = session.permissions.filter((p) => !p.allow);
      for (const denied of denials) {
        builder.addCustom({ name: "kiro.permission_denied", tool: denied.toolId, title: denied.title, reason: denied.reason });
      }
      if (denials.length > 0) {
        console.warn(`[kiro] ${stimulus.name}: ${denials.length} tool request(s) denied, which may affect this result: ${[...new Set(denials.map((d) => d.reason))].join("; ")}`);
      }
      builder.addCustom({ name: "kiro.credits", credits: builder.credits });
      const output = builder.output;
      const completedAt = new Date();
      return {
        id: randomUUID(),
        stimulus,
        events: builder.events,
        metrics: { ...computeMetrics(builder.events), wallTimeMs: completedAt.getTime() - startedAt.getTime() },
        output,
        workDir: options.workDir,
        ...(endReason !== "completed" && { endReason }),
        metadata: {
          model: options.model ?? "auto",
          skillsLoaded: staged.names,
          startedAt,
          completedAt,
          executor: this.name,
          sessionID: sessionId,
        },
      };
    } catch (error) {
      if (deadline.aborted) throw new Error(`Kiro run exceeded its ${options.timeout}ms timeout`);
      throw error;
    } finally {
      session?.close();
      await withTimeout(new Promise((r) => setTimeout(r, 200)), CANCEL_GRACE_MS, "kiro shutdown");
      try { removeTree(fakeHome); } catch (error) { console.warn(`Could not remove ${fakeHome}: ${error.message}`); }
    }
  }

  async shutdown() {}
}

export function registerExecutors(registry) {
  registry.register(new KiroExecutor());
}
