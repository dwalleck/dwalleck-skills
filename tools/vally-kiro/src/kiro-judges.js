// `kiro-prompt` and `kiro-panel`: Vally's real LLM graders running on Kiro judges, so
// rubric handling, scoring and evidence selection stay Vally's own.
//
// They need their own names because the CLI registers `prompt` and `panel` itself after
// loading plugins, and duplicates throw. requiresLlmClient is false so the CLI doesn't
// create its Copilot client for them. That also means Vally's lint reports
// rubric-without-llm-judge for these stimuli, which is expected.
import { PanelGrader, PromptGrader } from "@microsoft/vally";
import { createKiroLlmClient } from "./kiro-llm-client.js";

export const DEFAULT_JUDGE_MODEL = "claude-sonnet-5.5";

class KiroJudgeGrader {
  constructor(inner, name) {
    this.inner = inner;
    this.metadata = {
      ...inner.metadata,
      name,
      description: `${inner.metadata.description} (judged by a Kiro agent)`,
      behavior: { ...inner.metadata.behavior, requiresLlmClient: false },
    };
  }

  defaultName(config) {
    return this.inner.defaultName?.(config)?.replace(this.inner.metadata.name, this.metadata.name) ?? this.metadata.name;
  }

  async grade(input) {
    const config = input.config?.models
      ? input.config
      : { ...input.config, model: input.config?.model ?? process.env.KIRO_JUDGE_MODEL ?? DEFAULT_JUDGE_MODEL };
    const result = await this.inner.grade({ ...input, config });
    return { ...result, name: result.name?.replace(this.inner.metadata.name, this.metadata.name) };
  }
}

export function registerGraders(registry) {
  const client = createKiroLlmClient();
  registry.register(new KiroJudgeGrader(new PromptGrader(client), "kiro-prompt"));
  registry.register(new KiroJudgeGrader(new PanelGrader(client), "kiro-panel"));
}
