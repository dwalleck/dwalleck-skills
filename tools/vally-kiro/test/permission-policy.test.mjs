import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { test } from "node:test";
import { decideJudgePermission } from "../src/kiro-llm-client.js";
import { createPermissionPolicy } from "../src/permission-policy.js";

const root = mkdtempSync(join(tmpdir(), "vk-policy-"));
const workDir = join(root, "work");
const skillsRoot = join(root, "home", "skills");
mkdirSync(workDir);
mkdirSync(skillsRoot, { recursive: true });
const decide = createPermissionPolicy({ workDir, skillsRoot });
const ask = (capability, resource, policy = decide) => policy({ _meta: { kiro: { toolId: "x", consent: { capability, resource } } } }).allow;

test("reads are limited to the workspace and staged skills", () => {
  assert.equal(ask("fs_read", join(workDir, "a.cs")), true);
  assert.equal(ask("fs_read", "relative/a.cs"), true);
  assert.equal(ask("fs_read", join(skillsRoot, "s", "SKILL.md")), true);
  assert.equal(ask("fs_read", join(root, "secret.txt")), false);
});

test("path traversal and sibling prefixes don't escape", () => {
  assert.equal(ask("fs_read", join(workDir, "..", "secret.txt")), false);
  assert.equal(ask("fs_read", "../secret.txt"), false);
  assert.equal(ask("fs_read", `${workDir}-sibling\\a.txt`), false);
});

test("writes are limited to the workspace", () => {
  assert.equal(ask("fs_write", join(workDir, "a.cs")), true);
  assert.equal(ask("fs_write", join(skillsRoot, "s", "SKILL.md")), false);
});

test("shell needs explicit opt-in", () => {
  assert.equal(ask("shell", "dotnet test"), false);
  assert.equal(ask("shell", "dotnet test", createPermissionPolicy({ workDir, skillsRoot, allowShell: true })), true);
});

test("unknown capabilities and missing consent fail closed", () => {
  assert.equal(ask("web", "https://example.com"), false);
  assert.equal(decide({ _meta: { kiro: { toolId: "mystery" } } }).allow, false);
  assert.equal(decide({}).allow, false);
});

test("only staged skills can be disclosed", () => {
  const disclose = (type, uri) => decide({ _meta: { kiro: { toolId: "disclose_context", disclosedContext: { type, uri } } } }).allow;
  assert.equal(disclose("skill", pathToFileURL(join(skillsRoot, "s", "SKILL.md")).href), true);
  assert.equal(disclose("skill", pathToFileURL(join(root, "other", "SKILL.md")).href), false);
  assert.equal(disclose("steering", pathToFileURL(join(skillsRoot, "s", "SKILL.md")).href), false);
});

test("judges may only use their own MCP server", () => {
  const judge = (capability, serverName) => decideJudgePermission({ _meta: { kiro: { toolId: "t", consent: { capability }, mcpTool: { identity: { serverName } } } } }).allow;
  assert.equal(judge("mcp", "judge"), true);
  assert.equal(judge("mcp", "judge-evil"), false);
  assert.equal(judge("shell", "judge"), false);
  assert.equal(decideJudgePermission({ _meta: { kiro: { toolId: "mcp_judge_view" } } }).allow, false);
});
