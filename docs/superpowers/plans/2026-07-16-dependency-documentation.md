# Dependency Documentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a complete, mode-aware dependency manual for every TrafficAgent subsystem and keep its pinned versions synchronized with repository manifests and lock files.

**Architecture:** Treat the bootstrap manifest, Python requirement files, npm manifests, settings, and CI workflow as machine-readable sources of truth. Add one human-readable guide that lists all direct dependencies and operational services while linking to lock files for complete transitive graphs, then enforce the important pinned values through the existing PowerShell contract suite.

**Tech Stack:** Markdown, Windows PowerShell 5.1, Python/pip, Node.js/npm, GitHub Actions

---

### Task 1: Add A Failing Documentation Synchronization Contract

**Files:**
- Modify: `scripts/tests/ProjectEnvironment.Tests.ps1`
- Test target: `docs/dependencies.md`

- [ ] **Step 1: Add the dependency-guide contract test**

Insert this test next to the existing repository manifest contract:

```powershell
@{
    Name = "Dependency guide stays aligned with repository manifests"
    Body = {
        $manifest = Read-BootstrapManifest -Path $ManifestPath
        $resolvedModulePath = (Resolve-Path -LiteralPath $ModulePath).Path
        $projectRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $resolvedModulePath))
        $guidePath = Join-Path $projectRoot "docs\dependencies.md"
        Assert-True -Condition (Test-Path -LiteralPath $guidePath -PathType Leaf) -Message "Dependency guide is missing."
        $content = [System.IO.File]::ReadAllText($guidePath, [System.Text.Encoding]::UTF8)

        Assert-Contains -ExpectedSubstring ([string]$manifest.runtime.python.version) -Actual $content -Message "Python runtime version is missing from the dependency guide."
        Assert-Contains -ExpectedSubstring ([string]$manifest.runtime.node.version) -Actual $content -Message "Node runtime version is missing from the dependency guide."
        foreach ($model in @($manifest.release.models)) {
            Assert-Contains -ExpectedSubstring ([string]$model.filename) -Actual $content -Message "Model filename is missing from the dependency guide."
            Assert-Contains -ExpectedSubstring ([string]$model.bytes) -Actual $content -Message "Model size is missing from the dependency guide."
            Assert-Contains -ExpectedSubstring ([string]$model.sha256) -Actual $content -Message "Model hash is missing from the dependency guide."
        }

        foreach ($requiredText in @(
            "requirements-cpu.txt",
            "requirements-gpu.txt",
            "requirements-common.lock",
            "package-lock.json",
            "torch==2.11.0+cpu",
            "torch==2.11.0+cu128",
            "CUDA 12.8",
            "SQLite",
            "PostgreSQL",
            "Redis",
            "MinIO",
            "system FFmpeg",
            "CUDA Toolkit",
            "WSL",
            "Docker"
        )) {
            Assert-Contains -ExpectedSubstring $requiredText -Actual $content -Message ("Dependency guide is missing: " + $requiredText)
        }
    }
},
```

- [ ] **Step 2: Run the focused contract and verify it fails**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command ". .\scripts\tests\ProjectEnvironment.Tests.ps1; `$result=Invoke-ProjectEnvironmentTests; `$test=`$result.Results | Where-Object Name -eq 'Dependency guide stays aligned with repository manifests'; `$test; if (`$test.Passed) { exit 0 } else { exit 1 }"
```

Expected: FAIL with `Dependency guide is missing.` because `docs/dependencies.md` does not exist.

### Task 2: Write The Complete Dependency Manual

**Files:**
- Create: `docs/dependencies.md`
- Modify: `README.md`

- [ ] **Step 1: Document host and scenario requirements**

Add a top-level mode matrix for local GPU, local CPU, frontend-only, backend-only, training/evaluation, tests, and production. Record Windows 10/11 x64, PowerShell 5.1+, disk requirements, ports 8000/5173, a modern browser, optional NVIDIA driver, and network endpoints used by bootstrap.

- [ ] **Step 2: Document pinned runtimes and compute variants**

Record Python `3.10.11`, Node.js `24.18.0`, npm supplied by the Node archive, `torch==2.11.0+cpu`, `torchvision==0.26.0+cpu`, `torch==2.11.0+cu128`, and `torchvision==0.26.0+cu128`. Explain that CUDA 12.8 wheels need a compatible NVIDIA driver and `nvidia-smi`, while a separate CUDA Toolkit is not required.

- [ ] **Step 3: List every direct backend dependency**

Create categorized tables from `backend/requirements-core.txt` covering web/API, detection/video, data/migrations, optional cache/storage, auth, configuration/utilities, and tests. Include each exact package spec, its purpose, and whether local runtime, production, training, or tests require it. State that all 93 resolved non-device packages live in `backend/requirements-common.lock`.

- [ ] **Step 4: List every direct frontend dependency**

Create runtime and development tables from `frontend/package.json`, listing all 7 runtime dependencies and all 16 dev dependencies with declared version ranges and responsibilities. Link `frontend/package-lock.json` as the exact transitive npm graph installed by `npm ci`.

- [ ] **Step 5: Document services, models, datasets, and compatibility-only config**

Distinguish local SQLite from production PostgreSQL, Redis, and MinIO. State that production server versions are not pinned by the repository and must be selected and validated by the deployer. Include both model filenames, byte sizes, SHA-256 values, release URLs, source, purpose, and licensing. Explain that TT100K/GTSRB datasets are required only for preparation/training/evaluation, and that OpenAI/Qwen/Ollama/Baidu values are not required by current traffic-sign workflows.

- [ ] **Step 6: Add install, verification, and maintenance commands**

Include bootstrap commands for `auto`, `gpu`, and `cpu`; manual backend CPU/GPU installs; frontend `npm ci`; doctor, pytest, pip check, lint, Vitest, build, and PowerShell contract commands. Add a source-of-truth table telling maintainers which files to update for each dependency class.

- [ ] **Step 7: Link the guide from README**

Add this entry under `## 文档`:

```markdown
- [完整依赖与运行模式说明](docs/dependencies.md)
```

### Task 3: Make The Contract Pass And Verify The Repository

**Files:**
- Verify: `docs/dependencies.md`
- Verify: `README.md`
- Verify: `scripts/tests/ProjectEnvironment.Tests.ps1`

- [ ] **Step 1: Run the focused dependency-guide contract**

Run the focused PowerShell command from Task 1. Expected: PASS.

- [ ] **Step 2: Run documentation consistency checks**

Run:

```powershell
git diff --check
rg -n "3\.10\.11|24\.18\.0|2\.11\.0|tt100k-yolo11s-reference42|gtsrb-yolo11n-cls|requirements-common.lock|package-lock.json" docs/dependencies.md
```

Expected: no whitespace errors and every pinned dependency marker is present.

- [ ] **Step 3: Run all verification suites**

Run backend pytest and pip check, frontend lint/tests/build, and `scripts/tests/run.ps1`. Expected: all commands exit `0` and the PowerShell summary reports `Failed: 0`.

- [ ] **Step 4: Commit the dependency manual**

```powershell
git add README.md docs/dependencies.md scripts/tests/ProjectEnvironment.Tests.ps1 docs/superpowers/plans/2026-07-16-dependency-documentation.md
git commit -m "docs: add complete dependency reference"
```

- [ ] **Step 5: Push main and verify GitHub CI**

Push `main` without force, confirm the remote SHA matches local HEAD, and wait for Backend, Frontend, and Windows bootstrap GitHub Actions jobs to conclude `success`.
