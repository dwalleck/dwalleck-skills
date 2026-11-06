// Test double for `kiro-cli acp`: speaks just enough ACP, driven by FAKE_KIRO_SCENARIO.
import { createInterface } from "node:readline";

const scenario = process.env.FAKE_KIRO_SCENARIO ?? "activates";
const send = (m) => process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", ...m })}\n`);
const update = (sessionId, u) => send({ method: "session/update", params: { sessionId, update: u } });
const say = (sessionId, text) => update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
let permissionId = 1000;
const waiting = new Map();
const askPermission = (sessionId, toolCallId, title, kiro) => new Promise((resolve) => {
  const id = permissionId++;
  waiting.set(id, resolve);
  send({ id, method: "session/request_permission", params: { sessionId, toolCall: { toolCallId, title }, options: [
    { optionId: "accept", kind: "allow_once" }, { optionId: "reject", kind: "reject_once" },
  ], _meta: { kiro } } });
});

const CONFIG = [{ id: "mode", currentValue: "vibe", options: [{ value: "vibe" }, { value: "vally-judge" }] },{ id: "model", currentValue: "auto", options: [{ value: "auto" }, { value: "claude-sonnet-5.5" }] }];

async function runPrompt(id, sessionId, text) {
  if (scenario === "activates") {
    update(sessionId, { sessionUpdate: "tool_call", toolCallId: "t1", title: "Load skill: probe", status: "pending", rawInput: { name: "probe" }, _meta: { kiro: { toolId: "disclose_context" } } });
    update(sessionId, { sessionUpdate: "tool_call_update", toolCallId: "t1", status: "completed", title: "Loaded skill: probe", rawOutput: { item: { type: "skill", displayName: "probe", id: "x/SKILL.md", config: { name: "probe" } } } });
    // An orphan update must not create a result.
    update(sessionId, { sessionUpdate: "tool_call_update", toolCallId: "orphan", status: "completed", title: "Tool Load" });
    update(sessionId, { sessionUpdate: "tool_call", toolCallId: "t2", title: "Run tests", kind: "read", status: "pending", rawInput: { command: "dotnet test" }, _meta: { kiro: { toolOrigin: "default" } } });
    update(sessionId, { sessionUpdate: "tool_call", toolCallId: "t4", title: "A title the model wrote", kind: "execute", status: "completed", rawInput: {}, _meta: { kiro: { toolOrigin: "default" } } });
    const outcome = await askPermission(sessionId, "t2", "Run tests", { toolId: "run_command", consent: { capability: "shell", resource: "dotnet test" } });
    update(sessionId, { sessionUpdate: "tool_call_update", toolCallId: "t2", status: outcome === "accept" ? "completed" : "failed", title: "Run tests" });
  }
  say(sessionId, "Interim text. ");
  update(sessionId, { sessionUpdate: "tool_call", toolCallId: `t3-${text.length}`, title: "Read", status: "completed", rawInput: {}, _meta: { kiro: { toolId: "read_file" } } });
  say(sessionId, `Final answer to: ${text}`);
  update(sessionId, { sessionUpdate: "session_info_update", _meta: { kiro: { kind: "turn_completion", promptTurnSummaries: [{ usage: 0.25 }] } } });
  send({ id, result: { stopReason: scenario === "refuses" ? "refusal" : "end_turn" } });
}

createInterface({ input: process.stdin }).on("line", (line) => {
  const m = JSON.parse(line);
  if (m.id !== undefined && !m.method) { waiting.get(m.id)?.(m.result?.outcome?.optionId); waiting.delete(m.id); return; }
  if (m.method === "initialize") send({ id: m.id, result: { protocolVersion: 1, agentCapabilities: {} } });
  else if (m.method === "session/new") {
    const sessionId = "sess_fake";
    send({ id: m.id, result: { sessionId, configOptions: CONFIG } });
    if (scenario !== "no-skills") {
      setTimeout(() => update(sessionId, { sessionUpdate: "available_commands_update", availableCommands: [{ name: "probe", _meta: { kiro: { type: "skill", originalName: "probe" } } }] }), 50);
    }
  } else if (m.method === "session/set_config_option") {
    const value = scenario === "ignores-model" ? "auto" : m.params.value;
    send({ id: m.id, result: { configOptions: CONFIG.map((o) => (o.id === m.params.configId ? { ...o, currentValue: value } : o)) } });
  } else if (m.method === "session/prompt") {
    void runPrompt(m.id, m.params.sessionId, m.params.prompt[0].text);
  } else if (m.id !== undefined) send({ id: m.id, error: { code: -32601, message: "no" } });
});
