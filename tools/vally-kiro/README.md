# vally-kiro

Runs [Vally](https://microsoft.github.io/vally/) evals against Kiro CLI skills. The agent under test and the LLM judges are both Kiro v3 sessions over ACP, using your `kiro-cli login`. No API key or Copilot subscription is needed.

## Run it

Requires Node 22.15+ and a signed-in Kiro CLI (`kiro-cli login`).

```powershell
cd tools/vally-kiro
npm install

# Check the derived spec, without running an agent
node bin/vally-kiro.mjs lint ../../tests/tunit-assertions/eval.yaml

# Run the eval. Without --require-pass, failing graders still exit 0.
node bin/vally-kiro.mjs eval ../../tests/tunit-assertions/eval.yaml --output-dir ./results --require-pass

# Run a subset
node bin/vally-kiro.mjs eval ../../tests/tunit-assertions/eval.yaml --tag journey=fix-test-assertion

# Re-score saved results without re-running the agent
Get-Content ./results/<timestamp>/results.jsonl | node bin/vally-kiro.mjs grade ../../tests/tunit-assertions/eval.yaml

# Judge two saved runs of the same stimuli head to head
node bin/vally-kiro.mjs compare --baseline ./results/<old> --treatment ./results/<new> --fail-on-regression
```

The skill is inferred from `tests/<name>/eval.yaml`; pass `--skill <dir>` otherwise. Other options include `--model`, `--judge-model`, `--mode`, `--allow-shell` and `--no-activation`. Anything else goes to Vally, such as `--runs 3`. Run the launcher with no arguments for the full list.

Vally collects usage telemetry by default. Set `VALLY_TELEMETRY_OPTOUT=1` to opt out.

## How a spec is translated

The canonical `eval.yaml` is never edited. The launcher writes a Kiro variant to `.generated/<skill>/eval.yaml`:

| In the spec | In the Kiro variant | Why |
|---|---|---|
| `type: prompt`, `type: panel` | `kiro-prompt`, `kiro-panel` | The CLI creates a Copilot client for the built-in names, and a plugin can't replace them. These wrap Vally's real graders. |
| `expect_activation` (default `true`) | `skill-invocation` grader | It's a skill-validator field that Vally rejects. |
| Executor | `kiro` | |
| The skill | Executor config, not `agent_environment.skills` | Vally would copy it into the workspace root, where an agent could read it without activating it. |

## What's measured

- **Skill activation:** a `skill_activation` event is recorded when Kiro delivers the skill (`disclose_context` completing with a `skill` item), not merely when it's requested.
- **Tools and turns:** tool calls and results, turn boundaries, and messages. `output` is the last assistant message. Tools are named by Kiro's ID when it reports one (`read_file`, `fs_write`, `run_command`, `disclose_context`). Tools that raise no permission request keep their title, such as `Grep Search`.
- **Credits:** each run adds a `kiro.credits` custom event.

ACP doesn't report input and output tokens, so token metrics stay at 0 and `token-budget` graders won't work.

## Isolation and permissions

Each agent and judge gets its own process and temporary `KIRO_HOME`, which hides your `~/.kiro` skills, steering and memory. `HOME` and `USERPROFILE` stay real, because kiro-cli 3.0 on Windows fails with "home directory not found" if `USERPROFILE` changes.

The agent under test runs under a policy that denies anything it doesn't recognize:

| Request | Default |
|---|---|
| Read files | Workspace and staged skills only |
| Write files | Workspace only |
| Shell | **Denied** unless `--allow-shell` |
| Anything else (web, MCP) | Denied |

The policy can only answer requests Kiro sends. `Grep Search` and `File Search` don't raise any, so they aren't covered by it. In a live test Kiro kept searches inside the workspace, and out-of-scope reads, writes and shell commands were all denied. That was one run against kiro-cli 3.0.0, so this isn't a security boundary for untrusted skills.

**A denied tool can look like a weak skill.** Denials print `[kiro] <stimulus>: N tool request(s) denied` and are saved as `kiro.permission_denied` events. Before trusting a failure, check for them. If a skill needs to build or run something, rerun with `--allow-shell`, which isn't sandboxed: commands run with your full permissions, so avoid an Administrator terminal.

Judges can use only `view`, `grep` and the verdict tool, all from `src/judge-mcp.js`. Scoping and read budgets are enforced there, not left to the model.

## Comparing runs

`vally compare` hard-codes a Copilot judge and has no plugin option, so `vally-kiro compare` preloads `src/compare-judge-hook.js`, which swaps that one import for the Kiro client. Vally still does the pairing, forward and reverse judging, statistics, report and exit codes. Options are Vally's own; the rubric comes from the saved runs. Each pair costs two judge sessions. To override the rubric, pass `--eval-spec .generated/<skill>/eval.yaml`, because Vally rejects a canonical spec that has `expect_activation`.

Read one stimulus's score with care. Two runs of the same skill scored up to ±0.40 on a single stimulus, so only larger gaps mean much. `--fail-on-regression` needs the whole 95% interval below zero, which a few pairs rarely reach: a 4-stimulus run against a hollowed-out skill averaged -0.50 and still exited 0. Compare more stimuli or use `--runs 3` before relying on it as a gate.

Kiro judges are told to copy rubric criteria verbatim. Vally pairs forward and reverse verdicts by that text, and paraphrases turn the per-criterion results into ties.

This depends on Vally's internals, which is one reason versions are pinned. `test/compare-judge.test.mjs` fails if an upgrade stops the swap from taking effect.

## Limitations

- `compare`'s experiment mode (`compare <experiment-dir>`) is untested, and the launcher can't run `vally experiment`, so use `--baseline` and `--treatment`.
- Vally's lint reports `rubric-without-llm-judge` for these specs. It's expected: the graders declare no LLM client so that the CLI won't start Copilot.
- Stimulus-level MCP servers aren't supported yet. The executor rejects them rather than ignoring them.
- CI needs a signed-in Kiro session on the runner. This has only been run locally.
- Tested with kiro-cli 3.0.0 and Vally 0.21.0, on Windows. Both are moving quickly, so versions are pinned.

## Development

`npm test` runs without Kiro or credits, using `test/fake-kiro.mjs`. Set `VALLY_KIRO_TRACE=<absolute path>` to log every ACP frame, and `KIRO_CLI` to use a different binary.
