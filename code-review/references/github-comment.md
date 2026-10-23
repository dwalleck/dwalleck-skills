<!-- Source: system-prompts/agent-prompt-code-review-part-8-github-comment-posting.md:8-16, with the Claude-specific inline-comment tool replaced by "a GitHub MCP tool if configured" and the `gh api` fallback made the default path. Splice order (comment posting appended after the findings) from `git show a21a614^:system-prompts/agent-prompt-code-review-workflow-routing.md`, line 30. -->
## Posting to GitHub (`--comment`)

The `--comment` flag was passed. After producing the findings list, if the
review target is a GitHub PR (a PR number or PR URL was passed), post each
finding as an inline PR comment — one comment per finding; include a
suggestion block only when it fully fixes the issue.

1. If a GitHub MCP tool that creates inline pull-request review comments is
   configured in this session, use it.
2. Otherwise use `gh`. Check it with `gh auth status`. Get the head commit with
   `gh pr view <pr> --json headRefOid --jq .headRefOid`, then post each finding:

   ```sh
   gh api --method POST repos/{owner}/{repo}/pulls/<pr>/comments \
     -f body="$BODY" -f commit_id="$HEAD_SHA" -f path="$FILE" \
     -F line="$LINE" -f side=RIGHT
   ```

   Resolve the PR's repository first. If the target was a PR URL
   (`https://github.com/<owner>/<repo>/pull/<n>`), take `<owner>` and `<repo>`
   from the URL, pass `--repo <owner>/<repo>` to `gh pr view`, and write them
   into the `gh api` path literally instead of `{owner}/{repo}`. Only for a bare
   PR number may `gh api` fill `{owner}` and `{repo}` from the current
   repository. Pass each
   value as its own quoted argument; never splice finding text into the command
   string. The body is the short summary in bold, then the summary, the failure
   scenario, and the category and verdict.
3. If GitHub rejects a comment (for example, the line is not part of the PR
   diff), do not retry it. List it under "Not posted" with the error.

If neither a GitHub MCP tool nor a working `gh` is available, the findings
are already printed; note that `--comment` was ignored and why. If the target
is not a PR, print the findings to the terminal and note that `--comment` was
ignored.

End with one line: how many comments were posted, and the PR URL.
