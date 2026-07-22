# Dependency Documentation Design

## Goal

Create one authoritative dependency guide that tells a new contributor or
operator exactly what each TrafficAgent subsystem needs, which dependencies are
mandatory for each deployment mode, and which repository files remain the
machine-readable source of truth.

## Deliverables

- Add `docs/dependencies.md` as the human-readable dependency manual.
- Add the manual to the documentation section in `README.md`.
- Extend the existing PowerShell repository contract tests so pinned runtime,
  compute, model, and lock-file references cannot silently diverge from the
  dependency manual.

## Dependency Boundaries

The manual is organized by operational boundary rather than as one flat package
list:

1. Windows host, browser, disk, ports, network access, and optional NVIDIA GPU.
2. Repository-local Python and Node.js runtimes installed by bootstrap.
3. CPU and CUDA 12.8 PyTorch variants.
4. Backend web, inference, data, storage, authentication, configuration, video,
   and test dependencies.
5. Frontend runtime and development dependencies.
6. Local SQLite mode and production PostgreSQL, Redis, and MinIO services.
7. Model artifacts, hashes, sizes, sources, and license restrictions.
8. Dataset preparation, model training, evaluation, and promotion tools.
9. CI and local verification dependencies.

Each dependency table records the pinned or declared version, responsibility,
and the modes that require it. The document includes a scenario matrix for a
local GPU install, local CPU install, frontend-only work, backend-only work,
training/evaluation, tests, and production deployment.

## Sources Of Truth

The document derives versions and installation behavior from:

- `scripts/config/bootstrap-manifest.json` for Python, Node.js, and model assets;
- `backend/requirements-core.txt` for direct Python packages;
- `backend/requirements-cpu.txt` and `backend/requirements-gpu.txt` for PyTorch;
- `backend/requirements-common.lock` for the complete resolved Python graph;
- `frontend/package.json` for direct frontend packages and scripts;
- `frontend/package-lock.json` for the complete resolved npm graph;
- `backend/.env.local.example` and `backend/app/config/settings.py` for local and
  production service requirements;
- `.github/workflows/ci.yml` for CI runtime and verification behavior.

The manual does not duplicate every transitive package from the lock files.
Doing so would create a second lock file that can become stale. Instead, it
lists every direct dependency and links to both complete lock graphs.

## Accuracy Rules

- Default Windows local mode requires SQLite only; PostgreSQL, Redis, and MinIO
  are explicitly marked as production-only unless enabled by configuration.
- OpenAI, Qwen, and Ollama values retained in the broad example environment are
  documented as compatibility-only configuration, not current runtime
  dependencies.
- Baidu API credentials are optional configuration fields and are not required
  by the traffic-sign workflows currently exposed by the application.
- `imageio-ffmpeg` supplies the video encoder binary, so a system FFmpeg install
  is not required.
- CUDA wheels include the required CUDA user-space runtime; users need a
  compatible NVIDIA driver and working `nvidia-smi`, not a separately installed
  CUDA Toolkit.
- WSL, Docker, Microsoft Store, administrator access, PostgreSQL, Redis, and
  MinIO are not requirements for the default local workflow.
- Model and TT100K licensing restrictions remain visible next to model download
  requirements rather than being deferred only to the license document.

## Contract Verification

Extend `scripts/tests/ProjectEnvironment.Tests.ps1` with one focused test that
reads `docs/dependencies.md` and checks it contains:

- Python `3.10.11` and Node.js `24.18.0` from the bootstrap manifest;
- CPU and CUDA 12.8 requirement entry points and PyTorch `2.11.0`;
- both model filenames, byte sizes, and SHA-256 digests;
- `requirements-common.lock` and `package-lock.json` references;
- SQLite, PostgreSQL, Redis, MinIO, system FFmpeg, CUDA Toolkit, WSL, and Docker
  mode distinctions.

The existing full PowerShell tests, backend tests, frontend tests, dependency
checks, production build, and `git diff --check` remain the completion gates.
