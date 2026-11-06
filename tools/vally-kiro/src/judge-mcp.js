// Stdio MCP server exposing a judge's ONLY tools: view, grep and the verdict tool.
// Path scoping and read budgets are enforced here, so they hold regardless of what the
// model does, including if evidence contains a prompt injection.
import { appendFileSync, readFileSync, realpathSync } from "node:fs";
import { createInterface } from "node:readline";

const config = JSON.parse(readFileSync(process.env.JUDGE_CONFIG, "utf8"));
const canonical = (path) => realpathSync.native(path).toLowerCase();
const allowed = new Set(config.evidenceFiles.map(canonical));
const used = { toolCalls: 0, chars: 0, budgetExhausted: false };

const send = (message) => process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
const record = (entry) => appendFileSync(config.outFile, `${JSON.stringify(entry)}\n`);
const text = (body, isError = false) => ({ content: [{ type: "text", text: body }], isError });

function readEvidence(path) {
  let key;
  try { key = canonical(String(path)); } catch { throw new Error(`Not an evidence file: ${path}`); }
  if (!allowed.has(key)) throw new Error(`Not an evidence file: ${path}`);
  return readFileSync(key, "utf8");
}

function budgeted(run) {
  if (used.toolCalls >= config.budget.maxToolCalls) {
    used.budgetExhausted = true;
    record({ kind: "usage", ...used });
    return text("Evidence tool-call budget exhausted. Submit your verdict.", true);
  }
  used.toolCalls++;
  let body;
  try {
    body = run();
  } catch (error) {
    record({ kind: "denied", error: error.message });
    record({ kind: "usage", ...used });
    return text(error.message, true);
  }
  const room = Math.min(config.budget.maxResultChars, config.budget.maxTotalChars - used.chars);
  if (room <= 0) {
    used.budgetExhausted = true;
    record({ kind: "usage", ...used });
    return text("Evidence character budget exhausted. Submit your verdict.", true);
  }
  const clipped = body.slice(0, room);
  used.chars += clipped.length;
  record({ kind: "usage", ...used });
  return text(clipped);
}

const tools = [
  {
    name: "view",
    description: "Read a line range of an evidence file.",
    inputSchema: { type: "object", required: ["path"], additionalProperties: false, properties: {
      path: { type: "string" }, start_line: { type: "integer" }, end_line: { type: "integer" },
    } },
  },
  {
    name: "grep",
    description: "Search explicit evidence files with a regular expression.",
    inputSchema: { type: "object", required: ["pattern", "paths"], additionalProperties: false, properties: {
      pattern: { type: "string" }, paths: { type: "array", items: { type: "string" } },
    } },
  },
  { name: config.tool.name, description: config.tool.description, inputSchema: config.tool.inputSchema },
];

function callTool({ name, arguments: args = {} }) {
  if (name === "view") {
    return budgeted(() => {
      const lines = readEvidence(args.path).split("\n");
      return lines.slice(Math.max(0, (args.start_line ?? 1) - 1), args.end_line ?? lines.length).join("\n");
    });
  }
  if (name === "grep") {
    return budgeted(() => {
      const pattern = new RegExp(args.pattern);
      return args.paths.flatMap((path) => readEvidence(path).split("\n")
        .flatMap((line, i) => (pattern.test(line) ? [`${path}:${i + 1}:${line}`] : []))).join("\n");
    });
  }
  if (name === config.tool.name) {
    record({ kind: "verdict", args });
    return text("Verdict recorded. End your turn now.");
  }
  return text(`Unknown tool: ${name}`, true);
}

createInterface({ input: process.stdin }).on("line", (line) => {
  if (!line.trim()) return;
  const message = JSON.parse(line);
  if (message.id === undefined) return;
  const { id, method, params } = message;
  if (method === "initialize") {
    send({ id, result: { protocolVersion: params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "judge", version: "0.1.0" } } });
  } else if (method === "tools/list") {
    send({ id, result: { tools } });
  } else if (method === "tools/call") {
    send({ id, result: callTool(params) });
  } else if (method === "ping") {
    send({ id, result: {} });
  } else {
    send({ id, error: { code: -32601, message: "Method not found" } });
  }
});
