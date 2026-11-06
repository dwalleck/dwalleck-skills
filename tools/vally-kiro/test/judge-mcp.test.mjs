import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const SERVER = join(dirname(fileURLToPath(import.meta.url)), "..", "src", "judge-mcp.js");

function startServer(budget = { maxToolCalls: 12, maxResultChars: 1000, maxTotalChars: 5000 }) {
  const dir = mkdtempSync(join(tmpdir(), "vk-mcp-"));
  const evidence = join(dir, "evidence.txt");
  const secret = join(dir, "secret.txt");
  const outFile = join(dir, "out.jsonl");
  writeFileSync(evidence, "line one\nline two\nline three\n");
  writeFileSync(secret, "do not read");
  const configPath = join(dir, "config.json");
  writeFileSync(configPath, JSON.stringify({ outFile, evidenceFiles: [evidence], budget, tool: { name: "submit_grade", description: "d", inputSchema: { type: "object" } } }));
  const child = spawn(process.execPath, [SERVER], { env: { ...process.env, JUDGE_CONFIG: configPath }, stdio: ["pipe", "pipe", "inherit"] });
  const pending = new Map();
  createInterface({ input: child.stdout }).on("line", (l) => { const m = JSON.parse(l); pending.get(m.id)?.(m); });
  let id = 1;
  const rpc = (method, params) => new Promise((resolve) => { const i = id++; pending.set(i, resolve); child.stdin.write(`${JSON.stringify({ id: i, method, params })}\n`); });
  const call = async (name, args) => (await rpc("tools/call", { name, arguments: args })).result;
  return { rpc, call, evidence, secret, outFile, stop: () => child.kill() };
}

test("offers exactly view, grep and the verdict tool", async () => {
  const s = startServer();
  const { result } = await s.rpc("tools/list");
  assert.deepEqual(result.tools.map((t) => t.name), ["view", "grep", "submit_grade"]);
  s.stop();
});

test("view and grep read evidence", async () => {
  const s = startServer();
  assert.equal((await s.call("view", { path: s.evidence, start_line: 2, end_line: 2 })).content[0].text, "line two");
  assert.match((await s.call("grep", { pattern: "three", paths: [s.evidence] })).content[0].text, /:3:line three/);
  s.stop();
});

test("refuses files that aren't evidence", async () => {
  const s = startServer();
  for (const result of [await s.call("view", { path: s.secret }), await s.call("grep", { pattern: ".", paths: [s.secret] }), await s.call("view", { path: join(s.evidence, "..", "secret.txt") })]) {
    assert.equal(result.isError, true);
    assert.doesNotMatch(result.content[0].text, /do not read/);
  }
  s.stop();
});

test("enforces the tool-call budget", async () => {
  const s = startServer({ maxToolCalls: 1, maxResultChars: 1000, maxTotalChars: 5000 });
  assert.equal((await s.call("view", { path: s.evidence })).isError, false);
  const second = await s.call("view", { path: s.evidence });
  assert.equal(second.isError, true);
  assert.match(second.content[0].text, /budget exhausted/);
  s.stop();
});

test("enforces character budgets", async () => {
  const s = startServer({ maxToolCalls: 5, maxResultChars: 4, maxTotalChars: 6 });
  assert.equal((await s.call("view", { path: s.evidence })).content[0].text.length, 4);
  assert.equal((await s.call("view", { path: s.evidence })).content[0].text.length, 2);
  assert.equal((await s.call("view", { path: s.evidence })).isError, true);
  s.stop();
});

test("records the verdict", async () => {
  const s = startServer();
  await s.call("submit_grade", { overall_score: 3 });
  const records = readFileSync(s.outFile, "utf8").trim().split("\n").map((l) => JSON.parse(l));
  assert.deepEqual(records.at(-1), { kind: "verdict", args: { overall_score: 3 } });
  s.stop();
});
