# GitHub Main Repository Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the verified TrafficAgent application on `main`, improve the GitHub repository homepage, and remove every local and remote branch except `main`.

**Architecture:** Keep repository history linear by committing the documentation cleanup on the existing verified descendant of `main`, then move local `main` forward without rewriting history. Treat local verification and the pushed `main` GitHub Actions run as hard gates before explicitly deleting named branches and disposable worktrees.

**Tech Stack:** Git, GitHub CLI, GitHub Actions, Markdown, FastAPI/pytest, React/Vite/Vitest, Windows PowerShell 5.1

---

### Task 1: Polish The GitHub Homepage

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add repository status badges below the title**

Use badges bound to the permanent `main` workflow and repository resources:

```markdown
[![CI](https://github.com/Dman-s/Project1/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Dman-s/Project1/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/Dman-s/Project1?display_name=tag)](https://github.com/Dman-s/Project1/releases/latest)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)
![Python 3.10](https://img.shields.io/badge/Python-3.10-3776AB?logo=python&logoColor=white)
![Node.js 24](https://img.shields.io/badge/Node.js-24-5FA04E?logo=node.js&logoColor=white)
```

- [ ] **Step 2: Put the one-command quick start before the detailed capability list**

Keep these facts together near the top: Windows 10/11 x64, no Microsoft Store/WSL/Docker/admin requirement, the bootstrap command, frontend URL, API docs URL, and first-login registration.

- [ ] **Step 3: Replace repeated workflow prose with a scannable table**

Use four rows for image street-scene detection, cropped-sign classification, video detection, and camera detection. Preserve the full-timeline, live preview, H.264 playback, Chinese labels, 50 km/h refinement, and silent-output behavior.

- [ ] **Step 4: Preserve model and licensing caveats**

Keep the 42-class model table, unsupported `ph5`/`w32`/`wo` statement, TT100K CC BY-NC restriction, Ultralytics terms, AGPL source license, and traffic-light non-support statement.

- [ ] **Step 5: Verify README links and formatting**

Run:

```powershell
git diff --check
rg -n "actions/workflows/ci.yml|releases/latest|bootstrap-windows.ps1|tt100k-reference42|THIRD_PARTY_NOTICES" README.md
```

Expected: no whitespace errors and every required repository link is present.

- [ ] **Step 6: Commit the homepage cleanup**

```powershell
git add README.md docs/superpowers/plans/2026-07-16-github-main-repository-cleanup.md
git commit -m "docs: polish GitHub repository homepage"
```

### Task 2: Promote The Verified History To Local Main

**Files:**
- Verify: repository refs and working tree

- [ ] **Step 1: Confirm `main` remains an ancestor**

Run:

```powershell
git merge-base --is-ancestor origin/main HEAD
```

Expected: exit code `0`. Stop on any other result.

- [ ] **Step 2: Move local `main` to the verified commit and switch branches**

Run:

```powershell
git branch -f main HEAD
git switch main
```

Expected: `main` points to the same SHA as the cleanup commit and the user-owned untracked Markdown file remains unchanged.

- [ ] **Step 3: Run merged backend verification**

Run:

```powershell
& .\backend\.venv\Scripts\python.exe -m pytest -q .\backend\tests
& .\backend\.venv\Scripts\python.exe -m pip check
```

Expected: all backend tests pass and pip reports no broken requirements.

- [ ] **Step 4: Run merged frontend verification**

Run from `frontend/`:

```powershell
& ..\.runtime\node\npm.cmd run lint
& ..\.runtime\node\npm.cmd run test:run
& ..\.runtime\node\npm.cmd run build
```

Expected: lint exits `0`, all Vitest tests pass, and Vite creates `dist/`.

- [ ] **Step 5: Run merged Windows bootstrap verification**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\tests\run.ps1
```

Expected: `Failed: 0`.

### Task 3: Publish And Verify Main

**Files:**
- Verify: GitHub branch and Actions state

- [ ] **Step 1: Push `main` without force**

Run:

```powershell
git push origin main
```

Expected: a fast-forward update from `5d2fe6c` to the cleanup commit.

- [ ] **Step 2: Confirm GitHub received the exact SHA**

Run:

```powershell
git rev-parse HEAD
git ls-remote origin refs/heads/main
```

Expected: both SHA values match.

- [ ] **Step 3: Wait for the `main` CI run**

Use `gh run list --branch main` to identify the run for the pushed SHA, then:

```powershell
gh run watch <run-id> --repo Dman-s/Project1 --exit-status --interval 15
```

Expected: Backend, Frontend, and Windows bootstrap tests all conclude `success`. Stop before branch deletion if the command fails.

### Task 4: Enforce The Main-Only Branch Policy

**Files:**
- Remove: disposable Git worktrees and non-`main` refs

- [ ] **Step 1: Verify every removable local branch is contained in `main`**

For `feature/tt100k-training`, `codex/video-detection-playback`, and `codex/video-inference-schedule`, run `git merge-base --is-ancestor <branch> main`. Delete only branches that return exit code `0`; inspect and preserve any branch that is not contained.

- [ ] **Step 2: Remove disposable worktrees**

Use `git worktree list` to resolve exact paths, confirm each path is under `D:\Project1-main1\.worktrees`, and remove only the listed Codex worktrees with `git worktree remove <exact-path>`.

- [ ] **Step 3: Delete contained local non-main branches**

Run explicit non-force deletions:

```powershell
git branch -d feature/tt100k-training
git branch -d codex/video-detection-playback
git branch -d codex/video-inference-schedule
```

- [ ] **Step 4: Delete named remote branches**

After successful `main` CI, run:

```powershell
git push origin --delete feature/tt100k-training main1
```

- [ ] **Step 5: Prune and prove the final state**

Run:

```powershell
git fetch origin --prune
git branch
git branch -r
gh api repos/Dman-s/Project1/branches --paginate --jq '.[].name'
git status --short --branch
```

Expected: local, remote-tracking, and GitHub branch lists contain only `main`; `main` tracks `origin/main`; the user-owned Markdown file is still the only unrelated untracked file.

### Task 5: Verify Repository Metadata And Runtime

**Files:**
- Verify: GitHub metadata and local managed services

- [ ] **Step 1: Confirm repository metadata remains accurate**

Run `gh repo view Dman-s/Project1 --json description,homepageUrl,defaultBranchRef,repositoryTopics,licenseInfo`. Expected: default branch `main`, current Windows-native description, empty homepage, focused eight topics, and AGPL-3.0 license.

- [ ] **Step 2: Confirm the model release remains available**

Run `gh release view models-v1 --repo Dman-s/Project1`. Expected: release `models-v1` and its two model assets remain present.

- [ ] **Step 3: Confirm the locally running application survived branch cleanup**

Request `http://127.0.0.1:5173/` and `http://127.0.0.1:8000/api/health`. Expected: frontend HTTP `200` and backend status `healthy`.
