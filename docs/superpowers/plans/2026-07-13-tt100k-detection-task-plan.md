# TT100K Detection Task Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect the trained TT100K `best.pt` checkpoint to the authenticated traffic-sign upload flow, persist detection tasks/results, and display real annotated results in the chat UI.

**Architecture:** A lazy, locked local YOLO detector converts Ultralytics output into framework-neutral data. A detection-task service registers the model, owns database transitions and annotated files, while the existing `sign-analyzer` routes provide backward-compatible create-task responses plus task history endpoints. The frontend preserves text summaries and renders structured live results.

**Tech Stack:** Python 3.10, FastAPI, SQLAlchemy, SQLite/PostgreSQL-compatible ORM, Ultralytics YOLO, Pillow, OpenCV, React 18, Zustand, Vitest.

**Portable path:** `$PROJECT_ROOT` denotes the repository root in all commands and examples.

---

## File Map

- Modify `backend/app/config/settings.py`: inference paths, limits, thresholds, device preference, and resolved path properties.
- Create `backend/app/services/yolo_detector.py`: checkpoint loading and framework-neutral prediction conversion.
- Create `backend/app/services/detection_task_service.py`: model registry, task lifecycle, persistence, and annotated file storage.
- Replace `backend/app/services/sign_analyzer_service.py`: compatibility import only; remove external/mock inference behavior.
- Modify `backend/app/api/sign_analyzer.py`: validated uploads, local task creation, compatibility responses, task queries.
- Modify `backend/app/entity/schemas.py`: task list/detail response objects used by the new GET endpoints.
- Create `backend/tests/test_yolo_detector.py`: detector conversion and error tests without loading the real checkpoint.
- Create `backend/tests/test_detection_task_service.py`: SQLite persistence and ownership tests with a fake detector.
- Create `backend/tests/test_sign_analyzer.py`: authenticated API validation and compatibility contract tests.
- Create `frontend/src/utils/signResults.js`: text summary formatter.
- Create `frontend/src/components/SignDetectionResult.jsx`: structured annotated result rendering.
- Modify `frontend/src/store/useStore.js`: retain structured detection data in the live assistant message.
- Modify `frontend/src/components/ChatArea.jsx`: render `sign_result` messages.
- Create `frontend/tests/utils/signResults.test.js`: summary contract tests.
- Create `frontend/tests/components/SignDetectionResult.test.js`: server-rendered result component tests.
- Modify `backend/.env.local.example` and `docs/local-development.md`: local model configuration and smoke commands.

### Task 1: Add Inference Settings

**Files:**
- Modify: `backend/app/config/settings.py`
- Modify: `backend/tests/test_local_mode.py`
- Modify: `backend/.env.local.example`

- [ ] **Step 1: Write the failing settings test**

Add assertions that a settings object resolves the model and output paths from
the backend directory and exposes the approved defaults:

```python
def test_local_yolo_settings_resolve_project_paths():
    settings = Settings(_env_file=None, APP_MODE="local")

    assert settings.yolo_model_path.name == "best.pt"
    assert settings.yolo_model_path.is_absolute()
    assert settings.detection_output_path.name == "detections"
    assert settings.YOLO_DEVICE == "auto"
    assert settings.YOLO_CONFIDENCE == 0.25
    assert settings.YOLO_IOU == 0.45
    assert settings.YOLO_IMAGE_SIZE == 640
    assert settings.YOLO_MAX_BATCH_IMAGES == 20
    assert settings.YOLO_MAX_IMAGE_BYTES == 10 * 1024 * 1024
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```powershell
Set-Location "$PROJECT_ROOT\backend"
.\.venv\Scripts\python.exe -m pytest tests/test_local_mode.py::test_local_yolo_settings_resolve_project_paths -q
```

Expected: failure because the YOLO settings/properties do not exist.

- [ ] **Step 3: Implement settings and resolved paths**

Add string/numeric settings plus backend-relative properties. Resolve the
runtime device as `0` when `YOLO_DEVICE=auto` and CUDA is available, otherwise
`cpu`; keep explicit `cpu` and numeric device values as overrides. Reject thresholds
outside `0..1` through Pydantic field constraints or explicit validation.

```python
BACKEND_DIR = Path(__file__).resolve().parents[2]

YOLO_MODEL_PATH: str = "../training/runs/tt100k_yolo11n_gpu/weights/best.pt"
YOLO_DEVICE: str = "auto"
YOLO_CONFIDENCE: float = 0.25
YOLO_IOU: float = 0.45
YOLO_IMAGE_SIZE: int = 640
YOLO_MAX_BATCH_IMAGES: int = 20
YOLO_MAX_IMAGE_BYTES: int = 10 * 1024 * 1024
DETECTION_OUTPUT_DIR: str = "./uploads/detections"

@property
def yolo_model_path(self) -> Path:
    path = Path(self.YOLO_MODEL_PATH).expanduser()
    return path.resolve() if path.is_absolute() else (BACKEND_DIR / path).resolve()

@property
def detection_output_path(self) -> Path:
    path = Path(self.DETECTION_OUTPUT_DIR).expanduser()
    return path.resolve() if path.is_absolute() else (BACKEND_DIR / path).resolve()
```

Add equivalent values to `.env.local.example`.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run `pytest tests/test_local_mode.py -q`; expect all local-mode tests to pass.

### Task 2: Build the Local YOLO Detector

**Files:**
- Create: `backend/app/services/yolo_detector.py`
- Create: `backend/tests/test_yolo_detector.py`

- [ ] **Step 1: Write detector contract tests**

Use a generated Pillow image and fake model/result objects. Verify that:

```python
prediction = detector.predict(image_bytes, confidence=0.3, iou=0.5, image_size=640)

assert prediction.width == 32
assert prediction.height == 24
assert prediction.inference_time_ms == 12.5
assert prediction.detections[0].class_id == 1
assert prediction.detections[0].class_name == "pl60"
assert prediction.detections[0].confidence == pytest.approx(0.91)
assert prediction.detections[0].bbox == (1.0, 2.0, 20.0, 22.0)
assert prediction.annotated_jpeg.startswith(b"\xff\xd8")
```

Also test that a missing checkpoint raises `ModelUnavailableError` and corrupt
bytes raise `InvalidImageError` without calling the model.

- [ ] **Step 2: Run tests and verify RED**

Run `pytest tests/test_yolo_detector.py -q`; expect import failure because the
module does not exist.

- [ ] **Step 3: Implement detector data classes and lazy loader**

Create immutable `DetectedObject` and `ImagePrediction` dataclasses, explicit
`ModelUnavailableError`/`InvalidImageError`, and `LocalYoloDetector`:

```python
@dataclass(frozen=True)
class DetectedObject:
    class_id: int
    class_name: str
    confidence: float
    bbox: tuple[float, float, float, float]

@dataclass(frozen=True)
class ImagePrediction:
    width: int
    height: int
    inference_time_ms: float
    detections: tuple[DetectedObject, ...]
    annotated_jpeg: bytes
```

Inject `model_factory` for tests, load `ultralytics.YOLO` only inside
`_get_model()`, use Pillow to decode input, pass `conf`, `iou`, `imgsz`,
`device`, and `verbose=False` to `predict`, then use `cv2.imencode(".jpg",
result.plot())` for annotated output. Hold one lock around model loading and
prediction.

- [ ] **Step 4: Run detector tests and verify GREEN**

Run `pytest tests/test_yolo_detector.py -q`; expect all detector tests to pass.

### Task 3: Persist Detection Tasks and Results

**Files:**
- Create: `backend/app/services/detection_task_service.py`
- Create: `backend/tests/test_detection_task_service.py`
- Replace: `backend/app/services/sign_analyzer_service.py`

- [ ] **Step 1: Write task-service persistence tests**

Create a fake detector that returns deterministic `ImagePrediction` values and
instantiate `DetectionTaskService(detector=fake, output_dir=tmp_path)`. Insert a
real test user, then assert:

```python
outcome = service.run_task(
    db=db_session,
    user_id=user.id,
    images=[DetectionInput(filename="road.jpg", content=image_bytes)],
    task_type="single",
    confidence=0.25,
    iou=0.45,
    image_size=640,
)

assert outcome.task.status == "completed"
assert outcome.task.total_images == 1
assert outcome.task.total_objects == 1
assert outcome.images[0]["annotated_image_url"].startswith("/uploads/detections/")
assert db_session.query(DetectionResult).filter_by(task_id=outcome.task.id).count() == 1
assert db_session.query(DetectionScene).filter_by(name="tt100k_traffic_signs").count() == 1
assert db_session.query(ModelVersion).filter_by(is_default=True).count() == 1
```

Add tests for all-image failure, partial batch failure, task listing by owner,
and 404 semantics for another user's task.

- [ ] **Step 2: Run tests and verify RED**

Run `pytest tests/test_detection_task_service.py -q`; expect import failure.

- [ ] **Step 3: Implement registry and task lifecycle**

Define `DetectionInput`, `DetectionTaskOutcome`, and `TaskNotFoundError`.
Implement:

Implement `ensure_registry(db)`, `run_task(db, user_id, images, task_type,
confidence, iou, image_size)`, `list_tasks(db, user_id, limit=50)`, and
`get_task(db, user_id, task_id)` as the public `DetectionTaskService` methods.

Use the detector's class names for the scene, create one default model version
per resolved checkpoint, commit a `processing` task before prediction, save
annotated files as safe JPEG names under `<output-dir>/<task-id>/`, add one
`DetectionResult` per object, and finalize totals/status. The compatibility
payload for each image must contain `filename`, `success`, `error`,
`traffic_signs`, `traffic_lights: []`, `annotated_image_url`, dimensions, and
timing.

- [ ] **Step 4: Remove mock inference from the compatibility module**

Replace `sign_analyzer_service.py` with an import alias to the real task service
or remove all runtime references to it. No production path may return
`_mock_analyze` output.

- [ ] **Step 5: Run task-service tests and verify GREEN**

Run `pytest tests/test_detection_task_service.py -q`; expect all persistence
tests to pass.

### Task 4: Connect the Authenticated API

**Files:**
- Modify: `backend/app/api/sign_analyzer.py`
- Modify: `backend/app/entity/schemas.py`
- Create: `backend/tests/test_sign_analyzer.py`

- [ ] **Step 1: Write API contract tests**

Authenticate a unique test user and monkeypatch the route-level task service
with a fake-backed instance. Verify:

```python
response = client.post(
    "/api/sign-analyzer/analyze",
    headers={"Authorization": f"Bearer {token}"},
    files={"image": ("road.jpg", jpeg_bytes, "image/jpeg")},
)
assert response.status_code == 200
payload = response.json()
assert payload["success"] is True
assert payload["data"]["task_id"] > 0
assert payload["data"]["traffic_signs"][0]["type"] == "pl60"
assert payload["data"]["annotated_image_url"].startswith("/uploads/detections/")
```

Test no-token `401`, unsupported type `400`, oversize `400`, empty/corrupt
upload `400`, batch compatibility totals, task list ownership, and task detail
ownership.

- [ ] **Step 2: Run API tests and verify RED**

Run `pytest tests/test_sign_analyzer.py -q`; expect contract failures against
the current external/mock API.

- [ ] **Step 3: Implement bounded upload parsing**

Replace temporary-file processing with in-memory `DetectionInput` creation.
Normalize base names, validate allowed image suffixes, enforce
`YOLO_MAX_IMAGE_BYTES`, cap expanded image count at
`YOLO_MAX_BATCH_IMAGES`, and bound ZIP extraction by both entry count and total
uncompressed bytes. Raise
`HTTPException(status_code=400, detail=message)` for validation errors.

- [ ] **Step 4: Delegate create-task endpoints**

Call `detection_task_service.run_task` with the database, authenticated user ID,
normalized images, task type, confidence, IoU, and image size; map model
missing/incompatible model
errors to HTTP 503, and preserve the existing response envelope. The single
endpoint copies the first image result into `data`; the batch endpoint returns
`results`, `total_images`, `total_signs`, and `total_lights=0`.

- [ ] **Step 5: Add task query endpoints**

Add authenticated list and detail endpoints scoped by `current_user.id`. Build
responses from the existing `DetectionTaskResponse`,
`DetectionResultResponse`, and `DetectionTaskDetail` schemas, including
`scene_name` and flat object results.

- [ ] **Step 6: Run API and backend tests**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest tests/test_sign_analyzer.py -q
.\.venv\Scripts\python.exe -m pytest -q
```

Expected: focused API tests and the full backend suite pass.

### Task 5: Render Structured Results in the Frontend

**Files:**
- Create: `frontend/src/utils/signResults.js`
- Create: `frontend/src/components/SignDetectionResult.jsx`
- Modify: `frontend/src/store/useStore.js`
- Modify: `frontend/src/components/ChatArea.jsx`
- Create: `frontend/tests/utils/signResults.test.js`
- Create: `frontend/tests/components/SignDetectionResult.test.js`

- [ ] **Step 1: Write formatter and rendering tests**

Export `formatSignResult` and verify it includes task ID, image count, canonical
class code, and percentage confidence. Use `react-dom/server` to assert the
result component renders the annotated URL, filename, `pl60`, `91%`, and a
per-image error without requiring a browser.

- [ ] **Step 2: Run frontend tests and verify RED**

Run `npm run test:run`; expect module-not-found failures for the new utility and
component.

- [ ] **Step 3: Implement summary utility and result component**

The utility accepts the API `data` object and returns persisted plain text. The
component renders one stable `figure` per image with the annotated image when
available and a compact detection list. It must handle zero detections and
failed images without shifting surrounding chat layout.

- [ ] **Step 4: Store and render structured messages**

In `recognizeSigns`, create the assistant message as:

```javascript
{
  id: (Date.now() + 1).toString(),
  conversationId,
  role: 'assistant',
  content: resultContent,
  createdAt: new Date(),
  type: 'sign_result',
  resultData: data.data,
}
```

In `ChatArea`, render `SignDetectionResult` for `sign_result` before the generic
text bubble branch.

- [ ] **Step 5: Run frontend tests and build**

Run `npm run test:run` and `npm run build`; expect both to pass.

### Task 6: Real Checkpoint Smoke Test and Documentation

**Files:**
- Modify: `docs/local-development.md`
- Modify: `README.md`

- [ ] **Step 1: Run a direct detector smoke test**

Set project-local writable cache directories and run a labeled TT100K
validation image through `LocalYoloDetector`. Assert the loaded model path ends
in `tt100k_yolo11n_gpu/weights/best.pt`, the prediction contains no hard-coded
`限速标志`/signal-light mock data, annotated JPEG bytes are non-empty, and the
selected device is CUDA `0` when CUDA is available (otherwise CPU).

- [ ] **Step 2: Run an authenticated HTTP smoke test**

Start the backend in `APP_MODE=local`, register/login a smoke user, upload the
chosen validation image to `/api/sign-analyzer/analyze`, then verify:

- HTTP 200 and a numeric `task_id`
- model name/path identifies the TT100K checkpoint
- `traffic_lights` is empty
- task detail returns the same owner/task ID
- the annotated URL returns HTTP 200
- SQLite contains the scene, model version, task, and matching result rows

- [ ] **Step 3: Document model configuration and usage**

Add model path/device/threshold environment variables, authenticated curl or
PowerShell upload examples, response/task endpoints, CPU first-request latency,
and the 45-class canonical-code limitation to `docs/local-development.md`.
Link the model-inference section from the root README.

- [ ] **Step 4: Run final verification**

Run:

```powershell
Set-Location "$PROJECT_ROOT\backend"
$env:YOLO_CONFIG_DIR="$PROJECT_ROOT\.venv\cache\yolo"
$env:MPLCONFIGDIR="$PROJECT_ROOT\.venv\cache\matplotlib"
.\.venv\Scripts\python.exe -m pytest -q
.\.venv\Scripts\python.exe -m pip check

Set-Location "$PROJECT_ROOT\frontend"
npm run test:run
npm run build
```

Expected: all tests pass, pip reports no broken requirements, and Vite builds
successfully. Recheck `/api/health/detail`, `/api/sign-analyzer/tasks`, both dev
server ports, and `git diff --check` before reporting completion.
