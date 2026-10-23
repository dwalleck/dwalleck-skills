# Baseline rules

Start every run's rules file from these, then add the run's concrete commands, build slots, hosts and paths. Each
line came from a retro of an earlier run.

## Checks

- A failure in a test the diff does not touch: rerun that test alone, record both results and the load, and add it to
  the run's known-intermittent list. Rerun the full check only when the focused rerun fails too.
- One full check per verified state; a second only after a failure.
- While an independent review of your code is pending, run focused tests only; the full check follows that review's
  repairs.
- Run no full check while your own end-to-end run or a load test is running.
- Run a batch of focused runs (several test classes, isolated reruns, a red→green pair, a mutation sweep) inside one
  hold of the build lock.

## End-to-end evidence

- Run the final end-to-end (native) evidence once, after the last review verdict and the integration-tip merge. Before
  that, at most one smoke run of a new scenario on one host.
- Build a candidate only for the commit you will run.
- Measure timings only for a target the ticket or design names.
- Start a new driver or scenario from the run's shared driver template, not from another ticket's copy.
- A ticket split into tracks runs on one candidate at a time: the code track builds it, pins it by source tree, and
  hands the pin to every host track. A code change makes a new candidate, and every track reruns on it.

## Mutations

- Name a mutation only for a claim whose tests could not run red first; a red-first run is the sensitivity proof.
- A mutation's RED stays valid while its mutated line and the assertions that turned it red are unchanged. Cite it
  with an applicability line; never rerun the set as a final pass.
- Check a ticket's mutations into the repo's mutation spec directory in the ticket's last code commit, so mergers
  rerun them instead of rewriting them.

## Reviews

- Give your reviewer this file. A reviewer works in its own clone or worktree, runs mutations and repros with the
  focused filter of the affected tests, and reports to the implementer that started it.
- While a reviewer runs, keep working or end your turn, and let its notification wake you. If the notification
  arrives without the report, read the reviewer's output file.

## Merges and waiting

- Merge the integration tip with a plain `git merge` and resolve each conflict by hand. `-X theirs` and `-X ours`
  silently drop your own edits.
- Start long jobs (checks, builds, end-to-end runs) as tracked background jobs (`run_in_background`), and wait with a
  notification or a Monitor on a file and pattern the job writes. A Bash call near its timeout means switch to Monitor.
