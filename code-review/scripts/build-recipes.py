#!/usr/bin/env python3
"""Generate and check the code-review skill's Kiro workflow recipes and the
in-context fallback's reference bundle.

Usage:
  build-recipes.py                 write assets/workflows/*.workflow.json and
                                   references/inline-bundle.md
  build-recipes.py --check         regenerate in memory, require byte equality
                                   with the shipped files, and validate them
  build-recipes.py --check --dir D validate the *.workflow.json files in D
                                   (skips the byte-equality and bundle checks)

Edit this script, not the generated JSON. The bundle concatenates
BUNDLE_SOURCES verbatim; edit those files, never the bundle. --check also
fails when the bundle is over BUNDLE_LIMIT characters, the read cap of the
file tools; past that, the fallback would have to page it with offset/limit.
Validation follows
https://kiro.dev/docs/workflows/authoring.md: root fields, node types and
their fields, joinPolicy values, unique ids, <= 50 step nodes, depth <= 8,
templates that reference only declared inputs or artifacts of steps that
finish strictly before the consumer (never another parallel branch), plus
skill-specific checks: agents exist in assets/agents/, {{skill_dir}} paths
exist, and each recipe's finder angles match the SKILL.md level matrix.
Exits 1 on any failure.
"""
import glob
import json
import os
import re
import sys

SKILL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(SKILL, "assets", "workflows")
AGENT_DIR = os.path.join(SKILL, "assets", "agents")

WORKER = "code-review-worker"
VERIFIER = "code-review-verifier"

CORRECTNESS_5 = ["a-line-scan", "b-removed-behavior", "c-cross-file",
                 "d-language-pitfall", "e-wrapper-proxy"]
CLEANUP_5 = ["reuse", "simplification", "efficiency", "altitude", "conventions"]

BUNDLE = os.path.join(SKILL, "references", "inline-bundle.md")
# Every reference file the in-context fallback reads, angles in the SKILL.md matrix order.
BUNDLE_SOURCES = (["finder-rules.md", "dedup.md", "verify.md", "gap-sweep.md", "output.md"]
                  + ["angles/%s.md" % key for key in CORRECTNESS_5 + CLEANUP_5])
BUNDLE_LIMIT = 30000

# Level matrix (SKILL.md): medium/high = A, B, C + 5; max = A-E + 5.
RECIPES = {
    "code-review-8": {
        "levels": "medium, high",
        "angles": CORRECTNESS_5[:3] + CLEANUP_5,
        "sweep": False,
    },
    "code-review-10": {
        "levels": "max",
        "angles": CORRECTNESS_5 + CLEANUP_5,
        "sweep": True,
    },
}

INPUTS = {
    "skill_dir": "string",
    "run_dir": "string",
    "repo_dir": "string",
    "diff_path": "string",
    "instructions_path": "string",
    "level": "string",
    "level_intro": "string",
    "verify_policy": "string",
    "candidate_cap": "string",
    "findings_cap": "string",
}

CHECKOUT = (
    "Surrounding code is in the checkout {{repo_dir}}. Read its files by absolute "
    "path, and run git as `git -C {{repo_dir}} log|show|blame|diff|grep …`. Search "
    "it with `git -C {{repo_dir}} grep -n <pattern>`: your search tools only cover "
    "the session workspace, which may be a different folder. If params.json has "
    "\"repo_matches_head\": false, read the reviewed version of a file with "
    "`git -C {{repo_dir}} show <pr.head_sha>:<path>`, or fetch it with `gh` if that "
    "commit is not present."
)

FINDER = """You are one finder in a code review, running as one step of the Kiro workflow `<RECIPE>`. Your angle: <TITLE>.

Your working directory is not the reviewed repository. Use only the absolute paths below.

Read these in full first (page through long files with offset/limit until you reach the end):
1. {{skill_dir}}/references/finder-rules.md: your rules.
2. {{skill_dir}}/references/angles/<KEY>.md: your one angle. Look at the diff through this angle only.
3. {{diff_path}}: the unified diff under review. It is the whole review scope; do not regenerate it and do not review anything outside it.
4. {{instructions_path}}: the user's extra instructions. Honor them.
5. {{run_dir}}/params.json: the review target (target_label, pr, repo_matches_head).

Level intro: {{level_intro}}
Candidate cap: up to {{candidate_cap}} candidates.

<CHECKOUT>

This job is read-only. Write exactly one file: the JSON array that finder-rules.md tells you to return, to {{run_dir}}/candidates/<KEY>.json (overwrite it; write [] if you find nothing). Give each `file` relative to the repository root, as in the diff headers. Do not edit, create, or delete anything else, and do not post anything.

Finish with exactly one line: `<KEY>: wrote <n> candidates`. You do not need to call send_message when you succeed. Call send_message with severity "error" only if you could not read the diff or the rules."""

VERIFY = """You are the verify step of a code review (Kiro workflow `<RECIPE>`). You run in a fresh session: you did not find these candidates, and each one must be judged independently.

Your working directory is not the reviewed repository. Use only absolute paths.

Read first, in full:
- {{skill_dir}}/references/verify.md: the verifier prompt, the vote definitions, and the verify policies.
- {{skill_dir}}/references/dedup.md: the dedup rule.
- {{diff_path}}: the diff under review (the whole scope).
- {{instructions_path}}: the user's extra instructions.
- {{run_dir}}/params.json: the review target.

Verify policy: {{verify_policy}}. The reviewed checkout is {{repo_dir}}: read files there by absolute path; use `git -C {{repo_dir}} log|show|blame|grep …`. If params.json has "repo_matches_head": false, read the reviewed version of a file with `git -C {{repo_dir}} show <pr.head_sha>:<path>`.

1. Pool. Read every finder file:
<FILES>
   A missing or unparsable file means that finder failed: add its angle key to "missing_angles" and go on. Remember which angle each candidate came from.
2. Dedup the pool by the rule in dedup.md. Give each remaining candidate an id C01, C02, … and list in "angles" every angle that raised it.
3. Judge each candidate with exactly one vote: the verifier prompt from verify.md, then the {{verify_policy}} policy's rubric addition (only recall has one), then the candidate. Never judge several candidates in one judgment.
   - Mode "sub-agents": if the invoke_sub_agent tool is available to you, start one sub-agent per candidate with agent code-review-worker, all in parallel (in batches if the tool limits how many run at once). Give each one the verifier prompt text, the rubric addition if any, the candidate's JSON, the diff path {{diff_path}}, the checkout {{repo_dir}}, and the instruction that it is read-only, writes no file, and replies in the VOTE/EVIDENCE form.
   - Mode "one-at-a-time": if invoke_sub_agent is not available or cannot start, judge the candidates yourself, one at a time. For each, re-read its hunk and the code it points at as if you had seen no other candidate, and do not let one verdict inform another.
   - Mode "mixed": some votes came from sub-agents and you judged the rest yourself (for example, after a sub-agent failed).
   A judgment with no clear vote follows the policy's no-clear-vote rule in verify.md.
4. Keep or drop each candidate by the {{verify_policy}} policy in verify.md (under max, apply its coordinator rule).
5. Write {{run_dir}}/verified.json, overwriting it, as one JSON object:
   {"mode": "sub-agents" | "one-at-a-time" | "mixed" | "none", "policy": "{{verify_policy}}", "missing_angles": [], "pooled": 0, "deduplicated": 0, "by_sub_agents": 0, "by_verify_step": 0,
    "kept": [{"id": "C01", "file": "", "line": 0, "summary": "", "failure_scenario": "", "category": "", "angles": [], "verdict": "CONFIRMED | PLAUSIBLE", "evidence": "", "judged_by": "sub-agent | verify-step"}],
    "dropped": [{"id": "", "file": "", "line": 0, "summary": "", "category": "", "verdict": "", "evidence": ""}]}
   Use mode "none" when no candidates were pooled.

Write no other file and do not edit the reviewed repository. Finish with exactly one line: `verify: <kept> kept of <deduplicated> (<mode>)`. You do not need to call send_message when you succeed. Call send_message with severity "error" only if you could not read verify.md or the diff."""

SWEEP = """You are the gap-sweep step of a max-effort code review (Kiro workflow `<RECIPE>`): the "one more finder" that gap-sweep.md describes, a fresh reviewer who has the current list. You are that finder, so run its quoted prompt yourself; do not start sub-agents.

Your working directory is not the reviewed repository. Use only absolute paths.

Read in full:
- {{skill_dir}}/references/gap-sweep.md: your prompt.
- {{skill_dir}}/references/finder-rules.md: the candidate shape and rules.
- {{diff_path}}: the diff under review (the whole scope).
- {{instructions_path}}: the user's extra instructions. Honor them.
- {{run_dir}}/params.json: the review target.
- {{artifacts.verified}}: the current list is its "kept" array (file, line, summary). Do not re-raise anything on it.

Level intro: {{level_intro}}

<CHECKOUT>

This job is read-only. Write exactly one file: a JSON array of up to 8 new candidates in the finder-rules.md shape to {{run_dir}}/sweep.json (overwrite it; write [] if nothing is new). Do not edit, create, or delete anything else.

Finish with exactly one line: `sweep: wrote <n> candidates`. You do not need to call send_message when you succeed; use severity "error" only if you could not read the diff."""

REPORT = """You are the report step of a code review (Kiro workflow `<RECIPE>`). Write the final review.

Your working directory is not the reviewed repository. Use only absolute paths.

Read in full:
- {{skill_dir}}/references/output.md: the output format and ranking rules. Follow them exactly.
- {{run_dir}}/params.json: pipeline, target_label, notes.
- {{artifacts.verified}}: "kept" (the verified findings), "mode", "missing_angles", "by_sub_agents", "by_verify_step".
<SWEEP_READ>- {{diff_path}}: read it only as needed to judge severity.

Level: {{level}}. Verify policy: {{verify_policy}}. Findings cap: {{findings_cap}}.
Route: `workflow (<RECIPE>)`. Take the verification value from "mode" as output.md maps it.
Notes: params.json "notes", plus one note per entry in "missing_angles" ("finder <key> failed; that angle was not reviewed").

Write the review to {{run_dir}}/findings.md exactly in output.md's format. Write the same ranked, capped findings to {{run_dir}}/findings.json as a JSON array of objects with file, line, short_summary, summary, failure_scenario, category, verdict. Write no other file.

Then call send_message with severity "success" and the message `code review findings ready: {{run_dir}}/findings.md`, and end with that same line."""

SWEEP_READ = ("- {{artifacts.sweep}}: the sweep additions (a JSON array in the finder "
              "shape). Give each one the verdict `unverified (sweep)`.\n")


def angle_title(key):
    path = os.path.join(SKILL, "references", "angles", key + ".md")
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("### "):
                return line[4:].strip()
    raise SystemExit("no ### heading in " + path)


def fill(text, **subs):
    for k, v in subs.items():
        text = text.replace("<" + k + ">", v)
    return text


def build(name):
    spec = RECIPES[name]
    angles = spec["angles"]
    finders = []
    for key in angles:
        finders.append({
            "type": "step",
            "id": "find-" + key,
            "agent": WORKER,
            "prompt": fill(FINDER, RECIPE=name, KEY=key, TITLE=angle_title(key),
                           CHECKOUT=CHECKOUT),
            "artifacts": {"cand_" + key.replace("-", "_"):
                          "{{run_dir}}/candidates/" + key + ".json"},
        })
    files = "\n".join("   - {{run_dir}}/candidates/%s.json (angle %s)" % (k, k)
                      for k in angles)
    steps = [
        {"type": "parallel", "id": "find", "joinPolicy": "allSettled",
         "branches": finders},
        {"type": "step", "id": "verify", "agent": VERIFIER,
         "prompt": fill(VERIFY, RECIPE=name, FILES=files),
         "artifacts": {"verified": "{{run_dir}}/verified.json"}},
    ]
    if spec["sweep"]:
        steps.append({"type": "step", "id": "sweep", "agent": WORKER,
                      "prompt": fill(SWEEP, RECIPE=name, CHECKOUT=CHECKOUT),
                      "artifacts": {"sweep": "{{run_dir}}/sweep.json"}})
    steps.append({
        "type": "step", "id": "report", "agent": WORKER,
        "prompt": fill(REPORT, RECIPE=name,
                       SWEEP_READ=SWEEP_READ if spec["sweep"] else ""),
        "artifacts": {"findings_md": "{{run_dir}}/findings.md",
                      "findings_json": "{{run_dir}}/findings.json"},
    })
    sweep_txt = "sweep, " if spec["sweep"] else ""
    return {
        "name": name,
        "description": (
            "Code review (%s) for the code-review skill: %d parallel finders, "
            "independent verify, %sreport → <run_dir>/findings.md. Inputs: "
            "skill_dir, run_dir, repo_dir, diff_path, instructions_path (absolute "
            "paths), level, level_intro, verify_policy, candidate_cap, "
            "findings_cap. Managed by the code-review skill (generated by "
            "scripts/build-recipes.py); the skill overwrites this file when it "
            "differs from its shipped copy." % (spec["levels"], len(angles), sweep_txt)),
        "inputs": dict(INPUTS),
        "injectOriginalUserRequest": False,
        "steps": steps,
    }


def render(recipe):
    return json.dumps(recipe, indent=2, ensure_ascii=False) + "\n"


def build_bundle():
    parts = [
        "<!-- Generated by scripts/build-recipes.py from the files named below. "
        "Edit those files and rerun the script; never edit this file. -->\n",
        "Every reference the in-context fallback needs, in one file; apply only "
        "your level's angles.\n",
    ]
    for rel in BUNDLE_SOURCES:
        with open(os.path.join(SKILL, "references", *rel.split("/")), encoding="utf-8") as fh:
            text = fh.read()
        if not text.endswith("\n"):
            text += "\n"
        parts.append("\n## references/%s\n\n%s" % (rel, text))
    return "".join(parts)


def check_bundle():
    """Return the errors for the shipped bundle (empty when it is current)."""
    expected = build_bundle()
    errors = []
    if not os.path.exists(BUNDLE):
        return ["inline-bundle.md is missing (rerun without --check)"]
    with open(BUNDLE, encoding="utf-8") as fh:
        if fh.read() != expected:
            errors.append("inline-bundle.md differs from the generator output (rerun without --check)")
    if len(expected) > BUNDLE_LIMIT:
        errors.append("inline-bundle.md is %d characters, over the %d read cap"
                      % (len(expected), BUNDLE_LIMIT))
    return errors


# ---- validation -----------------------------------------------------------

ROOT_KEYS = {"name", "description", "inputs", "modelId", "effortLevel", "steps",
             "injectOriginalUserRequest"}  # last one: 2.32 runtime schema, not in the doc table
NODE_FIELDS = {
    "step": ({"id", "agent", "prompt"},
             {"artifacts", "captureOutput", "completion", "modelId", "effortLevel"}),
    "sequence": ({"id", "steps"}, set()),
    "repeat": ({"id", "steps", "maxIterations", "onMaxIterations"},
               {"stopCondition", "stopWhen"}),
    "parallel": ({"id", "branches", "joinPolicy"}, set()),
    "watch": ({"id", "handler", "config"}, {"idleTimeoutSec"}),
}
TEMPLATE = re.compile(r"\{\{\s*([^{}]+?)\s*\}\}")


def templates(node):
    texts = [node.get("prompt", "")] + list(node.get("artifacts", {}).values())
    return [m for t in texts for m in TEMPLATE.findall(t)]


def validate(recipe, inputs_expected=None):
    errors = []
    stats = {"steps": 0, "depth": 0, "finder_angles": []}
    extra = set(recipe) - ROOT_KEYS
    if extra:
        errors.append("unknown root keys: %s" % sorted(extra))
    for req in ("name", "steps"):
        if req not in recipe:
            errors.append("missing root key " + req)
    inputs = recipe.get("inputs", {})
    if not all(isinstance(v, str) for v in inputs.values()):
        errors.append("input type hints must be strings")
    if inputs_expected is not None and set(inputs) != set(inputs_expected):
        errors.append("inputs differ from the shipped set")
    agents = {os.path.splitext(os.path.basename(p))[0]
              for p in glob.glob(os.path.join(AGENT_DIR, "*.json"))}
    ids = set()

    def walk(node, depth, avail):
        """Validate node; return the artifact names it produces."""
        stats["depth"] = max(stats["depth"], depth)
        t = node.get("type")
        if t not in NODE_FIELDS:
            errors.append("bad node type %r" % t)
            return set()
        req, opt = NODE_FIELDS[t]
        missing = req - set(node)
        unknown = set(node) - req - opt - {"type"}
        if missing:
            errors.append("%s %s missing %s" % (t, node.get("id"), sorted(missing)))
        if unknown:
            errors.append("%s %s unknown fields %s" % (t, node.get("id"), sorted(unknown)))
        nid = node.get("id")
        if nid in ids:
            errors.append("duplicate id " + str(nid))
        ids.add(nid)
        if t == "step":
            stats["steps"] += 1
            if node.get("agent") not in agents:
                errors.append("step %s: agent %s not in assets/agents" % (nid, node.get("agent")))
            for ref in templates(node):
                if ref.startswith("artifacts."):
                    if ref[len("artifacts."):] not in avail:
                        errors.append("step %s: {{%s}} not produced by a strictly prior step" % (nid, ref))
                elif "." in ref or ref.endswith("output"):
                    errors.append("step %s: {{%s}} output templates are not used" % (nid, ref))
                elif ref not in inputs:
                    errors.append("step %s: {{%s}} is not a declared input" % (nid, ref))
            for rel in re.findall(r"\{\{skill_dir\}\}/([\w./-]+\w)", node.get("prompt", "")):
                if not os.path.exists(os.path.join(SKILL, rel)):
                    errors.append("step %s: %s does not exist in the skill" % (nid, rel))
            if str(nid).startswith("find-"):
                found = re.findall(r"references/angles/([\w-]+)\.md", node["prompt"])
                if len(set(found)) != 1:
                    errors.append("finder %s names %d angle files" % (nid, len(set(found))))
                else:
                    stats["finder_angles"].append(found[0])
            return set(node.get("artifacts", {}))
        if t == "parallel":
            if node.get("joinPolicy") not in ("all", "allSettled", "any"):
                errors.append("parallel %s: bad joinPolicy" % nid)
            produced = set()
            for b in node.get("branches", []):
                produced |= walk(b, depth + 1, set(avail))  # branches see only prior siblings
            return produced
        if t in ("sequence", "repeat"):
            return walk_seq(node.get("steps", []), depth + 1, avail)
        return set()

    def walk_seq(nodes, depth, avail):
        avail = set(avail)
        produced = set()
        for n in nodes:
            out = walk(n, depth, avail)
            avail |= out
            produced |= out
        return produced

    walk_seq(recipe.get("steps", []), 2, set())  # the implicit root sequence is depth 1
    if stats["steps"] > 50:
        errors.append("more than 50 step nodes")
    if stats["depth"] > 8:
        errors.append("nesting depth over 8")
    name = recipe.get("name")
    if name in RECIPES and sorted(stats["finder_angles"]) != sorted(RECIPES[name]["angles"]):
        errors.append("finder angles %s differ from the level matrix" % stats["finder_angles"])
    return errors, stats


def main(argv):
    check = "--check" in argv
    scratch = None
    if "--dir" in argv:
        scratch = argv[argv.index("--dir") + 1]
    if not check:
        os.makedirs(OUT_DIR, exist_ok=True)
        for name in RECIPES:
            with open(os.path.join(OUT_DIR, name + ".workflow.json"), "w", encoding="utf-8") as fh:
                fh.write(render(build(name)))
            print("wrote assets/workflows/%s.workflow.json" % name)
        with open(BUNDLE, "w", encoding="utf-8") as fh:
            fh.write(build_bundle())
        print("wrote references/inline-bundle.md")
    target = scratch or OUT_DIR
    failed = False
    for path in sorted(glob.glob(os.path.join(target, "*.workflow.json"))):
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        recipe = json.loads(text)
        errors, stats = validate(recipe, INPUTS)
        name = recipe.get("name")
        if scratch is None and name in RECIPES and text != render(build(name)):
            errors.append("shipped file differs from the generator output (rerun without --check)")
        if errors:
            failed = True
            for e in errors:
                print("%s: ERROR %s" % (name, e))
        else:
            print("%s: %d steps, depth %d (implicit root = 1), %d angles OK"
                  % (name, stats["steps"], stats["depth"], len(stats["finder_angles"])))
    if scratch is None:
        bundle_errors = check_bundle()
        if bundle_errors:
            failed = True
            for e in bundle_errors:
                print("inline-bundle.md: ERROR %s" % e)
        else:
            print("inline-bundle.md: %d sources, %d characters OK"
                  % (len(BUNDLE_SOURCES), len(build_bundle())))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
