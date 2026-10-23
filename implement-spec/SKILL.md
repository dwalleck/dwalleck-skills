---
name: implement-spec
description: "Implement the result of /to-spec and /to-tickets in code."
disable-model-invocation: true
---

You have been provided a spec. This spec should have tickets associated with it, describing how to implement the spec.

The issue tracker should have been provided to you. If not, tell the user to run `/setup-matt-pocock-skills`.

The goal is the entire spec implemented on a single **integration branch**, with every ticket resolved the way the issue tracker closes work.

The tickets are not a list of steps. They are a **task graph** with blocking relationships between them. This means there is always a **frontier** of tickets which are ready to be grabbed.

Communication to and from subagents should be sparse. Communicate primarily through **context pointers**: to the spec, tickets, research notes, and previous commits. Don't duplicate information already available via pointers.

**Implementer subagents** should be run in the background where possible for maximum concurrency.

Keep a **run ledger**: one file, in an out-of-repo directory every subagent can read, from which a fresh session can resume the run. Update it after every merge, every subagent start or stop, and every user decision. It records the integration branch tip; each ticket as resolved, active (worktree, branch, HEAD), blocked (by what) or not started; the frontier; decisions the user made during the run and where each is recorded; and shared resources with their holders. Point to tickets, commits and evidence rather than copying them.

Keep a **rules file** beside the ledger: the current rules every subagent follows for shared resources (build locks, hosts, leases), reporting and binding user decisions; start it from [RULES-BASE.md](RULES-BASE.md). It is the single source of truth: prompts point to it rather than restating it, and a rule that changes is edited there, with a dated note of why in a separate log. Turn any rule broken twice into a script that enforces it.

When writing a subagent prompt, start from [PROMPTS.md](PROMPTS.md).

To pause the run, or when the run starts from an earlier session's handoff, read [PAUSE-RESUME.md](PAUSE-RESUME.md).

## Steps

1. Read the spec and tickets to understand the task graph.

2. (optional) Use an **exploration subagent** to conduct any exploration required by the tickets - relevant codebase files or external documentation. Ensure the exploration subagent can save files - it should save its markdown notes in a directory outside the repo, accessible by all future subagents. This lets **implementer subagents** focus on implementation rather than exploration.

3. Create the integration branch. First list the uncommitted and untracked files in the main branch's working tree that the integration branch will carry (spec, tickets, docs); ask the user to commit them on the main branch or set them aside, so the closing merge has nothing in its way. If the issue tracker closes work through PRs, or the user asks for one, open a draft PR after the first merge in step 5 (a branch with no commits ahead of main can't open one), marked as closing the spec and tickets.

4. Use **implementer subagents** to implement each ticket, each in its own worktree on its own branch. Each implementer subagent:
   - confirms its worktree is based on the integration branch before starting, and resets onto it if not;
   - calls the Skill tool with `tdd` to build the ticket;
   - keeps a dated **handoff** in its worktree current at every checkpoint (commit, test gate, review verdict): branch, HEAD, uncommitted paths, attempts with verdicts, resources held, next step, and a **Friction** list (anything that cost time, failed unexpectedly or broke a rule, one line each; retros read it);
   - stops only to report: ready to merge, a user decision needed, or a real blocker. A reading of a ticket or of a user decision that differs from its words (narrower, broader, or resting on a premise the code disproves) is a user decision needed: root puts it to the user and never settles it;
   - merges the integration branch tip into its own branch before reporting done.

   At dispatch, split a ticket whose acceptance needs native runs on more than one host into **tracks**: a **code track** that owns all code, builds and pins each candidate and runs its own host's natives, and a **host track** per other host that runs natives only on the candidates handed to it; one merger merges the code track once every track reports pass on the same pin.

5. Once an **implementer subagent** completes, merge its work to the integration branch with a **merger subagent**.

6. If this changes the **frontier** of available tickets, kick off more **implementer subagents** to work on the new tickets. This allows for maximum concurrency.

7. Once all tickets are complete, call the Skill tool with `code-review` on the integration branch. Fix all issues raised by the code review in a single **implementer subagent**. Pin end-to-end evidence to the source tree it ran on, and check the pin mechanically before step 8: fixes that change product code rerun the evidence they affect.

8. If a draft PR exists, mark it ready for review. Otherwise, resolve each ticket the way the issue tracker closes work, and report the integration branch. Then ask the user whether to merge it into the main branch: trial the merge in a scratch worktree and run the full check there, and report what the merge brings and any working-tree files that block it before touching the main branch.

9. Clean up all **implementer subagent** worktrees.
