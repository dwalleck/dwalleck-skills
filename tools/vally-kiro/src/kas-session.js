// One Kiro v3 (KAS) ACP process, shared by the executor and the judges.
//
// Auth is the `kiro-cli login` session (--auth-method cli), so no API key is needed.
// KIRO_HOME is isolated per process: it hides ~/.kiro (user skills, steering, memory)
// from the run and leaves auth working. HOME and USERPROFILE stay real: kiro-cli 3.0 on
// Windows fails with "home directory not found" when USERPROFILE is changed.
import { spawn, spawnSync } from "node:child_process";
import { appendFileSync, existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";

const INIT_TIMEOUT_MS = 60_000;
const SESSION_TIMEOUT_MS = 180_000;

export function resolveKiroCommand() {
  // KIRO_CLI is a path, or a JSON argv array for wrappers and test doubles.
  const override = process.env.KIRO_CLI;
  if (override) return override.startsWith("[") ? JSON.parse(override) : [override];
  const windowsCli = join(process.env.LOCALAPPDATA ?? "", "Kiro-Cli", "kiro-cli.exe");
  return [existsSync(windowsCli) ? windowsCli : "kiro-cli"];
}

export function createIsolatedHome() {
  return mkdtempSync(join(tmpdir(), "vally-kiro-home-"));
}

export function removeTree(dir) {
  rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}

export function isolatedEnv(kiroHome, extra = {}) {
  return { ...process.env, ...extra, KIRO_HOME: kiroHome };
}

export const withTimeout = (promise, ms, what) => {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${what} timed out after ${ms}ms`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
};

function killTree(child) {
  if (child.exitCode !== null || child.pid === undefined) return;
  // kiro-cli launches KAS as a child node process; killing only the launcher leaks it.
  if (process.platform === "win32") spawnSync("taskkill", ["/pid", String(child.pid), "/T", "/F"], { windowsHide: true, stdio: "ignore" });
  else child.kill();
}

/**
 * @param {object} args
 * @param {string} args.cwd
 * @param {NodeJS.ProcessEnv} args.env
 * @param {(request: object) => {allow: boolean, reason: string}} args.decidePermission
 * @param {(update: object) => void} [args.onUpdate]
 * @param {(frame: unknown) => void} [args.onFrame]
 * @param {AbortSignal} [args.signal]
 */
export function openKasSession({ cwd, env, decidePermission, onUpdate, onFrame, signal }) {
  const [command, ...prefix] = resolveKiroCommand();
  const child = spawn(command, [...prefix, "acp", "--agent-engine", "v3", "--auth-method", "cli"], {
    cwd, env, stdio: ["pipe", "pipe", "pipe"], windowsHide: true,
  });
  const pending = new Map();
  const permissions = [];
  const stderrTail = [];
  let nextId = 1;
  let closed = false;

  const trace = (direction, message) => {
    onFrame?.({ direction, message });
    if (process.env.VALLY_KIRO_TRACE) appendFileSync(process.env.VALLY_KIRO_TRACE, `${JSON.stringify({ pid: child.pid, direction, message })}\n`);
  };
  const write = (message) => {
    trace("client->agent", message);
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
  };
  const failAll = (error) => {
    for (const { reject } of pending.values()) reject(error);
    pending.clear();
  };
  const exitError = (code) => {
    const tail = stderrTail.join("").trim().slice(-600);
    return new Error(`kiro-cli acp exited early (code ${code})${tail ? `: ${tail}` : ""}`);
  };

  child.on("error", (error) => failAll(new Error(`Could not start kiro-cli: ${error.message}. Install Kiro CLI or set KIRO_CLI.`)));
  child.on("exit", (code) => { if (!closed) failAll(exitError(code)); });
  child.stdin.on("error", () => {});
  child.stderr.on("data", (chunk) => {
    stderrTail.push(String(chunk));
    if (stderrTail.length > 20) stderrTail.shift();
  });

  const onAbort = () => { failAll(new Error("Kiro session aborted")); close(); };
  signal?.addEventListener("abort", onAbort, { once: true });

  createInterface({ input: child.stdout }).on("line", (line) => {
    let message;
    try { message = JSON.parse(line); } catch { return; }
    trace("agent->client", message);
    if (message.method === "session/request_permission") {
      const decision = decidePermission(message.params);
      permissions.push({ ...decision, toolId: message.params?._meta?.kiro?.toolId, title: message.params?.toolCall?.title, toolCallId: message.params?.toolCall?.toolCallId });
      const kinds = decision.allow ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"];
      const option = message.params?.options?.find((o) => o.kind === kinds[0]) ?? message.params?.options?.find((o) => o.kind === kinds[1]);
      // Fail closed: with no matching option, cancelling never grants anything.
      write({ id: message.id, result: { outcome: option ? { outcome: "selected", optionId: option.optionId } : { outcome: "cancelled" } } });
    } else if (message.method && message.id !== undefined) {
      write({ id: message.id, error: { code: -32601, message: "Not supported by vally-kiro" } });
    } else if (message.method === "session/update") {
      onUpdate?.(message.params?.update);
    } else if (message.id !== undefined && !message.method) {
      const entry = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) entry?.reject(new Error(`${entry.method} failed: ${message.error.message} ${JSON.stringify(message.error.data ?? "")}`.trim()));
      else entry?.resolve(message.result);
    }
  });

  const request = (method, params) => new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject, method });
    write({ id, method, params });
  });

  function close() {
    if (closed) return;
    closed = true;
    signal?.removeEventListener("abort", onAbort);
    killTree(child);
  }

  /** KAS accepts unoffered values silently, so every setting is confirmed by read-back. */
  async function setOption(sessionId, configId, value, offered) {
    const option = offered?.find((o) => (o.id ?? o.configId) === configId);
    const values = option?.options?.map((o) => o.value ?? o.id) ?? [];
    if (option && !values.includes(value)) {
      throw new Error(`Kiro does not offer ${configId} "${value}". Available: ${values.join(", ")}`);
    }
    const result = await withTimeout(request("session/set_config_option", { sessionId, configId, value }), INIT_TIMEOUT_MS, `set ${configId}`);
    const current = result?.configOptions?.find((o) => (o.id ?? o.configId) === configId)?.currentValue;
    if (current !== undefined && current !== value) throw new Error(`Kiro kept ${configId} "${current}" after setting "${value}"`);
    return result?.configOptions ?? offered;
  }

  async function start({ settings = [] } = {}) {
    await withTimeout(request("initialize", {
      protocolVersion: 1,
      clientCapabilities: {},
      clientInfo: { name: "vally-kiro", version: "0.1.0" },
    }), INIT_TIMEOUT_MS, "initialize").catch(explainAuth);
    const session = await withTimeout(request("session/new", { cwd, mcpServers: [] }), SESSION_TIMEOUT_MS, "session/new").catch(explainAuth);
    let offered = session.configOptions;
    for (const [configId, value] of settings) {
      if (value !== undefined) offered = await setOption(session.sessionId, configId, value, offered);
    }
    return { sessionId: session.sessionId };
  }

  return {
    start,
    prompt: (sessionId, text) => request("session/prompt", { sessionId, prompt: [{ type: "text", text }] }),
    cancel: (sessionId) => write({ method: "session/cancel", params: { sessionId } }),
    permissions,
    close,
  };
}

function explainAuth(error) {
  if (/auth/i.test(error.message)) throw new Error(`${error.message}\nRun \`kiro-cli login\` and try again.`);
  throw error;
}
