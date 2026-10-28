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

**Toolkit**: every build, test, check, commit and merge goes through `scripts/ipe.ps1`
([scripts/README.md](scripts/README.md)), configured by the repo's `.kiro/implement-spec.psd1`. The root agent creates
worktrees with `New-TicketWorktree` and edits the ledger only with `Update-Ledger`. It records a workflow id only from
the `run_workflow` result. It lists every finding of the reviews in steps 5, 7 and 8, with no cap, through
`Export-ReviewFindings`.

To pause the run, or when the run starts from an earlier session's handoff, read [PAUSE-RESUME.md](PAUSE-RESUME.md).

## Steps

1. Read the spec and tickets to understand the task graph. Name the **shared-foundation wave** in the ledger: the tickets that the most other tickets are blocked by.

2. (optional) Use an **exploration subagent** to conduct any exploration required by the tickets - relevant codebase files or external documentation. Ensure the exploration subagent can save files - it should save its markdown notes in a directory outside the repo, accessible by all future subagents, in the form the rules file's "Research notes" section gives. This lets **implementer subagents** focus on implementation rather than exploration. Before ticket 01, run a short **spike** (a throwaway test in a scratch folder) for every `unverified` framework behaviour the plan relies on, and update the note.

3. Create the integration branch. First list the uncommitted and untracked files in the main branch's working tree that the integration branch will carry (spec, tickets, docs); ask the user to commit them on the main branch or set them aside, so the closing merge has nothing in its way. If the issue tracker closes work through PRs, or the user asks for one, open a draft PR after the first merge in step 5 (a branch with no commits ahead of main can't open one), marked as closing the spec and tickets.

4. Use **implementer subagents** to implement each ticket, each in its own worktree on its own branch (`New-TicketWorktree`). Each implementer subagent:
   - confirms its worktree is based on the integration branch before starting, and resets onto it if not;
   - calls the Skill tool with `tdd` to build the ticket;
   - keeps a dated **handoff** in its worktree current at every checkpoint (commit, test gate, review verdict, report): branch, HEAD, uncommitted paths, attempts with verdicts, resources held, next step, and a **Friction** list (anything that cost time, failed unexpectedly or broke a rule, one line each; retros read it);
   - stops only to report: ready to merge, a user decision needed, or a real blocker. A reading of a ticket or of a user decision that differs from its words (narrower, broader, or resting on a premise the code disproves) is a user decision needed: root puts it to the user and never settles it;
   - merges the integration branch tip into its own branch and passes `Invoke-FullCheck` on it before reporting done.

   At dispatch, split a ticket whose acceptance needs native runs on more than one host into **tracks**: a **code track** that owns all code, builds and pins each candidate and runs its own host's natives, and a **host track** per other host that runs natives only on the candidates handed to it; one merger merges the code track once every track reports pass on the same pin.

5. When an implementer reports ready, root launches its **ticket review** (PROMPTS.md "Ticket review"): the code-review workflow recipe `code-review-8` at level medium, findings cap `all`, on `<base>...<ticket branch>`, where `<base>` is the integration tip the branch was cut from or last merged (`git merge-base <integration> <branch>`). Root launches it because step sessions cannot launch workflows. The implementer fixes the findings as the rules file's "Reviews" section says; then a **merger subagent** merges (`Merge-Ticket`, then `Resolve-Ticket`), and blocks on any finding that section leaves open.

6. If this changes the **frontier** of available tickets, kick off more **implementer subagents** to work on the new tickets. This allows for maximum concurrency.

7. When the shared-foundation wave is merged, launch one **cross-ticket review**: `code-review-8` at level high, findings cap `all`, on `<integration base>...<integration tip>`, aimed at duplication and seams between tickets; its findings go to one implementer, as in step 8.

8. Once all tickets are complete, call the Skill tool with `code-review` on the integration branch, findings cap `all`. List every finding with `Export-ReviewFindings`, and fix all of them in a single **implementer subagent**. Pin end-to-end evidence to the source tree it ran on, and check the pin mechanically before step 9: fixes that change product code rerun the evidence they affect.

9. If a draft PR exists, mark it ready for review. Otherwise, resolve each ticket the way the issue tracker closes work, and report the integration branch. Then ask the user whether to merge it into the main branch: trial the merge in a scratch worktree and run the full check there, and report what the merge brings and any working-tree files that block it before touching the main branch.

10. Clean up all **implementer subagent** worktrees.

## Watching the run

Root only.

- On any failure or crash notification, first `inspect_workflow` the run, then relaunch or resume it, before any other action.
- Launch a brief that depends on a file another step is writing only after that file exists and its writer has reported it final; put numbers into a brief only from that final file.
- At every turn, check each ledger row that is `active`: one with no notification for 45 minutes gets `inspect_workflow` and a handoff read, with the result recorded via `Update-Ledger -AppendNote`.
- At each gate (merge, review verdict, decision), check that the ticket's handoff is dated after the gate, and ask the agent to update a stale one before going on.

## Relaying decisions

- Send a paused agent only the message that unblocks it; hold FYIs for its next report.
- Send one settled message per decision, in PROMPTS.md's "Decision" form. Before sending, re-read your previous message to that agent and resolve any contradiction first.
- Number each decision (`<run>-D<n>`), so the agent can recognise a repeated message (rules file "Handoff and messages").
