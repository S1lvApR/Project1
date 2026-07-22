# Windows Bootstrap and GitHub Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the repository reproducibly installable on Windows 10/11 without Microsoft Store, WSL, or Docker, then publish the cleaned project and versioned model assets to `Dman-s/Project1`.

**Architecture:** A repository-local PowerShell bootstrap installs pinned Python and Node.js runtimes, selects GPU or CPU PyTorch, installs locked dependencies, downloads hash-verified model assets, and generates safe local configuration. Shared PowerShell functions provide testable hash, device, configuration, and process checks; separate doctor/start/stop commands handle operations. Source and metadata go to Git, while model weights go to a GitHub Release.

**Tech Stack:** Windows PowerShell 5.1, Python 3.10.11, PyTorch 2.11.0, FastAPI, Node.js 24.18.0, React/Vite, GitHub Actions, GitHub CLI

**Portable placeholders:** `$PROJECT_ROOT` is the repository root. `$REFERENCE_MODEL_SOURCE` is a local source directory whose provenance and redistribution permission have been verified.

---

## File Map

- `.gitignore`: keep local runtimes, models, datasets, logs, archives, and reference projects out of Git while allowing dependency locks and GitHub metadata.
- `backend/requirements-core.txt`: backend dependencies that do not choose a PyTorch wheel channel.
- `backend/requirements-gpu.txt`: CUDA 12.8 PyTorch plus core requirements.
- `backend/requirements-cpu.txt`: CPU PyTorch plus core requirements.
- `backend/requirements.txt`: backward-compatible GPU default.
- `frontend/package-lock.json`: deterministic frontend dependency lock.
- `scripts/config/bootstrap-manifest.json`: pinned runtime and model URLs, versions, sizes, hashes, and provenance.
- `scripts/lib/ProjectEnvironment.psm1`: pure/testable environment, hash, config, and process helper functions.
- `scripts/tests/ProjectEnvironment.Tests.ps1`: offline unit-style PowerShell tests.
- `scripts/tests/BootstrapScripts.Tests.ps1`: parser and command contract tests for entry-point scripts.
- `scripts/tests/run.ps1`: dependency-free PowerShell test runner.
- `scripts/bootstrap-windows.ps1`: idempotent one-command environment installer.
- `scripts/doctor.ps1`: environment and model diagnostics.
- `scripts/start.ps1`: guarded backend/frontend launcher with health checks.
- `scripts/stop.ps1`: PID-identity-checked process shutdown.
- `backend/.env.local.example`: portable local configuration template.
- `README.md`: project overview and shortest working setup path.
- `docs/windows-setup.md`: complete setup, model, GPU/CPU, and troubleshooting guide.
- `docs/local-development.md`: remove machine-specific paths and point to maintained scripts.
- `docs/releases/models-v1.md`: release notes, model metrics, provenance, known class gaps, and checksums.
- `.github/workflows/ci.yml`: CPU backend and deterministic frontend CI.
- `.github/ISSUE_TEMPLATE/bug_report.yml`: reproducible bug report form.
- `.github/ISSUE_TEMPLATE/feature_request.yml`: feature request form.
- `.github/pull_request_template.md`: verification checklist.
- `THIRD_PARTY_NOTICES.md`: separate software, model, and dataset terms, including model provenance and redistribution gates.

## Task 1: Isolate Work and Establish Repository Hygiene

**Files:**
- Modify: `.gitignore`
- Track: `frontend/package-lock.json`

- [ ] **Step 1: Create an isolated worktree from the approved design commit**

Run from `$PROJECT_ROOT`:

```powershell
git -c safe.directory="$PROJECT_ROOT" worktree add .worktrees/windows-bootstrap -b codex/windows-bootstrap-release HEAD
```

Expected: the worktree is created at `$PROJECT_ROOT\.worktrees\windows-bootstrap` and the current untracked datasets/archives remain only in the original worktree.

- [ ] **Step 2: Record the failing ignore checks**

Run:

```powershell
git check-ignore frontend/package-lock.json
git check-ignore .runtime/state/backend.pid models/tt100k-yolo11s-reference42.pt .codex-tmp-tt100k.html Train.tar reference-model-source
```

Expected before editing: `frontend/package-lock.json` is incorrectly ignored; at least `.runtime/` and the root reference directory do not have explicit project-level rules.

- [ ] **Step 3: Update ignore rules narrowly**

Remove `package-lock.json` from the Node lock ignores. Add root-local rules for:

```gitignore
/.runtime/
/models/
/.codex-tmp-*
/backend-*.log
/frontend-*.log
/Train.tar
/reference-model-source/
/*.zip
```

Keep generic `*.pt`, database, upload, training data, and `.env` rules. Do not delete any ignored local file.

- [ ] **Step 4: Verify ignore behavior and track the lock**

Run:

```powershell
git check-ignore frontend/package-lock.json
if ($LASTEXITCODE -eq 0) { throw 'package-lock.json is still ignored' }
git check-ignore .runtime/state/backend.pid models/example.pt .codex-tmp-tt100k.html Train.tar reference-model-source
git add .gitignore frontend/package-lock.json
git diff --cached --check
```

Expected: the lock is not ignored; every local/runtime sample is ignored; staged diff has no whitespace errors.

- [ ] **Step 5: Commit**

```powershell
git commit -m "Track frontend lock and ignore local assets"
```

## Task 2: Split Python Dependencies by Compute Device

**Files:**
- Create: `backend/requirements-core.txt`
- Create: `backend/requirements-gpu.txt`
- Create: `backend/requirements-cpu.txt`
- Modify: `backend/requirements.txt`

- [ ] **Step 1: Write a failing dependency contract check**

Run this from the worktree root before creating the files:

```powershell
$required = @(
  'backend/requirements-core.txt',
  'backend/requirements-gpu.txt',
  'backend/requirements-cpu.txt'
)
if (($required | Where-Object { -not (Test-Path $_) }).Count -eq 0) {
  throw 'Expected split requirement files to be absent initially'
}
```

Expected: the contract confirms the split files do not exist yet.

- [ ] **Step 2: Move non-PyTorch packages into core requirements**

Preserve current package pins and remove the duplicate `httpx` entry. Keep `ultralytics==8.3.0` and `sahi==0.11.18` in core. Use clean UTF-8 comments rather than the currently corrupted banner text.

- [ ] **Step 3: Add explicit GPU and CPU requirement entry points**

`backend/requirements-gpu.txt`:

```text
--extra-index-url https://download.pytorch.org/whl/cu128
torch==2.11.0+cu128
torchvision==0.26.0+cu128
-r requirements-core.txt
```

`backend/requirements-cpu.txt`:

```text
--extra-index-url https://download.pytorch.org/whl/cpu
torch==2.11.0+cpu
torchvision==0.26.0+cpu
-r requirements-core.txt
```

`backend/requirements.txt` contains only `-r requirements-gpu.txt` plus a compatibility comment.

- [ ] **Step 4: Verify both dependency graphs**

Run without reinstalling the current environment:

```powershell
python -m pip install --dry-run -r backend/requirements-gpu.txt
python -m pip install --dry-run -r backend/requirements-cpu.txt
```

Expected: both resolver runs succeed; GPU resolves `+cu128`, CPU resolves `+cpu`.

- [ ] **Step 5: Commit**

```powershell
git add backend/requirements*.txt
git commit -m "Split backend GPU and CPU dependencies"
```

## Task 3: Build the Tested PowerShell Environment Core

**Files:**
- Create: `scripts/config/bootstrap-manifest.json`
- Create: `scripts/lib/ProjectEnvironment.psm1`
- Create: `scripts/tests/ProjectEnvironment.Tests.ps1`
- Create: `scripts/tests/run.ps1`

- [ ] **Step 1: Add the manifest with fixed trusted inputs**

Use these exact runtime values:

```json
{
  "schemaVersion": 1,
  "python": {
    "version": "3.10.11",
    "fileName": "python-3.10.11-amd64.exe",
    "url": "https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe",
    "sha256": "D8DEDE5005564B408BA50317108B765ED9C3C510342A598F9FD42681CBE0648B"
  },
  "node": {
    "version": "24.18.0",
    "fileName": "node-v24.18.0-win-x64.zip",
    "url": "https://nodejs.org/dist/v24.18.0/node-v24.18.0-win-x64.zip",
    "sha256": "0AE68406B42D7725661DA979B1403EC9926DA205C6770827F33AAC9D8F26E821"
  },
  "release": {
    "repository": "Dman-s/Project1",
    "tag": "models-v1"
  }
}
```

Add model records for:

- `tt100k-yolo11s-reference42.pt`, SHA-256 `E8A0E0F1E5A9004C708D7EEE9EDD97E9E9D0A7986023E96C807D0FFCD3D50F88`, repository-owner-selected default detector subject to TT100K CC BY-NC and Ultralytics terms.
- `tt100k-yolo11n-common45.pt` is explicitly excluded from this release.
- `gtsrb-yolo11n-cls.pt`, 3,291,010 bytes, SHA-256 `323E5BD1B0DC5D1F6FBB4C487FAF2320DA0DF9C21132DD46C0C94FEE7B33B16C`, local default classifier pending provenance review.

The default detector is 19,231,379 bytes. Candidate URLs follow
`https://github.com/Dman-s/Project1/releases/download/models-v1/<fileName>`, but a URL must not be activated for a blocked asset. Each record includes purpose, source, license, and byte count; a single license field is not proof that software, dataset, and model redistribution terms are all satisfied.


- [ ] **Step 2: Write failing helper tests**

Create a dependency-free assertion harness and tests for:

```powershell
Assert-Equal (Compare-Version '3.10.11' '3.10.11') 0
Assert-True (Test-VersionAtLeast '24.18.0' '20.0.0')
Assert-Equal (Resolve-DeviceMode -Requested cpu -NvidiaSmiAvailable $true) 'cpu'
Assert-Equal (Resolve-DeviceMode -Requested auto -NvidiaSmiAvailable $true) 'gpu'
Assert-Equal (Resolve-DeviceMode -Requested auto -NvidiaSmiAvailable $false) 'cpu'
Assert-Throws { Resolve-DeviceMode -Requested gpu -NvidiaSmiAvailable $false }
Assert-Throws { Assert-FileHash -Path $fixture -Expected ('0' * 64) }
```

Also test that generated env content contains relative model paths, `APP_MODE=local`, SQLite, disabled Redis/MinIO, and a supplied JWT; assert it never contains the fixture API secret.

- [ ] **Step 3: Run tests and confirm failure**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/tests/run.ps1
```

Expected: FAIL because `ProjectEnvironment.psm1` and its functions do not exist.

- [ ] **Step 4: Implement the helper module**

Implement and export:

```text
Get-ProjectRoot
Read-BootstrapManifest
Compare-Version
Test-VersionAtLeast
Get-FileSha256
Assert-FileHash
Resolve-DeviceMode
New-SecureToken
New-LocalEnvContent
Test-PathInsideRoot
Get-ProjectProcessIdentity
Test-ProjectProcessIdentity
Invoke-CheckedCommand
```

Use `System.Security.Cryptography.RandomNumberGenerator` for tokens, `ConvertFrom-Json` for the manifest, `Get-FileHash` for assets, and argument arrays rather than command-string evaluation.

- [ ] **Step 5: Run tests and confirm pass**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/tests/run.ps1
```

Expected: all helper tests pass under Windows PowerShell 5.1.

- [ ] **Step 6: Commit**

```powershell
git add scripts/config scripts/lib scripts/tests
git commit -m "Add tested Windows environment helpers"
```

## Task 4: Implement the Idempotent Bootstrap

**Files:**
- Create: `scripts/bootstrap-windows.ps1`
- Create: `scripts/tests/BootstrapScripts.Tests.ps1`

- [ ] **Step 1: Write failing bootstrap contract tests**

Parse the script with `System.Management.Automation.Language.Parser` and assert zero parse errors. Invoke `-PlanOnly -Device auto -SkipModels` and assert the JSON/text plan includes Python 3.10.11, Node 24.18.0, a selected requirements file, `npm ci`, and no filesystem mutation outside a temporary fixture root.

- [ ] **Step 2: Run the tests and confirm failure**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/tests/run.ps1
```

Expected: FAIL because the bootstrap entry point is absent.

- [ ] **Step 3: Implement runtime installation and cache validation**

The script must:

- use `[CmdletBinding(SupportsShouldProcess)]`;
- accept `-Device auto|gpu|cpu`, `-SkipRuntimeDownload`, `-SkipModels`, `-ForceConfig`, `-Start`, `-PlanOnly`, and an internal test-only `-ProjectRoot`;
- require Windows x64, TLS 1.2, and at least 12 GB free space for GPU or 6 GB for CPU;
- download to `.runtime/downloads/<file>.partial`, validate SHA-256, then atomically rename;
- install Python per-user to `.runtime/python` with `InstallAllUsers=0`, `PrependPath=0`, `Include_launcher=0`, `Include_test=0`, and `TargetDir=<path>`;
- expand Node into a temporary directory and move the expected versioned folder to `.runtime/node`;
- reject paths outside the project root before removing any stale runtime directory.

- [ ] **Step 4: Implement dependency, model, and config setup**

Create/reuse `backend/.venv`, install the selected requirement entry point, and run `pip check`. In `auto`, install GPU requirements when `nvidia-smi` exists, run `torch.cuda.is_available()`, and reinstall CPU requirements if CUDA self-test fails. In `gpu`, CUDA self-test failure is fatal.

Run `.runtime/node/npm.cmd ci` from `frontend`. Download each default model through the same partial-file/hash flow. Generate `backend/.env` only when absent or `-ForceConfig` is set; write UTF-8 without BOM and never print the generated JWT.

- [ ] **Step 5: Pass offline tests and run plan mode**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/tests/run.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/bootstrap-windows.ps1 -PlanOnly -Device auto
```

Expected: tests pass; plan mode chooses GPU on the current machine and lists all validated actions without installing anything.

- [ ] **Step 6: Commit**

```powershell
git add scripts/bootstrap-windows.ps1 scripts/tests
git commit -m "Add idempotent Windows bootstrap"
```

## Task 5: Add Diagnostics and Safe Process Lifecycle

**Files:**
- Create: `scripts/doctor.ps1`
- Create: `scripts/start.ps1`
- Create: `scripts/stop.ps1`
- Modify: `scripts/tests/BootstrapScripts.Tests.ps1`

- [ ] **Step 1: Write failing diagnostics and lifecycle tests**

Add parser tests for all scripts. With a temporary fake runtime/model tree, assert doctor emits one result object per check and exits nonzero for a bad model hash. Create a harmless long-running PowerShell fixture, write its PID plus expected command identity, and test that stop accepts the matching fixture but rejects a PID record whose identity does not match.

- [ ] **Step 2: Run tests and confirm failure**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/tests/run.ps1
```

Expected: FAIL because doctor/start/stop are absent.

- [ ] **Step 3: Implement `doctor.ps1`**

Check operating system, architecture, disk, runtime versions, virtual environment, selected torch build, CUDA state, package health, frontend lock/modules, env file, SQLite parent directory, all configured model hashes, and ports 8000/5173. Support `-Device auto|gpu|cpu`, `-Json`, and internal `-ProjectRoot`. Human output uses `[PASS]`, `[WARN]`, `[FAIL]`; JSON output contains `name`, `status`, `message`, and `required`.

- [ ] **Step 4: Implement guarded start and stop**

`start.ps1` runs doctor first, rejects occupied ports unless their PID records match this project, starts backend and frontend with hidden windows, writes process records containing PID, executable, start time, and command line, then waits up to 90 seconds for `/api/health` and frontend TCP readiness.

`stop.ps1` reads records, validates the current process identity and start time, stops only matches, waits for exit, and removes stale records. It must never kill a process based only on port number.

- [ ] **Step 5: Pass tests and current-machine diagnostics**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/tests/run.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/doctor.ps1 -Device gpu
```

Expected: all offline tests pass; current GPU diagnostics report RTX 4060, CUDA available, and model hashes valid after models are staged.

- [ ] **Step 6: Commit**

```powershell
git add scripts/doctor.ps1 scripts/start.ps1 scripts/stop.ps1 scripts/tests
git commit -m "Add Windows diagnostics and process controls"
```

## Task 6: Make Configuration and Documentation Portable

**Files:**
- Modify: `backend/.env.local.example`
- Modify: `README.md`
- Create: `docs/windows-setup.md`
- Modify: `docs/local-development.md`
- Create: `docs/releases/models-v1.md`
- Create: `THIRD_PARTY_NOTICES.md`

- [ ] **Step 1: Add a failing portability scan**

```powershell
$trackedDocs = @('README.md', 'docs/windows-setup.md', 'docs/local-development.md', 'backend/.env.local.example')
rg -n '[A-Z]:\\|forbidden-local-secret-placeholder' $trackedDocs
```

Expected before editing: machine-specific/reference paths and a fixed development JWT are found.

- [ ] **Step 2: Replace the local env template**

Use `../models/...` paths as resolved from the backend working directory, retain SQLite/local service flags, document optional API keys as empty values, and use `JWT_SECRET_KEY=generated-by-bootstrap` only as a non-runnable marker. The bootstrap must replace that marker with a random value.

- [ ] **Step 3: Rewrite README around the working path**

Lead with the actual traffic-sign application, include features, Windows requirements, the one-command setup:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 -Device auto -Start
```

Document URLs, GPU/CPU overrides, model choices, tests, project layout, known 42-class model gaps, and links to setup/training docs. Add `docs/releases/models-v1.md` with exact filenames, byte counts, hashes, measured metrics, provenance, separate software/data/model terms, publication status, and missing-class limitations. Do not claim a feature, redistribution right, or release exists until verified.

- [ ] **Step 4: Add full setup/troubleshooting and third-party notices**

Cover proxy settings, download retry, hash mismatch, NVIDIA driver requirements, forced CPU install, missing models, port conflicts, logs, stop behavior, and clean reinstall. Document Ultralytics obligations separately from TT100K's official CC BY-NC terms and citation. Record that the repository owner selected the 42-class checkpoint for this non-commercial release.

- [ ] **Step 5: Run portability and link checks**

```powershell
rg -n '[A-Z]:\\|forbidden-local-secret-placeholder' README.md docs/windows-setup.md docs/local-development.md backend/.env.local.example
git diff --check
```

Expected: no machine-specific path or fixed secret remains; no whitespace errors.

- [ ] **Step 6: Commit**

```powershell
git add README.md docs/windows-setup.md docs/local-development.md docs/releases/models-v1.md backend/.env.local.example THIRD_PARTY_NOTICES.md
git commit -m "Document reproducible Windows setup"
```

## Task 7: Add GitHub Maintenance Files and CI

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `.github/ISSUE_TEMPLATE/bug_report.yml`
- Create: `.github/ISSUE_TEMPLATE/feature_request.yml`
- Create: `.github/pull_request_template.md`

- [ ] **Step 1: Write a failing metadata contract check**

```powershell
$required = @(
  '.github/workflows/ci.yml',
  '.github/ISSUE_TEMPLATE/bug_report.yml',
  '.github/ISSUE_TEMPLATE/feature_request.yml',
  '.github/pull_request_template.md'
)
$missing = $required | Where-Object { -not (Test-Path $_) }
if ($missing.Count -eq 0) { throw 'Expected GitHub metadata to be absent initially' }
```

- [ ] **Step 2: Add CPU-only backend and locked frontend CI**

Use Ubuntu latest, Python 3.10, and Node 24. Backend installs `backend/requirements-cpu.txt`, runs `pytest -q` and `pip check`; frontend runs `npm ci`, `npm run lint`, `npm run test:run`, and `npm run build`. Add a Windows job that only parses and runs offline PowerShell tests. No CI job downloads business model weights.

- [ ] **Step 3: Add issue and PR templates**

Bug reports request Windows version, GPU/driver, `doctor.ps1 -Json` output with secrets removed, reproduction steps, and logs. PRs require tests, dependency lock updates, model provenance, and confirmation that no data/weights/secrets were committed.

- [ ] **Step 4: Validate metadata syntax and tests**

After installing `backend/requirements-cpu.txt`, validate both workflow and issue forms with:

```powershell
backend/.venv/Scripts/python.exe -c "from pathlib import Path; import yaml; files=list(Path('.github').rglob('*.yml')); [yaml.safe_load(p.read_text(encoding='utf-8')) for p in files]; print(f'parsed {len(files)} yaml files')"
```

Then run the PowerShell suite and verify every npm command in CI exists in `frontend/package.json`.

- [ ] **Step 5: Commit**

```powershell
git add .github
git commit -m "Add repository CI and contribution templates"
```

## Task 8: Stage Local Model Candidates and Run End-to-End Verification

**Files:**
- Local only: `.runtime/release/models-v1/*.pt`
- Modify if measured metadata differs: `scripts/config/bootstrap-manifest.json`

- [ ] **Step 1: Copy local candidates from approved sources**

From the original workspace, copy without modifying the sources:

```powershell
Copy-Item "$REFERENCE_MODEL_SOURCE\weights\best.pt" .runtime\release\models-v1\tt100k-yolo11s-reference42.pt
Copy-Item "$PROJECT_ROOT\training\runs\gtsrb_yolo11n_cls_gpu_final\weights\best.pt" .runtime\release\models-v1\gtsrb-yolo11n-cls.pt
```

- [ ] **Step 2: Verify all release hashes and sizes**

```powershell
Get-ChildItem .runtime\release\models-v1\*.pt | Get-FileHash -Algorithm SHA256
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/tests/run.ps1
```

Expected hashes exactly match Task 3. Update only byte counts in the manifest if required; any hash mismatch is fatal. Staging proves identity only and does not authorize publication.

- [ ] **Step 3: Run full backend and frontend verification**

```powershell
& "$PROJECT_ROOT\backend\.venv\Scripts\python.exe" -m pytest -q backend/tests
& "$PROJECT_ROOT\backend\.venv\Scripts\python.exe" -m pip check
Set-Location frontend
npm ci
npm run lint
npm run test:run
npm run build
```

Expected: all 109 backend tests pass; pip check succeeds; all 21 frontend tests pass; lint and build succeed.

- [ ] **Step 4: Run setup and lifecycle smoke tests**

Run bootstrap `-PlanOnly`, doctor against staged models, then start and stop the existing configured app. Confirm `/api/health`, `/docs`, `/camera`, image upload from `$PROJECT_ROOT\Test`, and Chinese class meanings.

- [ ] **Step 5: Scan the exact publication set**

```powershell
git diff --check
git status --short
git ls-files | rg '(\.env$|\.pt$|\.pth$|\.onnx$|\.db$|Train\.tar|\.codex-tmp)'
git ls-tree -r -l HEAD | Sort-Object { [int64](($_ -split '\s+')[3]) } -Descending | Select-Object -First 20
rg -n '(sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|BEGIN (RSA |EC )?PRIVATE KEY)' $(git ls-files)
```

Expected: no tracked secrets, weights, databases, datasets, archives, or unexpected large objects.

- [ ] **Step 6: Commit any final manifest-only correction**

```powershell
git add scripts/config/bootstrap-manifest.json
git diff --cached --quiet; if ($LASTEXITCODE -ne 0) { git commit -m "Finalize release asset manifest" }
```

## Task 9: Integrate and Publish to GitHub

**Files:**
- Git refs and GitHub repository metadata
- GitHub Release: `models-v1`

- [ ] **Step 1: Review the implementation range**

Use the requesting-code-review skill against the design commit through implementation HEAD. Resolve all Critical and Important findings, then rerun Task 8 verification.

- [ ] **Step 2: Merge the isolated branch back to the feature branch**

From `$PROJECT_ROOT`:

```powershell
git -c safe.directory="$PROJECT_ROOT" merge --ff-only codex/windows-bootstrap-release
```

Expected: fast-forward succeeds and original untracked local assets remain untouched.

- [ ] **Step 3: Authenticate GitHub CLI and fetch remote state**

```powershell
gh auth status
gh auth login --web --git-protocol https
git -c safe.directory="$PROJECT_ROOT" fetch origin --prune
```

Only run login when status is unauthenticated. Inspect `origin/main`, `origin/feature/tt100k-training`, and ancestry before integration.

- [ ] **Step 4: Integrate without rewriting history**

If local HEAD contains `origin/main`, fast-forward/create local `main` at HEAD. Otherwise merge `origin/main` normally on a temporary integration branch, resolve only genuine repository conflicts, rerun all key tests, then update local `main`. Never use `push --force`, `reset --hard`, or delete user files.

- [ ] **Step 5: Push source branches**

```powershell
git -c safe.directory="$PROJECT_ROOT" push origin feature/tt100k-training
git -c safe.directory="$PROJECT_ROOT" push origin main
```

Expected: both pushes succeed and remote `main` resolves to the verified integration commit.

- [ ] **Step 6: Update repository metadata**

```powershell
gh repo edit Dman-s/Project1 --description "Windows-native YOLO11 traffic-sign detection platform with FastAPI, React, GPU/CPU inference, video and camera support" --enable-issues --enable-projects=false --enable-wiki=false
gh repo edit Dman-s/Project1 --add-topic yolo11 --add-topic traffic-sign-detection --add-topic fastapi --add-topic react --add-topic pytorch --add-topic computer-vision
```

- [ ] **Step 7: Create the model release from approved assets only**

Do not run this step until `docs/releases/models-v1.md` matches the selected 42-class detector and GTSRB classifier exactly. Do not upload the excluded common-45 checkpoint.

```powershell
$APPROVED_MODEL_ASSETS = @('<path-to-approved-model-1>', '<path-to-approved-model-2>')
gh release create models-v1 $APPROVED_MODEL_ASSETS --repo Dman-s/Project1 --title "Traffic sign models v1" --notes-file docs/releases/models-v1.md
```

If the tag already exists, first run `gh release view models-v1 --repo Dman-s/Project1 --json assets,tagName,url`. Only when it is this project's model release and the local hashes match the manifest, run:

```powershell
gh release upload models-v1 $APPROVED_MODEL_ASSETS --repo Dman-s/Project1 --clobber
```

- [ ] **Step 8: Verify GitHub and a clean clone**

```powershell
gh repo view Dman-s/Project1 --json defaultBranchRef,description,repositoryTopics,url
gh release view models-v1 --repo Dman-s/Project1 --json assets,tagName,url
gh run list --repo Dman-s/Project1 --limit 5
```

Clone into `.runtime/verification/Project1`, verify commit and README, run PowerShell tests and bootstrap `-PlanOnly`, download at least one release model through the bootstrap path, and confirm its SHA-256.

- [ ] **Step 9: Remove the completed worktree**

After all GitHub checks pass and the branch is merged:

```powershell
git -c safe.directory="$PROJECT_ROOT" worktree remove .worktrees/windows-bootstrap
git -c safe.directory="$PROJECT_ROOT" branch -d codex/windows-bootstrap-release
```

Do not remove the worktree if publication or verification remains incomplete.
