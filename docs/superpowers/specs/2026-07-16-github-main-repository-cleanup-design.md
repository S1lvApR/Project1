# GitHub Main Repository Cleanup Design

## Goal

Make `main` the only long-lived local and remote branch, publish the fully
verified video-detection work there, and make the GitHub repository homepage
clear enough for a new Windows user to install, run, test, and understand the
project without searching through implementation notes.

## Current State

- GitHub's default branch is `main` at `5d2fe6c`.
- `feature/tt100k-training` is a fast-forward descendant at `541adba` and its
  Linux backend, frontend, and Windows bootstrap CI jobs all pass.
- The remote also has an unrelated stale `main1` branch.
- Repository description, topics, AGPL license, issue forms, pull request
  template, CI workflow, and the `models-v1` release are already configured.
- The local worktree contains one user-owned untracked Markdown file. It must
  remain untracked and unchanged.

## Branch Policy

1. Add the repository-homepage cleanup commit to the verified descendant of
   `main`.
2. Fast-forward local `main` to that commit. No merge commit and no rewritten
   history are allowed.
3. Run the complete backend, frontend, and Windows bootstrap verification on
   local `main`.
4. Push `main` and wait for all GitHub Actions jobs for the pushed SHA to pass.
5. Delete remote `feature/tt100k-training` and `main1` only after GitHub confirms
   the successful `main` run.
6. Stop project processes tied to disposable worktrees, remove those worktrees,
   and delete all local non-`main` branches after confirming their commits are
   reachable from `main`.

At completion, both `git branch` and the GitHub branch list contain only
`main`. The existing `models-v1` release remains unchanged.

## Repository Homepage

The README will stay technical and Windows-focused rather than becoming a
marketing page. Its first viewport will contain:

- the `TrafficAgent` name and one-sentence purpose;
- badges for `main` CI, latest release, AGPL-3.0 license, Python, and Node.js;
- the one-command Windows bootstrap;
- direct links to the application capabilities and detailed documentation.

The remainder will be reordered into: capabilities, quick start, workflows,
models, verification, repository layout, documentation, and licensing. Existing
accuracy and licensing caveats remain explicit. No public homepage URL, hosted
demo, screenshot, or GitHub Pages site will be claimed because the application
currently runs only on localhost and no durable public visual asset is part of
the repository.

## GitHub Metadata

Keep the existing concise English description and the current focused topics:
FastAPI, GTSRB, PyTorch, React, traffic-sign detection, TT100K, Windows, and
YOLO11. Leave the homepage field empty until a real public deployment exists.
Keep Issues, Releases, CI, templates, and the AGPL license enabled.

## Verification And Failure Handling

- Local gates: backend pytest and dependency check; frontend lint, tests, and
  production build; all PowerShell environment tests; `git diff --check`.
- Remote gate: every job in the `main` GitHub Actions run must pass.
- If local verification or remote CI fails, stop before deleting any branch.
- If `main` is no longer an ancestor of the cleanup commit, stop instead of
  forcing the push.
- Branch deletion is performed with explicit branch names, never wildcard or
  force-push operations.
