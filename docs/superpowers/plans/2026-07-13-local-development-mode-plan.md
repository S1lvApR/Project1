# Local Development Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the FastAPI backend on Windows with SQLite and local files when WSL, Docker, PostgreSQL, Redis, and MinIO are unavailable, without changing the production profile.

**Architecture:** Add an explicit `APP_MODE=local` profile to settings. Build the SQLAlchemy engine from the resolved URL, use SQLite-specific connection options only for SQLite, create ORM tables during local startup, and skip optional Redis/MinIO initialization and checks when their flags are disabled. Keep the existing PostgreSQL and external-service defaults for production.

**Tech Stack:** Python 3.10, FastAPI, Pydantic Settings, SQLAlchemy, SQLite, pytest.

---

### Task 1: Add Profile Configuration Tests

**Files:**
- Create: `backend/tests/test_local_mode.py`
- Test: `backend/tests/test_local_mode.py`

- [ ] **Step 1: Write failing tests**

Add tests for local settings resolving `sqlite:///./data/local.db`, disabling Redis and MinIO by default, honoring explicit `DATABASE_URL`, and keeping production defaults when `APP_MODE=production`.

- [ ] **Step 2: Run the focused tests**

Run: `backend\\.venv\\Scripts\\python.exe -X utf8 -m pytest tests/test_local_mode.py -v` from `backend`.

Expected: failures because the settings profile fields and resolved URL do not exist yet.

- [ ] **Step 3: Implement the smallest settings API**

Add `APP_MODE`, optional `DATABASE_URL`, optional `REDIS_ENABLED`, optional `MINIO_ENABLED`, `is_local`, `database_url`, `redis_enabled`, and `minio_enabled` to `app/config/settings.py`.

- [ ] **Step 4: Re-run the focused tests**

Run the same pytest command and verify all profile tests pass.

### Task 2: Build a SQLite-Compatible Engine

**Files:**
- Modify: `backend/app/database/session.py`
- Test: `backend/tests/test_local_mode.py`

- [ ] **Step 1: Add the failing engine test**

Test that `build_engine(local_settings)` creates a SQLite engine with `check_same_thread=False` and that the local database parent directory is created.

- [ ] **Step 2: Run the test and verify the expected failure**

Run: `backend\\.venv\\Scripts\\python.exe -X utf8 -m pytest tests/test_local_mode.py::test_local_engine -v` from `backend`.

Expected: failure because `build_engine` does not exist.

- [ ] **Step 3: Implement the engine factory**

Create `build_engine(settings)` in `app/database/session.py`. Use SQLite `connect_args={"check_same_thread": False}` and omit PostgreSQL pool-only options for SQLite. Keep the current pool settings for non-SQLite URLs. Construct the module-level engine through this factory.

- [ ] **Step 4: Verify the engine test**

Run the focused test and confirm it passes without changing the production URL behavior.

### Task 3: Initialize Local ORM Tables at Startup

**Files:**
- Modify: `backend/app/database/session.py`
- Modify: `backend/main.py`
- Test: `backend/tests/test_local_mode.py`

- [ ] **Step 1: Add a failing schema initialization test**

Use a temporary SQLite URL and assert that `initialize_local_database` creates the ORM tables only for local settings.

- [ ] **Step 2: Run the test and verify it fails for the missing initializer**

Run: `backend\\.venv\\Scripts\\python.exe -X utf8 -m pytest tests/test_local_mode.py::test_local_database_initialization -v` from `backend`.

- [ ] **Step 3: Implement local initialization**

Import ORM models inside `initialize_local_database`, call `Base.metadata.create_all(bind=engine)` only when `settings.is_local`, and call it from the FastAPI lifespan before the scheduler starts. Do not auto-create production tables.

- [ ] **Step 4: Verify schema creation and production guard**

Run the focused tests and confirm the local SQLite file contains tables while a production settings object does not trigger auto-creation.

### Task 4: Make Redis and MinIO Optional

**Files:**
- Modify: `backend/main.py`
- Modify: `backend/app/api/health.py`
- Test: `backend/tests/test_local_mode.py`

- [ ] **Step 1: Add a failing optional-service health test**

Test the health response using local settings and assert Redis and MinIO are reported as `disabled`, while the database remains checked.

- [ ] **Step 2: Run the test and verify it fails**

Run: `backend\\.venv\\Scripts\\python.exe -X utf8 -m pytest tests/test_local_mode.py::test_optional_services_disabled -v` from `backend`.

- [ ] **Step 3: Implement the guards**

Skip `init_minio()` when `settings.minio_enabled` is false. In detailed health, report disabled optional services without making network calls and count `disabled` as non-degraded. Keep the current checks when flags are enabled.

- [ ] **Step 4: Verify the focused health test**

Run the focused test and confirm no Redis or MinIO network request is made in local mode.

### Task 5: Add Local Configuration and Documentation

**Files:**
- Create: `backend/.env.local.example`
- Create: `docs/local-development.md`

- [ ] **Step 1: Add the local environment template**

Document `APP_MODE=local`, the SQLite URL, disabled optional services, local cache directories, and the existing JWT development value without changing the user's ignored `backend/.env`.

- [ ] **Step 2: Document startup commands**

Document backend activation, local cache variables, `uvicorn` startup, frontend `npm run dev`, database location, and the feature limitations of local mode.

- [ ] **Step 3: Check documentation consistency**

Verify every variable in the template matches `Settings` and every command uses the project-local Python environment.

### Task 6: Full Verification

**Files:**
- No additional source files.

- [ ] **Step 1: Run all backend tests**

Run: `backend\\.venv\\Scripts\\python.exe -X utf8 -m pytest` from `backend`.

Expected: all existing and local-mode tests pass.

- [ ] **Step 2: Run dependency and import checks**

Run `python -X utf8 -m pip check` and import FastAPI, SQLAlchemy, Pydantic Settings, Ultralytics, OpenCV, and Pillow with writable cache variables.

- [ ] **Step 3: Run frontend tests and build**

Run `npm run test:run` and `npm run build` from `frontend`.

- [ ] **Step 4: Smoke-test the local profile**

Start the backend with `APP_MODE=local`, request `/api/health` and `/api/health/detail`, verify the SQLite database is created, and confirm no PostgreSQL/Redis/MinIO listener is required.
