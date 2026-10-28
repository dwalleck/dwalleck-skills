---
name: repo-toolkit
description: >-
  Build, test, full check, focused test run, mutation run, worktree search,
  line endings/BOM, warnings baseline, commit, merge, review bundle: in a repo
  with a .kiro/repo-toolkit.psd1 (or .kiro/implement-spec.psd1) config, run
  every one of these through scripts/ipe.ps1 instead of hand-written dotnet,
  git or PowerShell scripts. Also: subst drive mapping for deep paths, SQL
  container start and connection setup for tests, leaked test databases,
  ledger and ticket updates, review findings export. Most commands need
  that config; Test-LineEndings and ReviewBundle also run without it.
  DO NOT USE to decide which tests to write.
---

# repo-toolkit

One PowerShell toolkit for a repo's build, test, check and git chores. Every command runs with a timeout, long
paths on, and the repo's values from its config.

    pwsh -NoProfile -File .kiro\skills\repo-toolkit\scripts\ipe.ps1 help
    pwsh -NoProfile -File .kiro\skills\repo-toolkit\scripts\ipe.ps1 <Command> -Name value [-Switch] ...

Read [scripts/README.md](scripts/README.md) before the first call: commands, config (base file plus local overlay),
exit codes and self-tests. When the toolkit lacks a job, add the job to the toolkit rather than writing a one-off
script.
