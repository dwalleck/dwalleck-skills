// Unattended permission policy for the agent under test: scoped allows, everything
// else denied. KAS raises a request for every tool call, with `_meta.kiro.consent`
// describing the capability and resource.
import { realpathSync } from "node:fs";
import { isAbsolute, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

function canonical(path) {
  try { return realpathSync.native(path); } catch { return resolve(path); }
}

function resourcePath(resource, base) {
  if (typeof resource !== "string" || resource.length === 0) return undefined;
  const raw = resource.startsWith("file:") ? fileURLToPath(resource) : resource;
  return canonical(isAbsolute(raw) ? raw : resolve(base, raw));
}

export function isInside(path, root) {
  const rel = relative(canonical(root), path);
  return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

/**
 * @param {{workDir: string, skillsRoot: string, allowShell?: boolean}} scope
 * @returns {(request: object) => {allow: boolean, reason: string}}
 */
export function createPermissionPolicy({ workDir, skillsRoot, allowShell = false }) {
  return (request) => {
    const kiro = request?._meta?.kiro ?? {};
    const consent = kiro.consent;

    if (kiro.toolId === "disclose_context") {
      const disclosed = kiro.disclosedContext;
      if (disclosed?.type !== "skill") return { allow: false, reason: `disclose_context of type ${disclosed?.type}` };
      const path = resourcePath(disclosed.uri, workDir);
      if (path && isInside(path, skillsRoot)) return { allow: true, reason: "staged skill" };
      return { allow: false, reason: `skill outside the staged set: ${disclosed.uri}` };
    }
    if (!consent) return { allow: false, reason: `no consent context for tool ${kiro.toolId}` };

    const path = resourcePath(consent.resource, workDir);
    switch (consent.capability) {
      case "fs_read":
        if (path && (isInside(path, workDir) || isInside(path, skillsRoot))) return { allow: true, reason: "read in scope" };
        return { allow: false, reason: `read outside scope: ${consent.resource}` };
      case "fs_write":
        if (path && isInside(path, workDir)) return { allow: true, reason: "write in workspace" };
        return { allow: false, reason: `write outside workspace: ${consent.resource}` };
      case "shell":
        return allowShell
          ? { allow: true, reason: "shell allowed by executor config" }
          : { allow: false, reason: "shell denied (set allowShell to enable)" };
      default:
        return { allow: false, reason: `capability ${consent.capability} denied` };
    }
  };
}
