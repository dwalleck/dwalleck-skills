// Converts KAS `session/update` notifications into Vally trajectory events.
const RESULT_LIMIT = 4000;

function contentText(content) {
  if (!Array.isArray(content)) return content?.text ?? "";
  return content.map((part) => part?.content?.text ?? part?.text ?? "").join("");
}

function clip(value) {
  if (value === undefined) return undefined;
  const text = typeof value === "string" ? value : JSON.stringify(value);
  return text.length > RESULT_LIMIT ? `${text.slice(0, RESULT_LIMIT)}...[truncated]` : value;
}

export class TrajectoryBuilder {
  events = [];
  /** Skills Kiro advertised to the session, which is what actually loaded. */
  advertisedSkills = new Set();
  credits = 0;
  #message = "";
  #reasoning = "";
  #tools = new Map();
  #turnId;

  #push(type, data) {
    this.events.push({ type, timestamp: new Date(), data });
  }

  #flushText() {
    if (this.#reasoning) { this.#push("reasoning", { content: this.#reasoning }); this.#reasoning = ""; }
    if (this.#message) { this.#push("assistant_message", { content: this.#message }); this.#message = ""; }
  }

  startTurn(turnId, prompt) {
    this.#turnId = turnId;
    this.#push("turn_start", { turnId });
    this.#push("user_message", { content: prompt });
  }

  endTurn() {
    this.#flushText();
    this.#push("turn_end", { turnId: this.#turnId });
  }

  addError(message, type = "kiro") {
    this.#flushText();
    this.#push("error", { message, type });
  }

  addCustom(data) {
    this.#push("custom", data);
  }

  /** The last assistant message, matching how Vally's Copilot executor defines output. */
  get output() {
    this.#flushText();
    return this.events.findLast((e) => e.type === "assistant_message")?.data.content ?? "";
  }

  /** Applies the real tool ID that a permission request reports for a call. */
  nameTool(toolCallId, toolId) {
    const tool = this.#tools.get(toolCallId);
    if (!tool || !toolId) return;
    tool.toolName = toolId;
    const event = this.events.find((e) => e.type === "tool_call" && e.data.toolCallId === toolCallId);
    if (event) event.data.toolName = toolId;
  }

  handleUpdate(update) {
    switch (update?.sessionUpdate) {
      case "agent_message_chunk":
        this.#message += update.content?.text ?? "";
        break;
      case "agent_thought_chunk":
        this.#reasoning += update.content?.text ?? "";
        break;
      case "tool_call":
        this.#flushText();
        this.#onToolCall(update);
        break;
      case "tool_call_update":
        this.#onToolUpdate(update);
        break;
      case "available_commands_update":
        for (const command of update.availableCommands ?? []) {
          if (command._meta?.kiro?.type === "skill") this.advertisedSkills.add(command._meta.kiro.originalName ?? command.name);
        }
        break;
      case "session_info_update":
        this.#onSessionInfo(update._meta?.kiro);
        break;
      default:
        break;
    }
  }

  #onToolCall(update) {
    // KAS omits toolId on built-in tools until a permission request names them (see
    // nameTool). An execute call's title is written by the model, so it's never a name.
    const toolName = update._meta?.kiro?.toolId ?? (update.kind === "execute" ? "run_command" : update.title) ?? update.kind ?? "unknown";
    this.#tools.set(update.toolCallId, { toolName, done: false });
    this.#push("tool_call", {
      toolName,
      toolCallId: update.toolCallId,
      arguments: update.rawInput,
      ...(this.#turnId !== undefined && { turnId: this.#turnId }),
    });
    if (update.status === "completed" || update.status === "failed") this.#onToolUpdate(update);
  }

  #onToolUpdate(update) {
    // KAS sends orphan updates with no prior tool_call ("Tool Load", "Subagent Response").
    const tool = this.#tools.get(update.toolCallId);
    if (!tool || tool.done) return;
    if (update.status === "completed") {
      tool.done = true;
      const result = update.rawOutput ?? contentText(update.content);
      this.#push("tool_result", { toolName: tool.toolName, toolCallId: update.toolCallId, success: true, result: clip(result) });
      this.#recordActivation(tool, update);
    } else if (update.status === "failed" || update.status === "denied") {
      tool.done = true;
      const message = contentText(update.content) || update.title || `Tool ${update.status}`;
      this.#push("tool_result", { toolName: tool.toolName, toolCallId: update.toolCallId, success: false, error: { message: String(message) } });
    }
  }

  // A skill counts as activated only once Kiro has actually delivered it to the model.
  #recordActivation(tool, update) {
    const item = update.rawOutput?.item;
    if (tool.toolName !== "disclose_context" || item?.type !== "skill") return;
    this.#push("skill_activation", { name: item.config?.name ?? item.displayName ?? update.rawInput?.name, path: item.id ?? "" });
  }

  #onSessionInfo(kiro) {
    if (kiro?.kind !== "turn_completion") return;
    for (const summary of kiro.promptTurnSummaries ?? []) {
      if (Number.isFinite(summary.usage)) this.credits += summary.usage;
    }
  }
}
