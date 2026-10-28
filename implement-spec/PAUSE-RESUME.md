# Pausing and resuming a run

## Pause

1. Tell every running subagent to stop at its next **safe point**: no build, test or launch in flight; shared locks and devices released; temporary edits to shared code reverted byte for byte; its handoff dated after its last gate.
2. Wait for each subagent to confirm its safe point.
3. Leave unfinished work uncommitted and listed in its handoff, so every commit stays gated work.
4. Update the run ledger, then write a top-level handoff beside it: pointers to the ledger and to each active track's handoff, open user decisions, and the recommended resumption order.

The pause is complete when every subagent has confirmed its safe point and the ledger and top-level handoff are written.

## Resume

1. Read the top-level handoff, the run ledger, and each active track's handoff.
2. Verify every recorded fact against the environment before acting: branch tips, worktree HEADs, uncommitted path counts, ticket statuses, free resources. On any mismatch, stop and report both values to the user; the user decides which is true. `inspect_workflow` every workflow id in the ledger; handle a failed or paused run (relaunch or resume) before any new launch.
3. Recompute the frontier from the ticket files on the integration branch.
4. Start fresh subagents, each pointed at its track's handoff and resuming at its recorded next step. Completed gates, qualified runs and recorded verdicts, failures included, stand as recorded. Paths and commit hashes carry the run across sessions; agent IDs from the earlier session do not.
5. Continue the main Steps from where the ledger left off.
