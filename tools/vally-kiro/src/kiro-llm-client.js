// LlmClient backed by a fresh Kiro v3 session per judge call. The judge is a dedicated
// Kiro agent whose only tools come from judge-mcp.js, matching Vally's own contract:
// read-only access to the evidence files and the verdict tool, nothing else.
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createIsolatedHome, isolatedEnv, openKasSession, removeTree, withTimeout } from "./kas-session.js";

const JUDGE_MCP = join(dirname(fileURLToPath(import.meta.url)), "judge-mcp.js");
const JUDGE_AGENT = "vally-judge";
const DEFAULT_BUDGET = { maxToolCalls: 12, maxResultChars: 16_000, maxTotalChars: 64_000 };
const DEFAULT_TURN_TIMEOUT_MS = 120_000;
// `compare` pairs forward and reverse verdicts by criterion text, and a paraphrase scores as a tie.
const VERBATIM_CRITERIA = "When your verdict names a rubric criterion, copy the criterion's text exactly as the rubric writes it, without its list number. Do not shorten or paraphrase it.";

function writeJudgeWorkspace(dir, options, evidenceFiles) {
  const outFile = join(dir, "judge-calls.jsonl");
  const configPath = join(dir, "judge-config.json");
  writeFileSync(configPath, JSON.stringify({
    outFile,
    evidenceFiles,
    budget: options.workspace?.budget ?? DEFAULT_BUDGET,
    tool: { name: options.tool.name, description: options.tool.description, inputSchema: options.tool.parameters.toJSONSchema() },
  }));
  mkdirSync(join(dir, ".kiro", "agents"), { recursive: true });
  writeFileSync(join(dir, ".kiro", "agents", `${JUDGE_AGENT}.json`), JSON.stringify({
    name: JUDGE_AGENT,
    description: "Read-only Vally judge",
    prompt: `${options.systemMessage}\n\n${VERBATIM_CRITERIA}`,
    tools: ["@judge"],
    includeMcpJson: false,
    includePowers: false,
    mcpServers: { judge: { command: process.execPath, args: [JUDGE_MCP], env: { JUDGE_CONFIG: configPath } } },
  }, null, 2));
  return outFile;
}

function readRecords(outFile) {
  if (!existsSync(outFile)) return [];
  return readFileSync(outFile, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
}

/** Only the judge's own MCP server may run tools, identified by what KAS reports. */
export function decideJudgePermission(request) {
  const kiro = request?._meta?.kiro ?? {};
  const allow = kiro.consent?.capability === "mcp" && kiro.mcpTool?.identity?.serverName === "judge";
  return { allow, reason: allow ? "judge tool" : `not a judge tool: ${kiro.toolId}` };
}

export function createKiroLlmClient({ onFrame } = {}) {
  return {
    supportsWorkspaceDelivery: true,

    async judge(options) {
      if (options.provider) throw new Error("Kiro judges do not support judge_provider");
      const started = Date.now();
      const dir = mkdtempSync(join(tmpdir(), "vally-kiro-judge-"));
      const fakeHome = createIsolatedHome();
      const evidenceFiles = (options.workspace?.evidenceFiles ?? []).map((file) => resolve(options.workspace.workingDirectory, file));
      const outFile = writeJudgeWorkspace(dir, options, evidenceFiles);
      const session = openKasSession({
        cwd: dir,
        env: isolatedEnv(fakeHome),
        decidePermission: decideJudgePermission,
        onFrame,
        signal: options.signal,
      });
      try {
        const { sessionId } = await session.start({
          settings: [["mode", JUDGE_AGENT], ["model", options.model], ["effortLevel", options.reasoningEffort]],
        });
        const maxReminders = options.maxReminders ?? 2;
        let prompt = options.userMessage;
        for (let remindersUsed = 0; ; remindersUsed++) {
          await withTimeout(session.prompt(sessionId, prompt), options.timeoutMs ?? DEFAULT_TURN_TIMEOUT_MS, "Kiro judge turn");
          const records = readRecords(outFile);
          const verdict = records.findLast((r) => r.kind === "verdict");
          const parsed = verdict ? options.tool.parameters.safeParse(verdict.args) : undefined;
          if (parsed?.success) {
            const usage = records.findLast((r) => r.kind === "usage");
            return {
              args: parsed.data,
              latencyMs: Date.now() - started,
              remindersUsed,
              ...(evidenceFiles.length > 0 && {
                evidenceUsage: { toolCalls: usage?.toolCalls ?? 0, chars: usage?.chars ?? 0, budgetExhausted: usage?.budgetExhausted ?? false },
              }),
            };
          }
          const problem = parsed ? parsed.error.message : `no ${options.tool.name} call`;
          if (remindersUsed >= maxReminders) throw new Error(`Kiro judge gave no valid verdict: ${problem}`);
          prompt = `You did not deliver a valid verdict (${problem}). Call the ${options.tool.name} tool now with valid arguments.`;
        }
      } finally {
        session.close();
        for (const path of [dir, fakeHome]) {
          try { removeTree(path); } catch (error) { options.workspace?.onCleanupError?.(`remove ${path}`, error); }
        }
      }
    },

    async shutdown() {},
  };
}
